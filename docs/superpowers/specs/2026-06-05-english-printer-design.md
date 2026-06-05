# Canonical English pretty-printer — design (F2)

**Date:** 2026-06-05 · **Bead:** axiom-xec · **Status:** approved
(foundation for strict-mode display `axiom-8zj` and diff `axiom-aof`)

## Goal

A total, deterministic mapping clause → English for the supported subset,
so logically equivalent rules always display identically (diff-friendly).
Desugaring is lossy — `X has role admin.` and `X is a role of admin.`
both produce `role(X, admin)` — so canonicalization picks **one** surface
form per logical shape.

## Canonical forms (in precedence order)

| Shape | Canonical English | Round-trips |
|---|---|---|
| `can_V(X)` (functor prefix `can_`, unary) | `X can V.` | ✓ |
| builtin binary (`same_as`, `less_than`, `greater_than`, `equal`, `member_of`) | `X is <builtin> Y.` | ✓ |
| `p(X)` unary | `X is a p.` | ✓ |
| `p(X, Y)` binary | `X is a p of Y.` | ✓ |
| negated unary | `X is not a p` (in rule bodies) | ✓ |
| negated binary | `X is not a p of Y` | ✓ (since axiom-g00) |
| anything else (arity ≥3, `append_of/3`, cut) | fallback: raw functor form `p(X, Y, Z)` / `!` | ✗ display-only |

- Rules: `<head> if <cond> and <cond> …`; facts: `<head>.`
- Det markers appended to the head as in `:show` (`!`, `?`, `*`) — they
  parse back.
- Adjective loss is accepted: `fluffy(luna)` renders `Luna is a fluffy.`
  — grammatically clunky, logically canonical. Documented, not fixed.
- Variable names render as-authored (alpha-renaming display would hurt
  familiarity; identity questions are F1's hashes, not the display).
- Atoms render verbatim; proper-noun capitalization is not reconstructed
  (`socrates`, not `Socrates`) — parses fine either way.

## API

`src/english.zig` (engine module):

```zig
pub fn clauseToEnglish(allocator, clause) ![]const u8   // owned by allocator
pub fn isFullyMappable(clause) bool                     // false → fallback used somewhere
```

REPL: `:show english` lists `index: <canonical sentence>` for every
clause (always canonical — never the stored source_text; that is the
point). `:help` updated. Diff (`axiom-aof`) will consume
`clauseToEnglish` for old/new renderings.

## Testing

1. **Round-trip property**: load a fixture covering every mappable shape,
   render all clauses to English, load the rendered text into a fresh
   session, compare `:show ids` hash multisets — must be identical.
2. Canonical collapse: `X has role admin.` and `X is a role of admin.`
   render to the same sentence.
3. Fallback: a ternary clause renders in functor form and
   `isFullyMappable` is false (display marked `% internal:`).
4. Regression: piped battery, examples sweep, PTY, FFI.
