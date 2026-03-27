# Axiom Library — Embedding Guide

Axiom ships as a library that you can link into any Zig (or C/C++) program. Every `zig build` produces:

```
zig-out/
├── lib/libaxiom.a         # static library
├── lib/libaxiom.dylib     # shared library (macOS) / .so (Linux)
└── include/axiom.h        # C header
```

There are **two ways** to use the library from Zig:

1. **C FFI** — link against `libaxiom.a` and call the exported C functions. Works from any language with C interop. Opaque handles, null-terminated strings, simple integer return codes.

2. **Zig module** — `@import("axiom")` for a native Zig API with proper types, slices, error unions, and iterators. Requires adding the Axiom build as a dependency.

Both APIs give you the same engine. The C FFI wraps the Zig module with a C-compatible calling convention.

---

## C FFI API

### Linking

```sh
# Static (recommended — no runtime dependency)
zig cc -o myapp myapp.c -I/path/to/include -L/path/to/lib -laxiom

# Or with system cc
cc -o myapp myapp.c -Izig-out/include zig-out/lib/libaxiom.a
```

If you installed to `~/.local`:

```sh
cc -o myapp myapp.c -I~/.local/include -L~/.local/lib -laxiom
```

Include the header:

```c
#include "axiom.h"
```

### Lifecycle

```c
// Create an engine instance. Each instance is independent.
AxiomProgram *p = axiom_new();

// ... use it ...

// Free all memory. Invalidates all result pointers.
axiom_free(p);
```

`axiom_new()` allocates an arena internally. All strings returned by the library are valid until `axiom_free()` is called. You never need to free individual results.

### Loading Knowledge

Three ways to load Axiom source:

```c
// From a C string (null-terminated)
axiom_load_source(p,
    "Socrates is a man.\n"
    "X is mortal if X is a man.\n"
);

// From a buffer with explicit length (not null-terminated)
axiom_load_source_len(p, buf, buf_len);

// From a .axm file
axiom_load_file(p, "rules/knowledge.axm");
```

All return `0` on success, `-1` on error.

You can call these multiple times — facts and rules accumulate.

### Asserting Facts Programmatically

If you don't want to go through the English parser:

```c
// man(socrates)
axiom_assert_fact1(p, "man", "socrates");

// parent(socrates, plato)
axiom_assert_fact2(p, "parent", "socrates", "plato");
```

These create ground facts directly in the engine. Arguments are atoms (strings).

### Querying

#### English queries

The most powerful way — pass any Axiom query string:

```c
AxiomResult *r = axiom_query_english(p, "Who is mortal?");
```

This parses the English, desugars it, and runs the query. Variable names match the query form: `_Who` for "Who" queries, `_What` for "What", `_Which` for "Which".

#### Programmatic queries

For structured queries without parsing:

```c
// mortal(X) — one variable, returns all X
AxiomResult *r = axiom_query1(p, "mortal");
// Bind variable name is "X"

// mortal(socrates) — ground check (yes/no)
AxiomResult *r = axiom_query_ground1(p, "mortal", "socrates");

// parent(socrates, Y) — first arg ground, second is variable
AxiomResult *r = axiom_query2_av(p, "parent", "socrates");
// Bind variable name is "Y"

// parent(X, Y) — both variables
AxiomResult *r = axiom_query2_vv(p, "parent");
// Bind variable names are "X" and "Y"
```

### Reading Results

```c
// How many solutions?
size_t n = axiom_result_count(r);

// Did it succeed at all?
if (axiom_result_has_solutions(r)) { ... }

// Get a variable binding from solution i
const char *who = axiom_result_get_binding(r, 0, "_Who");
// Returns "socrates", or NULL if unbound

// Iterate all solutions
for (size_t i = 0; i < axiom_result_count(r); i++) {
    const char *x = axiom_result_get_binding(r, i, "X");
    if (x) printf("X = %s\n", x);
}
```

**Variable names** depend on how you queried:

| Query function | Variable names |
|---|---|
| `axiom_query1` | `"X"` |
| `axiom_query_ground1` | (none — just check `has_solutions`) |
| `axiom_query2_av` | `"Y"` |
| `axiom_query2_vv` | `"X"`, `"Y"` |
| `axiom_query_english("Who is ...?")` | `"_Who"` |
| `axiom_query_english("What is ...?")` | `"_What"` |
| `axiom_query_english("Which ...?")` | `"_Which"` |

### Utility

```c
// How many clauses (facts + rules) are loaded?
size_t n = axiom_clause_count(p);

// Turn on trace output (prints to stdout)
axiom_set_trace(p, true);
axiom_set_trace(p, false);
```

### Complete C Example

```c
#include <stdio.h>
#include "axiom.h"

int main(void) {
    AxiomProgram *p = axiom_new();

    // Load knowledge base
    axiom_load_source(p,
        "Socrates is a man.\n"
        "Plato is a man.\n"
        "X is mortal if X is a man.\n"
        "X is a philosopher if X is a man.\n"
    );

    // Yes/No check
    AxiomResult *r = axiom_query_english(p, "Is Socrates mortal?");
    printf("Is Socrates mortal? %s\n",
        axiom_result_has_solutions(r) ? "Yes" : "No");

    // Enumerate all results
    AxiomResult *who = axiom_query_english(p, "Who is a philosopher?");
    for (size_t i = 0; i < axiom_result_count(who); i++) {
        const char *name = axiom_result_get_binding(who, i, "_Who");
        if (name) printf("  %s is a philosopher\n", name);
    }

    // Add a fact at runtime and re-query
    axiom_assert_fact1(p, "man", "aristotle");
    AxiomResult *r2 = axiom_query_ground1(p, "mortal", "aristotle");
    printf("Is aristotle mortal? %s\n",
        axiom_result_has_solutions(r2) ? "Yes" : "No");

    axiom_free(p);
    return 0;
}
```

Build:

```sh
cc -o example example.c -Izig-out/include zig-out/lib/libaxiom.a
```

---

## Zig Module API

For Zig projects that add Axiom as a build dependency, you get a higher-level API with proper Zig types.

### Setup in build.zig

If Axiom is a local dependency:

```zig
// In your project's build.zig
const axiom_dep = b.dependency("axiom", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("axiom", axiom_dep.module("axiom"));
```

Or if linking the pre-built library:

```zig
exe.addIncludePath(.{ .cwd_relative = "/path/to/include" });
exe.addLibraryPath(.{ .cwd_relative = "/path/to/lib" });
exe.linkSystemLibrary("axiom");
```

### Program

```zig
const axiom = @import("axiom");

// Create a program with your allocator
var program = axiom.Program.init(allocator);
```

### Loading Source

```zig
// From a file
try program.loadFile("knowledge.axm");

// From a string
try program.loadSource(
    \\Socrates is a man.
    \\X is mortal if X is a man.
);
```

### Asserting Facts

```zig
// man(socrates)
try program.assertFact("man", &.{.{ .atom = "socrates" }});

// parent(socrates, plato)
try program.assertFact("parent", &.{
    .{ .atom = "socrates" },
    .{ .atom = "plato" },
});
```

The `Term` union supports `.atom`, `.variable`, `.integer`, `.compound`, `.list`, and `.nil`.

### Asserting Rules

```zig
// mortal(X) :- man(X).
try program.assertRule(
    "mortal",
    &.{.{ .variable = "X" }},
    &.{.{ .call = .{ .functor = "man", .args = &.{.{ .variable = "X" }} } }},
);
```

### Querying with Iterator

```zig
// mortal(X) — iterate solutions
var iter = try program.query("mortal", &.{.{ .variable = "X" }});

while (iter.next()) |solution| {
    // solution is *const Substitution
    const resolved = try solution.deepWalk(
        .{ .variable = "X" },
        allocator,
    );
    switch (resolved) {
        .atom => |name| std.debug.print("X = {s}\n", .{name}),
        else => {},
    }
}
```

### Querying All At Once

```zig
// Get all solutions as a slice
const solutions = try program.queryAll(
    "mortal",
    &.{.{ .variable = "X" }},
);

std.debug.print("{d} solutions\n", .{solutions.len});

for (solutions) |solution| {
    const x = try solution.deepWalk(.{ .variable = "X" }, allocator);
    // ...
}
```

### Yes/No Check

```zig
const solutions = try program.queryAll(
    "mortal",
    &.{.{ .atom = "socrates" }},
);
const is_mortal = solutions.len > 0;
```

### Utility

```zig
// Number of loaded clauses
const n = program.clauseCount();

// Enable trace output
program.setTrace(true);
```

### Term Types

The `axiom.Term` tagged union:

```zig
const Term = union(enum) {
    atom: []const u8,       // constant: "socrates"
    variable: []const u8,   // logic variable: "X"
    integer: i64,           // number: 42
    compound: Compound,     // structure: mortal(X)
    list: TermList,         // cons cell: [H|T]
    nil,                    // empty list: []
};
```

### Substitution

A `Substitution` maps variable names to terms:

```zig
// Look up a single variable (shallow — may return another variable)
if (solution.lookup("X")) |term| { ... }

// Walk to the end of the chain
const walked = solution.walk(.{ .variable = "X" });

// Fully resolve all variables recursively
const resolved = try solution.deepWalk(.{ .variable = "X" }, allocator);
```

### Complete Zig Example

```zig
const std = @import("std");
const axiom = @import("axiom");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var program = axiom.Program.init(alloc);

    // Load English rules
    try program.loadSource(
        \\Socrates is a man.
        \\Plato is a man.
        \\X is mortal if X is a man.
    );

    // Yes/No check
    const check = try program.queryAll("mortal", &.{.{ .atom = "socrates" }});
    std.debug.print("Is Socrates mortal? {s}\n", .{
        if (check.len > 0) "Yes" else "No",
    });

    // Find all mortals
    var iter = try program.query("mortal", &.{.{ .variable = "X" }});
    while (iter.next()) |solution| {
        const x = try solution.deepWalk(.{ .variable = "X" }, alloc);
        switch (x) {
            .atom => |name| std.debug.print("  {s} is mortal\n", .{name}),
            else => {},
        }
    }

    // Add fact at runtime
    try program.assertFact("man", &.{.{ .atom = "aristotle" }});
    std.debug.print("Clauses: {d}\n", .{program.clauseCount()});
}
```

---

## API Reference

### C FFI Functions

| Function | Signature | Description |
|---|---|---|
| `axiom_new` | `() -> *Program` | Create engine instance |
| `axiom_free` | `(*Program)` | Destroy instance, free all memory |
| `axiom_load_source` | `(*Program, *c_char) -> int` | Load from C string |
| `axiom_load_source_len` | `(*Program, *c_char, len) -> int` | Load from buffer |
| `axiom_load_file` | `(*Program, *c_char) -> int` | Load `.axm` file |
| `axiom_assert_fact1` | `(*Program, functor, arg1) -> int` | Assert `f(a)` |
| `axiom_assert_fact2` | `(*Program, functor, arg1, arg2) -> int` | Assert `f(a, b)` |
| `axiom_query1` | `(*Program, functor) -> *Result` | Query `f(X)` |
| `axiom_query_ground1` | `(*Program, functor, arg) -> *Result` | Check `f(a)` |
| `axiom_query2_av` | `(*Program, functor, arg1) -> *Result` | Query `f(a, Y)` |
| `axiom_query2_vv` | `(*Program, functor) -> *Result` | Query `f(X, Y)` |
| `axiom_query_english` | `(*Program, *c_char) -> *Result` | English query |
| `axiom_result_count` | `(*Result) -> size_t` | Solution count |
| `axiom_result_has_solutions` | `(*Result) -> bool` | Any solutions? |
| `axiom_result_get_binding` | `(*Result, index, var) -> *c_char` | Get binding |
| `axiom_clause_count` | `(*Program) -> size_t` | Loaded clause count |
| `axiom_set_trace` | `(*Program, bool)` | Toggle tracing |

### Zig Module Types and Methods

| Type | Method | Description |
|---|---|---|
| `Program` | `init(allocator)` | Create program |
| | `loadFile(path)` | Load `.axm` file |
| | `loadSource(string)` | Load from string |
| | `assertFact(functor, args)` | Assert a fact |
| | `assertRule(functor, args, body)` | Assert a rule |
| | `query(functor, args)` | Query, returns iterator |
| | `queryAll(functor, args)` | Query, returns all solutions |
| | `clauseCount()` | Number of clauses |
| | `setTrace(bool)` | Toggle tracing |
| `QueryIterator` | `next()` | Next solution or null |
| | `reset()` | Restart iteration |
| | `count()` | Total solutions |
| `Substitution` | `lookup(name)` | Shallow variable lookup |
| | `walk(term)` | Walk variable chain |
| | `deepWalk(term, alloc)` | Fully resolve term |
| `Term` | `.atom`, `.variable`, `.integer`, `.compound`, `.list`, `.nil` | Tagged union |

---

## Memory Model

**C FFI**: Each `axiom_new()` creates an arena allocator. All memory — clauses, solutions, result strings — is allocated from this arena. Nothing needs to be individually freed. Call `axiom_free()` once when done, and everything is released. Result pointers are valid until `axiom_free()`.

**Zig module**: You provide the allocator. Use an arena allocator if you want the same fire-and-forget model. If using a GPA, you're responsible for the lifetime of slices returned by `queryAll`.

## Thread Safety

Each `Program` / `AxiomProgram` instance is **single-threaded**. Do not share an instance across threads. Create separate instances for concurrent use.
