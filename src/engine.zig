// axiom-s0w
// Engine coordinator — clause store, resolution loop, and variable renaming.
// Substitutions/unification, built-ins, proof printing, output helpers, and
// determinism/mode checks live in sibling files within this module:
//   substitution.zig  — Binding, Substitution, unify
//   builtins.zig      — built-in predicates (solve + check variants)
//   proof.zig         — ProofNode, proof explanation printing
//   checks.zig        — predicate-info registry, determinism/mode checks
//   output.zig        — std.fmt-free trace/output helpers
const std = @import("std");
const types = @import("types.zig");
const Term = types.Term;
const Goal = types.Goal;
const Clause = types.Clause;

const substitution = @import("substitution.zig");
const builtins = @import("builtins.zig");
const proof = @import("proof.zig");
const explain = @import("explain.zig"); // axiom-9nz
const checks = @import("checks.zig");
pub const output = @import("output.zig"); // axiom-wk4: pub for REPL styling
const traceCompound = output.traceCompound;
const writeRaw = output.writeRaw;
const writeInt = output.writeInt;

// Re-exports — public engine-module API
pub const Binding = substitution.Binding;
pub const Substitution = substitution.Substitution;
pub const unify = substitution.unify;
pub const ProofNode = proof.ProofNode;

const Determinism = types.Determinism;
const Mode = types.Mode;
const PredicateInfo = types.PredicateInfo;
const ModeDecl = types.ModeDecl;

pub const Engine = struct {
    clauses: std.ArrayList(Clause),
    allocator: std.mem.Allocator,
    var_counter: usize,
    trace_enabled: bool,
    pred_info: checks.PredInfoMap,

    pub fn init(allocator: std.mem.Allocator) Engine {
        return .{
            .clauses = .empty,
            .allocator = allocator,
            .var_counter = 0,
            .trace_enabled = false,
            .pred_info = checks.PredInfoMap.init(allocator),
        };
    }

    pub fn addClause(self: *Engine, clause: Clause) !void {
        // axiom-76a: own the source text — callers may pass transient buffers
        var stored = clause;
        if (clause.source_text.len > 0) {
            stored.source_text = try self.allocator.dupe(u8, clause.source_text);
        }
        try self.clauses.append(self.allocator, stored);
        try checks.recordClause(&self.pred_info, self.allocator, stored);
    }

    // axiom-76a
    /// Remove clause at `index`, returning it for display. Null if out of
    /// range. Arena memory is not reclaimed until engine death.
    pub fn removeClause(self: *Engine, index: usize) ?Clause {
        if (index >= self.clauses.items.len) return null;
        return self.clauses.orderedRemove(index);
    }

    // axiom-76a
    /// Remove all clauses and predicate info (det/mode declarations).
    pub fn clearClauses(self: *Engine) void {
        self.clauses.clearRetainingCapacity();
        self.pred_info.clearRetainingCapacity();
    }

    pub fn registerMode(self: *Engine, decl: ModeDecl) !void {
        try checks.registerMode(&self.pred_info, self.allocator, decl);
    }

    pub fn getPredInfo(self: *const Engine, name: []const u8, arity: u8) ?PredicateInfo {
        return checks.getPredInfo(&self.pred_info, name, arity);
    }

    /// Run determinism and mode checks on all loaded predicates
    pub fn runChecks(self: *Engine) !void {
        try checks.runChecks(&self.pred_info, self.clauses.items);
    }

    pub fn getClauses(self: *const Engine) []const Clause {
        return self.clauses.items;
    }

    /// Collect all solutions for given goals
    pub fn solveAll(self: *Engine, goals: []const Goal) ![]Substitution {
        var solutions: std.ArrayList(Substitution) = .empty;
        const initial = Substitution.init(self.allocator);
        try self.solveGoalsAll(goals, initial, &solutions, 0);
        return solutions.toOwnedSlice(self.allocator);
    }

    /// Internal resolution loop — pub for builtins.zig (mutual recursion).
    pub fn solveGoalsAll(self: *Engine, goals: []const Goal, subst: Substitution, solutions: *std.ArrayList(Substitution), depth: usize) !void {
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
                if (try builtins.tryBuiltin(self, compound, subst, rest, solutions, depth)) {
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

    /// Internal yes/no evaluation — pub for builtins.zig (mutual recursion).
    pub fn checkGoals(self: *Engine, goals: []const Goal, subst: Substitution, found: *bool) !void {
        if (found.*) return;

        if (goals.len == 0) {
            found.* = true;
            return;
        }

        const goal = goals[0];
        const rest = goals[1..];

        switch (goal) {
            .call => |compound| {
                if (try builtins.tryBuiltinCheck(self, compound, subst, rest, found)) return;

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

    // ─── Proof explanation ─────────────────────────────────────────────

    // axiom-9nz
    /// Re-prove the query's goals under a solution and print the proof
    /// tree. See explain.zig for the witness re-prover.
    pub fn explainSolution(self: *Engine, goals: []const Goal, subst: *const Substitution) void {
        explain.explainSolution(self, goals, subst);
    }

    // ─── Variable Renaming ─────────────────────────────────────────────

    const RenameError = std.mem.Allocator.Error;

    /// Internal — pub for explain.zig (witness re-prover).
    pub fn renameClause(self: *Engine, clause: Clause) RenameError!Clause {
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

    fn concatVarName(self: *Engine, name: []const u8, suffix: usize) ![]const u8 {
        // Build "name_N" without std.fmt.allocPrint
        var num_buf: [20]u8 = undefined;
        const num_str = output.uintToStr(suffix, &num_buf);
        const total_len = name.len + 1 + num_str.len; // name + '_' + digits
        const buf = try self.allocator.alloc(u8, total_len);
        @memcpy(buf[0..name.len], name);
        buf[name.len] = '_';
        @memcpy(buf[name.len + 1 ..][0..num_str.len], num_str);
        return buf;
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
