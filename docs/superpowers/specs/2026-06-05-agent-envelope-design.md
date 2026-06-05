# Agent / AI envelope — design (spec 5)

**Date:** 2026-06-05 · **Bead:** axiom-02w · **Status:** approved

## Goal

Axiom as deterministic substrate for LLM agents: the model proposes,
Axiom gates, denials come back as explanations the model can act on, and
allowed alternatives keep the loop moving. Mostly host-side composition of
spec 1; one new enumeration helper.

## Allowed alternatives

The roadmap's KB-only schema (`Subject can action A on R if Decision D
…`) cannot invoke deny-overrides — that resolution lives in `decide`, not
in a rule. Honest v1 is host-side enumeration:

- The KB declares its action universe with arity-1 facts:
  `Deploy is an action.` → `action(deploy)` — no clash with the ctx
  schema's `action/2`.
- `Engine.allowedActions(subject, resource) ![]const []const u8`:
  solveAll `action(A)`, run `decide(subject, A, resource)` per candidate,
  collect those that resolve to allow (full deny-overrides per action).

Surfaces:

- REPL: `Which actions can <subject> perform [on <resource>]?` —
  special-shaped Which-query (backtracking recognition like `Should`),
  printing the allowed list or `No allowed actions.`
- Zig: `Program.allowedActions(subject, resource)`.
- C: `axiom_allowed_actions(p, subject, resource, &count)` →
  `const char **`, newp-arena-owned like the rest.

## Guardrail contract (host pattern, documented + demoed)

```
check(subject, action, resource?) -> { allowed: outcome == ALLOW, decision }
```

- **Hard gate**: act only on ALLOW. DENY and INDETERMINATE both block
  (fail-safe: an unmodeled action is not an allowed action).
- **Decision-as-context**: on deny, render an explanation block for the
  LLM from reasons + evidence, plus `allowed_actions` for replanning.
- **Plan validation**: per-step `decide` loop; whole-plan modeling stays
  deferred per roadmap.

## Demo: `examples/guardrail/`

- `policy.axm` — small ops policy: roles, an action universe, allow/deny
  outcome rules with `% id:` labels (deny-overrides exercised).
- `guardrail.c` — a fake agent proposes a 2-step plan; the host gates
  each step with `axiom_decide`; the denied step prints the
  LLM-feedback block (reasons, evidence, allowed alternatives via
  `axiom_allowed_actions`); the plan is "revised" to an allowed
  alternative and re-validated. Exits nonzero on any unexpected outcome,
  so it doubles as a test.
- `README.md` — the contract, the schema conventions (`outcome/2`,
  `subject/2`, `action/2` ctx triples; `action/1` universe;
  `% id:` labels as reason vocabulary), and the per-step plan loop.

## Testing

1. REPL: `Which actions can leslie perform?` lists exactly the allowed
   subset of the action universe; deny-overrides excludes denied ones;
   unknown subject → none.
2. `examples/guardrail` compiles against the installed lib and its
   self-checking main passes.
3. FFI suite extended with an `axiom_allowed_actions` case.
4. Full regression battery.
