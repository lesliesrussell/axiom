# REPL polish — design

**Date:** 2026-06-05 · **Bead:** axiom-wk4 · **Status:** approved

Part 3 of the REPL improvement program (after KB management and deep :why).

## Items

### 1. File-load parse errors (silent data loss today)

`processSourceWithDir` swallows parse failures with a bare `recover()` — a
typo'd statement in a `.axm` file vanishes without a word. Fix:

- `processSourceWithDir` gains a `context: ?[]const u8` (filename; null for
  REPL lines).
- On parse failure, print `<file>:<line>:<col>: skipped statement near
  "<token>"` using the parser's existing `last_error_line/col/token`, then
  recover as before.
- The load summary reports skips: `Loaded 'rbac.axm' (52 clauses, 1
  skipped).` (skip part omitted when zero).

### 2. Quiet bulk loads

`Added: pred/N` per clause is feedback for interactive asserts, noise for
file loads. A `verbose_asserts: bool` on the `Axiom` struct gates the line:
true for REPL input, false during `loadFile` (and therefore includes and
`:reload`). Loads print `Loaded '<file>' (N clauses).` where N is the
clause-count delta around the load — no new counters.

### 3. ANSI colors

`output.zig` gains:

```zig
pub const Style = enum { err, ok, dim, accent, reset };
pub var color_enabled: bool = false;       // set once at REPL startup
pub fn style(s: Style) void;               // writes escape code when enabled
```

Enabled when stdout is a TTY and `NO_COLOR` is unset. Applied to:

- `Yes.` / solution lines — green (`ok`)
- `No.` and all error/usage messages — red (`err`)
- proof labels `[fact] [rule] [built-in] [negation] [...] [unproven?]` — dim
- `axiom> ` prompt — accent (cyan)

Piped output is byte-identical to today (every existing test relies on
this).

### 4. Caret on REPL parse errors

`printParseErrorWithPos` echoes the offending source line and a `^` under
the failing column:

```
Parse error at line 1, column 9 near "teh":
  Socrates teh a man.
          ^
```

Line extracted from the input by the parser's error line number; caret
clamped to the line length. File-load errors keep the one-line form from
item 1 (no echo — files can be long, the file:line:col reference suffices).

## Testing

1. Load a file with one bad statement between good ones → error line names
   file:line:col, good clauses load, summary says `1 skipped`.
2. File load prints summary only — no `Added:` lines; interactive assert
   still prints `Added:`.
3. All piped output contains zero ESC bytes (`grep -c $'\x1b'` → 0);
   save→clear→load and :why outputs unchanged vs master.
4. Caret column lines up under the offending token (fixed-width test line).
5. Interactive color smoke via `script -q` PTY capture: ESC codes present.
6. C FFI suite passes.
