# Agent guardrail pattern

Axiom as a deterministic policy layer around an LLM agent: the model
proposes actions, Axiom decides, and the host enforces.

## The contract

```
check(subject, action, resource?) -> { allowed, decision }
```

- `allowed` is `decision.outcome == AXIOM_DECISION_ALLOW` — **DENY and
  INDETERMINATE both block**. An action the policy doesn't model is not an
  allowed action (fail-safe default).
- Conflict resolution is deny-overrides: one matching deny rule beats any
  number of allows.

## KB conventions

| Predicate | Role |
|---|---|
| `subject/2`, `action/2`, `resource/2` | decision inputs, asserted by `axiom_decide` under the reserved `axiom_decision_ctx` atom |
| `outcome/2` | `D has outcome allow/deny if …` rules — the policy itself |
| `reason_id/2` | optional explicit reason vocabulary; otherwise `% id:` rule labels are reported |
| `action/1` | the action universe (`Deploy_release is an action.`) — enumerated for allowed-alternatives |

## The loop

1. Gate every plan step: `axiom_decide(p, subject, action, resource)`.
2. On block, render the decision back to the model:
   reasons (`d->reasons`), evidence (`d->evidence`), and
   `axiom_allowed_actions(p, subject, resource, &n)` as the replanning
   menu.
3. The model revises; re-validate. Per-step gating composes to plan
   validation — whole-plan modeling inside the KB is possible later but
   not required.

From the REPL the same machinery is interactive:

```
axiom> Should leslie delete_database?
Deny.
Reasons:
  - nobody_deletes
axiom> Which actions can leslie perform?
  restart_service
  read_logs
```

## Run the demo

```sh
zig build
cc examples/guardrail/guardrail.c -Izig-out/include zig-out/lib/libaxiom.a -o /tmp/guardrail
cd examples/guardrail && /tmp/guardrail
```

`guardrail.c` is self-checking: a fake agent proposes
`read_logs → delete_database`, step 2 is blocked with the explanation
block, the plan revises to an allowed alternative, and a contractor is
verified to have no allowed actions.
