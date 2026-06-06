# RFC bundle 001–005 — capture + review annotations

**Date:** 2026-06-06 · **Bead:** axiom-2o2 (capture) · **Status:** roadmap;
per-RFC design pending

Author: Leslie. The full RFC text lives in the session record; this
document captures the bead map, the review annotations against the
codebase as of `b55cb4b`, and the open decisions. Each RFC gets its own
design doc + bead cycle before implementation.

## Bead map and adoption order

Author's order: 001 → 002 → 005 → 004 → 003.
Adjusted order (agreed rationale below): **002 → 005 → 001 → 004 → 003**.

| RFC | Bead | Status notes |
|---|---|---|
| 002 Safe negation modes | `axiom-f2a` (P1) | **Phase 1 already shipped** (axiom-d4s lint); remaining: stratification graph, mode directive, probe display |
| 005 Structured explanation API | `axiom-52r` (P1) | IR mostly exists (ProofNode/Decision/WhyNot); packaging + JSON + FFI |
| 001 Schemas & typing | `axiom-u02` (P2) | blocked on two syntax decisions (below) |
| 004 Temporal | `axiom-bec` (P2) | encoding decision flagged (compound terms vs Term-union variants) |
| 003 Incremental/indexing | `axiom-p9x` (P3) | blocked-by 001+002 per both orderings; benchmark harness is a prerequisite |

## Review annotations

- **RFC 002 is half-done.** The safety rule (vars in negated goals bound
  by earlier positive goals; head occurrence does not count) shipped in
  axiom-d4s with closed_world explicitly *not* bypassing the check — both
  match the RFC text. New work is the stratification analysis (predicate
  dependency graph, negative-cycle detection — checks.zig) and the
  `Negation mode is …` directive (lexeme-backtracking parse like the
  `Predicate … is closed_world.` form).
- **RFC 005's data model already exists internally.** `ProofNode`
  carries kind/goal/clause_id/label/children; `Engine.Decision` is the
  decision_summary; `Engine.WhyNot` is counterfactual_block. The work is
  a unifying document model, a versioned JSON serializer, FFI/Zig
  accessors, and `:why json`. `failed_goal`/diagnostic mode is the only
  genuinely new machinery (bounded failed-branch capture).
- **RFC 001 has two syntax collisions to settle first:**
  1. `Person is a type.` is a *valid fact today* — it asserts
     `type(person)`. Reserving the noun silently changes existing
     programs.
  2. `parent has modes (+, -).` duplicates the existing
     `mode parent(+In, -Out).` declaration shipped in March — two
     surface forms for one concept contradicts the canonicalization
     principle (one canonical form per meaning).
- **RFC 004 encoding recommendation:** new `Term` union variants ripple
  through unify, deepWalk, identity hashing, the English printer, and
  the C ABI. A v1 that lexes ISO literals into **compound terms**
  (`date(2026, 6, 30)`) gets the same surface and built-ins with zero
  union surgery; promotion to first-class variants can come later if
  arithmetic-heavy workloads demand it. Ambient-`Now` rejection matches
  the `axiom_decision_ctx` precedent: context is asserted, not ambient.
- **RFC 003 correctly last.** `solveGoalsAll` scans clauses linearly;
  predicate/first-arg indexes with insertion-ordered buckets preserve
  today's solution order. F1's alpha-normalized hashes already enable
  the reload-reuse story. The witness re-prover already satisfies the
  "explanations re-prove rather than serialize caches" requirement. No
  benchmark suite exists — building one is part of the epic.

## Open decisions (need author input)

1. **RFC 001 declaration syntax** — given the collisions: reserve nouns
   (`type`, `predicate`) and accept the breakage; or introduce a
   distinct declaration form (e.g. extending the existing `mode …`
   keyword family: `type Person.`, `schema parent(Person, Person).`);
   or prefix-keyword everything. The existing `mode` declaration should
   remain the single mode syntax either way.
2. **RFC 002 default timeline** — compatibility default for one release
   per the RFC; should `examples/` and `lib/policy.axm` opt into
   `strict` immediately as flagship usage?
3. **RFC 004 v1 encoding** — compound-term dates (cheap, recommended)
   vs first-class Term variants (heavier, prettier internals).
4. **RFC 005 schema stability** — which JSON fields are frozen at v1
   (`kind`, `goal`, `english`, `rule_id`, `children`?) and what the
   version field looks like.
