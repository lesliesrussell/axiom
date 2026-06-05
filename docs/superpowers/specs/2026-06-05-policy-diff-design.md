# Versioned policy: semantic diff + what-if — design (spec 4)

**Date:** 2026-06-05 · **Bead:** axiom-aof · **Status:** approved

## Descopes (per roadmap's own alternatives, plus one)

- No `ProgramSnapshot` objects: operate on `(Program, Program′)` pairs;
  git owns versioning.
- No `:snapshot baseline` REPL state: stateless `:diff <oldfile>
  <newfile>` and `:whatif <oldfile> <newfile> <inputsfile>` — versions are
  files.

## Semantic diff (`src/diff.zig`, engine module)

```zig
pub const DiffKind = enum { added, removed, modified };
pub const RuleDiff = struct {
    kind: DiffKind,
    old_clause: ?Clause, // null for added
    new_clause: ?Clause, // null for removed
};
pub fn diffPrograms(allocator, old: []const Clause, new: []const Clause) ![]RuleDiff
```

Algorithm:

1. Count-map of F1 hashes per side (multiset — duplicate clauses behave).
2. Hash present in both with equal counts → unchanged (not reported).
3. Surplus hashes on one side become candidates.
4. **Modified pairing**: a removed candidate and an added candidate with
   the same non-empty `% id:` label pair as MODIFIED (the label names the
   rule across edits). Everything else is ADDED / REMOVED.
5. Alpha-renamed-only edits hash identically (F1) → no diff entry. That
   is the point.

English renderings come from F2's `clauseToEnglish` at the display layer.

## What-if

`Engine`-level helper composes existing pieces: for each input
`(subject, action, resource?)`, run `decide` on both programs; report
inputs whose **outcome** differs (reason-only changes are not deltas in
v1 — documented).

## REPL

```
axiom> :diff v1/policy.axm v2/policy.axm
+ added:    X has outcome allow if ... 
- removed:  ...
~ modified (mfa_rule):
    old: D has outcome deny if ...
    new: D has outcome allow if ...

axiom> :whatif v1/policy.axm v2/policy.axm inputs.txt
Changed:
  alice log_in: deny -> allow
    old reasons: mfa_required
    new reasons: mfa_requirement_removed
```

- Inputs file: one `subject action [resource]` per line, `%` comments and
  blanks skipped.
- Scratch loading reuses the full loader (spans, labels, includes, skip
  reporting) by temporarily swapping `self.engine` with a fresh one and
  restoring after — Engine is a value, the swap is safe and total.
- Colors: added green, removed red, modified accent (piped stays plain).

## C FFI (`include/axiom.h`)

```c
typedef enum { AXIOM_DIFF_ADDED, AXIOM_DIFF_REMOVED, AXIOM_DIFF_MODIFIED } AxiomDiffKind;
typedef struct {
    AxiomDiffKind kind;
    const char *predicate;    /* "name/arity" of the head */
    const char *rule_id;      /* label, or 16-hex clause id */
    const char *old_english;  /* NULL for added */
    const char *new_english;  /* NULL for removed */
} AxiomRuleDiff;
AxiomRuleDiff *axiom_diff_programs(AxiomProgram *oldp, AxiomProgram *newp, size_t *out_count);

typedef struct { const char *subject; const char *action; const char *resource; } AxiomDecisionInput;
typedef struct {
    AxiomDecisionInput input;
    AxiomDecision *old_decision;
    AxiomDecision *new_decision;
} AxiomDecisionDelta;
AxiomDecisionDelta *axiom_compare_decisions(AxiomProgram *oldp, AxiomProgram *newp,
    const AxiomDecisionInput *inputs, size_t input_count, size_t *out_count);
```

Results are owned by **newp's arena** (documented; freed by
`axiom_free(newp)`).

## Testing

1. Diff fixture: added + removed + label-paired modified + unchanged +
   alpha-renamed-only → exact kinds, renamed rule absent from output.
2. What-if fixture: v1 denies, v2 allows for one input; second input
   unchanged → only the first reported, with old/new reasons.
3. C FFI: diff count/kinds + compare delta smoke.
4. Full regression battery.
