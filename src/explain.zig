// axiom-9nz
// Witness re-prover for deep :why. Resolution flattens rule bodies into one
// goal list, which destroys the parent/child structure a proof tree needs.
// Instead of tracking provenance on the hot path, this module re-proves the
// query's goals after the fact: the solution's bindings make the goals
// (mostly) ground, so the search is narrow and fast.
//
// Caveat: if two clauses can prove the same ground goal, the witness may
// select a different one than the original run did. Any valid proof of the
// solution is a correct explanation.
const std = @import("std");
const types = @import("types.zig");
const Term = types.Term;
const Goal = types.Goal;
const substitution = @import("substitution.zig");
const Substitution = substitution.Substitution;
const unify = substitution.unify;
const proof = @import("proof.zig");
const ProofNode = proof.ProofNode;
const builtins = @import("builtins.zig");
const output = @import("output.zig");
const writeRaw = output.writeRaw;
const Engine = @import("engine.zig").Engine;

const max_depth = 64;
const Error = std.mem.Allocator.Error;

/// Re-prove `goals` under solution `subst`, returning one tree per goal.
/// axiom-47h: extracted so JSON mode can serialize trees directly.
pub fn buildProofTrees(eng: *Engine, goals: []const Goal, subst: *const Substitution) Error![]const ProofNode {
    var witness = subst.clone() catch return &.{};
    var trees: std.ArrayList(ProofNode) = .empty;
    for (goals) |g| {
        if (try topGoalNode(eng, g, &witness)) |node| {
            try trees.append(eng.allocator, node);
        }
    }
    return trees.toOwnedSlice(eng.allocator);
}

/// Re-prove `goals` under solution `subst` and print the proof tree(s).
pub fn explainSolution(eng: *Engine, goals: []const Goal, subst: *const Substitution) void {
    const trees = buildProofTrees(eng, goals, subst) catch return;
    writeRaw("\nBecause:\n");
    const witness = subst; // trees are fully walked at build time
    for (trees) |*node| {
        proof.printTree(node, witness, eng.allocator, 1);
    }
}

fn topGoalNode(eng: *Engine, g: Goal, witness: *Substitution) Error!?ProofNode {
    switch (g) {
        .call => |c| {
            if (try proveGoal(eng, c, witness, 0)) |node| return node;
            return ProofNode{ .goal = try walkCompound(eng, c, witness), .kind = .unproven, .children = &.{} };
        },
        .not => |inner| switch (inner.*) {
            .call => |c| {
                const walked = try walkCompound(eng, c, witness);
                const kind: ProofNode.Kind = if (try isProvable(eng, c, witness)) .unproven else .negation;
                return ProofNode{ .goal = walked, .kind = kind, .children = &.{} };
            },
            else => return null,
        },
        .cut => return null,
    }
}

fn walkCompound(eng: *Engine, c: Term.Compound, subst: *const Substitution) Error!Term.Compound {
    const walked = try subst.deepWalk(.{ .compound = c }, eng.allocator);
    return walked.compound;
}

fn isProvable(eng: *Engine, c: Term.Compound, witness: *const Substitution) Error!bool {
    var found = false;
    const goal_slice = try eng.allocator.alloc(Goal, 1);
    goal_slice[0] = .{ .call = c };
    const check_subst = try witness.clone();
    eng.checkGoals(goal_slice, check_subst, &found, 0) catch return false;
    return found;
}

/// Public negation check for Engine.whyNot. axiom-07s
pub fn isProvablePublic(eng: *Engine, c: Term.Compound, witness: *const Substitution) Error!bool {
    return isProvable(eng, c, witness);
}

/// Public entry for Engine.decide — same directed search. axiom-i01
pub fn proveGoalPublic(eng: *Engine, compound: Term.Compound, witness: *Substitution, depth: usize) Error!?ProofNode {
    return proveGoal(eng, compound, witness, depth);
}

/// Directed proof search. Unifications are committed into `witness` so
/// sibling body goals see bindings made by earlier ones (body-local
/// variables). Returns null when no proof exists.
fn proveGoal(eng: *Engine, compound: Term.Compound, witness: *Substitution, depth: usize) Error!?ProofNode {
    const wc = try walkCompound(eng, compound, witness);
    if (depth >= max_depth) {
        return ProofNode{ .goal = wc, .kind = .truncated, .children = &.{} };
    }

    if (try proveBuiltin(eng, wc, witness)) |node| return node;

    clause_loop: for (eng.clauses.items) |clause| {
        const renamed = try eng.renameClause(clause);
        var attempt = try witness.clone();
        const matched = unify(.{ .compound = wc }, .{ .compound = renamed.head }, &attempt) catch false;
        if (!matched) continue;

        if (renamed.body.len == 0) {
            witness.* = attempt;
            // store the goal resolved under the post-unification bindings —
            // fact leaves otherwise leak renamed variables into evidence
            const resolved = try walkCompound(eng, wc, witness);
            return ProofNode{ .goal = resolved, .kind = .fact, .children = &.{}, .clause_id = clause.id, .clause_label = clause.label };
        }

        // axiom-ek7: ground the body with the engine's full-backtracking
        // search before building child nodes. The per-goal directed pass
        // below commits to the first proof of each body goal; an existential
        // body var with several candidates (one not fixed by head
        // unification) would otherwise pick a dead end and fail the clause —
        // ":why" reported "unproven" for true answers and decide() returned
        // empty reasons/evidence.
        var grounded: std.ArrayList(Substitution) = .empty;
        eng.solveGoalsAll(renamed.body, try attempt.clone(), &grounded, 0) catch continue :clause_loop;
        if (grounded.items.len == 0) continue :clause_loop;
        attempt = grounded.items[0];

        var kids: std.ArrayList(ProofNode) = .empty;
        for (renamed.body) |bg| {
            switch (bg) {
                .call => |bc| {
                    const child = try proveGoal(eng, bc, &attempt, depth + 1);
                    if (child == null or child.?.kind == .unproven) continue :clause_loop;
                    try kids.append(eng.allocator, child.?);
                },
                .not => |inner| switch (inner.*) {
                    .call => |nc| {
                        if (try isProvable(eng, nc, &attempt)) continue :clause_loop;
                        try kids.append(eng.allocator, .{
                            .goal = try walkCompound(eng, nc, &attempt),
                            .kind = .negation,
                            .children = &.{},
                        });
                    },
                    else => {},
                },
                .cut => {},
            }
        }

        witness.* = attempt;
        const resolved = try walkCompound(eng, wc, witness);
        return ProofNode{
            .goal = resolved,
            .kind = .rule,
            .children = try kids.toOwnedSlice(eng.allocator),
            .clause_id = clause.id, // axiom-i01
            .clause_label = clause.label,
        };
    }

    return null;
}

/// Built-in predicates, witness flavor: verify (comparisons) or commit the
/// first satisfying binding (same_as, member_of, length, append_of).
/// Null means "not satisfiable as a built-in" — including non-builtin
/// functors, which then fall through to clause search.
fn proveBuiltin(eng: *Engine, wc: Term.Compound, witness: *Substitution) Error!?ProofNode {
    const f = wc.functor;
    const node = ProofNode{ .goal = wc, .kind = .builtin, .children = &.{} };

    if (std.mem.eql(u8, f, "same_as") and wc.args.len == 2) {
        var attempt = try witness.clone();
        if (unify(wc.args[0], wc.args[1], &attempt) catch false) {
            witness.* = attempt;
            return node;
        }
        return null;
    }
    if (std.mem.eql(u8, f, "less_than") and wc.args.len == 2) {
        const a = witness.walk(wc.args[0]);
        const b = witness.walk(wc.args[1]);
        if (a == .integer and b == .integer and a.integer < b.integer) return node;
        return null;
    }
    if (std.mem.eql(u8, f, "greater_than") and wc.args.len == 2) {
        const a = witness.walk(wc.args[0]);
        const b = witness.walk(wc.args[1]);
        if (a == .integer and b == .integer and a.integer > b.integer) return node;
        return null;
    }
    if (std.mem.eql(u8, f, "equal") and wc.args.len == 2) {
        const a = witness.walk(wc.args[0]);
        const b = witness.walk(wc.args[1]);
        if (a == .integer and b == .integer and a.integer == b.integer) return node;
        return null;
    }
    if (std.mem.eql(u8, f, "member_of") and wc.args.len == 2) {
        var list_term = witness.walk(wc.args[1]);
        while (true) {
            switch (list_term) {
                .list => |l| {
                    var attempt = try witness.clone();
                    if (unify(wc.args[0], l.head.*, &attempt) catch false) {
                        witness.* = attempt;
                        return node;
                    }
                    list_term = witness.walk(l.tail.*);
                },
                else => break,
            }
        }
        return null;
    }
    if (std.mem.eql(u8, f, "length") and wc.args.len == 2) {
        var list_term = witness.walk(wc.args[0]);
        var count: i64 = 0;
        while (true) {
            switch (list_term) {
                .list => |l| {
                    count += 1;
                    list_term = witness.walk(l.tail.*);
                },
                else => break,
            }
        }
        var attempt = try witness.clone();
        if (unify(wc.args[1], .{ .integer = count }, &attempt) catch false) {
            witness.* = attempt;
            return node;
        }
        return null;
    }
    if (std.mem.eql(u8, f, "append_of") and wc.args.len == 3) {
        const list_a = witness.walk(wc.args[1]);
        const list_b = witness.walk(wc.args[2]);
        const result = builtins.appendLists(eng.allocator, list_a, list_b) catch return null;
        var attempt = try witness.clone();
        if (unify(wc.args[0], result, &attempt) catch false) {
            witness.* = attempt;
            return node;
        }
        return null;
    }

    return null;
}
