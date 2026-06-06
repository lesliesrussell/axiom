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
pub const identity = @import("identity.zig"); // axiom-ekd: pub for REPL display
pub const english = @import("english.zig"); // axiom-xec: canonical display
pub const diff = @import("diff.zig"); // axiom-aof: semantic diff
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
    closed_world_preds: std.StringHashMap(void), // axiom-d4s
    // axiom-7yv: resolution budgets — unbounded recursion must produce a
    // clean error, not a hang (step) or native stack overflow (depth)
    step_count: usize,
    step_limit: usize,
    depth_limit: usize,
    limit_functor: []const u8,
    limit_arity: usize,

    // axiom-7yv
    pub const default_step_limit: usize = 200_000;
    pub const default_depth_limit: usize = 1_024;
    pub const SolveError = std.mem.Allocator.Error || error{ StepLimitExceeded, DepthLimitExceeded };

    pub fn init(allocator: std.mem.Allocator) Engine {
        return .{
            .clauses = .empty,
            .allocator = allocator,
            .var_counter = 0,
            .trace_enabled = false,
            .pred_info = checks.PredInfoMap.init(allocator),
            .closed_world_preds = std.StringHashMap(void).init(allocator),
            .step_count = 0,
            .step_limit = default_step_limit,
            .depth_limit = default_depth_limit,
            .limit_functor = "",
            .limit_arity = 0,
        };
    }

    // axiom-7yv
    /// Charge one resolution step against the session budgets. Records the
    /// offending predicate so frontends can name it in the error message.
    fn bumpLimits(self: *Engine, compound: Term.Compound, depth: usize) SolveError!void {
        self.step_count += 1;
        if (self.step_count > self.step_limit) {
            self.limit_functor = compound.functor;
            self.limit_arity = compound.args.len;
            return error.StepLimitExceeded;
        }
        if (depth > self.depth_limit) {
            self.limit_functor = compound.functor;
            self.limit_arity = compound.args.len;
            return error.DepthLimitExceeded;
        }
    }

    pub fn addClause(self: *Engine, clause: Clause) !void {
        // axiom-76a: own the source text — callers may pass transient buffers
        var stored = clause;
        if (clause.source_text.len > 0) {
            stored.source_text = try self.allocator.dupe(u8, clause.source_text);
        }
        if (clause.label.len > 0) {
            stored.label = try self.allocator.dupe(u8, clause.label);
        }
        stored.id = identity.clauseHash(self.allocator, stored); // axiom-ekd
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
        self.closed_world_preds.clearRetainingCapacity(); // axiom-d4s
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
        checks.lintNegation(self.allocator, self.clauses.items); // axiom-d4s
    }

    // axiom-d4s
    pub fn declareClosedWorld(self: *Engine, name: []const u8) !void {
        const owned = try self.allocator.dupe(u8, name);
        try self.closed_world_preds.put(owned, {});
    }

    pub fn isClosedWorld(self: *const Engine, name: []const u8) bool {
        return self.closed_world_preds.contains(name);
    }

    pub fn getClauses(self: *const Engine) []const Clause {
        return self.clauses.items;
    }

    /// Collect all solutions for given goals
    pub fn solveAll(self: *Engine, goals: []const Goal) ![]Substitution {
        self.step_count = 0; // axiom-7yv: fresh budget per top-level query
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
                try self.bumpLimits(compound, depth); // axiom-7yv
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
                        try self.checkGoals(inner_goals, subst, &found, depth + 1);
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
    /// axiom-7yv: depth threads the same resolution budget as solveGoalsAll.
    pub fn checkGoals(self: *Engine, goals: []const Goal, subst: Substitution, found: *bool, depth: usize) !void {
        if (found.*) return;

        if (goals.len == 0) {
            found.* = true;
            return;
        }

        const goal = goals[0];
        const rest = goals[1..];

        switch (goal) {
            .call => |compound| {
                try self.bumpLimits(compound, depth); // axiom-7yv
                if (try builtins.tryBuiltinCheck(self, compound, subst, rest, found, depth)) return;

                for (self.clauses.items) |clause| {
                    if (found.*) return;
                    const renamed = try self.renameClause(clause);
                    var new_subst = try subst.clone();
                    const goal_term = Term{ .compound = compound };
                    const head_term = Term{ .compound = renamed.head };

                    if (try unify(goal_term, head_term, &new_subst)) {
                        if (renamed.body.len == 0) {
                            try self.checkGoals(rest, new_subst, found, depth);
                        } else {
                            const combined = try self.concatGoals(renamed.body, rest);
                            try self.checkGoals(combined, new_subst, found, depth + 1);
                        }
                    }
                }
            },
            .not => |inner| {
                switch (inner.*) {
                    .call => |compound| {
                        var inner_found = false;
                        const inner_goals = try self.allocSliceGoal(&.{Goal{ .call = compound }});
                        try self.checkGoals(inner_goals, subst, &inner_found, depth + 1);
                        if (!inner_found) {
                            try self.checkGoals(rest, subst, found, depth);
                        }
                    },
                    else => {},
                }
            },
            .cut => {
                try self.checkGoals(rest, subst, found, depth);
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

    /// axiom-47h: proof trees as data (JSON mode).
    pub fn buildProofTrees(self: *Engine, goals: []const Goal, subst: *const Substitution) ![]const proof.ProofNode {
        return explain.buildProofTrees(self, goals, subst);
    }

    // ─── Decisions (axiom-i01) ──────────────────────────────────────

    // axiom-2fx: spec-aligned outcome ladder. Deny-overrides generalizes
    // to highest-rank-wins; rank 0 is plain allow, anything above gates it.
    pub const DecisionOutcome = enum {
        allow,
        allow_with_redaction,
        allow_with_sandbox,
        require_confirmation,
        deny,
        indeterminate,
    };

    // axiom-2fx: precedence of outcome atoms (higher beats lower).
    // Unknown outcome atoms are ignored.
    pub fn outcomeRank(atom: []const u8) ?u8 {
        if (std.mem.eql(u8, atom, "deny")) return 4;
        if (std.mem.eql(u8, atom, "require_confirmation")) return 3;
        if (std.mem.eql(u8, atom, "allow_with_sandbox")) return 2;
        if (std.mem.eql(u8, atom, "allow_with_redaction")) return 1;
        if (std.mem.eql(u8, atom, "allow")) return 0;
        return null;
    }

    fn outcomeFromRank(rank: u8) DecisionOutcome {
        return switch (rank) {
            0 => .allow,
            1 => .allow_with_redaction,
            2 => .allow_with_sandbox,
            3 => .require_confirmation,
            else => .deny,
        };
    }

    /// The outcome atom for a ranked outcome — also the enum tag name.
    fn outcomeAtom(outcome: DecisionOutcome) []const u8 {
        return @tagName(outcome);
    }

    pub const Decision = struct {
        outcome: DecisionOutcome,
        reasons: []const []const u8,
        evidence: []const []const u8,
    };

    /// Reserved context atom for decision inputs.
    pub const decision_ctx = "axiom_decision_ctx";

    /// Evaluate the KB's decision rules for (subject, action[, resource]).
    /// Conflict resolution is deny-overrides: any derivable deny wins;
    /// allow requires at least one allow and zero denies; neither =>
    /// indeterminate. Inputs are asserted in a temporary scope (popped
    /// afterward), so repeated calls do not accumulate clauses.
    pub fn decide(self: *Engine, subject: []const u8, action: []const u8, resource: ?[]const u8) !Decision {
        const a = self.allocator;
        const before = self.clauses.items.len;
        defer {
            // pop the temp-asserted ctx facts (asserts append at the end)
            while (self.clauses.items.len > before) {
                _ = self.clauses.pop();
            }
        }

        const ctx: Term = .{ .atom = decision_ctx };
        try self.addClause(.{ .head = .{ .functor = "subject", .args = try dupTerms(a, &.{ ctx, .{ .atom = try a.dupe(u8, subject) } }) }, .body = &.{} });
        try self.addClause(.{ .head = .{ .functor = "action", .args = try dupTerms(a, &.{ ctx, .{ .atom = try a.dupe(u8, action) } }) }, .body = &.{} });
        if (resource) |r| {
            try self.addClause(.{ .head = .{ .functor = "resource", .args = try dupTerms(a, &.{ ctx, .{ .atom = try a.dupe(u8, r) } }) }, .body = &.{} });
        }

        // query: outcome(ctx, O)
        const out_var: Term = .{ .variable = "AxiomDecideO" };
        const goal: Goal = .{ .call = .{ .functor = "outcome", .args = try dupTerms(a, &.{ ctx, out_var }) } };
        const goals = try a.alloc(Goal, 1);
        goals[0] = goal;
        const solutions = try self.solveAll(goals);

        // axiom-2fx: deny-overrides, generalized — highest rank wins
        var winner: ?usize = null;
        var best_rank: u8 = 0;
        for (solutions, 0..) |sol, i| {
            const bound = sol.walk(out_var);
            if (bound != .atom) continue;
            const rank = outcomeRank(bound.atom) orelse continue;
            if (winner == null or rank > best_rank) {
                best_rank = rank;
                winner = i;
                if (rank == 4) break; // deny short-circuits
            }
        }
        if (winner == null) {
            return .{ .outcome = .indeterminate, .reasons = &.{}, .evidence = &.{} };
        }
        const outcome = outcomeFromRank(best_rank);

        // reasons: explicit reason_id(ctx, R) bindings take precedence
        var reasons: std.ArrayList([]const u8) = .empty;
        var evidence: std.ArrayList([]const u8) = .empty;

        const r_var: Term = .{ .variable = "AxiomDecideR" };
        const r_goals = try a.alloc(Goal, 1);
        r_goals[0] = .{ .call = .{ .functor = "reason_id", .args = try dupTerms(a, &.{ ctx, r_var }) } };
        const r_solutions = try self.solveAll(r_goals);
        for (r_solutions) |sol| {
            const bound = sol.walk(r_var);
            if (bound == .atom) try appendUnique(a, &reasons, bound.atom);
        }

        // witness proof of the winning outcome: rule labels + fact evidence
        const outcome_atom: []const u8 = outcomeAtom(outcome); // axiom-2fx
        const win_goal: Term.Compound = .{ .functor = "outcome", .args = try dupTerms(a, &.{ ctx, .{ .atom = outcome_atom } }) };
        var witness = try solutions[winner.?].clone();
        if (try explain.proveGoalPublic(self, win_goal, &witness, 0)) |tree| {
            try collectFromProof(a, &tree, &reasons, &evidence, reasons.items.len > 0);
        }

        return .{
            .outcome = outcome,
            .reasons = try reasons.toOwnedSlice(a),
            .evidence = try evidence.toOwnedSlice(a),
        };
    }

    /// Enumerate the KB's action universe (arity-1 action/1 facts) and
    /// return the actions that decide() resolves to allow for this
    /// subject[/resource]. axiom-02w
    pub fn allowedActions(self: *Engine, subject: []const u8, resource: ?[]const u8) ![]const []const u8 {
        const a = self.allocator;
        const act_var: Term = .{ .variable = "AxiomActA" };
        const goals = try a.alloc(Goal, 1);
        goals[0] = .{ .call = .{ .functor = "action", .args = try dupTerms(a, &.{act_var}) } };
        const solutions = try self.solveAll(goals);

        var allowed: std.ArrayList([]const u8) = .empty;
        for (solutions) |sol| {
            const bound = sol.walk(act_var);
            if (bound != .atom) continue;
            const candidate = bound.atom;
            // dedupe (multiple identical facts)
            var dup = false;
            for (allowed.items) |existing| {
                if (std.mem.eql(u8, existing, candidate)) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;
            const d = try self.decide(subject, candidate, resource);
            if (d.outcome == .allow) try allowed.append(a, candidate);
        }
        return allowed.toOwnedSlice(a);
    }

    // ─── Counterfactuals (axiom-07s) ────────────────────────────────

    pub const NearMiss = struct {
        rule: []const u8,
        blocker: []const u8,
        blocker_negated: bool,
    };

    pub const DenyPath = struct {
        rule: []const u8,
        evidence: []const []const u8,
        outcome: []const u8 = "deny", // axiom-2fx: which gate fired
    };

    pub const WhyNot = struct {
        near_misses: []const NearMiss,
        denies: []const DenyPath,
    };

    /// Per-rule first-blocker counterfactual analysis: which deny rules
    /// fired (and on which removable facts), and where each allow rule
    /// that did NOT fire got blocked. Temp-ctx scoped like decide().
    pub fn whyNot(self: *Engine, subject: []const u8, action: []const u8, resource: ?[]const u8) !WhyNot {
        const a = self.allocator;
        const before = self.clauses.items.len;
        defer {
            while (self.clauses.items.len > before) {
                _ = self.clauses.pop();
            }
        }

        const ctx: Term = .{ .atom = decision_ctx };
        try self.addClause(.{ .head = .{ .functor = "subject", .args = try dupTerms(a, &.{ ctx, .{ .atom = try a.dupe(u8, subject) } }) }, .body = &.{} });
        try self.addClause(.{ .head = .{ .functor = "action", .args = try dupTerms(a, &.{ ctx, .{ .atom = try a.dupe(u8, action) } }) }, .body = &.{} });
        if (resource) |r| {
            try self.addClause(.{ .head = .{ .functor = "resource", .args = try dupTerms(a, &.{ ctx, .{ .atom = try a.dupe(u8, r) } }) }, .body = &.{} });
        }

        // ── active gating rules + their removable evidence ──
        // axiom-2fx: every outcome that beats plain allow is a blocker —
        // deny, require_confirmation, allow_with_sandbox, allow_with_redaction
        var denies: std.ArrayList(DenyPath) = .empty;
        const gate_atoms = [_][]const u8{ "deny", "require_confirmation", "allow_with_sandbox", "allow_with_redaction" };
        for (gate_atoms) |gate| {
            const gate_goal: Term.Compound = .{ .functor = "outcome", .args = try dupTerms(a, &.{ ctx, .{ .atom = gate } }) };
            const dg = try a.alloc(Goal, 1);
            dg[0] = .{ .call = gate_goal };
            const gate_solutions = try self.solveAll(dg);
            for (gate_solutions) |sol| {
                var witness = try sol.clone();
                const tree = (try explain.proveGoalPublic(self, gate_goal, &witness, 0)) orelse continue;
                const rule_name = try ruleName(a, tree.clause_label, tree.clause_id);
                var dup = false;
                for (denies.items) |d| {
                    if (std.mem.eql(u8, d.rule, rule_name)) {
                        dup = true;
                        break;
                    }
                }
                if (dup) continue;
                var ev: std.ArrayList([]const u8) = .empty;
                var unused_reasons: std.ArrayList([]const u8) = .empty;
                try collectFromProof(a, &tree, &unused_reasons, &ev, true);
                try denies.append(a, .{ .rule = rule_name, .evidence = try ev.toOwnedSlice(a), .outcome = gate });
            }
        }

        // ── near-miss allow rules: first blocker per clause ──
        var misses: std.ArrayList(NearMiss) = .empty;
        const allow_head: Term.Compound = .{ .functor = "outcome", .args = try dupTerms(a, &.{ ctx, .{ .atom = "allow" } }) };
        const n_clauses = before; // iterate the user KB only (pre-ctx)
        var ci: usize = 0;
        while (ci < n_clauses) : (ci += 1) {
            const clause = self.clauses.items[ci];
            if (!std.mem.eql(u8, clause.head.functor, "outcome") or clause.head.args.len != 2) continue;
            if (clause.body.len == 0) continue;

            const renamed = try self.renameClause(clause);
            var attempt = Substitution.init(a);
            const matched = unify(.{ .compound = allow_head }, .{ .compound = renamed.head }, &attempt) catch false;
            if (!matched) continue; // not an allow rule (e.g. head is deny)

            var blocker: ?NearMiss = null;
            var fired = true;
            for (renamed.body) |bg| {
                switch (bg) {
                    .call => |bc| {
                        if (try explain.proveGoalPublic(self, bc, &attempt, 0)) |node| {
                            if (node.kind != .unproven) continue;
                        }
                        fired = false;
                        const walked = try walkForDisplay(a, bc, &attempt);
                        // blocked at a ctx-input goal => the rule is about
                        // different inputs, not a counterfactual — skip it
                        if (mentionsCtx(walked)) break;
                        blocker = .{
                            .rule = try ruleName(a, clause.label, clause.id),
                            .blocker = try english.goalToEnglish(a, walked),
                            .blocker_negated = false,
                        };
                    },
                    .not => |inner| switch (inner.*) {
                        .call => |nc| {
                            const provable = explain.isProvablePublic(self, nc, &attempt) catch false;
                            if (!provable) continue;
                            fired = false;
                            const walked = try walkForDisplay(a, nc, &attempt);
                            if (mentionsCtx(walked)) break;
                            blocker = .{
                                .rule = try ruleName(a, clause.label, clause.id),
                                .blocker = try english.goalToEnglish(a, walked),
                                .blocker_negated = true,
                            };
                        },
                        else => {},
                    },
                    .cut => {},
                }
                if (blocker != null) break;
            }
            if (!fired) {
                if (blocker) |b| try misses.append(a, b);
            }
        }

        return .{
            .near_misses = try misses.toOwnedSlice(a),
            .denies = try denies.toOwnedSlice(a),
        };
    }

    fn ruleName(a: std.mem.Allocator, label: []const u8, id: u64) ![]const u8 {
        if (label.len > 0) return label;
        var hex_buf: [16]u8 = undefined;
        const hex = identity.hashHex(id, &hex_buf);
        return a.dupe(u8, hex);
    }

    fn walkForDisplay(a: std.mem.Allocator, c: Term.Compound, subst: *const Substitution) !Term.Compound {
        const walked = try subst.deepWalk(.{ .compound = c }, a);
        return walked.compound;
    }

    fn dupTerms(a: std.mem.Allocator, terms: []const Term) ![]Term {
        const out = try a.alloc(Term, terms.len);
        @memcpy(out, terms);
        return out;
    }

    fn appendUnique(a: std.mem.Allocator, list: *std.ArrayList([]const u8), item: []const u8) !void {
        for (list.items) |existing| {
            if (std.mem.eql(u8, existing, item)) return;
        }
        try list.append(a, item);
    }

    fn collectFromProof(a: std.mem.Allocator, node: *const proof.ProofNode, reasons: *std.ArrayList([]const u8), evidence: *std.ArrayList([]const u8), skip_reasons: bool) !void {
        switch (node.kind) {
            .rule => {
                if (!skip_reasons) {
                    if (node.clause_label.len > 0) {
                        try appendUnique(a, reasons, node.clause_label);
                    } else {
                        var hex_buf: [16]u8 = undefined;
                        const hex = identity.hashHex(node.clause_id, &hex_buf);
                        try appendUnique(a, reasons, try a.dupe(u8, hex));
                    }
                }
            },
            .fact => {
                // temp-asserted ctx triples are scaffolding, not evidence
                if (!mentionsCtx(node.goal)) {
                    const sentence = try english.goalToEnglish(a, node.goal);
                    try appendUnique(a, evidence, sentence);
                }
            },
            else => {},
        }
        for (node.children) |*child| {
            try collectFromProof(a, child, reasons, evidence, skip_reasons);
        }
    }

    fn mentionsCtx(c: Term.Compound) bool {
        for (c.args) |arg| {
            if (arg == .atom and std.mem.eql(u8, arg.atom, decision_ctx)) return true;
        }
        return false;
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
