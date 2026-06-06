// axiom-s0w
// Substitutions and unification — the core of resolution. Split out of
// engine.zig; part of the engine module (re-exported from engine.zig).
const std = @import("std");
const types = @import("types.zig");
const Term = types.Term;

pub const Binding = struct {
    name: []const u8,
    value: Term,
};

pub const Substitution = struct {
    bindings: std.StringHashMap(Term),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Substitution {
        return .{
            .bindings = std.StringHashMap(Term).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn clone(self: *const Substitution) !Substitution {
        var new: Substitution = .{
            .bindings = std.StringHashMap(Term).init(self.allocator),
            .allocator = self.allocator,
        };
        var iter = self.bindings.iterator();
        while (iter.next()) |entry| {
            try new.bindings.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        return new;
    }

    pub fn bind(self: *Substitution, name: []const u8, value: Term) !void {
        try self.bindings.put(name, value);
    }

    pub fn lookup(self: *const Substitution, name: []const u8) ?Term {
        return self.bindings.get(name);
    }

    pub fn walk(self: *const Substitution, term: Term) Term {
        var current = term;
        while (true) {
            switch (current) {
                .variable => |name| {
                    if (self.lookup(name)) |val| {
                        current = val;
                    } else {
                        return current;
                    }
                },
                else => return current,
            }
        }
    }

    pub fn deepWalk(self: *const Substitution, term: Term, allocator: std.mem.Allocator) !Term {
        const walked = self.walk(term);
        switch (walked) {
            .variable => return walked,
            .atom => return walked,
            .integer => return walked,
            .nil => return walked,
            .compound => |c| {
                const new_args = try allocator.alloc(Term, c.args.len);
                for (c.args, 0..) |arg, i| {
                    new_args[i] = try self.deepWalk(arg, allocator);
                }
                return .{ .compound = .{ .functor = c.functor, .args = new_args } };
            },
            .list => |l| {
                const new_head = try allocator.create(Term);
                new_head.* = try self.deepWalk(l.head.*, allocator);
                const new_tail = try allocator.create(Term);
                new_tail.* = try self.deepWalk(l.tail.*, allocator);
                return .{ .list = .{ .head = new_head, .tail = new_tail } };
            },
        }
    }
};

// axiom-sek
/// Does variable `name` occur in `term` under the current bindings?
/// Guards unify against cyclic bindings (X = [X]) that would otherwise
/// send deepWalk, rename, and printing into unbounded recursion.
fn occurs(name: []const u8, term: Term, subst: *const Substitution) bool {
    const walked = subst.walk(term);
    switch (walked) {
        .variable => |v| return std.mem.eql(u8, v, name),
        .atom, .integer, .nil => return false,
        .compound => |c| {
            for (c.args) |arg| {
                if (occurs(name, arg, subst)) return true;
            }
            return false;
        },
        .list => |l| return occurs(name, l.head.*, subst) or occurs(name, l.tail.*, subst),
    }
}

pub fn unify(t1: Term, t2: Term, subst: *Substitution) !bool {
    const a = subst.walk(t1);
    const b = subst.walk(t2);

    const a_tag: @typeInfo(Term).@"union".tag_type.? = a;
    const b_tag: @typeInfo(Term).@"union".tag_type.? = b;

    // axiom-sek: X with X is trivially true — binding X→X would make
    // walk() loop forever
    if (a_tag == .variable and b_tag == .variable and std.mem.eql(u8, a.variable, b.variable)) {
        return true;
    }

    if (a_tag == .variable) {
        if (occurs(a.variable, b, subst)) return false; // axiom-sek
        try subst.bind(a.variable, b);
        return true;
    }
    if (b_tag == .variable) {
        if (occurs(b.variable, a, subst)) return false; // axiom-sek
        try subst.bind(b.variable, a);
        return true;
    }

    if (a_tag != b_tag) return false;

    switch (a) {
        .atom => return std.mem.eql(u8, a.atom, b.atom),
        .integer => return a.integer == b.integer,
        .nil => return true,
        .compound => {
            if (!std.mem.eql(u8, a.compound.functor, b.compound.functor)) return false;
            if (a.compound.args.len != b.compound.args.len) return false;
            for (a.compound.args, b.compound.args) |aa, bb| {
                if (!try unify(aa, bb, subst)) return false;
            }
            return true;
        },
        .list => {
            if (!try unify(a.list.head.*, b.list.head.*, subst)) return false;
            return try unify(a.list.tail.*, b.list.tail.*, subst);
        },
        .variable => unreachable,
    }
}
