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
| `:show` | List all loaded clauses in internal form |
| `:trace on` / `:trace off` | Toggle execution tracing |
| `:why` | Explain the last successful query |
| `:pred` | Inspect predicate signatures |
| `:check` | Sanity-check the loaded program |
| `:help` | Show command help |
| `:quit` / `:q` | Exit |

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

```text
axiom> Is Socrates mortal?
Yes.
axiom> :why

Because:
  - mortal(socrates)  [rule]
    - man(socrates)  [fact]
```

---

## Built-in Predicates

These need no `include` — the engine handles them directly.

**Unification**

| Predicate | Description |
|---|---|
| `same_as/2` | Succeeds if both arguments unify |

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

The full FFI surface (load, assert, structured + English queries, result iteration, trace toggle) is documented in `docs/library.md`.

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
| `engine.zig` | Unification, backtracking, cut, negation-as-failure, built-ins, tracing, proof tree |
| `types.zig` | Core term types (`Term`, `Clause`, `Substitution`, …) shared across modules |
| `lib.zig` | Public Zig module — `Program`, `QueryIterator`, exposed via `@import("axiom")` |
| `capi.zig` | C ABI shim — opaque handles, `extern fn`s matching `include/axiom.h` |
| `main.zig` | CLI entrypoint and REPL (`:load`, `:trace`, `:why`, `:pred`, `:check`, …) |

Pipeline: **source → lexer → parser → desugar → engine**. The CLI, the Zig module, and the C FFI are three thin frontends sharing the same core modules; `build.zig` wires them up as separate artifacts (executable, static lib, shared lib) backed by the same internal modules.

---

## Project Layout

```
axiom/
├── build.zig            # multi-artifact build (exe + static + shared + module)
├── build.zig.zon        # package manifest
├── src/                 # Zig source — engine, parser, REPL, FFI shim
├── include/axiom.h      # public C header
├── lib/                 # standard-library .axm files (lists, math)
├── examples/            # tutorial + RBAC + dungeon + family + FFI test
├── docs/
│   ├── language.md      # full language reference
│   └── library.md       # full embedding guide (C FFI + Zig module)
└── zig-out/             # build artifacts (after `zig build`)
```

---

## Documentation

- **[`docs/language.md`](docs/language.md)** — complete language reference: every fact pattern, rule pattern, query form, determiner, built-in, REPL command, and error message format.
- **[`docs/library.md`](docs/library.md)** — complete embedding guide: linking, lifecycle, every C FFI function, every Zig module method, term types, substitutions, memory model, threading.
- **[`include/axiom.h`](include/axiom.h)** — authoritative C ABI.
- **[`examples/tutorial.axm`](examples/tutorial.axm)** — guided introduction.

---

## Status & Versioning

Axiom is at **v0.x** — the surface syntax, REPL command set, and FFI are stable enough to embed but may still evolve. The `build.zig.zon` package id is fixed; the version field tracks releases.

Minimum Zig: **0.16.0**.

---

## License

See repository root for license information.
