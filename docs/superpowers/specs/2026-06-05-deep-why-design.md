# Deep `:why` proof trees — design

**Date:** 2026-06-05 · **Bead:** axiom-9nz · **Status:** approved

Part 2 of the REPL improvement program (after KB management, axiom-76a).

## Problem

`:why` is shallow and sometimes lies. The engine records `last_proof` once at
the first clause match during resolution and never populates children;
`printProofNode` then fabricates sub-nodes from the clause body with
hard-coded `[fact]` labels — a body goal proven by a rule, a built-in, or a
negation is mislabeled. Explainability is the product's core pitch; the
explanation must be real.

## Approach: witness re-prover

Resolution flattens rule bodies into one goal list (`concatGoals`), which
destroys the parent/child structure a proof tree needs. Rather than tag goals
with provenance (invasive) or restructure the resolution loop (risky), a
separate **directed re-prover** runs only when `:why` is invoked: with the
solution's bindings in hand the goal is (mostly) ground, so the search is
narrow and fast. Precedent: `checkGoals` is already a parallel evaluator.

**Caveat (accepted):** if two clauses can prove the same ground goal, the
witness may select a different one than the original run did. Any valid proof
of the solution is a correct explanation.

## REPL surface

| Input | Behavior |
|---|---|
| `:why` | Explain solution 1 of the last successful query |
| `:why <n>` | Explain the nth displayed solution |
| `:why <out-of-range>` | `Query had K solutions — :why 1..K.` |
| `:why`, no query yet | Existing "No successful query" message |

`main.zig` replaces `last_solution: ?Substitution` with `last_solutions:
[]Substitution` (the slice `solveAll` returned — arena-owned, already alive).
`last_query_goals` already exists.

## Re-prover (`src/explain.zig`, engine module)

```
proveGoal(eng, compound, subst, allocator, depth) ?ProofNode
```

1. `deepWalk` the goal under the solution substitution.
2. Built-in functor (same set as `builtins.zig`) → `[built-in]` leaf.
3. Else iterate clauses: rename, unify walked goal against head in a scratch
   substitution. Empty body → `[fact]` leaf. Non-empty body → recursively
   prove every body goal under the scratch substitution; all succeed →
   `[rule]` node with those children. First proving clause wins.
4. Negated body goal (`.not`) → confirm unprovable via `eng.checkGoals` →
   `[negation]` leaf showing `\+ goal`. Cut goals are skipped.
5. `depth >= 64` → return a truncation node printed as `[...]`; cyclic KBs
   can never hang the explainer.
6. No proof found (shouldn't happen for a real solution; possible after
   `:retract`) → `[unproven?]` leaf rather than silence.

`ProofNode.children` (already in `proof.zig`) finally gets populated;
printing in `proof.zig` recurses over real children instead of fabricating
them from clause bodies.

## Engine changes

**Removed** (dead once the re-prover exists):
- `Engine.last_proof` field and its reset in `solveAll`
- the set-once recording block inside `solveGoalsAll`
- `getLastProof`, and `explainLastProof`'s dependence on stored state

**Added:**
- `Engine.explainSolution(goals: []const Goal, subst: *const Substitution)
  void` — runs the re-prover over the query's goals and prints the tree(s)
  in the existing visual style.

Net effect: the hot resolution path gets simpler.

## Output format

Same visual language as today, recursive and truthful:

```
Because:
  - grandparent(tom, ann)  [rule]
    - parent(tom, bob)  [fact]
    - parent(bob, ann)  [fact]
```

Leaves: `[fact]`, `[built-in]`, `\+ p(...)  [negation]`, `[...]`
(depth-capped), `[unproven?]`. Terms print resolved under the solution
substitution.

## Testing

Piped-REPL verification:

1. Socrates 2-level: rule node with one real `[fact]` child.
2. 3-level chain: grandparent → two parent facts; nested rule (mortal via
   man via rule) shows `[rule]` child labeled correctly — the case the old
   code mislabeled.
3. Recursive ancestor on a 3-node chain: tree terminates, correct shape.
4. Negation in body → `[negation]` leaf.
5. Built-in in body (`less_than`) → `[built-in]` leaf.
6. `:why 2` explains the second solution; `:why 99` reports the range;
   `:why` with no query keeps the existing message.
7. C FFI suite still passes (capi does not use proof APIs).
