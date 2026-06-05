# Safe negation — design

**Date:** 2026-06-05 · **Bead:** axiom-d4s · **Status:** approved (spec 2 of
policy-VM roadmap)

## Problem

Negation-as-failure flounders on unbound variables (`Who is happy?` over
`\+ owner(X, Y)` silently answers No), and "no proof" is conflated with
"known false". Policy authors need the footgun flagged and the intent
expressible. No engine semantics change.

## Part A — unsafe-negation lint (`:check`)

A negated goal is **safe** when every variable in it also appears in an
earlier *positive* body goal (head occurrence does not count — callers may
leave head variables unbound, e.g. `Who` queries).

- Implemented in `checks.zig` over desugared clauses: scan each body
  left-to-right keeping a bound-variable set (vars of positive `.call`
  goals); for each `.not` goal, any variable not in the set is reported.
- Warning shows the original sentence when available:

```
Warning: negation on unbound variable X in:
  X can log_in if X is not banned.
Suggestion: bind X with a positive condition earlier in the rule body.
```

- Runs as part of `:check` (alongside det/mode checks).

## Part B — closed-world declarations

```
Predicate banned is closed_world.
```

- Parse: statement form recognized when the first token's lexeme is
  exactly `Predicate`, followed by an identifier, `is`, `closed_world`.
  (Capitalized `Predicate` lexes as a variable token; the parser
  special-cases the lexeme before sentence parsing.)
- Storage: `Engine.closed_world_preds: StringHashMap(void)` keyed by
  predicate name (all arities). Shown by `:pred name/arity`.
- REPL semantics annotation: a yes/no query whose positive goals are all
  closed-world predicates answers
  `No (by closed-world assumption; no proof found).` instead of `No.`
- **Divergence from roadmap text:** a closed-world declaration does NOT
  silence the Part-A unbound warning — CWA is about meaning ("absence is
  falsity"), floundering is an operational hazard; both can apply.

## Part C — three-valued status pattern (`lib/policy.axm`)

Standard-library pattern giving explicit unknown:

```
X has status allowed if X is a subject and X is allowed.
X has status denied if X is a subject and X is denied.
X has status unknown if X is a subject and X is not allowed and X is not denied.
```

Note the `subject/1` domain predicate: the naive roadmap version
(`X has status unknown if X is not allowed and X is not denied.`) is
itself unsafe negation — Part A's lint would flag it, correctly. The
library version demonstrates the safe idiom: bind against a domain, then
negate. File header documents this and the closed_world pairing
(`Predicate allowed is closed_world.` etc. left to the consuming KB).

## Testing

1. Lint: rule with unbound negated var warns with sentence + suggestion;
   the safe variant (bound earlier) does not; head-only binding warns.
2. `Predicate banned is closed_world.` parses; `:pred banned/1` shows it;
   `Is Leslie banned?` (no facts) prints the CWA-annotated No; non-CW
   predicates keep plain `No.`
3. `lib/policy.axm` loads clean (0 skipped) and passes its own lint; the
   status pattern answers allowed/denied/unknown correctly on a 3-subject
   fixture.
4. Regression: examples sweep zero skips, tutorial/rbac load, PTY suite,
   C FFI suite.
