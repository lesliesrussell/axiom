# Axiom Language Reference

Axiom is a logic programming language with controlled-English syntax. Sentences written in a restricted subset of English are translated into Horn-clause logic (Prolog-style) and evaluated by a unification and backtracking engine.

## Terminology

- **Atom**: A lowercase identifier representing a constant. `socrates`, `admin`, `exit_gate`.
- **Variable**: A capitalized identifier. In rules, variables are universally quantified. `X`, `Person`, `User`.
- **Predicate**: A relationship or property, identified by a functor name and arity. `man/1`, `parent/2`.
- **Fact**: A ground clause with no conditions.
- **Rule**: A clause with a head and one or more body conditions.
- **Query**: A question that the engine attempts to prove.

## Facts

Facts assert unconditional truths. They end with a period.

| Pattern | Internal form | Example |
|---------|---------------|---------|
| `X is a Y.` | `Y(X)` | `Socrates is a man.` → `man(socrates)` |
| `X is a Y of Z.` | `Y(X, Z)` | `John is a parent of Mary.` → `parent(john, mary)` |
| `X is Y Z.` | `Y(X, Z)` | `entrance is connected_to hall.` → `connected_to(entrance, hall)` |
| `X has Y Z.` | `Y(X, Z)` | `Leslie has role admin.` → `role(leslie, admin)` |
| `X is Y.` | `Y(X)` | `Luna is fluffy.` → `fluffy(luna)` |
| `X can V [P].` | `can_V[_P](X)` | `Leslie can log in.` → `can_log_in(leslie)` |

**Capitalized words in facts are proper nouns (atoms).** `Socrates` becomes the atom `socrates`.

**Integer literals** are supported directly: `Zara has score 92.` → `score(zara, 92)`.

## Rules

Rules define conditional relationships using `if` and `and`.

```
<Head> if <Condition> [and <Condition> ...].
```

| Pattern | Example | Internal form |
|---------|---------|---------------|
| Simple rule | `X is mortal if X is a man.` | `mortal(X) :- man(X).` |
| Multiple conditions | `X is Y if X is a Z and X has W V.` | `Y(X) :- Z(X), W(X, V).` |
| With negation | `X can log_in if X is a user and X is not banned.` | `can_log_in(X) :- user(X), \+ banned(X).` |
| With math | `X has honors yes if X has score S and S is greater_than 89.` | `honors(X, yes) :- score(X, S), greater_than(S, 89).` |

**Capitalized words in rules are variables.** `X`, `Person`, `Y` etc. are all logic variables that can bind to any value during resolution.

### The "Every" / "Each" shortcut

```
Every man is mortal.
```
Desugars to: `mortal(X) :- man(X).`

With explicit conditions:
```
Every person is mortal if that person is a man.
```
Desugars to: `mortal(Person) :- man(Person).`

## Queries

Queries ask the engine to prove something. They end with `?`.

| Pattern | Effect | Example |
|---------|--------|---------|
| `Is X a Y?` | Yes/No check | `Is Socrates mortal?` |
| `Is X Y Z?` | Yes/No check | `Is 3 less_than 5?` |
| `Is X a Y of Z?` | Yes/No check | `Is John a parent of Mary?` |
| `Who is a Y?` | Find all X where Y(X) | `Who is mortal?` |
| `Who is a Y of Z?` | Find all X where Y(X, Z) | `Who is a parent of Mary?` |
| `Who has Y Z?` | Find all X where Y(X, Z) | `Who has honors yes?` |
| `What is a Y?` | Same as Who | `What is a pet?` |
| `Which Xs have Y Z?` | Find by property | `Which users have role admin?` |
| `Can X V [P]?` | Test capability | `Can Leslie log in?` |

## Negation

Negation-as-failure: a negated goal succeeds if the positive goal cannot be proven.

| Pattern | Internal form |
|---------|---------------|
| `X is not Y.` | `\+ Y(X)` |
| `X is not a Y.` | `\+ Y(X)` |
| `X is not Y Z.` | `\+ Y(X, Z)` |
| `not X is a Y` (in body) | `\+ Y(X)` |

## Cut

```
Cut here.
```

In a rule body, inserts a cut (`!`) that prevents backtracking past that point.

## Lists

List literals use bracket syntax:

```
[1, 2, 3]
[]
[a, b, c]
```

Lists can be used with built-in predicates like `member_of` and `length`:

```
Is 2 a member_of [1, 2, 3]?       → Yes.
[1, 2, 3] has length 3.           → stored as length([1,2,3], 3)
```

## Integers

Integer literals work in facts, rules, and queries:

```
Zara has score 92.
X has honors yes if X has score S and S is greater_than 89.
Is 3 less_than 5?                  → Yes.
```

## Includes

Split code across multiple files:

```
include "lib/lists.axm".
include "other_module.axm".
```

- Paths are **relative to the including file's directory**.
- Cyclic includes are detected and rejected with an error.
- `:load` processes `include` statements within loaded files.

## Determiners

| Determiner | Context | Effect |
|------------|---------|--------|
| `a` / `an` | In `X is a Y` | Marks Y as a unary predicate |
| `the` | Discouraged | Use `a` instead |
| `every` / `each` | `Every X is Y.` | Creates a universal rule |
| `that` | `that person` in rules | References the same variable |

## REPL Commands

| Command | Effect |
|---------|--------|
| `:load <file>` | Load and process an `.axm` file |
| `:show` | List all loaded clauses in internal form |
| `:trace on` / `:trace off` | Enable/disable execution tracing |
| `:trace` | Show current trace status |
| `:why` | Explain the last successful query |
| `:help` | Show command help |
| `:quit` / `:q` | Exit the REPL |

### Tracing

When trace is enabled, each query prints resolution events:

```
axiom> :trace on
axiom> Is Socrates mortal?
[CALL] mortal(socrates)
[EXIT] mortal(socrates)
  [CALL] man(socrates)
  [EXIT] man(socrates)
Yes.
```

Events:
- `[CALL]` — entering a goal
- `[EXIT]` — goal succeeded
- `[FAIL]` — goal failed (no matching clause)
- `[REDO]` — backtracking to try another clause

Indentation shows the depth of the search.

### Proof Explanation

After a successful query, `:why` shows the proof tree:

```
axiom> Is Socrates mortal?
Yes.
axiom> :why

Because:
  - mortal(socrates)  [rule]
    - man(X)  [fact]
```

## Built-in Predicates

Built-in predicates are handled directly by the engine and do not require loading any files.

### Unification

| Predicate | Description | Example |
|-----------|-------------|---------|
| `same_as/2` | Succeeds if both arguments unify | `X is not same_as Y` |

### Arithmetic

| Predicate | Description | Example |
|-----------|-------------|---------|
| `less_than/2` | Integer `<` comparison | `Is 3 less_than 5?` → Yes |
| `greater_than/2` | Integer `>` comparison | `Is 10 greater_than 7?` → Yes |
| `equal/2` | Integer `==` comparison | `Is 5 equal 5?` → Yes |

### Lists

| Predicate | Description | Example |
|-----------|-------------|---------|
| `member_of/2` | List membership | `Is 2 a member_of [1, 2, 3]?` → Yes |
| `length/2` | List length | `[1, 2, 3] has length 3.` |
| `append_of/3` | List concatenation | Result = A ++ B (use in rules) |

## Standard Library

The standard library provides English wrappers for built-in predicates. Use `include` to load them.

### lib/lists.axm

```
include "lib/lists.axm".
```

- `X is in L` — wrapper for `member_of(X, L)`

### lib/math.axm

```
include "lib/math.axm".
```

- `X is smaller_than Y` — wrapper for `less_than(X, Y)`
- `X is bigger_than Y` — wrapper for `greater_than(X, Y)`
- `X is equal_to Y` — wrapper for `equal(X, Y)`

## Error Messages

When a sentence cannot be parsed, Axiom shows:

- The **line and column** where parsing failed
- The **offending token**
- A **hint** about what patterns are accepted

```
axiom> X broken here.
Parse error at line 1, column 3 near "broken":
  Expected a sentence like:
    "X is a Y."  or  "X has Y Z."  or  "X is Y if ...".
  Queries start with: Is, Who, What, Which, Can
```

## Embedding API

Axiom can be embedded in Zig applications via `src/lib.zig`:

```zig
const axiom = @import("axiom");

var program = axiom.Program.init(allocator);
try program.loadFile("rules.axm");
try program.assertFact("man", &.{.{ .atom = "socrates" }});

var iter = try program.query("mortal", &.{.{ .variable = "X" }});
while (iter.next()) |solution| {
    // solution is a Substitution with variable bindings
}
```

Key API:
- `Program.init(allocator)` — create a new program
- `program.loadFile(path)` — load an `.axm` file
- `program.loadSource(string)` — load from a string
- `program.assertFact(functor, args)` — add a fact
- `program.assertRule(functor, args, body)` — add a rule
- `program.query(functor, args)` — query, returns `QueryIterator`
- `program.queryAll(functor, args)` — query, returns all solutions at once
- `program.setTrace(bool)` — enable/disable tracing

## Variable Naming Convention

- **Single letters** (`X`, `Y`, `Z`, `A`, `B`) — always variables
- **Capitalized words in facts** — proper nouns (atoms), lowercased internally
- **Capitalized words in rules** — logic variables
- **Words starting with `_`** — internal variables (e.g., `_Who` in queries)
- **Lowercase words** — atoms or predicates depending on position
- **Underscored names** — allowed: `admin_user`, `exit_gate`, `can_log_in`

## Comments

```
% This is a comment (to end of line)
```
