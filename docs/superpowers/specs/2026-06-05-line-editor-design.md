# Interactive line editor — design

**Date:** 2026-06-05 · **Bead:** axiom-82z · **Status:** approved

Part 4 (final) of the REPL improvement program.

## Problem

The REPL reads raw stdin: no history recall, no line editing beyond the
terminal driver's backspace, no completion. Daily use means retyping
queries and `:load` paths.

## Activation gate

The editor runs only when **stdin and stdout are both TTYs**
(`File.isTty`). Piped/redirected input keeps the existing `readStreaming`
loop untouched — every scripted test remains byte-identical. `repl()`
refactors its per-line dispatch body into `handleLine(input) bool`
(false = quit), shared by both paths.

## Module: `src/editor.zig`

Root-module file (REPL concern, not part of the engine library).

**Raw mode** — `std.posix.tcgetattr`/`tcsetattr`: save original, clear
`ICANON | ECHO | ISIG` (and `IXON` for C-s/C-q passthrough), VMIN=1
VTIME=0. Restored via defer on every exit path. C-c arrives as byte 0x03
(line cancel); C-d on empty line returns null (EOF → quit).

**Rendering** — full-line redraw per keystroke: `\r` + prompt + buffer +
`ESC[K` + `\r` + cursor-forward(prompt+cursor). Simple and flicker-free at
REPL line lengths. Lines longer than the terminal width render imperfectly
— accepted v1 limitation.

**Keymap** (emacs; dispatch table `byte/escape-seq → Action` so a vim mode
can layer on later):

| Keys | Action |
|---|---|
| C-a / C-e, Home / End | line start / end |
| C-b / C-f, ← / → | char left / right |
| ESC b / ESC f (Alt) | word left / right |
| C-k / C-u / C-w | kill to EOL / whole line / word back |
| Backspace (0x7f/0x08) | delete back |
| C-d | delete forward; on empty line: EOF |
| C-p / C-n, ↑ / ↓ | history prev / next (in-progress edit stashed) |
| C-l | clear screen, redraw line |
| C-c | cancel line, fresh prompt |
| Enter (\r or \n) | accept line |
| Tab | completion (below) |

Unrecognized control bytes and incomplete escape sequences are ignored.

## History

- In-memory `ArrayList([]const u8)`; ↑/↓ walks entries, stashing the
  in-progress line; editing a recalled entry edits a copy.
- Persisted to `$HOME/.axiom_history` (`HOME` from `init.environ_map`;
  feature off if unset). Loaded at startup (last 1000 entries kept);
  appended on accept — crash-safe. Consecutive duplicates and empty lines
  are not appended. File grows unbounded (accepted; trim is a later nicety).

## Tab completion

Context decided by inspecting the buffer:

1. **Command position** (starts with `:`, no space yet): cycle through the
   command list (`:check`, `:clear`, `:help`, `:load`, `:pred`, `:quit`,
   `:reload`, `:retract`, `:save`, `:show`, `:show facts`, `:show rules`,
   `:trace`, `:why`) filtered by the typed prefix. Repeated Tab cycles;
   any other key commits.
2. **File argument** (after `:load ` or `:save `):
   - **fzf available**: restore cooked termios → `std.process.spawn` `fzf`
     with stdout piped, stdin+stderr inherited (fzf owns the screen) →
     read selection → re-enter raw mode, full redraw with selection
     inserted. fzf detected by spawn attempt; `FileNotFound` → fallback.
     Non-zero exit (user ESC'd fzf) → no change, redraw.
   - **fallback**: cycle entries of the path's directory matching the
     typed prefix; `.axm` files and directories listed first.
3. Anywhere else: Tab inserts nothing (no-op).

## main.zig changes

- `repl()` splits: TTY path constructs `Editor` and loops
  `editor.readLine("axiom> ")`; pipe path keeps the current loop verbatim.
  Both feed `handleLine`.
- Prompt styling moves into the prompt string passed to the editor
  (accent + reset), since the editor re-renders it.
- `Editor.init` receives allocator + `HOME` value from `main`'s
  `init.environ_map`.

## Out of scope (documented)

- vim mode (keymap seam left in place)
- line-wrap-aware rendering; reverse-i-search (C-r); window-resize
  handling mid-edit; Windows console support; history file trimming

## Testing

1. **PTY driver** (python `pty` module, test script in `scripts/`):
   spawns the real binary on a pseudo-terminal, writes keystroke bytes,
   asserts on rendered output. Cases: type+enter echo; C-a/C-e/C-k edit;
   backspace; ↑ recalls prior line; ↑↑↓ navigation; C-c cancels; C-d
   quits; tab cycles `:l` → `:load`; history persists across two runs
   (HOME pointed at a temp dir).
2. **Piped regression**: full existing smoke battery byte-identical
   (editor never activates).
3. fzf path exercised manually (PTY automation of fzf's UI is out of
   scope); fallback cycling covered by the PTY driver with fzf shadowed
   off PATH.
4. C FFI suite unchanged.
