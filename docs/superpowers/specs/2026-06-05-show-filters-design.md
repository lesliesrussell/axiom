# `:show` filters — design

**Date:** 2026-06-05 · **Bead:** axiom-krf · **Status:** approved

## Problem

`:show` dumps every loaded clause. In a large knowledge base (rbac.axm has
~50 clauses) there is no way to see only the ground facts or only the rules.

## Design

Extend the REPL `:show` command with an optional filter word. Display-only:
the filter lives in `main.zig`; the engine API is untouched (a fact is
already distinguishable as `clause.body.len == 0`).

| Input | Behavior |
|---|---|
| `:show` | All clauses, unchanged output |
| `:show facts` | Only clauses with empty body |
| `:show rules` | Only clauses with non-empty body |
| `:show <other>` | `Usage: :show [facts|rules]` |

Rules:

- **Global indices**: filtered views keep each clause's position in the full
  clause list (fact #7 prints as `7:` everywhere), so numbers cross-reference
  between views.
- **Empty results**: `No facts loaded.` / `No rules loaded.` (full `:show`
  keeps `No clauses loaded.`).
- `:help` gains the filter syntax: `:show [facts|rules]`.
- The parser-level English command path (`.show`) keeps listing everything.

## Implementation sketch

- `const ShowFilter = enum { all, facts, rules };`
- `showClauses(self, filter)` — one skip-check inside the existing loop;
  empty-message text switches on the filter.
- REPL loop: exact `:show` match → `.all`; `startsWith ":show "` → parse the
  trailing word, unknown → usage line.

## Testing

No zig test harness exists. Verify by piping REPL input and checking output:
load a mixed fact/rule base, assert `:show facts` excludes rules and keeps
original indices, `:show rules` the inverse, `:show junk` prints usage.
