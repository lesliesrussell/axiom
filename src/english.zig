// axiom-xec
// Canonical English pretty-printer: a total, deterministic mapping from
// desugared clauses back to controlled English. Desugaring is lossy
// ("X has role admin." and "X is a role of admin." both produce
// role(X, admin)), so this module picks ONE canonical surface form per
// logical shape — logically equivalent clauses always render identically.
//
// Shapes without an English mapping (arity >= 3, cut) fall back to raw
// functor form, marked "% internal:" — display-only, not re-parseable.
const std = @import("std");
const types = @import("types.zig");
const Term = types.Term;
const Goal = types.Goal;
const Clause = types.Clause;

const infix_builtins = [_][]const u8{ "same_as", "less_than", "greater_than", "equal", "member_of" };

/// Render a clause as one canonical English sentence. Caller owns the
/// result (allocated with `allocator`).
pub fn clauseToEnglish(allocator: std.mem.Allocator, clause: Clause) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    var w = Writer{ .allocator = allocator, .buf = &buf };

    if (!isFullyMappable(clause)) {
        try w.put("% internal: ");
        try w.rawClause(clause);
        return buf.toOwnedSlice(allocator);
    }

    try w.compoundEnglish(clause.head, false);
    if (clause.det.marker()) |m| try w.putByte(m);

    if (clause.body.len > 0) {
        try w.put(" if ");
        for (clause.body, 0..) |goal, i| {
            if (i > 0) try w.put(" and ");
            switch (goal) {
                .call => |c| try w.compoundEnglish(c, false),
                .not => |inner| switch (inner.*) {
                    .call => |c| try w.compoundEnglish(c, true),
                    else => unreachable, // excluded by isFullyMappable
                },
                .cut => unreachable,
            }
        }
    }
    try w.putByte('.');
    return buf.toOwnedSlice(allocator);
}

/// Render a single (typically ground) goal compound as canonical English
/// without the trailing period — used for decision evidence. axiom-i01
pub fn goalToEnglish(allocator: std.mem.Allocator, c: Term.Compound) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    var w = Writer{ .allocator = allocator, .buf = &buf };
    if (compoundMappable(c)) {
        try w.compoundEnglish(c, false);
    } else {
        try w.rawCompound(c);
    }
    return buf.toOwnedSlice(allocator);
}

/// False when any part of the clause needs the raw-functor fallback.
pub fn isFullyMappable(clause: Clause) bool {
    if (!compoundMappable(clause.head)) return false;
    for (clause.body) |goal| {
        switch (goal) {
            .call => |c| if (!compoundMappable(c)) return false,
            .not => |inner| switch (inner.*) {
                .call => |c| if (!negatedMappable(c)) return false,
                else => return false,
            },
            .cut => return false,
        }
    }
    return true;
}

fn compoundMappable(c: Term.Compound) bool {
    if (std.mem.startsWith(u8, c.functor, "can_")) return c.args.len == 1;
    return c.args.len == 1 or c.args.len == 2;
}

fn negatedMappable(c: Term.Compound) bool {
    // there is no negated "can" surface form
    return !std.mem.startsWith(u8, c.functor, "can_") and compoundMappable(c);
}

fn isInfixBuiltin(functor: []const u8) bool {
    for (infix_builtins) |b| {
        if (std.mem.eql(u8, functor, b)) return true;
    }
    return false;
}

const Writer = struct {
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),

    fn put(self: *Writer, s: []const u8) !void {
        try self.buf.appendSlice(self.allocator, s);
    }

    fn putByte(self: *Writer, b: u8) !void {
        try self.buf.append(self.allocator, b);
    }

    fn putInt(self: *Writer, v: i64) !void {
        var tmp: [24]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch return;
        try self.put(s);
    }

    /// Canonical English for one goal compound. `negated` renders the
    /// "is not" forms used in rule bodies.
    fn compoundEnglish(self: *Writer, c: Term.Compound, negated: bool) !void {
        // X can V.  (negated can is excluded by negatedMappable)
        if (std.mem.startsWith(u8, c.functor, "can_") and c.args.len == 1) {
            try self.term(c.args[0]);
            try self.put(" can ");
            try self.put(c.functor["can_".len..]);
            return;
        }
        // X is [not] <builtin> Y.
        if (c.args.len == 2 and isInfixBuiltin(c.functor)) {
            try self.term(c.args[0]);
            try self.put(if (negated) " is not " else " is ");
            try self.put(c.functor);
            try self.putByte(' ');
            try self.term(c.args[1]);
            return;
        }
        // X is [not] a p [of Y].
        if (c.args.len == 1) {
            try self.term(c.args[0]);
            try self.put(if (negated) " is not a " else " is a ");
            try self.put(c.functor);
            return;
        }
        // binary
        try self.term(c.args[0]);
        try self.put(if (negated) " is not a " else " is a ");
        try self.put(c.functor);
        try self.put(" of ");
        try self.term(c.args[1]);
    }

    fn term(self: *Writer, t: Term) !void {
        switch (t) {
            .atom => |a| try self.put(a),
            .variable => |v| try self.put(v),
            .integer => |v| try self.putInt(v),
            .nil => try self.put("[]"),
            .compound => |c| try self.rawCompound(c),
            .list => |l| {
                try self.putByte('[');
                try self.term(l.head.*);
                var tail = l.tail;
                while (true) {
                    switch (tail.*) {
                        .list => |next| {
                            try self.put(", ");
                            try self.term(next.head.*);
                            tail = next.tail;
                        },
                        .nil => break,
                        else => {
                            try self.put(" | ");
                            try self.term(tail.*);
                            break;
                        },
                    }
                }
                try self.putByte(']');
            },
        }
    }

    // ── raw fallback ────────────────────────────────────────────────

    fn rawClause(self: *Writer, clause: Clause) !void {
        try self.rawCompound(clause.head);
        if (clause.det.marker()) |m| try self.putByte(m);
        if (clause.body.len > 0) {
            try self.put(" :- ");
            for (clause.body, 0..) |goal, i| {
                if (i > 0) try self.put(", ");
                try self.rawGoal(goal);
            }
        }
        try self.putByte('.');
    }

    fn rawGoal(self: *Writer, goal: Goal) std.mem.Allocator.Error!void {
        switch (goal) {
            .call => |c| try self.rawCompound(c),
            .not => |inner| {
                try self.put("\\+ ");
                try self.rawGoal(inner.*);
            },
            .cut => try self.putByte('!'),
        }
    }

    fn rawCompound(self: *Writer, c: Term.Compound) std.mem.Allocator.Error!void {
        try self.put(c.functor);
        try self.putByte('(');
        for (c.args, 0..) |arg, i| {
            if (i > 0) try self.put(", ");
            try self.term(arg);
        }
        try self.putByte(')');
    }
};
