# Decision objects — design (spec 1)

**Date:** 2026-06-05 · **Bead:** axiom-i01 · **Status:** approved
(conflict resolution decided 2026-06-05: deny-overrides)

## Schema (deviation from roadmap, flagged)

The roadmap's `Decision D has outcome allow.` does not parse — capitalized
`Decision` lexes as a variable — and the noun adds nothing logically.
Canonical schema drops it; everything below parses today:

```
D has outcome allow
  if D has subject S and D has action log_in and S can log_in.

% id: login_rule_1
D has outcome deny
  if D has subject S and D has action log_in and S is banned.
```

Desugared: `outcome(D, allow)`, `subject(D, S)`, `action(D, A)`,
`resource(D, R)`, optional `reason_id(D, Label)`.

## Engine API (`Engine.decide`)

```zig
pub const Decision = struct {
    outcome: enum { allow, deny, indeterminate },
    reasons: []const []const u8,   // explicit reason_id atoms, else rule labels/hex ids from the proof
    evidence: []const []const u8,  // canonical English of ground fact leaves
};
pub fn decide(self, subject, action, resource: ?[]const u8) !Decision
```

1. **Temp scope**: assert `subject(axiom_decision_ctx, <subject>)`,
   `action(ctx, <action>)`, and `resource(ctx, <resource>)` when given;
   record the clause count, and pop back to it afterward (works because
   asserts append at the end). The ctx atom `axiom_decision_ctx` is
   reserved by convention.
2. **Outcomes**: `solveAll` on `outcome(axiom_decision_ctx, O)` (goals
   path — the structured path historically skipped derived rules).
3. **Deny-overrides**: any solution binding O to `deny` → DENY; else any
   `allow` → ALLOW; else (including exotic outcome atoms) INDETERMINATE.
4. **Reasons**: query `reason_id(ctx, R)` under the winning scope; if any
   bindings, those atoms are the reasons. Otherwise, witness re-prove the
   winning `outcome(ctx, <o>)` and collect each `[rule]` node's clause
   label (or 16-hex id when unlabeled).
5. **Evidence**: `[fact]` leaves of the same proof, rendered as canonical
   English (F2's printer, new `goalToEnglish` for ground compounds) —
   **excluding** facts that mention the ctx atom (the temp-asserted
   triples are scaffolding, not evidence).

### ProofNode extension

`ProofNode` gains `clause_id: u64` and `clause_label: []const u8` set by
the witness re-prover when a clause matches. `:why` displays labels when
present: `[rule login_rule_1]` instead of `[rule]` — a small visible
upgrade for free.

## Surface

**REPL**: `Should <subject> <action> [<resource>]?` — recognized like the
`Predicate` declaration (lexeme `Should`, full-shape backtracking).
Output:

```
axiom> Should leslie log_in?
Allow.
Reasons:
  - login_rule_1
Evidence:
  - leslie is a user.
```

Colored: Allow green, Deny red, Indeterminate plain.

**Zig module** (`lib.zig`): `Program.decide(subject, action, resource)`
returning the engine struct.

**C FFI** (`capi.zig` + `include/axiom.h`):

```c
typedef enum { AXIOM_DECISION_ALLOW, AXIOM_DECISION_DENY,
               AXIOM_DECISION_INDETERMINATE } AxiomDecisionOutcome;
typedef struct {
    AxiomDecisionOutcome outcome;
    const char *subject; const char *action; const char *resource;
    size_t reason_count;   const char **reasons;
    size_t evidence_count; const char **evidence;
} AxiomDecision;
AxiomDecision *axiom_decide(AxiomProgram *p, const char *subject,
                            const char *action, const char *resource);
```

Arena-owned, freed by `axiom_free`, NULL resource allowed — consistent
with the existing memory model. `examples/ffi_test.c` gains decide cases.

## Testing

1. Allow path: policy KB grants; `Should` prints Allow + reason label +
   evidence; ctx scaffolding absent from evidence.
2. Deny-overrides: KB deriving both allow and deny → Deny.
3. Indeterminate: no outcome rules match.
4. Explicit `reason_id` rules take precedence over proof-derived labels.
5. Temp-scope hygiene: clause count identical before/after decide;
   repeated decides don't accumulate.
6. `:why` shows `[rule <label>]` for labeled rules.
7. C FFI: allow/deny/indeterminate via `axiom_decide`; existing suite
   still passes. Full regression battery.
