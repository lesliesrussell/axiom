<!-- axiom-xii -->
# Axiom Agent Runtime Security Spec

> **Status:** captured 2026-06-06, tracked as epic **axiom-84n**.
> Numeric citation markers (`[1]`–`[15]`) are preserved from the originating
> research notes and are not resolved in this repository.

## Axiom Fit (implementation preface)

This preface maps the spec onto Axiom as it exists today and onto the gap
issues the epic tracks. The spec body below is normative; this section is
orientation.

### What already exists

| Spec concept | Axiom feature today |
|---|---|
| Policy oracle returning decision + explanation | `Should X act?` decisions: `allow` / `deny` / `indeterminate`, deny-overrides, rule labels, evidence (`src/engine.zig` `decide()`) |
| Explanation trace for audit/regression | `Why not?` counterfactuals (denies + near-misses), `:why` proof trees, all over the `--json` protocol |
| Reason codes | Labeled rules (`% id: <label>`) returned in `reasons[]` — labels double as stable reason codes |
| Allowlists with fail-closed semantics | `Predicate p is closed_world.` — absence of proof is an explicit, annotated `No` |
| Deterministic evaluation | Pure resolution over an explicit fact base; identical input streams give identical answers |
| Machine-readable I/O contract | `--json` line protocol with versioned envelope (`v`, `input`, `type`) |
| Session-scoped decision context | `decide()` asserts `subject`/`action` facts in a temporary scope, popped after evaluation — the template for per-event fact loading |
| Gate → why-not → remediate → retry loop | Demonstrated end to end in `examples/agent_demo.py` and `scripts/kyc_test.py` |

### Gaps tracked by this epic

| Gap | Issue |
|---|---|
| String/path matching builtin (`target matches /proc/*/environ`) — no regex/glob primitive exists | **axiom-rhc** |
| Decision outcomes limited to allow/deny/indeterminate; spec needs `allow_with_redaction`, `allow_with_sandbox`, `require_confirmation` with defined precedence | **axiom-2fx** |
| Event envelope → facts compilation (schema + reference shim) | **axiom-9jy** |
| Reference policy implementing D1–D6 + incident rules | **axiom-4t9** |
| Conformance harness for the 7 test classes | **axiom-vr8** |

### Engine robustness prerequisites

A fail-closed oracle must not be hangable or crashable by crafted input.
Two known engine bugs block the conformance milestone:

- **axiom-7yv** (P0) — unbounded recursion hangs: no depth/step budget in
  resolution. An attacker-influenced policy or fact set could stall the
  oracle; a stalled oracle must still fail closed.
- **axiom-sek** (P1) — missing occurs check: `same_as(X, [X])` builds an
  infinite structure and aborts the process (SIGABRT). Process death of the
  oracle is a fail-open hazard for the interposition layer.

---

## Purpose

This specification defines a security architecture that prevents the class of failures demonstrated in the June 2026 Claude Code GitHub Actions supply-chain incident, while also addressing adjacent attack vectors including malicious skills, MCP servers, indirect prompt injection, secret exfiltration, workflow chaining, trust confusion, and policy bypass through agent tooling.[1][2]

The design assumes a deterministic policy engine already exists in Axiom and focuses on the surrounding event model, enforcement shell, taint model, trust model, and minimum-denial policies required to make agent platforms safe enough for real automation.

## Problem Statement

In the reported incident, Claude Code GitHub Actions granted broad repository and workflow access, accepted attacker-controlled content through insufficient trust validation, allowed agent-mode execution on untrusted input, and exposed secrets through command execution plus write-back channels such as issue updates and workflow summaries.[1][2]

The exploit chain was not one bug but a composition of weaknesses: permissive trigger trust, untrusted natural-language input, excessive capabilities, secrets present in process environment, write-capable outbound channels, and a missing independent policy boundary between model intent and side effects.[1][2]

Any platform with the following properties is vulnerable to similar incidents:[3][4][2]

- An LLM agent can read attacker-controlled text.
- The agent can invoke tools or shell commands.
- The agent has access to secrets, tokens, or privileged ambient credentials.
- The agent can send data to writable or networked sinks.
- Trust decisions are implemented ad hoc in app code or workflow YAML instead of a reviewed policy layer.

## Security Goals

The system defined here must satisfy the following goals for all agent runtimes, including Claude Code, Codex-like systems, CI-integrated agents, local coding agents, and MCP-enabled toolchains.[3][5][4][6]

1. Untrusted content must never directly authorize privileged actions.[2]
2. Sensitive data must not flow to untrusted sinks, regardless of the prompt that requested the action.[1][2]
3. Skills, MCP servers, and tools must not exceed declared capabilities.[5][4]
4. Policy must be explainable, reviewable, testable, and enforced outside the model.[7]
5. Security decisions must compose across multi-step attack chains, not just single actions.[1][2]
6. Failing closed must be the default behavior for ambiguous trust and secret-bearing contexts.[8][9]

## Non-Goals

This specification does not attempt to solve prompt injection at the model level, prove language-model obedience, or rely on vendor-side hidden guardrails as a primary security boundary.[10][11][2]

It also does not require static signatures of known malware as the main defense, because the dominant risk in these incidents is policy abuse and secret-bearing action chains rather than traditional binary malware distribution.[12][13]

## Architecture

The system consists of five layers.[3][12][9]

1. **Interposition layer**: wraps tool calls, shell execution, filesystem access, MCP requests, GitHub API actions, and network egress before execution.[12][9]
2. **Axiom policy oracle**: evaluates normalized events and returns `allow`, `deny`, `allow_with_redaction`, `allow_with_sandbox`, or `require_confirmation`, together with an explanation trace.[14]
3. **Taint and trust engine**: tracks provenance of content, secrets, and privileged state across the action graph.[10][2]
4. **Execution sandbox**: constrains what a permitted action can touch, even after policy approval.[8][9][6]
5. **Audit and replay log**: records every decision, causal input set, policy proof, and actual side effect for post-incident analysis and regression testing.[7][2]

The enforcement point must live outside the model runtime. The model may propose actions, but the interposition layer is the only component allowed to authorize effects.[3][9]

## Threat Model

The system must assume all of the following are potentially attacker-controlled unless proven otherwise:[3][10][9][2]

- Issue bodies, comments, pull requests, commit messages, diff text, workflow artifacts, logs, pasted stack traces, and webpages.
- `SKILL.md`, prompt templates, slash-command definitions, tool descriptions, MCP metadata, and repository command files.
- GitHub Apps and bots not explicitly allowlisted by organization policy.[1][2]
- Files modified after a trusted event fires but before the agent reads them.[1][2]
- Outputs from external tools, including MCP servers, unless separately trusted.

The system must further assume that any agent granted shell access can attempt to read ambient credentials through direct files, procfs, inherited environment variables, child-process state, or alternate tool paths.[1][2][6]

## Core Concepts

### Trust Levels

Every principal, content object, tool, and destination is assigned a trust level at evaluation time:[3][5][2]

- `trusted_human`
- `trusted_service`
- `trusted_repo_content`
- `reviewed_skill`
- `reviewed_mcp`
- `untrusted_user`
- `untrusted_bot`
- `untrusted_remote_content`
- `tainted_runtime_output`

Trust is not binary. A trusted actor can still deliver tainted content if the content includes untrusted embedded material or was edited after a trigger boundary.[2]

### Secret Classes

Sensitive material must be labeled by class, not treated as a single boolean:[1][2][6]

- `api_key`
- `github_token`
- `oidc_exchange_credential`
- `ssh_key`
- `cloud_credential`
- `env_secret`
- `repo_secret`
- `session_cookie`
- `private_source`
- `user_pii`

### Sinks

Any action that can reveal, persist, or amplify sensitive material is a sink:[12][9][2]

- Issue or PR updates
- Workflow summaries and logs
- Network egress
- Git push or workflow write
- Third-party MCP calls
- Clipboard, notifications, or terminal output in shared environments
- Memory/config files that influence later agent behavior

## Event Model

All runtimes must emit a normalized event envelope to Axiom. The minimum schema is:

```json
{
  "v": 1,
  "time": "2026-06-06T14:05:00Z",
  "session_id": "sess_...",
  "runtime": "claude_code_github_action",
  "mode": "agent",
  "repo": {
    "owner": "anthropics",
    "name": "claude-code-action",
    "visibility": "public"
  },
  "principal": {
    "actor": "malicious-app[bot]",
    "actor_type": "github_app",
    "trust_level": "untrusted_bot"
  },
  "trigger": {
    "event_type": "issue_opened",
    "source_object": "issue#123",
    "source_trust": "untrusted_user",
    "edited_after_trigger": false
  },
  "proposed_action": {
    "kind": "file_read",
    "target": "/proc/self/environ"
  },
  "context": {
    "prompt_sources": [
      {"type": "issue_body", "trust": "untrusted_user", "tainted": true}
    ],
    "tools_available": ["bash", "mcp__github__update_issue"],
    "permissions": ["issues:write", "id-token:write"],
    "secrets_present": ["github_token", "oidc_exchange_credential"]
  }
}
```

The canonical action kinds are:[12][8][9][2]

- `skill_install`
- `mcp_connect`
- `prompt_ingest`
- `file_read`
- `file_write`
- `command_exec`
- `tool_call`
- `network_egress`
- `issue_update`
- `pr_comment`
- `workflow_summary_write`
- `git_push`
- `workflow_modify`
- `secret_materialize`
- `trust_downgrade`
- `session_end`

## Taint Propagation

The system must implement mandatory taint propagation.[10][2]

1. Any content originating from untrusted actors or untrusted remote sources is marked `instruction_tainted`.
2. Any data read from sensitive paths or sensitive environment variables is marked with its secret class.
3. Any model output whose reasoning depends on tainted input inherits `instruction_tainted` unless explicitly de-tainted by policy-approved parsing or sanitization.
4. Any command arguments, issue updates, network payloads, or workflow summaries that include or derive from secret-tainted values inherit the relevant secret taint.
5. Taint is monotonic within a session unless a trusted transform explicitly emits a redacted replacement.

For this incident class, reading `/proc/self/environ` must produce `env_secret` plus `oidc_exchange_credential` taints if the corresponding variables are present.[1][2]

## Trust and Trigger Policy

The following trigger rules are mandatory.[1][2]

1. A bot identity suffix such as `[bot]` must never be treated as proof of trust.[1][2]
2. GitHub Apps must be matched against an explicit organizational allowlist keyed by immutable app identifier, not display name.[2]
3. Agent mode must reject all untrusted or ambiguous actors by default.[1][2]
4. Any content edited after the triggering event but before agent fetch must be treated as newly untrusted and must either abort the run or force a full re-evaluation under untrusted-input policy.[1][2]
5. `allowed_non_write_users` or equivalent “open trigger” settings must force a restricted execution profile with no ambient secrets other than the minimum token required for the narrow task.[1][2]

## Mandatory Deny Rules

These rules are normative. If a proposed action matches any rule, the action must be denied regardless of model intent.[8][9][2]

### Rule D1: Secret-bearing procfs access

Deny `file_read` on `/proc/self/environ`, `/proc/*/environ`, process status files that expose credentials, and equivalent runtime-secret surfaces whenever the session includes untrusted input or the runtime contains ambient credentials.[1][2]

### Rule D2: Secret to untrusted sink

Deny any sink action if payload taint includes `api_key`, `github_token`, `oidc_exchange_credential`, `ssh_key`, `cloud_credential`, `env_secret`, or `repo_secret` and the destination is not explicitly approved for that secret class.[12][10][1][2]

### Rule D3: Untrusted input to command execution

Deny `command_exec` or high-risk `tool_call` when the action request is materially derived from `instruction_tainted` input and the command is not on a narrow safe allowlist with argument validation.[10][8][2]

### Rule D4: Untrusted input plus write-capable GitHub tools

Deny issue edits, PR comment writes, label changes, workflow summary writes, or repository mutations when the session includes untrusted prompt sources and the target channel could act as an exfiltration sink.[1][2]

### Rule D5: Workflow self-mutation under tainted context

Deny `workflow_modify`, `git_push`, tag creation, or release publication if the session is tainted by untrusted input or secret access unless a human approval step bound to a reviewed diff explicitly authorizes it.[15][1][2]

### Rule D6: Capability mismatch

Deny actions by skills or MCP servers that exceed declared capabilities, touch undeclared destinations, or invoke shell/network primitives not present in their reviewed manifest.[5][4]

## Restricted Profiles

The runtime must support named execution profiles selected by policy.[8][9][6]

| Profile | Intended use | Allowed capabilities | Forbidden capabilities |
|---|---|---|---|
| `triage_public` | Public issue labeling and classification | Read issue metadata, apply fixed labels | Shell, arbitrary MCP, workflow summary writes, network egress, issue body updates |
| `review_trusted` | Trusted PR review | Read repo, comment on PR, structured diagnostics | Secret access, workflow writes, push, non-reviewed MCP |
| `agent_untrusted` | Any automation ingesting untrusted content | Minimal read-only tools | Shell, ambient secrets, write sinks, GitHub App token exchange |
| `maintainer_mutation` | Trusted code modification | Diff generation, branch writes in sandbox | Workflow mutation without secondary approval |

If `allowed_non_write_users` or analogous open triggering is enabled, the profile must be `triage_public` or stricter.[1][2]

## Secret Handling

Ambient secrets are the core enabler of escalation in this incident class.[1][2]

The runtime must implement the following controls:[8][9][6][2]

- Child processes spawned by the agent receive a scrubbed environment by default.[2]
- OIDC exchange credentials must never be available to sessions processing untrusted content.[1][2]
- Secrets are brokered through a sidecar that returns scoped capability handles rather than raw values whenever possible.
- Secret reads are logged as first-class events and immediately elevate session risk level.
- Secrets must be redacted before entering model-visible context unless the specific task profile requires the raw value and policy permits it.

## Tool Wrappers and Argument Validation

The system must not trust raw shell or CLI argument surfaces for sensitive tools.[2]

Every high-risk tool requires a wrapper with structured validation. Examples:[2]

- `gh issue view` must accept only numeric identifiers for a bound repository issue, never arbitrary URLs.[2]
- Git operations must be restricted to approved remotes, branches, and refs.
- File access tools must resolve paths against an allowlisted root and deny path traversal or procfs access.
- Network tools must enforce destination allowlists, method restrictions, and payload inspection.

Generic shell access must be modeled as a privileged capability separate from narrow wrappers. If the policy can express the action using a narrow tool, shell must not be granted as a fallback.[8][9]

## MCP and Skill Controls

Because similar vectors exist in MCP servers and skill ecosystems, the same enforcement model applies.[3][5][4]

- Every MCP server and skill must declare capabilities, data sources, sinks, and network destinations in a manifest.[5][4]
- Axiom policy decides whether a session may connect to that MCP or enable that skill.
- Requests and responses across MCP boundaries must be logged and taint-tracked.
- MCP responses are treated as untrusted unless the server is reviewed and pinned.
- A reviewed MCP may still be downgraded if it begins returning content that drives policy-sensitive actions outside its declared domain.

## Human Approval Semantics

Some actions may be too useful to ban outright but too risky to allow automatically. For those, the policy engine may return `require_confirmation`.[7]

A confirmation step is only valid if it includes all of the following:[8][9]

- The exact action requested.
- The trust and taint summary that caused gating.
- The sensitive resources affected.
- A diff or structured preview of side effects.
- A short-lived approval token bound to that exact action hash.

A human approval for one action must not authorize subsequent unrelated actions.

## Incident-Specific Reference Policy

The following reference rules would have blocked the June 2026 exploit chain.[1][2]

1. `deny if actor_type = github_app and actor_app_id not in trusted_app_allowlist`.[1][2]
2. `deny if mode = agent and trigger.source_trust != trusted_human`.[1][2]
3. `deny if proposed_action.kind = file_read and target matches /proc/.*/environ`.[1][2]
4. `deny if session.taints contains oidc_exchange_credential and sink in {issue_update, workflow_summary_write, network_egress}`.[1][2]
5. `deny if permissions contains id-token:write and trigger.source_trust != trusted_human`.[1][2]
6. `deny if workflow profile = public_triage and any capability in {bash, arbitrary_mcp, issue_update_body, summary_write}`.[1][2]
7. `abort if source object edited_after_trigger = true`.[2]

## Axiom Integration Contract

Axiom should be invoked as a pure decision oracle over JSON events, matching the existing direction toward agent-friendly machine-readable I/O.[14]

Input contract:

- One event object per decision request.
- Stable versioned schema.
- Full trust, taint, and capability context included.
- Deterministic output for identical event streams and policy sets.

Output contract:

```json
{
  "v": 1,
  "decision": "deny",
  "reason_code": "SECRET_TO_UNTRUSTED_SINK",
  "explanation": {
    "summary": "Session contains OIDC exchange credentials and attempted to write tainted data to a public issue.",
    "facts": [
      "trigger.source_trust = untrusted_user",
      "session.taints contains oidc_exchange_credential",
      "proposed_action.kind = issue_update"
    ]
  },
  "requirements": []
}
```

The explanation must be concise enough for operators yet precise enough for regression tests and audit review.[7]

## Operational Requirements

Implementations conforming to this spec must provide:[8][9][6]

- Fail-closed behavior if the policy oracle is unavailable.
- Immutable audit logs for all denied and allowed high-risk actions.
- Replay tooling to re-run historical sessions against updated policy.
- Organization-scoped trust registries for apps, MCP servers, skills, repos, and destinations.
- Default-secure templates for CI, local agents, and issue triage workflows.
- Continuous tests using incident reproductions and synthetic attack chains.

## Conformance Tests

A conforming system must at minimum pass the following test classes.[1][2]

1. Untrusted bot-triggered issue cannot enter privileged agent mode.
2. Any attempt to read `/proc/self/environ` in a tainted session is denied.
3. Any secret-tainted value cannot be written to issue bodies, PR comments, workflow summaries, logs, or arbitrary URLs.
4. Edited-after-trigger content causes abort or trust downgrade before tool execution.
5. A public-triage profile cannot execute shell commands or arbitrary MCP calls.
6. A skill or MCP server that requests undeclared shell or network access is denied.
7. A trusted code-modification workflow still requires per-action approval for workflow-file mutation.

## Deployment Guidance

The shortest path to practical adoption is to deploy this architecture in three phases.[14]

### Phase 1: Observe

Wrap agent runtimes and emit normalized events to logs plus a non-blocking Axiom evaluation channel. Measure how often existing workflows would be denied.[14]

### Phase 2: Gate high-risk actions

Start enforcing deny rules for secret access, untrusted sinks, open-trigger workflows, procfs reads, workflow mutation, and undeclared MCP capabilities.[8][9][2]

### Phase 3: Full profile enforcement

Move all agent jobs onto named execution profiles with ambient-secret scrubbing, reviewed wrappers, and mandatory trust registries.[8][6][2]

## Design Rationale

The incident demonstrated that the real security boundary cannot be the model, the prompt, or a single permission check in workflow code.[1][2]

The correct boundary is an external policy system that reasons over provenance, trust, capability, and data flow before side effects occur. Axiom is well suited to serve that role because it makes the decision layer deterministic, human-readable, and auditable.[7]
