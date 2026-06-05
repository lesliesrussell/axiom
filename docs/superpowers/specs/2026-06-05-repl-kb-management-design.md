# REPL KB management — design

**Date:** 2026-06-05 · **Bead:** axiom-76a · **Status:** approved

Part 1 of the REPL improvement program (KB management → debugging/explain →
polish → input UX). Each part is its own spec/bead/branch cycle.

## Problem

The REPL is assert-only. A mistyped fact can't be removed without restarting;
a session's knowledge base can't be persisted; the edit-`.axm`-retest loop
requires retyping `:load` paths. The REPL should be a workbench.

## Commands

| Command | Behavior |
|---|---|
| `:retract <n>` | Remove clause #n (the index `:show` prints). Echo what was removed: `Retracted 7: man(plato).` Out-of-range or non-numeric → error message. Numbers are list positions and shift down after removal — documented in `:help`. |
| `:clear` | Wipe clauses, pred_info (det/mode declarations), and the loaded-file list. Print `Cleared N clauses.` No confirmation prompt. |
| `:save <file>` | Write each clause's original source sentence, in KB order, one per line. Output is an `.axm` file that `:load` reads back exactly. Clauses with no source text (asserted via lib/capi) are skipped and counted: `Saved 12 clauses (2 had no source text).` |
| `:reload` | `:clear`, then re-`:load` every explicitly loaded file (CLI args and `:load`s, in original order). Interactive asserts are lost — that is `:save`'s job. Per-file load output as today. Missing files error and are skipped. |

## Source-text plumbing

`types.Clause` gains `source_text: []const u8 = ""`. Capture points:

- REPL line input: the trimmed sentence line.
- File loading: each statement's source **span** — the raw text from the
  statement's first token through its terminating period (not the whole
  line: two sentences can share a line, one sentence cannot span lines
  today but spans are robust if that changes). The parser exposes each
  statement's start/end token offsets to make this slice.
- lib.zig `assertFact`/`assertRule` and capi programmatic asserts: `""`.

The text is owned by the engine allocator (duped on addClause) so REPL line
buffers can be reused safely.

## Engine additions (API-additive)

- `removeClause(self, index: usize) ?Clause` — `clauses.orderedRemove`;
  returns the removed clause for echo, null if out of range. Arena memory is
  not reclaimed until engine death (same policy as all clause data).
- `clearClauses(self)` — empties the clause list and pred_info map.
- `:retract` deliberately does **not** touch pred_info: det/mode declarations
  describe the predicate, not one clause.

REPL-side state (main.zig `Axiom` struct): `loaded_files:
std.ArrayList([]const u8)` appended on every successful explicit load.

## Limitations (documented, out of scope)

- Interactive **mode declarations** are not written by `:save` (only clauses
  carry source text).
- `:reload` re-reads from disk; deleted files are skipped with an error line.
- No sentence-pattern retract (`:retract Socrates is a man.`) — may layer on
  later.

## Testing

Piped-REPL verification (no zig test harness exists):

1. Assert 3 facts + 1 rule → `:retract 2` → `:show` shows renumbered list
   without the retracted fact; retract echo correct; `:retract 99` errors.
2. `:save /tmp/kb.axm` → `:clear` → `:load /tmp/kb.axm` → `:show` matches
   pre-clear listing byte-for-byte.
3. `:load` a temp file, edit it on disk, `:reload` → new content visible;
   interactive asserts gone.
4. C FFI test still passes (Clause field addition is default-valued).
