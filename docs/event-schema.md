<!-- axiom-9jy -->
# Event Envelope → Axiom Facts

How the [security spec](security-spec.md) event envelope compiles into
Axiom facts for one decision request. Reference implementation:
`scripts/axiom_gate.py`.

## Model

Each decision request becomes one **event entity** (`e1`, `e2`, … per
session). The shim asserts the envelope as facts about that entity, then
asks `Should <event> <action_kind>?`. The engine's decision context binds
`subject = event`, `action = action kind`; policy rules pattern-match the
event's facts. Events accumulate in the session — each decision references
its own entity, so prior events never contaminate later ones.

Atoms carry enumerated values (trust levels, secret classes, action
kinds). Strings carry free-form text (paths, actor names, permission
scopes, URLs) and work with the `like` glob builtin:

```
E has outcome deny if E has target T and T is like "/proc/*/environ".
```

## Mapping table

| Envelope field | Fact emitted (event `E`) | Term type |
|---|---|---|
| — | `E is an event.` | atom |
| `runtime` | `E has runtime <v>.` | atom |
| `mode` | `E has exec_mode <v>.` — `mode` is a reserved keyword | atom |
| `repo.visibility` | `E has repo_visibility <v>.` | atom |
| `principal.actor` | `E has actor "<v>".` | string |
| `principal.actor_type` | `E has actor_type <v>.` | atom |
| `principal.actor_app_id` | `E has actor_app_id "<v>".` | string |
| `principal.trust_level` | `E has actor_trust <v>.` | atom |
| `trigger.event_type` | `E has trigger_type <v>.` | atom |
| `trigger.source_object` | `E has source_object "<v>".` | string |
| `trigger.source_trust` | `E has source_trust <v>.` | atom |
| `trigger.edited_after_trigger` (true) | `E is edited_after_trigger.` | atom |
| `proposed_action.kind` | `E has action_kind <v>.` + decision action | atom |
| `proposed_action.target` | `E has target "<v>".` | string |
| `proposed_action.destination` | `E has destination "<v>".` | string |
| `context.profile` | `E has profile <v>.` | atom |
| `context.prompt_sources[].trust` | `E has prompt_trust <v>.` | atom |
| `context.prompt_sources[].tainted` (any true) | `E is instruction_tainted.` | atom |
| `context.tools_available[]` | `E has tool <v>.` | atom |
| `context.permissions[]` | `E has permission "<v>".` | string |
| `context.secrets_present[]` | `E has secret <v>.` | atom |
| `context.session_taints[]` | `E has taint <v>.` | atom |
| `context.capabilities[]` (skill/MCP manifest) | `E has capability <v>.` | atom |

Booleans become presence facts (`E is edited_after_trigger.`) — absence
means false under a `closed_world` declaration in the policy. Unknown
envelope fields are ignored by the shim (forward compatibility); unknown
*values* pass through as atoms/strings for the policy to judge.

## Decision round-trip

Input event (spec example, abbreviated):

```json
{
  "principal": {"actor": "malicious-app[bot]", "actor_type": "github_app",
                 "trust_level": "untrusted_bot"},
  "trigger": {"event_type": "issue_opened", "source_trust": "untrusted_user",
               "edited_after_trigger": false},
  "proposed_action": {"kind": "file_read", "target": "/proc/self/environ"},
  "context": {"prompt_sources": [{"type": "issue_body",
               "trust": "untrusted_user", "tainted": true}],
              "secrets_present": ["github_token", "oidc_exchange_credential"]}
}
```

Shim session over `axiom --json`:

```
E1 is an event.
E1 has actor "malicious-app[bot]".
E1 has actor_type github_app.
E1 has actor_trust untrusted_bot.
E1 has trigger_type issue_opened.
E1 has source_trust untrusted_user.
E1 has action_kind file_read.
E1 has target "/proc/self/environ".
E1 has prompt_trust untrusted_user.
E1 is instruction_tainted.
E1 has secret github_token.
E1 has secret oidc_exchange_credential.
Should e1 file_read?
Why not?            (only when the outcome is not plain allow)
```

## Output contract

The shim translates the engine decision into the spec's output object:

```json
{
  "v": 1,
  "decision": "deny",
  "reason_code": "D1_PROCFS_SECRET_READ",
  "explanation": {
    "summary": "deny by rule d1_procfs_secret_read",
    "facts": ["e1 is a target of \"/proc/self/environ\"", "e1 is a instruction_tainted"]
  },
  "requirements": []
}
```

- `decision` — the engine outcome. **Fail-closed:** `indeterminate`
  (no policy rule matched) is reported as `deny` with reason code
  `NO_MATCHING_POLICY`.
- `reason_code` — the winning rule's label, uppercased. Label your policy
  rules with stable `% id:` codes.
- `explanation.facts` — the decision's evidence (leaf facts of the
  winning proof).
- `requirements` — `["human_approval"]` for `require_confirmation`,
  `["sandbox"]` / `["redaction"]` for the gated allows, else empty.

## Failure semantics

Any shim-level failure — engine unavailable, parse error in a fact,
malformed envelope, engine `kind:limit` error — yields
`{"decision": "deny", "reason_code": "ORACLE_ERROR"}`. The interposition
layer must treat anything but a well-formed `allow*` as deny.
