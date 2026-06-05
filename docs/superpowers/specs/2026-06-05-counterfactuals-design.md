# Counterfactuals: "Why not?" — design

**Date:** 2026-06-05 · **Bead:** axiom-07s · **Status:** approved
(roadmap spec 1's deferred "counterfactuals: minimal failing conditions")

## Goal

`:why` explains a Yes. Nothing explains a Deny. After a denied or
indeterminate `Should`, "Why not?" reports what would have to change:

```
axiom> Should leslie deploy_release?
Indeterminate. (no outcome rule matched)
axiom> Why not?
Allow would need:
  - oncall_deploys: blocked at "leslie is oncall"
```

```
axiom> Should rae deploy_release?
Deny.
axiom> Why not?
Deny rules in effect:
  - contractors_limited, relying on: "rae is a contractor"
Allow would need:
  - oncall_deploys: blocked at "rae is oncall"
```

Honest scope: this is **per-rule first-blocker analysis**, not minimal
hitting sets across proofs (NP-ish, deferred). Removing a listed deny
dependency defuses *that* rule; another deny may still apply — rerun.

## Engine API (`Engine.whyNot`)

```zig
pub const NearMiss = struct {
    rule: []const u8,        // label or 16-hex id
    blocker: []const u8,     // canonical English of the first failing subgoal
    blocker_negated: bool,   // failing goal was a negation (i.e. the positive form is currently true)
};
pub const DenyPath = struct {
    rule: []const u8,
    evidence: []const []const u8, // removable supporting facts (ctx excluded)
};
pub const WhyNot = struct {
    near_misses: []const NearMiss, // allow rules that did not fire
    denies: []const DenyPath,      // deny rules that did fire
};
pub fn whyNot(self, subject, action, resource: ?[]const u8) !WhyNot
```

Algorithm (temp-ctx exactly like `decide`, popped after):

- **Denies**: for each solution of `outcome(ctx, deny)`, witness-prove and
  collect rule label + fact-leaf evidence (existing `collectFromProof`
  pieces; ctx scaffolding excluded). Dedupe by rule.
- **Near-misses**: for each clause whose head unifies with
  `outcome(ctx, allow)` (fresh rename, scratch substitution): prove body
  goals left-to-right with the witness prover, mutating the scratch
  substitution; on the first failure record the goal **walked under the
  scratch bindings** rendered via F2 (`goalToEnglish`), with
  `blocker_negated` true for `.not` goals (whose inner is provable). If
  the whole body proves, the rule fired (it is not a near-miss).
  Goals past the first blocker are unknown territory — one blocker per
  rule, by design.

## Surface

- REPL: `Why not?` — the `Should` handler stores the last inputs
  (`last_should`); `Why not?` without a prior `Should` prints
  `No decision to explain. Ask a Should question first.` After an
  *allowed* decision: `Last decision was Allow — nothing to explain.
  (:why explains it)`.
- Parser: `Why not?` recognized by lexeme backtracking (`Why` lexes as a
  variable), same pattern as `Should`/`Predicate`.
- C API: deferred — REPL/Zig first; `axiom_why_not` can mirror
  `axiom_decide` when an embedder asks.

## Testing

1. Indeterminate case: near-miss lists each allow rule with its true
   first blocker; rule order = clause order.
2. Deny case: deny rule + its removable evidence; near-misses still
   listed.
3. Negated blocker: allow rule with `S is not banned` where the subject
   is banned → blocker rendered with `blocker_negated` ("currently
   true").
4. Verification loop: assert the blocker fact from test 1, re-run
   `Should` → Allow (the counterfactual is real).
5. `Why not?` with no prior Should / after an Allow → the two messages.
6. Full regression battery.
