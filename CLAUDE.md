# Project Instructions for AI Agents

This file provides instructions and context for AI coding agents working on this project.

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:ca08a54f -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files
- The issue tracker is LOCAL ONLY — NEVER run `bd dolt push` or `bd dolt pull`. Beads data must not be pushed to the git remote.

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   git push
   git status  # MUST show "up to date with origin"
   ```
   (Do NOT run `bd dolt push` — beads are local only.)
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->


## Build & Test

```bash
zig build               # build axiom + libaxiom into zig-out/
scripts/run_tests.sh    # full regression: build + every self-checking suite
```

Individual suites (each exits nonzero on any deviation):

```bash
python3 scripts/json_test.py                  # --json protocol contract
python3 scripts/kyc_test.py                   # end-to-end language scenario
python3 scripts/pty_test.py                   # interactive line editor (PTY)
python3 scripts/axiom_gate.py --selftest      # event-envelope gate shim
python3 scripts/security_conformance_test.py  # security spec conformance (7 classes + adversarial)
```

## Architecture Overview

Axiom is a logic programming language (Zig) with controlled-English
syntax: English sentences → Horn clauses → unification/backtracking
resolution. It ships as a CLI/REPL (`--json` line protocol for agents),
a C FFI (`libaxiom` + `include/axiom.h`), and a Zig module.

Pipeline: `lexer.zig` → `parser.zig` (sentence AST) → `desugar.zig`
(clauses) → `engine.zig` (resolution, decisions, budgets) with
`builtins.zig`, `substitution.zig` (unification + occurs check),
`explain.zig` (proof trees, `Why not?`), `checks.zig` (lints),
`main.zig` (REPL + JSON protocol), `capi.zig`/`lib.zig` (C/Zig APIs).

The decision layer (`Should X act?`) resolves `outcome/2` rules with a
ranked ladder (deny > require_confirmation > allow_with_sandbox >
allow_with_redaction > allow). On top of it sits the agent security
stack: `docs/security-spec.md` (architecture), `docs/event-schema.md`
(envelope → facts), `scripts/axiom_gate.py` (fail-closed gate shim),
`policies/agent-security.axm` (reference policy).

Full references: `README.md`, `docs/language.md`, `docs/library.md`.

## Conventions & Patterns

- Comment-tag code added for a bead with just the bead ID (`// axiom-xyz`
  in Zig, `% axiom-xyz` in .axm, `# axiom-xyz` in Python/shell), one
  comment per contiguous block.
- Test suites are self-checking Python scripts in `scripts/` (exit
  nonzero on deviation, `ok/FAIL` per check) driving the binary over
  `--json`; `scripts/run_tests.sh` runs them all.
- Policy rules get stable `% id: <label>` names — labels double as
  reason codes in machine output.
- Fail-closed is the default posture: allowlists are `closed_world`,
  unknown/indeterminate outcomes are treated as deny, engine errors
  must be structured (never hangs or crashes) so gates can keep serving.
- `.axm` policy/example files live in `examples/`, `lib/`, `policies/`;
  design docs per shipped feature in `docs/superpowers/specs/`.
