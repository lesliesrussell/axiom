# JSON protocol mode + agent skills — design

**Date:** 2026-06-06 · **Beads:** axiom-47h (protocol), axiom-o2b (skills,
blocked by 47h) · **Status:** approved

## Goal

Make Axiom drivable by AI coding agents (Claude Code, Codex, pi.dev,
Hermes, …): `axiom --json` turns stdin/stdout into a line-oriented JSON
protocol, and an installable skill teaches agents to use it. Leaner than
the withdrawn RFC 005: an output-mode toggle at the REPL boundary over
structures that already exist (`ProofNode`, `Decision`, `WhyNot`, diff
results) — serialization, not new machinery.

## Part A — protocol (axiom-47h)

### Activation

- CLI: `axiom --json [files…]` — flags parsed before file arguments;
  forces the piped loop even on a TTY; colors, banner, and prompts
  suppressed. stdout carries protocol objects only.
- REPL: `:json` toggles mid-session (response to the toggle itself is a
  `mode` object when turning on, plain text when turning off).

### Framing

JSONL — exactly **one JSON object, one line, per input statement**.
Envelope on every object:

```json
{"v": 1, "input": "Should vega dock?", "type": "decision", ...}
```

Blank lines and pure comments produce no output. A multi-statement input
line produces one object per statement.

### Response types

| type | payload fields |
|---|---|
| `ok` | `added: {pred, arity, id, label}` — assertions; also mode/cw declarations (`declared`) |
| `yesno` | `answer: bool, cwa: bool` |
| `solutions` | `count, solutions: [{Var: value, …}]` (No. = `count: 0`) |
| `decision` | `outcome, reasons[], evidence[]` |
| `whynot` | `denies: [{rule, evidence[]}], near_misses: [{rule, blocker, blocker_negated}]` |
| `proof` | `tree: {kind, goal, rule?, children[]}` (`:why [n]`) |
| `clauses` | `clauses: [{index, id, label, text, english}]` (`:show*`) |
| `loaded` | `file, clauses, skipped: [{line, col, near, hint?}]` |
| `retracted` / `cleared` / `saved` / `reloaded` | the obvious fields |
| `diff` | `changes: [{kind, label?, old?, new?}]` |
| `whatif` | `changed: [{subject, action, resource?, old, new, old_reasons[], new_reasons[]}], total` |
| `check` | `warnings: [text]` |
| `pred` | declared info for `:pred` |
| `error` | `kind ("parse"\|"file"\|"usage"\|...), message, line?, col?, near?, hint?` |
| `mode` | `json: true` |

Values: atoms/variables as strings, integers as numbers, lists as arrays.
Unknown/unhandled commands in JSON mode answer `error` with
`kind: "usage"` rather than silence.

### Incidental engine text → notes

Trace lines, lint warnings, det-conflict and mode-violation messages
print directly through `output.zig`. JSON mode installs a **capture
buffer** there (`pub var capture: ?*std.ArrayList(u8)`); `writeRaw`
appends to it instead of stdout when set. The handler drains the buffer
per statement and attaches non-empty text as `"notes": ["…"]` on the
response object. The engine's warning paths stay untouched; the protocol
stays airtight.

### Implementation shape

- `main.zig`: `json_mode: bool` on `Axiom`; `handleLine` gains a JSON
  branch that routes each command to an emitter using the underlying
  structures (mirroring the existing text handlers); a small `json.zig`
  (root module) holds string-escaping and object-building helpers plus
  ProofNode/Decision/WhyNot/diff serializers.
- Existing text path byte-identical when JSON mode is off — the entire
  regression battery must pass unchanged.

## Part B — skills (axiom-o2b)

- `skills/axiom/SKILL.md` — Claude Code skill ("drive + author"):
  - spawning `axiom --json policy.axm`, the envelope, every response
    type with a worked example
  - authoring cheatsheet: sentence patterns, decision schema
    (`outcome/2`, deny-overrides), `% id:` labels, `closed_world`,
    safe-negation idiom
  - the guardrail loop (decide → blocked → whynot → revise), pointing at
    `examples/starport.axm` and `examples/guardrail/`
- `install-skills.sh` (repo root):
  - installs verbatim into `~/.claude/skills/axiom/` when `~/.claude`
    exists
  - probes for other agents (`~/.codex`, `~/.pi`, `~/.hermes` and
    XDG-config variants); where found, installs an adapted plain-
    markdown copy in their conventional docs/instructions location;
    otherwise reports `skipped (not detected)`
  - idempotent; `--dry-run` prints actions without writing

## Testing

1. `scripts/json_test.py`: drives `axiom --json` over a fixture
   exercising every response type; asserts each stdout line parses as
   JSON, envelope fields present, zero non-JSON bytes, and spot-checks
   payloads (decision outcome, proof tree depth, skipped hint).
2. `:json` toggle round-trip inside one session.
3. Trace-on inside JSON mode → notes[] populated, protocol still valid.
4. Full existing regression battery (text path unchanged).
5. Installer `--dry-run` and real run against a temp `$HOME`.

## Out of scope (documented)

C-FFI JSON serialization (capi returns structs already), an MCP server
(natural future step), streaming partial results, schema negotiation
beyond the `v` field.
