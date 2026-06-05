# Strict mode + canonical display — design (spec 3, final scope)

**Date:** 2026-06-05 · **Bead:** axiom-8zj · **Status:** approved

## Scope honesty

Of the roadmap's three parts, two resolved during the program:

1. **Canonical display** — shipped as F2 (`:show english`, axiom-xec).
2. **Strict/lenient mode flag** — **dropped as vacuous**: unknown
   patterns already produce hard errors with skip-and-report everywhere
   (REPL since the start, file loads since axiom-wk4); there is no
   "broader lenient acceptance" implemented to toggle to. Strict *is*
   the only mode; documented rather than flagged. If a genuinely lenient
   grammar ever exists, the flag can return with meaning.
3. **Suggestion table** — this bead's substance.

## Phrasing hints

When a statement fails to parse, scan its source text for known
unsupported-English markers and append one targeted hint to the existing
error (both the REPL caret block and the file-load one-liner):

| Trigger | Hint |
|---|---|
| ` are ` / `Are ` | plurals — one sentence per subject: `X is a Y.` |
| `isn't aren't don't doesn't can't cannot won't` | contractions — write `is not` / `can` forms |
| leading `If ` / ` then ` | head-first conditionals — use the tail form: `X is mortal if X is a man.` |
| ` and ` before the verb (subject conjunction) | compound subjects — split into one sentence per subject |
| ` or ` | disjunction — write one rule per alternative |

First matching trigger wins (one hint, not a lecture). Matching is
case-insensitive on word boundaries to avoid false hits inside atoms
(`warehouse` must not trigger `are`).

## Testing

1. Each trigger phrase produces its hint in the REPL; file loads get the
   hint on the line after `file:line:col: skipped …`.
2. `warehouse(x)`-style false-positive guard: `Warenhaus is a thing.`
   and atoms containing `are`/`or` produce no hint.
3. Statements that parse fine are unaffected; full regression battery.
