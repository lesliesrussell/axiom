# Axiom

**Human-readable executable policy and reasoning infrastructure.**
**A deterministic policy layer around AI systems.**

> *What becomes possible because executable logic is readable by humans?*

Organizations lack transparent, human-auditable policy execution systems capable of expressing formal rules in accessible language while preserving explainability and deterministic reasoning. Axiom closes that gap — and gives probabilistic AI systems a deterministic substrate to reason against.

A logic programming language with controlled-English syntax. Sentences written in a restricted subset of English — *"Socrates is a man."*, *"X is mortal if X is a man."* — are parsed, desugared into Horn clauses, and evaluated by a Prolog-style unification + backtracking engine, with negation-as-failure, cut, lists, integers, and a tracing/proof-explanation REPL.

```text
axiom> Socrates is a man.
axiom> X is mortal if X is a man.
axiom> Is Socrates mortal?
Yes.
axiom> Who is mortal?
  socrates
axiom> :why

Because:
  - mortal(socrates)  [rule]
    - man(socrates)  [fact]
```

Implemented in [Zig](https://ziglang.org). Ships as a CLI/REPL, a Zig module, and a C FFI (`libaxiom.a` / `libaxiom.dylib` / `libaxiom.so`) with a public `axiom.h` header.

---

## Table of Contents

- [Why Axiom](#why-axiom)
- [Quick Start](#quick-start)
- [Building from Source](#building-from-source)
- [The Language](#the-language)
  - [Facts](#facts)
  - [Rules](#rules)
  - [Queries](#queries)
  - [Negation](#negation)
  - [Cut](#cut)
  - [Lists & Integers](#lists--integers)
  - [Includes](#includes)
- [The REPL](#the-repl)
  - [Commands](#commands)
  - [Tracing](#tracing)
  - [Proof Explanation](#proof-explanation)
- [Decisions: Policy as Queries](#decisions-policy-as-queries)
- [For AI Agents](#for-ai-agents)
  - [Agent runtime security](#agent-runtime-security)
- [Built-in Predicates](#built-in-predicates)
- [Standard Library](#standard-library)
- [Embedding](#embedding)
  - [C FFI](#c-ffi)
  - [Zig Module](#zig-module)
- [Examples](#examples)
- [Architecture](#architecture)
- [Project Layout](#project-layout)
- [Documentation](#documentation)
- [Status & Versioning](#status--versioning)

---

## Why Axiom

LLMs and ML systems make probabilistic decisions. Many domains — access control, compliance, financial logic, safety constraints, agent guardrails — need deterministic, auditable ones layered on top. Axiom is that layer: **readable enough for the policy author, formal enough for the engine, transparent enough for the auditor.**

Most logic engines force you to write Prolog. Prolog is dense, terse, and unforgiving to read aloud. Axiom keeps the engine — clauses, unification, backtracking, negation-as-failure, cut — but flips the surface syntax: **you write English, you read English, and the proof comes back in the same vocabulary you used to assert it.**

That changes who can pick it up. Domain experts who can spell out a policy in plain sentences can author and audit an Axiom knowledge base without learning operator notation. Compliance reviewers can read the same source the engine executes. The engine still gives you the parts that matter — recursion, lists, integers, negation — and the REPL gives you traces and proof trees so every conclusion is mechanically reproducible and visibly justified.

Use Axiom for:

- **AI guardrails / deterministic policy** — wrap probabilistic systems (LLMs, agents, ML classifiers) in auditable rules whose outcomes are traceable end-to-end
- **Policy & access control** — RBAC, separation-of-duty, permission inheritance (see `examples/rbac.axm`)
- **Compliance & audit** — express formal rules in language non-engineers can review, and produce proof trees on demand
- **Rule-based reasoning embedded in apps** — link `libaxiom` and call from C, C++, or Zig
- **Teaching logic programming** — controlled English keeps cognitive load on the *logic*, not the syntax
- **Modeling worlds** — facts about state + rules about consequences (see `examples/dungeon.axm`)

---

## Quick Start

Requires **Zig 0.16.0 or newer**.

```sh
git clone <this-repo> axiom
cd axiom
zig build
./zig-out/bin/axiom
```

Drop into the REPL:

```text
axiom> Socrates is a man.
axiom> Plato is a man.
axiom> X is mortal if X is a man.
axiom> Who is mortal?
  socrates
  plato
axiom> :quit
```

Or load a file:

```sh
./zig-out/bin/axiom
axiom> :load examples/tutorial.axm
```

The repo's `examples/tutorial.axm` is a 25-lesson interactive walkthrough — start there.

---

## Building from Source

```sh
zig build               # build everything (CLI + libs + header)
zig build run           # build + launch REPL
zig build run -- args   # pass args to the REPL
```

`zig build` produces:

```
zig-out/
├── bin/axiom              # CLI / REPL
├── lib/libaxiom.a         # static library
├── lib/libaxiom.dylib     # shared library (.so on Linux)
└── include/axiom.h        # C header
```

### Running the tests

```sh
scripts/run_tests.sh    # build + every self-checking suite
```

The regression run covers the `--json` protocol contract, an end-to-end
language scenario (KYC onboarding), the interactive line editor (over a
PTY), the event-envelope gate shim, and the security conformance suite.
Each suite is also runnable individually — see each file's header.

### Installing globally

Install an optimized build to `~/.local` (no sudo needed):

```sh
zig build install --prefix ~/.local -Doptimize=ReleaseFast
```

This places:

```
~/.local/
├── bin/axiom              # CLI / REPL
├── lib/libaxiom.a         # static library
├── lib/libaxiom.dylib     # shared library (.so on Linux)
└── include/axiom.h        # C header
```

Make sure `~/.local/bin` is on your `PATH`, then `axiom` works from anywhere:

```sh
axiom
axiom> Socrates is a man.
axiom> Is Socrates a man?
Yes.
```

C clients compile against the installed library:

```sh
cc app.c -I"$HOME/.local/include" -L"$HOME/.local/lib" -laxiom
# add -Wl,-rpath,"$HOME/.local/lib" if linking the shared library
```

For a system-wide install use `--prefix /usr/local` (requires sudo).

---

## The Language

A complete reference lives in [`docs/language.md`](docs/language.md). Highlights:

### Facts

Facts are unconditional truths. They end with `.`.

| Pattern | Internal form | Example |
|---|---|---|
| `X is a Y.` | `Y(X)` | `Socrates is a man.` → `man(socrates)` |
| `X is a Y of Z.` | `Y(X, Z)` | `John is a parent of Mary.` → `parent(john, mary)` |
| `X has Y Z.` | `Y(X, Z)` | `Leslie has role admin.` → `role(leslie, admin)` |
| `X is Y.` | `Y(X)` | `Luna is fluffy.` → `fluffy(luna)` |
| `X can V.` | `can_V(X)` | `Leslie can log_in.` → `can_log_in(leslie)` |

Capitalized words in facts are proper nouns (atoms). Integer literals are first-class: `Zara has score 92.`

### Rules

```text
X is mortal if X is a man.
X can log_in if X is a user and X is not banned.
X has honors yes if X has score S and S is greater_than 89.
```

Capitalized identifiers in rules are universally-quantified logic variables.

The `Every`/`Each` shortcut also works:

```text
Every man is mortal.
Every person is mortal if that person is a man.
```

### Queries

| Pattern | Effect |
|---|---|
| `Is X a Y?` | Yes/No |
| `Who is a Y?` | Find all `X` where `Y(X)` |
| `Who has Y Z?` | Find all `X` where `Y(X, Z)` |
| `Which users have role admin?` | Filter by property |
| `Can Leslie log_in?` | Capability check |

### Negation

Negation-as-failure: `\+`. A negated goal succeeds when the positive goal cannot be proven.

```text
X can log_in if X is a user and X is not banned.
```

### Cut

```text
Cut here.
```

In a rule body, inserts `!` to prevent backtracking past that point.

### Lists & Integers

```text
Is 2 a member_of [1, 2, 3]?
[1, 2, 3] has length 3.
Is 3 less_than 5?
```

### Includes

```text
include "lib/lists.axm".
include "rules/policy.axm".
```

Paths are relative to the including file. Cyclic includes are detected and rejected.

---

## The REPL

### Line editing

On a terminal, the REPL provides emacs-style line editing (`C-a`/`C-e`,
`C-k`/`C-u`/`C-w`, word motion with `M-b`/`M-f`), persistent history
(`~/.axiom_history`, recalled with arrows or `C-p`/`C-n`), and Tab
completion: command names cycle, and file arguments to `:load`/`:save`
open [fzf](https://github.com/junegunn/fzf) when installed (a built-in
prefix-cycling fallback otherwise). Piped input bypasses the editor
entirely.

### Commands

| Command | Effect |
|---|---|
| `:load <file>` | Load and process a `.axm` file |
| `:reload` | Clear, then re-load every loaded file (edit-retest loop) |
| `:save <file>` | Write the KB back out as its original English sentences |
| `:show` | List all loaded clauses in internal form |
| `:show facts` / `:show rules` | Filtered listing (global indices kept) |
| `:show ids` | Listing with stable clause ids and `% id:` labels |
| `:show english` | Canonical English rendering (phrasing-normalized) |
| `:retract <n>` | Remove clause *n* by its `:show` index |
| `:clear` | Remove all clauses and declarations |
| `:diff <old> <new>` | Semantic clause diff between two `.axm` files |
| `:whatif <old> <new> <inputs>` | Decision deltas between two policy versions |
| `:json` | Toggle the JSON protocol (see [For AI Agents](#for-ai-agents)) |
| `:trace on` / `:trace off` | Toggle execution tracing |
| `:why [n]` | Proof tree for solution *n* of the last query (default 1) |
| `:pred name/arity` | Inspect a predicate (determinism, modes, closed-world) |
| `:check` | Determinism/mode checks + unsafe-negation lint |
| `:help` | Show command help |
| `:quit` / `:q` | Exit |

Parse errors echo the offending line with a caret and a phrasing hint for
common unsupported English (plurals, contractions, head-first
conditionals). File loads report skipped statements as `file:line:col`.

### Tracing

```text
axiom> :trace on
axiom> Is Socrates mortal?
[CALL] mortal(socrates)
  [CALL] man(socrates)
  [EXIT] man(socrates)
[EXIT] mortal(socrates)
Yes.
```

Events: `[CALL]` enter goal · `[EXIT]` succeeded · `[FAIL]` failed · `[REDO]` backtrack. Indentation tracks search depth.

### Proof Explanation

Proof trees are real and recursive — every sub-goal is re-proven and
labeled honestly (`[fact]`, `[rule]`, `[built-in]`, `[negation]`), and
rules named with a `% id:` comment show their label:

```text
axiom> Is Tom special?
Yes.
axiom> :why

Because:
  - special(tom)  [rule]
    - grandparent(tom, ann)  [rule grandparent_def]
      - parent(tom, bob)  [fact]
      - parent(bob, ann)  [fact]
```

With multiple solutions, `:why 2` explains the second one.

---

## Decisions: Policy as Queries

The deterministic policy layer from the pitch above. Decision rules are
ordinary rules over a conventional schema — `outcome/2` with
`subject/action/resource` inputs — and resolve with generalized
**deny-overrides**: the highest-ranked derivable outcome wins,

```
deny > require_confirmation > allow_with_sandbox > allow_with_redaction > allow
```

so one matching deny beats any number of allows, and the three gated
outcomes let a policy permit an action only under conditions (human
approval, sandboxing, redaction). Nothing matching is *indeterminate*
(and indeterminate is not allowed).

```text
% id: licensed_captains_dock
D has outcome allow
  if D has subject C and D has action dock
  and C is a captain of S and C has license freight_class_a.

% id: flagged_ships_grounded
D has outcome deny
  if D has subject C and C is a captain of S and S is flagged.
```

```text
axiom> Should thane dock?
Deny.
Reasons:
  - flagged_ships_grounded
Evidence:
  - thane is a captain of ironclad.
  - ironclad is a flagged.

axiom> Why not?
Deny rules in effect:
  - flagged_ships_grounded, relying on: "ironclad is a flagged"
Allow would need:
  - licensed_captains_dock: blocked at "thane is a license of freight_class_a"

axiom> Which actions can mirelle perform?
  dock
  refuel
  unload_cargo
```

`Why not?` is counterfactual analysis: which facts the active denies rely
on, and the first blocking condition of each allow rule that didn't fire.
Declare the action universe with `Dock is an action.` facts to power
`Which actions …`. The same machinery is exposed to C
(`axiom_decide`, `axiom_allowed_actions`) and used by the
[`examples/guardrail/`](examples/guardrail/) LLM-agent demo.

For policy-as-code workflows, `:diff` shows clause-level semantic changes
between two file versions (variable renaming is invisible — clauses carry
alpha-normalized identity hashes) and `:whatif` reports which decisions
flip between versions.

Safer negation for policy KBs: `:check` lints negation over unbound
variables, and `Predicate banned is closed_world.` declares
absence-is-falsity explicitly — `Is x banned?` then answers
`No (by closed-world assumption; no proof found).` The
`lib/policy.axm` pattern adds a three-valued
allowed / denied / **unknown** status on top.

---

## For AI Agents

`axiom --json` turns stdin/stdout into a line-oriented protocol: every
statement produces exactly one JSON object, so an agent's loop is
write-line / read-line / parse.

```text
$ printf 'Should thane dock?\nWhy not?\n:quit\n' | axiom --json policy.axm
{"v":1,"input":"Should thane dock?","type":"decision","outcome":"deny",
 "reasons":["flagged_ships_grounded"],"evidence":["thane is a captain of ironclad", ...]}
{"v":1,"input":"Why not?","type":"whynot","denies":[...],"near_misses":[...]}
```

Decisions, proof trees, counterfactuals, semantic diffs, and parse errors
(with phrasing hints) all arrive structured; incidental engine text
(traces, lint warnings) rides in a `notes` array, never as bare bytes.
`:json` toggles the same protocol mid-session.

A ready-made skill teaches coding agents the protocol and the authoring
patterns:

```sh
./install-skills.sh        # installs into ~/.claude/skills/axiom/
                           # (probes Codex, pi.dev, Hermes too; --dry-run available)
```

Full schema and worked examples: [`skills/axiom/SKILL.md`](skills/axiom/SKILL.md).

### Agent runtime security

Axiom doubles as the deterministic policy oracle for agent runtimes (CI
agents, Claude Code-style tools, MCP toolchains): an interposition layer
compiles each proposed action into facts about an event entity, asks
`Should <event> <action>?`, and enforces the outcome. The full stack
ships in-repo:

- [`docs/security-spec.md`](docs/security-spec.md) — the architecture:
  trust levels, taint propagation, mandatory deny rules D1–D6,
  restricted profiles, fail-closed semantics
- [`docs/event-schema.md`](docs/event-schema.md) — event envelope →
  facts mapping
- [`scripts/axiom_gate.py`](scripts/axiom_gate.py) — reference gate
  shim over `--json` (fail-closed output contract)
- [`policies/agent-security.axm`](policies/agent-security.axm) — the
  reference policy: D1–D6, the June 2026 incident rules, closed-world
  allowlists, gated outcomes
- [`scripts/security_conformance_test.py`](scripts/security_conformance_test.py)
  — the spec's 7 conformance classes plus adversarial fail-closed cases

Robustness for hostile input is engine-level: resolution budgets turn
unbounded recursion into structured `kind: "limit"` errors instead of
hangs, and the occurs check makes cyclic unification fail cleanly
instead of crashing the oracle.

---

## Built-in Predicates

These need no `include` — the engine handles them directly.

**Unification**

| Predicate | Description |
|---|---|
| `same_as/2` | Succeeds if both arguments unify (with occurs check — cyclic terms fail cleanly) |

**Strings**

| Predicate | Description |
|---|---|
| `like/2` | Glob match for string terms — `*` spans any text: `T is like "/proc/*/environ"` |

**Arithmetic** (integer)

| Predicate | Description |
|---|---|
| `less_than/2` | `<` |
| `greater_than/2` | `>` |
| `equal/2` | `==` |

**Lists**

| Predicate | Description |
|---|---|
| `member_of/2` | List membership |
| `length/2` | List length |
| `append_of/3` | List concatenation |

---

## Standard Library

English wrappers in `lib/`:

```text
include "lib/lists.axm".
% provides: X is in L           (member_of)

include "lib/math.axm".
% provides: X is smaller_than Y  (less_than)
%           X is bigger_than Y   (greater_than)
%           X is equal_to Y      (equal)

include "lib/policy.axm".
% provides: X has status allowed | denied | unknown
% three-valued clearance over a subject/1 domain — define subject/1,
% allowed/1, denied/1 in your KB (see the file header for the safe
% negation idiom it demonstrates)
```

---

## Embedding

Full guide: [`docs/library.md`](docs/library.md).

### C FFI

Header: [`include/axiom.h`](include/axiom.h).

```c
#include <stdio.h>
#include "axiom.h"

int main(void) {
    AxiomProgram *p = axiom_new();

    axiom_load_source(p,
        "Socrates is a man.\n"
        "Plato is a man.\n"
        "X is mortal if X is a man.\n");

    AxiomResult *r = axiom_query_english(p, "Who is mortal?");
    for (size_t i = 0; i < axiom_result_count(r); i++) {
        const char *name = axiom_result_get_binding(r, i, "_Who");
        if (name) printf("  %s is mortal\n", name);
    }

    axiom_free(p);
    return 0;
}
```

Build:

```sh
cc -o demo demo.c -Izig-out/include zig-out/lib/libaxiom.a
```

Memory model: `axiom_new()` allocates an arena; every string returned is valid until `axiom_free()`. No per-result frees needed.

Each `AxiomProgram` is **single-threaded** — use one instance per thread.

The decision layer is fully exposed:

```c
AxiomDecision *d = axiom_decide(p, "thane", "dock", NULL);
if (d->outcome != AXIOM_DECISION_ALLOW) {          /* deny-overrides */
    for (size_t i = 0; i < d->reason_count; i++)
        printf("rule: %s\n", d->reasons[i]);       /* '% id:' labels  */
    size_t n;
    const char **alts = axiom_allowed_actions(p, "thane", NULL, &n);
    /* feed reasons + evidence + alternatives back to your agent */
}
```

Plus version analysis: `axiom_diff_programs(oldp, newp, &n)` for
clause-level semantic diffs and `axiom_compare_decisions(...)` for
decision deltas across policy versions. See
[`examples/guardrail/`](examples/guardrail/) for the complete agent-gate
pattern.

The full FFI surface (load, assert, structured + English queries, result iteration, decisions, diffs, trace toggle) is documented in `docs/library.md`.

### Zig Module

Add Axiom as a build dependency, then:

```zig
const std = @import("std");
const axiom = @import("axiom");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var program = axiom.Program.init(alloc);
    try program.loadSource(
        \\Socrates is a man.
        \\Plato is a man.
        \\X is mortal if X is a man.
    );

    var iter = try program.query("mortal", &.{ .{ .variable = "X" } });
    while (iter.next()) |sol| {
        const x = try sol.deepWalk(.{ .variable = "X" }, alloc);
        switch (x) {
            .atom => |name| std.debug.print("  {s} is mortal\n", .{name}),
            else => {},
        }
    }
}
```

The `axiom.Term` tagged union supports `.atom`, `.variable`, `.integer`, `.compound`, `.list`, `.nil`. `Substitution` exposes `lookup`, `walk`, and `deepWalk`. `Program` exposes `assertFact`, `assertRule`, `query`, `queryAll`, `clauseCount`, `setTrace`.

---

## Examples

Live in [`examples/`](examples/):

| File | What it demonstrates |
|---|---|
| `tutorial.axm` | 25-lesson interactive walkthrough — **start here** |
| `starport.axm` (+`_v2`, `_inputs.txt`) | **Full feature tour**: recursion, builtins, closed-world, three-valued status, labeled decisions with deny-overrides, `Why not?`, `:diff`/`:whatif` |
| `guardrail/` | LLM-agent guardrail demo: C host gates a plan via `axiom_decide` |
| `agent_demo.py` | A narrated agent session over `--json`: builds policy through the protocol, reads error hints, runs the gate→why-not→fix→retry loop |
| `family.axm`, `ancestor.axm` | Classic recursion (parent / ancestor) |
| `kingdom.axm`, `space_academy.axm` | Larger world models |
| `negation.axm` | Negation-as-failure patterns |
| `rbac.axm` | Full role-based access control: roles, hierarchy, separation-of-duty, suspension, audit queries |
| `dungeon.axm` | Logic-driven dungeon crawler — rooms, items, hazards, queries as game actions |
| `users.axm` | User/permission modeling |
| `all_tests.axm` | Aggregate regression suite |
| `ffi_test.c` | Minimal C client linking against `libaxiom` |

Run any of them:

```sh
./zig-out/bin/axiom
axiom> :load examples/rbac.axm
axiom> Which users have role admin?
```

---

## Architecture

A short tour of `src/`:

| File | Role |
|---|---|
| `lexer.zig` | Tokenizer for the controlled-English surface syntax |
| `parser.zig` | Pattern-matching parser → high-level sentence AST |
| `desugar.zig` | Lowers English sentences into Horn clauses (`head :- body.`) |
| `engine.zig` | Resolution coordinator: clause store, solve loop, renaming, decisions |
| `substitution.zig` | Bindings and unification |
| `builtins.zig` | Built-in predicates (comparisons, lists) |
| `explain.zig` | Witness re-prover: deep `:why` trees, decision reasons/evidence, `Why not?` |
| `proof.zig` | Proof-tree representation and printing |
| `checks.zig` | Predicate info, determinism/mode checks, unsafe-negation lint |
| `identity.zig` | Alpha-normalized clause hashes (stable rule identity) |
| `english.zig` | Canonical English pretty-printer (`:show english`, diff renderings) |
| `diff.zig` | Clause-level semantic diff between programs |
| `output.zig` | `std.fmt`-free output helpers + ANSI styling |
| `types.zig` | Core term types shared across modules |
| `editor.zig` | Raw-mode line editor: emacs bindings, history, tab/fzf completion |
| `jsonout.zig` | JSON building helpers for the agent protocol (`--json`) |
| `lib.zig` | Public Zig module — `Program`, `QueryIterator`, `decide` |
| `capi.zig` | C ABI shim — opaque handles, `extern fn`s matching `include/axiom.h` |
| `main.zig` | CLI entrypoint and REPL |

Pipeline: **source → lexer → parser → desugar → engine**. The CLI, the Zig module, and the C FFI are three thin frontends sharing the same core modules; `build.zig` wires them up as separate artifacts (executable, static lib, shared lib) backed by the same internal modules.

---

## Project Layout

```
axiom/
├── build.zig            # multi-artifact build (exe + static + shared + module)
├── build.zig.zon        # package manifest
├── src/                 # Zig source — engine, parser, REPL, FFI shim
├── include/axiom.h      # public C header
├── lib/                 # standard-library .axm files (lists, math, policy)
├── examples/            # tutorial, starport tour, RBAC, dungeon, guardrail demo, FFI test
├── policies/            # reference security policy (agent-security.axm)
├── skills/              # agent skill (see install-skills.sh)
├── scripts/             # test suites (run_tests.sh runs them all) + gate shim
├── docs/
│   ├── language.md      # full language reference
│   ├── library.md       # full embedding guide (C FFI + Zig module)
│   ├── security-spec.md # agent runtime security architecture
│   ├── event-schema.md  # event envelope → facts mapping
│   └── superpowers/specs/  # design docs, one per shipped feature
└── zig-out/             # build artifacts (after `zig build`)
```

---

## Documentation

- **[`docs/language.md`](docs/language.md)** — complete language reference: every fact pattern, rule pattern, query form, determiner, built-in, REPL command, and error message format.
- **[`docs/library.md`](docs/library.md)** — complete embedding guide: linking, lifecycle, every C FFI function, every Zig module method, decisions, term types, substitutions, memory model, threading.
- **[`docs/security-spec.md`](docs/security-spec.md)** — agent runtime security architecture: Axiom as the deterministic policy oracle for agent platforms.
- **[`docs/event-schema.md`](docs/event-schema.md)** — how normalized agent events compile into facts for one decision request.
- **[`include/axiom.h`](include/axiom.h)** — authoritative C ABI.
- **[`examples/tutorial.axm`](examples/tutorial.axm)** — guided introduction.

---

## Status & Versioning

Axiom is at **v0.x** — the surface syntax, REPL command set, and FFI are stable enough to embed but may still evolve. The `build.zig.zon` package id is fixed; the version field tracks releases.

Minimum Zig: **0.16.0**.

---

## License

Released under the MIT License. See [LICENSE](LICENSE) for the full text.
