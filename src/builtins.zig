// axiom-s0w
// Built-in predicates for both solve (all-solutions) and check (yes/no)
// evaluation. Split out of engine.zig; part of the engine module. Mutually
// recursive with Engine.solveGoalsAll / Engine.checkGoals.
const std = @import("std");
const types = @import("types.zig");
const Term = types.Term;
const Goal = types.Goal;
const substitution = @import("substitution.zig");
const Substitution = substitution.Substitution;
const unify = substitution.unify;
const output = @import("output.zig");
const traceCompound = output.traceCompound;
const writeRaw = output.writeRaw;

// axiom-bjr: comparisons on ground non-integers silently fail — a ship is
// not a number, and "No." hides the type confusion. Warn once per call.
fn warnNonInteger(functor: []const u8, a: Term, b: Term) void {
    const bad: ?Term = if (a != .integer and a != .variable) a else if (b != .integer and b != .variable) b else null;
    const t = bad orelse return;
    writeRaw("Warning: ");
    writeRaw(functor);
    writeRaw(" expects integers, got ");
    switch (t) {
        .atom => |name| writeRaw(name),
        .nil => writeRaw("[]"),
        .list => writeRaw("a list"),
        .compound => |c| writeRaw(c.functor),
        else => writeRaw("a non-integer"),
    }
    writeRaw(" — answering No.\n");
}
const Engine = @import("engine.zig").Engine;

pub fn tryBuiltin(eng: *Engine, compound: Term.Compound, subst: Substitution, rest: []const Goal, solutions: *std.ArrayList(Substitution), depth: usize) Engine.SolveError!bool {
    // same_as(X, Y) — unification
    if (std.mem.eql(u8, compound.functor, "same_as") and compound.args.len == 2) {
        var new_subst = try subst.clone();
        if (try unify(compound.args[0], compound.args[1], &new_subst)) {
            if (eng.trace_enabled) traceCompound(depth, "EXIT", compound, &new_subst, eng.allocator);
            try eng.solveGoalsAll(rest, new_subst, solutions, depth);
        } else if (eng.trace_enabled) {
            traceCompound(depth, "FAIL", compound, &subst, eng.allocator);
        }
        return true;
    }

    // less_than(X, Y) — integer comparison
    if (std.mem.eql(u8, compound.functor, "less_than") and compound.args.len == 2) {
        const a = subst.walk(compound.args[0]);
        const b = subst.walk(compound.args[1]);
        warnNonInteger("less_than", a, b); // axiom-bjr
        if (a == .integer and b == .integer) {
            if (a.integer < b.integer) {
                if (eng.trace_enabled) traceCompound(depth, "EXIT", compound, &subst, eng.allocator);
                try eng.solveGoalsAll(rest, subst, solutions, depth);
            } else if (eng.trace_enabled) {
                traceCompound(depth, "FAIL", compound, &subst, eng.allocator);
            }
        }
        return true;
    }

    // greater_than(X, Y)
    if (std.mem.eql(u8, compound.functor, "greater_than") and compound.args.len == 2) {
        const a = subst.walk(compound.args[0]);
        const b = subst.walk(compound.args[1]);
        warnNonInteger("greater_than", a, b); // axiom-bjr
        if (a == .integer and b == .integer) {
            if (a.integer > b.integer) {
                if (eng.trace_enabled) traceCompound(depth, "EXIT", compound, &subst, eng.allocator);
                try eng.solveGoalsAll(rest, subst, solutions, depth);
            } else if (eng.trace_enabled) {
                traceCompound(depth, "FAIL", compound, &subst, eng.allocator);
            }
        }
        return true;
    }

    // equal(X, Y)
    if (std.mem.eql(u8, compound.functor, "equal") and compound.args.len == 2) {
        const a = subst.walk(compound.args[0]);
        const b = subst.walk(compound.args[1]);
        warnNonInteger("equal", a, b); // axiom-bjr
        if (a == .integer and b == .integer) {
            if (a.integer == b.integer) {
                if (eng.trace_enabled) traceCompound(depth, "EXIT", compound, &subst, eng.allocator);
                try eng.solveGoalsAll(rest, subst, solutions, depth);
            } else if (eng.trace_enabled) {
                traceCompound(depth, "FAIL", compound, &subst, eng.allocator);
            }
        }
        return true;
    }

    // member(X, List) — list membership
    if (std.mem.eql(u8, compound.functor, "member_of") and compound.args.len == 2) {
        const element = compound.args[0];
        var list_term = subst.walk(compound.args[1]);
        while (true) {
            switch (list_term) {
                .list => |l| {
                    var new_subst = try subst.clone();
                    if (try unify(element, l.head.*, &new_subst)) {
                        if (eng.trace_enabled) traceCompound(depth, "EXIT", compound, &new_subst, eng.allocator);
                        try eng.solveGoalsAll(rest, new_subst, solutions, depth);
                    }
                    list_term = subst.walk(l.tail.*);
                },
                .nil => break,
                else => break,
            }
        }
        return true;
    }

    // length(List, N) — list length
    if (std.mem.eql(u8, compound.functor, "length") and compound.args.len == 2) {
        var list_term = subst.walk(compound.args[0]);
        var count: i64 = 0;
        while (true) {
            switch (list_term) {
                .list => |l| {
                    count += 1;
                    list_term = subst.walk(l.tail.*);
                },
                .nil => break,
                else => break,
            }
        }
        var new_subst = try subst.clone();
        if (try unify(compound.args[1], .{ .integer = count }, &new_subst)) {
            if (eng.trace_enabled) traceCompound(depth, "EXIT", compound, &new_subst, eng.allocator);
            try eng.solveGoalsAll(rest, new_subst, solutions, depth);
        }
        return true;
    }

    // append_of(Result, A, B) — list append: Result = A ++ B
    if (std.mem.eql(u8, compound.functor, "append_of") and compound.args.len == 3) {
        const list_a = subst.walk(compound.args[1]);
        const list_b = subst.walk(compound.args[2]);
        // Build the appended list
        const result_list = appendLists(eng.allocator, list_a, list_b) catch return false;
        var new_subst = try subst.clone();
        if (try unify(compound.args[0], result_list, &new_subst)) {
            if (eng.trace_enabled) traceCompound(depth, "EXIT", compound, &new_subst, eng.allocator);
            try eng.solveGoalsAll(rest, new_subst, solutions, depth);
        }
        return true;
    }

    return false;
}

// axiom-7yv: depth threads the resolution budget
pub fn tryBuiltinCheck(eng: *Engine, compound: Term.Compound, subst: Substitution, rest: []const Goal, found: *bool, depth: usize) Engine.SolveError!bool {
    if (std.mem.eql(u8, compound.functor, "same_as") and compound.args.len == 2) {
        var new_subst = try subst.clone();
        if (try unify(compound.args[0], compound.args[1], &new_subst)) {
            try eng.checkGoals(rest, new_subst, found, depth);
        }
        return true;
    }
    if (std.mem.eql(u8, compound.functor, "less_than") and compound.args.len == 2) {
        const a = subst.walk(compound.args[0]);
        const b = subst.walk(compound.args[1]);
        if (a == .integer and b == .integer and a.integer < b.integer) {
            try eng.checkGoals(rest, subst, found, depth);
        }
        return true;
    }
    if (std.mem.eql(u8, compound.functor, "greater_than") and compound.args.len == 2) {
        const a = subst.walk(compound.args[0]);
        const b = subst.walk(compound.args[1]);
        if (a == .integer and b == .integer and a.integer > b.integer) {
            try eng.checkGoals(rest, subst, found, depth);
        }
        return true;
    }
    if (std.mem.eql(u8, compound.functor, "equal") and compound.args.len == 2) {
        const a = subst.walk(compound.args[0]);
        const b = subst.walk(compound.args[1]);
        if (a == .integer and b == .integer and a.integer == b.integer) {
            try eng.checkGoals(rest, subst, found, depth);
        }
        return true;
    }
    if (std.mem.eql(u8, compound.functor, "member_of") and compound.args.len == 2) {
        const element = compound.args[0];
        var list_term = subst.walk(compound.args[1]);
        while (true) {
            switch (list_term) {
                .list => |l| {
                    var new_subst = try subst.clone();
                    if (try unify(element, l.head.*, &new_subst)) {
                        try eng.checkGoals(rest, new_subst, found, depth);
                        if (found.*) return true;
                    }
                    list_term = subst.walk(l.tail.*);
                },
                .nil => break,
                else => break,
            }
        }
        return true;
    }
    if (std.mem.eql(u8, compound.functor, "length") and compound.args.len == 2) {
        var list_term = subst.walk(compound.args[0]);
        var count: i64 = 0;
        while (true) {
            switch (list_term) {
                .list => |l| {
                    count += 1;
                    list_term = subst.walk(l.tail.*);
                },
                .nil => break,
                else => break,
            }
        }
        var new_subst = try subst.clone();
        if (try unify(compound.args[1], .{ .integer = count }, &new_subst)) {
            try eng.checkGoals(rest, new_subst, found, depth);
        }
        return true;
    }
    if (std.mem.eql(u8, compound.functor, "append_of") and compound.args.len == 3) {
        const list_a = subst.walk(compound.args[1]);
        const list_b = subst.walk(compound.args[2]);
        const result_list = appendLists(eng.allocator, list_a, list_b) catch return false;
        var new_subst = try subst.clone();
        if (try unify(compound.args[0], result_list, &new_subst)) {
            try eng.checkGoals(rest, new_subst, found, depth);
        }
        return true;
    }
    return false;
}

pub fn appendLists(allocator: std.mem.Allocator, a: Term, b: Term) !Term {
    switch (a) {
        .nil => return b,
        .list => |l| {
            const new_tail = try appendLists(allocator, l.tail.*, b);
            const head_ptr = try allocator.create(Term);
            head_ptr.* = l.head.*;
            const tail_ptr = try allocator.create(Term);
            tail_ptr.* = new_tail;
            return .{ .list = .{ .head = head_ptr, .tail = tail_ptr } };
        },
        else => return b,
    }
}
