# Policy-VM roadmap — five specs

**Date:** 2026-06-05 · **Bead:** axiom-m2l (capture) · **Status:** roadmap, per-spec design pending

Author: Leslie. Annotated with implementation review against the codebase as
of `040f55a`. Each spec gets its own design doc + bead cycle before
implementation; this document is the source roadmap.

## Bead map and order

| Spec | Bead | Depends on |
|---|---|---|
| 2. Safe negation | `axiom-d4s` (epic) | — (ship first) |
| F1. Clause identity (α-normalized hash + ids) | `axiom-ekd` | — |
| F2. Canonical English printer | `axiom-xec` | — |
| 1. Decision objects | `axiom-i01` (epic) | F1 |
| 3. Strict mode + canonical display | `axiom-8zj` (epic) | F2 |
| 4. Versioned policy / diff / what-if | `axiom-aof` (epic) | F1, F2, 1 |
| 5. Agent envelope | `axiom-02w` (epic) | 1 |

## Review annotations (what the codebase already gives us / gaps)

- **Reasons/evidence (spec 1)**: the witness re-prover (`explain.zig`,
  axiom-9nz) already builds honest proof trees; `[rule]` nodes → reasons,
  `[fact]` leaves → evidence rendered from `Clause.source_text`
  (axiom-76a). Packaging, not new machinery.
- **Rule identity gap**: clauses have `source_text` but no stable id.
  F1 (`axiom-ekd`) adds an alpha-normalized hash — variables must be
  renamed positionally before hashing because `renameClause` makes
  variable names unstable across runs.
- **Conflict resolution gap (spec 1, OPEN)**: nothing prevents both
  `outcome allow` and `outcome deny` deriving for the same decision. Cut
  is a no-op; there is no rule priority. Decision: default strategy
  (deny-overrides?) must be settled in the spec for `axiom-i01`.
- **Structured-query caveat (spec 1)**: the structured C query API
  historically did not evaluate derived rules (2026-03-27 finding);
  `axiom_decide` must drive the goals path (`solveAll`).
- **Unsafe-negation lint (spec 2)**: left-to-right bound-variable
  dataflow over desugared bodies; `checks.zig` is the natural home and
  `:check` the surface. The floundering footgun is live today
  (`Who is happy?` over `\+ owner(X,Y)`).
- **closed_world (spec 2)**: extends `PredicateInfo` exactly as det/modes
  declarations already do.
- **Ambiguity enumeration (spec 3, descoped)**: parser is single-path
  recursive descent; parse-forest enumeration is a rework. v1 = strict
  default + `:show english` + curated suggestion table.
- **Snapshots (spec 4, descoped)**: per the roadmap's own alternative,
  operate on `(Program, Program′)` pairs and let git own versioning.

---

## Original roadmap text

### 1. Decision objects as first-class results

Turn "queries that return bindings" into **decisions** with structured
metadata: decision allow/deny/undecided, reasons (rules fired), evidence
(facts supporting), counterfactuals (later).

Conventional vocabulary (`Decision D has outcome allow.`, `... has subject
S.`, `... has reason_id Rule.`, `... has evidence Fact.`) — decision rules
are ordinary rules; nothing baked into the core. Host API:

```c
typedef enum { AXIOM_DECISION_ALLOW, AXIOM_DECISION_DENY,
               AXIOM_DECISION_INDETERMINATE } AxiomDecisionOutcome;

typedef struct {
    const char *id;
    AxiomDecisionOutcome outcome;
    const char *subject; const char *action; const char *resource;
    size_t reason_count;  const char **reasons;
    size_t evidence_count; const char **evidence;
} AxiomDecision;

AxiomDecision *axiom_decide(AxiomProgram *p, const char *subject,
                            const char *action, const char *resource);
```

`axiom_decide` asserts the input triples in a temporary scope, queries
`Decision D has outcome O.`, and uses proof explanation to extract
reasons + evidence. Memory: arena-owned until `axiom_free`. English
surface: `Should S A [R]?` queries; REPL prints outcome + reason tree.

### 2. Unknown vs false and safer negation

Three-valued *view* over standard NAF (no engine change):

- Pattern 1 — explicit unknown: `X has status unknown if X is not allowed
  and X is not denied.` (standard library pattern).
- Pattern 2 — constrained negation: `:check` flags `not G` where `G` has
  unbound variables at that point in the body; suggests binding earlier.
- Pattern 3 — closed-world annotations: `Predicate banned is
  closed_world.`; checker treats negation on closed-world predicates as
  safe by design; REPL explains "No (by closed-world assumption)".

### 3. Strict controlled English and canonicalization

Strict mode (default for policy): only documented patterns accepted;
unknown patterns are hard errors. Lenient mode: warnings, slightly broader
acceptance. `:mode strict|lenient`, `axiom_set_strict_mode()`.

Canonicalization: every accepted pattern has a canonical internal form and
a canonical pretty-printed English form; logically equivalent rules always
display identically (diff-friendly). `:show english`. Ambiguous phrasings
rejected in strict mode with canonical suggestions.

### 4. Versioned policy, diffs, and what-if analysis

Rule-level semantic diff over clause-structure (not text): stable hash of
desugared form → ADDED / REMOVED / MODIFIED, with canonical English
renderings. What-if: run `axiom_decide` for a set of subject/action/
resource inputs against two program versions; report deltas with reasons.
REPL tooling: `:snapshot baseline`, `:whatif decisions.txt`.

### 5. Agent / AI envelope integration

Axiom as deterministic substrate for LLM agents: guardrail contract
(`check(subject, action, resource?) → {allowed, decision}`) over
`axiom_decide`; hard gate + decision-as-context (deny explanations fed
back to the LLM, allowed alternatives via `Which actions can S perform on
R?` rule schema). Plan validation: per-step checks first; whole-plan
modeling (`Plan P is valid if every step in P is allowed.`) later.
