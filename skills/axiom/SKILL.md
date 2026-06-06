---
name: axiom
description: Drive the Axiom logic engine as a deterministic reasoning and policy tool — query knowledge bases, make allow/deny decisions with explanations, and author controlled-English policy. Use when the user wants logic programming, rule-based policy (RBAC, guardrails, compliance), decision auditing, explainable reasoning, or mentions axiom/.axm files.
---

# Axiom: deterministic reasoning and policy

Axiom is a logic language with controlled-English syntax: facts and rules
written as restricted English sentences, evaluated by a Prolog-style
engine with deterministic, explainable results. As an agent you drive it
through the JSON protocol.

## Driving the engine

Spawn with `--json`; write one statement per line to stdin, read exactly
one JSON object per statement from stdout:

```sh
axiom --json policy.axm        # loads policy.axm, then reads stdin
```

Every response: `{"v":1, "input":"<your statement>", "type":"<kind>", ...}`.
Send `:quit` to end the session. Incidental engine text (trace, lint
warnings) arrives in an optional `notes` array — never as bare text.

### Response types

| You send | type | payload |
|---|---|---|
| `Socrates is a man.` | `ok` | `added: {pred, arity, id, label}` |
| `Is Socrates mortal?` | `yesno` | `answer` (bool), `cwa` (closed-world No) |
| `Who is mortal?` | `solutions` | `count`, `solutions: [{Who: "socrates"}]` |
| `Should vega dock?` | `decision` | `outcome` (allow/deny/indeterminate), `reasons[]`, `evidence[]` |
| `Why not?` | `whynot` | `denies: [{rule, evidence[]}]`, `near_misses: [{rule, blocker, blocker_negated}]` |
| `Which actions can vega perform?` | `actions` | `actions[]` |
| `:why` | `proof` | `trees: [{kind, goal, rule?, children[]}]` |
| `:show` / `:show english` | `clauses` | `[{index, id, label, text, english}]` |
| `:load file.axm` | `loaded` | `file, clauses, skipped` |
| `:diff old.axm new.axm` | `diff` | `changes: [{kind, label?, old?, new?}]` |
| `:whatif old.axm new.axm inputs.txt` | `whatif` | `changed[]`, `total` |
| `:check` | `check` | `warnings[]` (det/mode + unsafe-negation lint) |
| anything malformed | `error` | `kind, message?, line, col, near, hint` |

`error.hint` explains unsupported phrasings (plurals, contractions,
negated queries) — relay it, the fix is usually a one-word rewrite.

## Authoring policy (.axm)

```text
% Facts                                  desugared form
Socrates is a man.                       % man(socrates)
Vega is a captain of Nightingale.        % captain(vega, nightingale)
Leslie has role admin.                   % role(leslie, admin)
Nightingale has mass 4200.               % mass(nightingale, 4200)

% Rules (variables are Capitalized)
X is mortal if X is a man.
S is light if S has mass M and M is less than 5000.
S is welcome if S is a freighter and S is not flagged.
```

Rules for safe authoring:

- One sentence per subject (no plurals, no "and"-joined subjects).
- In negations (`X is not banned`), bind the variable with a positive
  condition first — `:check` lints violations.
- `Predicate banned is closed_world.` declares absence-is-falsity;
  closed-world `No` answers set `cwa: true`.
- Name important rules with a comment line directly above:
  `% id: my_rule_name` — the name appears in decision `reasons` and
  proof trees.

### Decision schema (guardrails)

Decisions resolve with **deny-overrides**: any matching deny beats any
number of allows; nothing matching = `indeterminate`. Treat anything
other than `allow` as blocked.

```text
% the action universe (powers "Which actions can ...")
Dock is an action.
Refuel is an action.

% id: licensed_captains_dock
D has outcome allow
  if D has subject C and D has action dock
  and C has license freight_class_a.

% id: flagged_ships_grounded
D has outcome deny
  if D has subject C and C is a captain of S and S is flagged.
```

### The guardrail loop

1. `Should <subject> <action>?` → gate on `outcome == "allow"`.
2. Blocked? Send `Why not?` — `denies[].evidence` says which facts to
   change; `near_misses[].blocker` says what each allow rule needed.
3. `Which actions can <subject> perform?` → the replanning menu.
4. Revise, re-validate. Per-step gating composes to plan validation.

## Worked example

```text
→ Should thane dock?
← {"v":1,"input":"Should thane dock?","type":"decision","outcome":"deny",
   "reasons":["flagged_ships_grounded"],
   "evidence":["thane is a captain of ironclad","ironclad is a flagged"]}
→ Why not?
← {"v":1,"input":"Why not?","type":"whynot",
   "denies":[{"rule":"flagged_ships_grounded",
              "evidence":["thane is a captain of ironclad","ironclad is a flagged"]}],
   "near_misses":[{"rule":"licensed_captains_dock",
                   "blocker":"thane is a license of freight_class_a",
                   "blocker_negated":false}, ...]}
```

## References (in the axiom repo)

- `examples/starport.axm` — full feature tour with a suggested session
- `examples/guardrail/` — C host demo of the gate pattern
- `docs/language.md` — complete language reference
