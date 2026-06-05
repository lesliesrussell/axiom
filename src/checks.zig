// axiom-s0w
// Predicate-info registry plus determinism and mode checking. Split out of
// engine.zig; part of the engine module. The registry is owned by Engine
// (pred_info field); these functions operate on it.
const std = @import("std");
const types = @import("types.zig");
const Term = types.Term;
const Goal = types.Goal;
const Clause = types.Clause;
const PredicateInfo = types.PredicateInfo;
const ModeDecl = types.ModeDecl;
const output = @import("output.zig");
const writeRaw = output.writeRaw;
const uintToStr = output.uintToStr;

pub const PredInfoMap = std.StringHashMap(PredicateInfo);

/// Register/validate predicate info for a newly added clause.
pub fn recordClause(pred_info: *PredInfoMap, allocator: std.mem.Allocator, clause: Clause) !void {
    const key = try concatPredKey(allocator, clause.head.functor, @intCast(clause.head.args.len));
    if (pred_info.get(key)) |existing| {
        // Check for determinism conflicts
        if (clause.det != .unspecified and existing.det != .unspecified and clause.det != existing.det) {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Error: Conflicting determinism for {s}/{d}: both '{c}' and '{c}' used.\n", .{
                clause.head.functor,
                clause.head.args.len,
                existing.det.marker() orelse '?',
                clause.det.marker() orelse '?',
            }) catch "Error: Conflicting determinism.\n";
            writeRaw(msg);
        }
        // Update det if this clause specifies and existing doesn't
        if (clause.det != .unspecified and existing.det == .unspecified) {
            try pred_info.put(key, .{
                .name = clause.head.functor,
                .arity = @intCast(clause.head.args.len),
                .det = clause.det,
                .arg_modes = existing.arg_modes,
                .source_file = existing.source_file,
                .first_line = existing.first_line,
            });
        }
    } else {
        try pred_info.put(key, .{
            .name = clause.head.functor,
            .arity = @intCast(clause.head.args.len),
            .det = clause.det,
            .arg_modes = null,
            .source_file = null,
            .first_line = 0,
        });
    }
}

pub fn registerMode(pred_info: *PredInfoMap, allocator: std.mem.Allocator, decl: ModeDecl) !void {
    const key = try concatPredKey(allocator, decl.pred_name, @intCast(decl.arg_modes.len));
    if (pred_info.get(key)) |existing| {
        // Check det compatibility
        if (decl.det != .unspecified and existing.det != .unspecified and decl.det != existing.det) {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Error: Mode declaration for {s}/{d} says '{c}' but clause uses '{c}'.\n", .{
                decl.pred_name,
                decl.arg_modes.len,
                decl.det.marker() orelse '?',
                existing.det.marker() orelse '?',
            }) catch "Error: conflicting mode/det.\n";
            writeRaw(msg);
        }
        // Update
        try pred_info.put(key, .{
            .name = decl.pred_name,
            .arity = @intCast(decl.arg_modes.len),
            .det = if (decl.det != .unspecified) decl.det else existing.det,
            .arg_modes = decl.arg_modes,
            .source_file = existing.source_file,
            .first_line = existing.first_line,
        });
    } else {
        try pred_info.put(key, .{
            .name = decl.pred_name,
            .arity = @intCast(decl.arg_modes.len),
            .det = decl.det,
            .arg_modes = decl.arg_modes,
            .source_file = null,
            .first_line = 0,
        });
    }
}

pub fn getPredInfo(pred_info: *const PredInfoMap, name: []const u8, arity: u8) ?PredicateInfo {
    // Manual key build — no std.fmt
    var buf: [128]u8 = undefined;
    if (name.len + 4 > buf.len) return null;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = '/';
    var num_buf: [4]u8 = undefined;
    const num_str = uintToStr(arity, &num_buf);
    @memcpy(buf[name.len + 1 ..][0..num_str.len], num_str);
    const key = buf[0 .. name.len + 1 + num_str.len];
    return pred_info.get(key);
}

/// Run determinism and mode checks on all loaded predicates
pub fn runChecks(pred_info: *const PredInfoMap, clauses: []const Clause) !void {
    var iter = pred_info.iterator();
    while (iter.next()) |entry| {
        const info = entry.value_ptr.*;
        if (info.det == .unspecified) continue;

        // Count clauses for this predicate
        var clause_count: usize = 0;
        for (clauses) |clause| {
            if (std.mem.eql(u8, clause.head.functor, info.name) and clause.head.args.len == info.arity) {
                clause_count += 1;
            }
        }

        // Det check: warn if multiple clauses for det predicate
        if (info.det == .det and clause_count > 1) {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Warning: {s}/{d} is declared det (!) but has {d} clauses — may produce multiple solutions.\n", .{ info.name, info.arity, clause_count }) catch continue;
            writeRaw(msg);
        }

        // Semidet check
        if (info.det == .semidet and clause_count > 1) {
            var buf2: [256]u8 = undefined;
            const msg2 = std.fmt.bufPrint(&buf2, "Warning: {s}/{d} is declared semidet (?) but has {d} clauses — may produce multiple solutions.\n", .{ info.name, info.arity, clause_count }) catch continue;
            writeRaw(msg2);
        }

        // Mode check info
        if (info.arg_modes) |modes| {
            _ = modes;
            var buf3: [256]u8 = undefined;
            const msg3 = std.fmt.bufPrint(&buf3, "  {s}/{d}: modes declared, runtime checking active.\n", .{ info.name, info.arity }) catch continue;
            writeRaw(msg3);
        }
    }
}

fn concatPredKey(allocator: std.mem.Allocator, name: []const u8, arity: u8) ![]const u8 {
    // Build "name/N" without std.fmt.allocPrint
    var num_buf: [4]u8 = undefined;
    const num_str = uintToStr(arity, &num_buf);
    const total_len = name.len + 1 + num_str.len;
    const buf = try allocator.alloc(u8, total_len);
    @memcpy(buf[0..name.len], name);
    buf[name.len] = '/';
    @memcpy(buf[name.len + 1 ..][0..num_str.len], num_str);
    return buf;
}

// axiom-d4s
// Unsafe-negation lint: a negated goal is safe when every variable in it
// also appears in an earlier positive body goal. Head occurrences do not
// count — callers may leave head variables unbound (e.g. "Who" queries),
// which makes \+ flounder.
pub fn lintNegation(allocator: std.mem.Allocator, clauses: []const Clause) void {
    for (clauses) |clause| {
        var bound = std.StringHashMap(void).init(allocator);
        defer bound.deinit();

        for (clause.body) |goal| {
            switch (goal) {
                .call => |c| collectVars(.{ .compound = c }, &bound),
                .not => |inner| switch (inner.*) {
                    .call => |c| reportUnbound(c, &bound, clause),
                    else => {},
                },
                .cut => {},
            }
        }
    }
}

fn collectVars(term: Term, bound: *std.StringHashMap(void)) void {
    switch (term) {
        .variable => |name| bound.put(name, {}) catch {},
        .compound => |c| for (c.args) |arg| collectVars(arg, bound),
        .list => |l| {
            collectVars(l.head.*, bound);
            collectVars(l.tail.*, bound);
        },
        else => {},
    }
}

fn reportUnbound(c: Term.Compound, bound: *const std.StringHashMap(void), clause: Clause) void {
    for (c.args) |arg| {
        if (firstUnboundVar(arg, bound)) |name| {
            writeRaw("Warning: negation on unbound variable ");
            writeRaw(name);
            writeRaw(" in:\n  ");
            if (clause.source_text.len > 0) {
                writeRaw(clause.source_text);
            } else {
                writeRaw(clause.head.functor);
                writeRaw("(...) rule");
            }
            writeRaw("\nSuggestion: bind ");
            writeRaw(name);
            writeRaw(" with a positive condition earlier in the rule body.\n");
            return; // one warning per negated goal
        }
    }
}

fn firstUnboundVar(term: Term, bound: *const std.StringHashMap(void)) ?[]const u8 {
    switch (term) {
        .variable => |name| return if (bound.contains(name)) null else name,
        .compound => |c| {
            for (c.args) |arg| {
                if (firstUnboundVar(arg, bound)) |n| return n;
            }
            return null;
        },
        .list => |l| {
            if (firstUnboundVar(l.head.*, bound)) |n| return n;
            return firstUnboundVar(l.tail.*, bound);
        },
        else => return null,
    }
}
