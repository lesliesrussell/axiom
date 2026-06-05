const std = @import("std");
const types = @import("types.zig");
const Term = types.Term;
const Goal = types.Goal;
const Clause = types.Clause;

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

// ─── Proof Tree ─────────────────────────────────────────────────────────────

pub const ProofNode = struct {
    goal: Term.Compound,
    clause_used: ?Clause, // null for built-ins / facts
    is_fact: bool,
    is_builtin: bool,
    children: []const ProofNode,
};

// ─── Unification ────────────────────────────────────────────────────────────

pub fn unify(t1: Term, t2: Term, subst: *Substitution) !bool {
    const a = subst.walk(t1);
    const b = subst.walk(t2);

    const a_tag: @typeInfo(Term).@"union".tag_type.? = a;
    const b_tag: @typeInfo(Term).@"union".tag_type.? = b;

    if (a_tag == .variable) {
        try subst.bind(a.variable, b);
        return true;
    }
    if (b_tag == .variable) {
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

// ─── Trace / output helpers (no std.fmt — safe across shared lib boundaries) ─

// axiom-6th
const stdout_file = std.Io.File.stdout();

fn writeRaw(s: []const u8) void {
    stdout_file.writeStreamingAll(types.defaultIo(), s) catch {}; // axiom-6th
}

fn writeInt(val: anytype) void {
    var buf: [20]u8 = undefined;
    const T = @TypeOf(val);
    if (@typeInfo(T) == .int) {
        const v: i64 = @intCast(val);
        if (v < 0) {
            writeRaw("-");
            writeUint(@intCast(-v), &buf);
        } else {
            writeUint(@intCast(v), &buf);
        }
    } else {
        writeUint(val, &buf);
    }
}

fn writeUint(val: u64, buf: *[20]u8) void {
    if (val == 0) {
        writeRaw("0");
        return;
    }
    var v = val;
    var i: usize = buf.len;
    while (v > 0) {
        i -= 1;
        buf[i] = @intCast('0' + (v % 10));
        v /= 10;
    }
    writeRaw(buf[i..]);
}

fn traceCompound(depth: usize, tag: []const u8, compound: Term.Compound, subst: *const Substitution, allocator: std.mem.Allocator) void {
    var indent_buf: [256]u8 = undefined;
    const indent_len = @min(depth * 2, 256);
    @memset(indent_buf[0..indent_len], ' ');
    writeRaw(indent_buf[0..indent_len]);

    writeRaw("[");
    writeRaw(tag);
    writeRaw("] ");
    writeRaw(compound.functor);
    writeRaw("(");
    for (compound.args, 0..) |arg, i| {
        if (i > 0) writeRaw(", ");
        const walked = subst.deepWalk(arg, allocator) catch arg;
        writeTermTo(walked);
    }
    writeRaw(")\n");
}

fn writeTermTo(term: Term) void {
    switch (term) {
        .atom => |a| writeRaw(a),
        .variable => |v| writeRaw(v),
        .integer => |i| writeInt(i),
        .nil => writeRaw("[]"),
        .compound => |c| {
            writeRaw(c.functor);
            writeRaw("(");
            for (c.args, 0..) |arg, idx| {
                if (idx > 0) writeRaw(", ");
                writeTermTo(arg);
            }
            writeRaw(")");
        },
        .list => |l| {
            writeRaw("[");
            writeTermTo(l.head.*);
            var tail = l.tail;
            while (true) {
                switch (tail.*) {
                    .list => |next| {
                        writeRaw(", ");
                        writeTermTo(next.head.*);
                        tail = next.tail;
                    },
                    .nil => break,
                    else => {
                        writeRaw(" | ");
                        writeTermTo(tail.*);
                        break;
                    },
                }
            }
            writeRaw("]");
        },
    }
}

// ─── Engine ────────────────────────────────────────────────────────────────

const Determinism = types.Determinism;
const Mode = types.Mode;
const PredicateInfo = types.PredicateInfo;
const ModeDecl = types.ModeDecl;

pub const Engine = struct {
    clauses: std.ArrayList(Clause),
    allocator: std.mem.Allocator,
    var_counter: usize,
    trace_enabled: bool,
    last_proof: ?ProofNode,
    pred_info: std.StringHashMap(PredicateInfo),

    pub fn init(allocator: std.mem.Allocator) Engine {
        return .{
            .clauses = .empty,
            .allocator = allocator,
            .var_counter = 0,
            .trace_enabled = false,
            .last_proof = null,
            .pred_info = std.StringHashMap(PredicateInfo).init(allocator),
        };
    }

    pub fn addClause(self: *Engine, clause: Clause) !void {
        try self.clauses.append(self.allocator, clause);

        // Register/validate predicate info
        const key = try self.predKey(clause.head.functor, @intCast(clause.head.args.len));
        if (self.pred_info.get(key)) |existing| {
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
                try self.pred_info.put(key, .{
                    .name = clause.head.functor,
                    .arity = @intCast(clause.head.args.len),
                    .det = clause.det,
                    .arg_modes = existing.arg_modes,
                    .source_file = existing.source_file,
                    .first_line = existing.first_line,
                });
            }
        } else {
            try self.pred_info.put(key, .{
                .name = clause.head.functor,
                .arity = @intCast(clause.head.args.len),
                .det = clause.det,
                .arg_modes = null,
                .source_file = null,
                .first_line = 0,
            });
        }
    }

    pub fn registerMode(self: *Engine, decl: ModeDecl) !void {
        const key = try self.predKey(decl.pred_name, @intCast(decl.arg_modes.len));
        if (self.pred_info.get(key)) |existing| {
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
            try self.pred_info.put(key, .{
                .name = decl.pred_name,
                .arity = @intCast(decl.arg_modes.len),
                .det = if (decl.det != .unspecified) decl.det else existing.det,
                .arg_modes = decl.arg_modes,
                .source_file = existing.source_file,
                .first_line = existing.first_line,
            });
        } else {
            try self.pred_info.put(key, .{
                .name = decl.pred_name,
                .arity = @intCast(decl.arg_modes.len),
                .det = decl.det,
                .arg_modes = decl.arg_modes,
                .source_file = null,
                .first_line = 0,
            });
        }
    }

    pub fn getPredInfo(self: *const Engine, name: []const u8, arity: u8) ?PredicateInfo {
        // Manual key build — no std.fmt
        var buf: [128]u8 = undefined;
        if (name.len + 4 > buf.len) return null;
        @memcpy(buf[0..name.len], name);
        buf[name.len] = '/';
        var num_buf: [4]u8 = undefined;
        const num_str = uintToStr(arity, &num_buf);
        @memcpy(buf[name.len + 1 ..][0..num_str.len], num_str);
        const key = buf[0 .. name.len + 1 + num_str.len];
        return self.pred_info.get(key);
    }

    fn predKey(self: *Engine, name: []const u8, arity: u8) ![]const u8 {
        return try self.concatPredKey(name, arity);
    }

    /// Run determinism and mode checks on all loaded predicates
    pub fn runChecks(self: *Engine) !void {
        var iter = self.pred_info.iterator();
        while (iter.next()) |entry| {
            const info = entry.value_ptr.*;
            if (info.det == .unspecified) continue;

            // Count clauses for this predicate
            var clause_count: usize = 0;
            for (self.clauses.items) |clause| {
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

    pub fn getClauses(self: *const Engine) []const Clause {
        return self.clauses.items;
    }

    /// Collect all solutions for given goals
    pub fn solveAll(self: *Engine, goals: []const Goal) ![]Substitution {
        var solutions: std.ArrayList(Substitution) = .empty;
        const initial = Substitution.init(self.allocator);
        self.last_proof = null;
        try self.solveGoalsAll(goals, initial, &solutions, 0);
        return solutions.toOwnedSlice(self.allocator);
    }

    fn solveGoalsAll(self: *Engine, goals: []const Goal, subst: Substitution, solutions: *std.ArrayList(Substitution), depth: usize) !void {
        if (goals.len == 0) {
            try solutions.append(self.allocator, try subst.clone());
            return;
        }

        const goal = goals[0];
        const rest = goals[1..];

        switch (goal) {
            .call => |compound| {
                if (self.trace_enabled) {
                    traceCompound(depth, "CALL", compound, &subst, self.allocator);
                }

                // Runtime mode check
                if (self.getPredInfo(compound.functor, @intCast(compound.args.len))) |info| {
                    if (info.arg_modes) |modes| {
                        for (modes, 0..) |m, idx| {
                            if (m == .in and idx < compound.args.len) {
                                const walked = subst.walk(compound.args[idx]);
                                if (walked == .variable) {
                                    writeRaw("Warning: mode violation: ");
                                    writeRaw(compound.functor);
                                    writeRaw("/");
                                    writeInt(compound.args.len);
                                    writeRaw(" expects argument ");
                                    writeInt(idx + 1);
                                    writeRaw(" ground (+), but got unbound variable.\n");
                                }
                            }
                        }
                    }
                }

                // Built-in predicates
                if (try self.tryBuiltin(compound, subst, rest, solutions, depth)) {
                    return;
                }

                var any_match = false;
                for (self.clauses.items) |clause| {
                    const renamed = try self.renameClause(clause);
                    var new_subst = try subst.clone();
                    const goal_term = Term{ .compound = compound };
                    const head_term = Term{ .compound = renamed.head };

                    if (try unify(goal_term, head_term, &new_subst)) {
                        any_match = true;
                        if (self.trace_enabled) {
                            traceCompound(depth, "EXIT", compound, &new_subst, self.allocator);
                        }

                        // Record proof for last solution
                        if (self.last_proof == null) {
                            self.last_proof = .{
                                .goal = compound,
                                .clause_used = clause,
                                .is_fact = clause.body.len == 0,
                                .is_builtin = false,
                                .children = &.{},
                            };
                        }

                        if (renamed.body.len == 0) {
                            try self.solveGoalsAll(rest, new_subst, solutions, depth);
                        } else {
                            const combined = try self.concatGoals(renamed.body, rest);
                            try self.solveGoalsAll(combined, new_subst, solutions, depth + 1);
                        }

                        if (self.trace_enabled and rest.len > 0) {
                            traceCompound(depth, "REDO", compound, &subst, self.allocator);
                        }
                    }
                }

                if (!any_match and self.trace_enabled) {
                    traceCompound(depth, "FAIL", compound, &subst, self.allocator);
                }
            },
            .not => |inner| {
                switch (inner.*) {
                    .call => |compound| {
                        if (self.trace_enabled) {
                            traceCompound(depth, "CALL", compound, &subst, self.allocator);
                            writeRaw("  (negation check)\n");
                        }
                        var found = false;
                        const inner_goals = try self.allocSliceGoal(&.{Goal{ .call = compound }});
                        try self.checkGoals(inner_goals, subst, &found);
                        if (!found) {
                            if (self.trace_enabled) {
                                traceCompound(depth, "EXIT", compound, &subst, self.allocator);
                                writeRaw("  (negation succeeded)\n");
                            }
                            try self.solveGoalsAll(rest, subst, solutions, depth);
                        } else if (self.trace_enabled) {
                            traceCompound(depth, "FAIL", compound, &subst, self.allocator);
                            writeRaw("  (negation failed - goal was provable)\n");
                        }
                    },
                    else => {},
                }
            },
            .cut => {
                try self.solveGoalsAll(rest, subst, solutions, depth);
            },
        }
    }

    fn checkGoals(self: *Engine, goals: []const Goal, subst: Substitution, found: *bool) !void {
        if (found.*) return;

        if (goals.len == 0) {
            found.* = true;
            return;
        }

        const goal = goals[0];
        const rest = goals[1..];

        switch (goal) {
            .call => |compound| {
                if (try self.tryBuiltinCheck(compound, subst, rest, found)) return;

                for (self.clauses.items) |clause| {
                    if (found.*) return;
                    const renamed = try self.renameClause(clause);
                    var new_subst = try subst.clone();
                    const goal_term = Term{ .compound = compound };
                    const head_term = Term{ .compound = renamed.head };

                    if (try unify(goal_term, head_term, &new_subst)) {
                        if (renamed.body.len == 0) {
                            try self.checkGoals(rest, new_subst, found);
                        } else {
                            const combined = try self.concatGoals(renamed.body, rest);
                            try self.checkGoals(combined, new_subst, found);
                        }
                    }
                }
            },
            .not => |inner| {
                switch (inner.*) {
                    .call => |compound| {
                        var inner_found = false;
                        const inner_goals = try self.allocSliceGoal(&.{Goal{ .call = compound }});
                        try self.checkGoals(inner_goals, subst, &inner_found);
                        if (!inner_found) {
                            try self.checkGoals(rest, subst, found);
                        }
                    },
                    else => {},
                }
            },
            .cut => {
                try self.checkGoals(rest, subst, found);
            },
        }
    }

    // ─── Built-in Predicates ─────────────────────────────────────────

    fn tryBuiltin(self: *Engine, compound: Term.Compound, subst: Substitution, rest: []const Goal, solutions: *std.ArrayList(Substitution), depth: usize) std.mem.Allocator.Error!bool {
        // same_as(X, Y) — unification
        if (std.mem.eql(u8, compound.functor, "same_as") and compound.args.len == 2) {
            var new_subst = try subst.clone();
            if (try unify(compound.args[0], compound.args[1], &new_subst)) {
                if (self.trace_enabled) traceCompound(depth, "EXIT", compound, &new_subst, self.allocator);
                try self.solveGoalsAll(rest, new_subst, solutions, depth);
            } else if (self.trace_enabled) {
                traceCompound(depth, "FAIL", compound, &subst, self.allocator);
            }
            return true;
        }

        // less_than(X, Y) — integer comparison
        if (std.mem.eql(u8, compound.functor, "less_than") and compound.args.len == 2) {
            const a = subst.walk(compound.args[0]);
            const b = subst.walk(compound.args[1]);
            if (a == .integer and b == .integer) {
                if (a.integer < b.integer) {
                    if (self.trace_enabled) traceCompound(depth, "EXIT", compound, &subst, self.allocator);
                    try self.solveGoalsAll(rest, subst, solutions, depth);
                } else if (self.trace_enabled) {
                    traceCompound(depth, "FAIL", compound, &subst, self.allocator);
                }
            }
            return true;
        }

        // greater_than(X, Y)
        if (std.mem.eql(u8, compound.functor, "greater_than") and compound.args.len == 2) {
            const a = subst.walk(compound.args[0]);
            const b = subst.walk(compound.args[1]);
            if (a == .integer and b == .integer) {
                if (a.integer > b.integer) {
                    if (self.trace_enabled) traceCompound(depth, "EXIT", compound, &subst, self.allocator);
                    try self.solveGoalsAll(rest, subst, solutions, depth);
                } else if (self.trace_enabled) {
                    traceCompound(depth, "FAIL", compound, &subst, self.allocator);
                }
            }
            return true;
        }

        // equal(X, Y)
        if (std.mem.eql(u8, compound.functor, "equal") and compound.args.len == 2) {
            const a = subst.walk(compound.args[0]);
            const b = subst.walk(compound.args[1]);
            if (a == .integer and b == .integer) {
                if (a.integer == b.integer) {
                    if (self.trace_enabled) traceCompound(depth, "EXIT", compound, &subst, self.allocator);
                    try self.solveGoalsAll(rest, subst, solutions, depth);
                } else if (self.trace_enabled) {
                    traceCompound(depth, "FAIL", compound, &subst, self.allocator);
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
                            if (self.trace_enabled) traceCompound(depth, "EXIT", compound, &new_subst, self.allocator);
                            try self.solveGoalsAll(rest, new_subst, solutions, depth);
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
                if (self.trace_enabled) traceCompound(depth, "EXIT", compound, &new_subst, self.allocator);
                try self.solveGoalsAll(rest, new_subst, solutions, depth);
            }
            return true;
        }

        // append_of(Result, A, B) — list append: Result = A ++ B
        if (std.mem.eql(u8, compound.functor, "append_of") and compound.args.len == 3) {
            const list_a = subst.walk(compound.args[1]);
            const list_b = subst.walk(compound.args[2]);
            // Build the appended list
            const result_list = self.appendLists(list_a, list_b) catch return false;
            var new_subst = try subst.clone();
            if (try unify(compound.args[0], result_list, &new_subst)) {
                if (self.trace_enabled) traceCompound(depth, "EXIT", compound, &new_subst, self.allocator);
                try self.solveGoalsAll(rest, new_subst, solutions, depth);
            }
            return true;
        }

        return false;
    }

    fn appendLists(self: *Engine, a: Term, b: Term) !Term {
        switch (a) {
            .nil => return b,
            .list => |l| {
                const new_tail = try self.appendLists(l.tail.*, b);
                const head_ptr = try self.allocator.create(Term);
                head_ptr.* = l.head.*;
                const tail_ptr = try self.allocator.create(Term);
                tail_ptr.* = new_tail;
                return .{ .list = .{ .head = head_ptr, .tail = tail_ptr } };
            },
            else => return b,
        }
    }

    fn tryBuiltinCheck(self: *Engine, compound: Term.Compound, subst: Substitution, rest: []const Goal, found: *bool) std.mem.Allocator.Error!bool {
        if (std.mem.eql(u8, compound.functor, "same_as") and compound.args.len == 2) {
            var new_subst = try subst.clone();
            if (try unify(compound.args[0], compound.args[1], &new_subst)) {
                try self.checkGoals(rest, new_subst, found);
            }
            return true;
        }
        if (std.mem.eql(u8, compound.functor, "less_than") and compound.args.len == 2) {
            const a = subst.walk(compound.args[0]);
            const b = subst.walk(compound.args[1]);
            if (a == .integer and b == .integer and a.integer < b.integer) {
                try self.checkGoals(rest, subst, found);
            }
            return true;
        }
        if (std.mem.eql(u8, compound.functor, "greater_than") and compound.args.len == 2) {
            const a = subst.walk(compound.args[0]);
            const b = subst.walk(compound.args[1]);
            if (a == .integer and b == .integer and a.integer > b.integer) {
                try self.checkGoals(rest, subst, found);
            }
            return true;
        }
        if (std.mem.eql(u8, compound.functor, "equal") and compound.args.len == 2) {
            const a = subst.walk(compound.args[0]);
            const b = subst.walk(compound.args[1]);
            if (a == .integer and b == .integer and a.integer == b.integer) {
                try self.checkGoals(rest, subst, found);
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
                            try self.checkGoals(rest, new_subst, found);
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
                try self.checkGoals(rest, new_subst, found);
            }
            return true;
        }
        if (std.mem.eql(u8, compound.functor, "append_of") and compound.args.len == 3) {
            const list_a = subst.walk(compound.args[1]);
            const list_b = subst.walk(compound.args[2]);
            const result_list = self.appendLists(list_a, list_b) catch return false;
            var new_subst = try subst.clone();
            if (try unify(compound.args[0], result_list, &new_subst)) {
                try self.checkGoals(rest, new_subst, found);
            }
            return true;
        }
        return false;
    }

    // ─── Proof explanation ─────────────────────────────────────────────

    pub fn getLastProof(self: *const Engine) ?ProofNode {
        return self.last_proof;
    }

    pub fn explainLastProof(self: *const Engine, subst: *const Substitution) void {
        const proof = self.last_proof orelse {
            writeRaw("No proof available. Run a query first.\n");
            return;
        };
        writeRaw("\nBecause:\n");
        self.printProofNode(&proof, subst, 1);
    }

    fn printProofNode(self: *const Engine, node: *const ProofNode, subst: *const Substitution, indent: usize) void {
        // Print indent
        var spaces: [64]u8 = undefined;
        const n = @min(indent * 2, 64);
        @memset(spaces[0..n], ' ');
        writeRaw(spaces[0..n]);

        writeRaw("- ");

        // Print the resolved goal
        writeRaw(node.goal.functor);
        writeRaw("(");
        for (node.goal.args, 0..) |arg, i| {
            if (i > 0) writeRaw(", ");
            const walked = subst.deepWalk(arg, self.allocator) catch arg;
            writeTermTo(walked);
        }
        writeRaw(")");

        if (node.is_builtin) {
            writeRaw("  [built-in]\n");
        } else if (node.is_fact) {
            writeRaw("  [fact]\n");
        } else {
            writeRaw("  [rule]\n");
            // Show clause body as sub-proof
            if (node.clause_used) |clause| {
                for (clause.body) |body_goal| {
                    switch (body_goal) {
                        .call => |c| {
                            const child = ProofNode{
                                .goal = c,
                                .clause_used = null,
                                .is_fact = true,
                                .is_builtin = false,
                                .children = &.{},
                            };
                            self.printProofNode(&child, subst, indent + 1);
                        },
                        .not => |inner| {
                            switch (inner.*) {
                                .call => |c| {
                                    writeRaw(spaces[0..n]);
                                    writeRaw("    \\+ ");
                                    var nbuf: [256]u8 = undefined;
                                    const nt = std.fmt.bufPrint(&nbuf, "{s}(...)", .{c.functor}) catch "?";
                                    writeRaw(nt);
                                    writeRaw("  [negation succeeded]\n");
                                },
                                else => {},
                            }
                        },
                        .cut => {},
                    }
                }
            }
        }
    }

    // ─── String helpers (no fmt/Writer — safe across shared lib boundaries) ──

    fn concatVarName(self: *Engine, name: []const u8, suffix: usize) ![]const u8 {
        // Build "name_N" without std.fmt.allocPrint
        var num_buf: [20]u8 = undefined;
        const num_str = uintToStr(suffix, &num_buf);
        const total_len = name.len + 1 + num_str.len; // name + '_' + digits
        const buf = try self.allocator.alloc(u8, total_len);
        @memcpy(buf[0..name.len], name);
        buf[name.len] = '_';
        @memcpy(buf[name.len + 1 ..][0..num_str.len], num_str);
        return buf;
    }

    fn concatPredKey(self: *Engine, name: []const u8, arity: u8) ![]const u8 {
        // Build "name/N" without std.fmt.allocPrint
        var num_buf: [4]u8 = undefined;
        const num_str = uintToStr(arity, &num_buf);
        const total_len = name.len + 1 + num_str.len;
        const buf = try self.allocator.alloc(u8, total_len);
        @memcpy(buf[0..name.len], name);
        buf[name.len] = '/';
        @memcpy(buf[name.len + 1 ..][0..num_str.len], num_str);
        return buf;
    }

    fn uintToStr(val: usize, buf: []u8) []const u8 {
        if (val == 0) {
            buf[0] = '0';
            return buf[0..1];
        }
        var v = val;
        var i: usize = buf.len;
        while (v > 0) {
            i -= 1;
            buf[i] = @intCast('0' + (v % 10));
            v /= 10;
        }
        return buf[i..];
    }

    // ─── Variable Renaming ─────────────────────────────────────────────

    const RenameError = std.mem.Allocator.Error;

    fn renameClause(self: *Engine, clause: Clause) RenameError!Clause {
        self.var_counter += 1;
        const suffix = self.var_counter;

        var mapping = std.StringHashMap([]const u8).init(self.allocator);
        defer mapping.deinit();

        const new_head = try self.renameCompound(clause.head, suffix, &mapping);
        const new_body = try self.renameGoals(clause.body, suffix, &mapping);

        return .{ .head = new_head, .body = new_body };
    }

    fn renameCompound(self: *Engine, compound: Term.Compound, suffix: usize, mapping: *std.StringHashMap([]const u8)) RenameError!Term.Compound {
        const new_args = try self.allocator.alloc(Term, compound.args.len);
        for (compound.args, 0..) |arg, i| {
            new_args[i] = try self.renameTerm(arg, suffix, mapping);
        }
        return .{ .functor = compound.functor, .args = new_args };
    }

    fn renameTerm(self: *Engine, term: Term, suffix: usize, mapping: *std.StringHashMap([]const u8)) RenameError!Term {
        switch (term) {
            .variable => |name| {
                if (mapping.get(name)) |new_name| {
                    return .{ .variable = new_name };
                }
                const new_name = try self.concatVarName(name, suffix);
                try mapping.put(name, new_name);
                return .{ .variable = new_name };
            },
            .compound => |c| {
                const renamed = try self.renameCompound(c, suffix, mapping);
                return .{ .compound = renamed };
            },
            .list => |l| {
                const new_head = try self.allocator.create(Term);
                new_head.* = try self.renameTerm(l.head.*, suffix, mapping);
                const new_tail = try self.allocator.create(Term);
                new_tail.* = try self.renameTerm(l.tail.*, suffix, mapping);
                return .{ .list = .{ .head = new_head, .tail = new_tail } };
            },
            else => return term,
        }
    }

    fn renameGoals(self: *Engine, goals: []const Goal, suffix: usize, mapping: *std.StringHashMap([]const u8)) RenameError![]const Goal {
        const new_goals = try self.allocator.alloc(Goal, goals.len);
        for (goals, 0..) |goal, i| {
            new_goals[i] = try self.renameGoal(goal, suffix, mapping);
        }
        return new_goals;
    }

    fn renameGoal(self: *Engine, goal: Goal, suffix: usize, mapping: *std.StringHashMap([]const u8)) RenameError!Goal {
        switch (goal) {
            .call => |c| {
                return .{ .call = try self.renameCompound(c, suffix, mapping) };
            },
            .not => |inner| {
                const new_inner = try self.allocator.create(Goal);
                new_inner.* = try self.renameGoal(inner.*, suffix, mapping);
                return .{ .not = new_inner };
            },
            .cut => return .cut,
        }
    }

    fn concatGoals(self: *Engine, a: []const Goal, b: []const Goal) ![]const Goal {
        const result = try self.allocator.alloc(Goal, a.len + b.len);
        @memcpy(result[0..a.len], a);
        @memcpy(result[a.len..], b);
        return result;
    }

    fn allocSliceGoal(self: *Engine, items: []const Goal) ![]const Goal {
        const slice = try self.allocator.alloc(Goal, items.len);
        @memcpy(slice, items);
        return slice;
    }
};
