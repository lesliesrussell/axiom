#!/usr/bin/env python3
# axiom-9jy
# Reference shim: security-spec event envelope -> Axiom facts -> decision.
#
# Compiles one normalized event (docs/event-schema.md) into facts about a
# fresh event entity, asks `Should <event> <action_kind>?` over `axiom
# --json`, and prints the spec's output contract object. Fail-closed: any
# engine error, parse rejection, or indeterminate outcome reports deny.
#
#   python3 scripts/axiom_gate.py --policy policies/agent-security.axm event.json
#   cat event.json | python3 scripts/axiom_gate.py --policy ...
#   python3 scripts/axiom_gate.py --selftest [path-to-axiom-binary]
#
# A long-lived gate can reuse one Gate instance: each decide() call gets a
# fresh event entity (e1, e2, ...) so prior events never contaminate later
# decisions.
import argparse
import json
import subprocess
import sys


def quote(v):
    """A string term — free-form text (paths, actor names, scopes)."""
    return '"' + str(v).replace('"', "'") + '"'


def event_facts(name, ev):
    """Compile an event envelope into Axiom assert statements."""
    facts = [f"{name} is an event."]

    def has(prop, value, string=False):
        facts.append(f"{name} has {prop} {quote(value) if string else value}.")

    if "runtime" in ev:
        has("runtime", ev["runtime"])
    if "mode" in ev:
        has("exec_mode", ev["mode"])  # 'mode' is reserved (mode declarations)
    if ev.get("repo", {}).get("visibility"):
        has("repo_visibility", ev["repo"]["visibility"])

    p = ev.get("principal", {})
    if "actor" in p:
        has("actor", p["actor"], string=True)
    if "actor_type" in p:
        has("actor_type", p["actor_type"])
    if "actor_app_id" in p:
        has("actor_app_id", p["actor_app_id"], string=True)
    if "trust_level" in p:
        has("actor_trust", p["trust_level"])

    t = ev.get("trigger", {})
    if "event_type" in t:
        has("trigger_type", t["event_type"])
    if "source_object" in t:
        has("source_object", t["source_object"], string=True)
    if "source_trust" in t:
        has("source_trust", t["source_trust"])
    if t.get("edited_after_trigger"):
        facts.append(f"{name} is edited_after_trigger.")

    a = ev.get("proposed_action", {})
    if "target" in a:
        has("target", a["target"], string=True)
    if "destination" in a:
        has("destination", a["destination"], string=True)
    if "kind" in a:
        has("action_kind", a["kind"])

    c = ev.get("context", {})
    if "profile" in c:
        has("profile", c["profile"])
    for src in c.get("prompt_sources", []):
        if "trust" in src:
            has("prompt_trust", src["trust"])
    if any(src.get("tainted") for src in c.get("prompt_sources", [])):
        facts.append(f"{name} is instruction_tainted.")
    for tool in c.get("tools_available", []):
        has("tool", tool)
    for perm in c.get("permissions", []):
        has("permission", perm, string=True)
    for secret in c.get("secrets_present", []):
        has("secret", secret)
    for taint in c.get("session_taints", []):
        has("taint", taint)
    for cap in c.get("capabilities", []):
        has("capability", cap)

    return facts


REQUIREMENTS = {
    "require_confirmation": ["human_approval"],
    "allow_with_sandbox": ["sandbox"],
    "allow_with_redaction": ["redaction"],
}


def output_contract(decision, whynot=None):
    """Engine decision object -> spec output contract. Fail-closed."""
    outcome = decision.get("outcome", "indeterminate")
    reasons = decision.get("reasons", [])
    # rule labels double as reason codes; clause-id hex reasons are noise
    labels = [r for r in reasons if not all(ch in "0123456789abcdef" for ch in r)]
    if outcome == "indeterminate":
        return {
            "v": 1,
            "decision": "deny",
            "reason_code": "NO_MATCHING_POLICY",
            "explanation": {"summary": "no policy rule matched — failing closed",
                            "facts": []},
            "requirements": [],
        }
    code = (labels[0] if labels else "UNLABELED_RULE").upper()
    out = {
        "v": 1,
        "decision": outcome,
        "reason_code": code,
        "explanation": {
            "summary": f"{outcome} by rule {labels[0] if labels else '(unlabeled)'}",
            "facts": decision.get("evidence", []),
        },
        "requirements": REQUIREMENTS.get(outcome, []),
    }
    if whynot and whynot.get("denies"):
        out["explanation"]["gates"] = [
            {"rule": d["rule"], "outcome": d.get("outcome", "deny"),
             "facts": d.get("evidence", [])}
            for d in whynot["denies"]
        ]
    return out


ORACLE_ERROR = {
    "v": 1,
    "decision": "deny",
    "reason_code": "ORACLE_ERROR",
    "explanation": {"summary": "policy oracle unavailable or rejected input — failing closed",
                    "facts": []},
    "requirements": [],
}


class Gate:
    def __init__(self, axiom_bin, policy_paths):
        self.proc = subprocess.Popen(
            [axiom_bin, "--json"] + list(policy_paths),
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1,
        )
        self.counter = 0
        # consume the `loaded` object per policy file
        for _ in policy_paths:
            obj = self._read()
            if obj.get("type") != "loaded":
                raise RuntimeError(f"policy load failed: {obj}")

    def _read(self):
        line = self.proc.stdout.readline()
        if not line:
            raise RuntimeError("oracle closed the stream")
        return json.loads(line)

    def _say(self, stmt):
        self.proc.stdin.write(stmt + "\n")
        self.proc.stdin.flush()
        return self._read()

    def decide(self, event):
        """One event envelope -> spec output contract object."""
        try:
            self.counter += 1
            name = f"E{self.counter}"
            action = event.get("proposed_action", {}).get("kind")
            if not action:
                return ORACLE_ERROR
            for fact in event_facts(name, event):
                obj = self._say(fact)
                if obj.get("type") != "ok":
                    return ORACLE_ERROR
            decision = self._say(f"Should {name.lower()} {action}?")
            if decision.get("type") != "decision":
                return ORACLE_ERROR
            whynot = None
            if decision["outcome"] != "allow":
                wn = self._say("Why not?")
                whynot = wn if wn.get("type") == "whynot" else None
            return output_contract(decision, whynot)
        except (RuntimeError, json.JSONDecodeError, BrokenPipeError):
            return ORACLE_ERROR

    def close(self):
        try:
            self.proc.stdin.close()
        except Exception:
            pass
        try:
            self.proc.wait(timeout=10)
        except Exception:
            self.proc.kill()


# ── selftest: the spec's incident event against a minimal D1 policy ──────

SELFTEST_POLICY = """\
Predicate edited_after_trigger is closed_world.
File_read is an action.
% id: read_is_normally_fine
E has outcome allow if E has subject S and S is an event and S has action_kind file_read.
% id: d1_procfs_secret_read
E has outcome deny if E has subject S and S has target T and T is like "/proc/*/environ" and S is instruction_tainted.
"""

SELFTEST_EVENT = {
    "v": 1,
    "runtime": "claude_code_github_action",
    "mode": "agent",
    "repo": {"owner": "anthropics", "name": "claude-code-action", "visibility": "public"},
    "principal": {"actor": "malicious-app[bot]", "actor_type": "github_app",
                  "trust_level": "untrusted_bot"},
    "trigger": {"event_type": "issue_opened", "source_object": "issue#123",
                "source_trust": "untrusted_user", "edited_after_trigger": False},
    "proposed_action": {"kind": "file_read", "target": "/proc/self/environ"},
    "context": {
        "prompt_sources": [{"type": "issue_body", "trust": "untrusted_user", "tainted": True}],
        "tools_available": ["bash", "mcp__github__update_issue"],
        "permissions": ["issues:write", "id-token:write"],
        "secrets_present": ["github_token", "oidc_exchange_credential"],
    },
}


def selftest(axiom_bin):
    import tempfile, os
    failures = []

    def expect(what, cond, ctx=None):
        print(("  ok  " if cond else "FAIL  ") + what)
        if not cond:
            failures.append(what)
            if ctx is not None:
                print("      " + json.dumps(ctx)[:300])

    with tempfile.NamedTemporaryFile("w", suffix=".axm", delete=False) as f:
        f.write(SELFTEST_POLICY)
        policy = f.name
    try:
        gate = Gate(axiom_bin, [policy])

        # the June 2026 incident event is denied with the D1 reason code
        out = gate.decide(SELFTEST_EVENT)
        expect("incident event denied", out["decision"] == "deny", out)
        expect("reason code is the D1 rule label",
               out["reason_code"] == "D1_PROCFS_SECRET_READ", out)
        expect("evidence names the procfs target",
               any("/proc/self/environ" in f for f in out["explanation"]["facts"]), out)
        expect("whynot gates attached",
               any(g["rule"] == "d1_procfs_secret_read"
                   for g in out["explanation"].get("gates", [])), out)

        # an innocuous read by the same session's NEXT event is allowed —
        # event isolation, no cross-contamination
        benign = json.loads(json.dumps(SELFTEST_EVENT))
        benign["proposed_action"]["target"] = "/repo/README.md"
        benign["context"]["prompt_sources"] = []
        out2 = gate.decide(benign)
        expect("benign read allowed", out2["decision"] == "allow", out2)

        # no matching policy -> fail closed
        weird = {"proposed_action": {"kind": "network_egress"}}
        out3 = gate.decide(weird)
        expect("unmatched action fails closed",
               out3["decision"] == "deny" and out3["reason_code"] == "NO_MATCHING_POLICY",
               out3)

        gate.close()

        # oracle death -> ORACLE_ERROR, not an exception
        dead = Gate(axiom_bin, [policy])
        dead.proc.kill()
        dead.proc.wait()
        out4 = dead.decide(SELFTEST_EVENT)
        expect("dead oracle fails closed", out4["reason_code"] == "ORACLE_ERROR", out4)
        dead.close()
    finally:
        os.unlink(policy)

    print(f"\n{len(failures)} failures" if failures else "\ngate selftest: all green")
    return 1 if failures else 0


def main():
    ap = argparse.ArgumentParser(description="Event envelope -> Axiom decision gate")
    ap.add_argument("event", nargs="?", help="event JSON file (default: stdin)")
    ap.add_argument("--policy", action="append", default=[], help="policy .axm file (repeatable)")
    ap.add_argument("--axiom", default="./zig-out/bin/axiom", help="axiom binary")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()

    if args.selftest:
        sys.exit(selftest(args.axiom))

    raw = open(args.event).read() if args.event else sys.stdin.read()
    gate = Gate(args.axiom, args.policy)
    out = gate.decide(json.loads(raw))
    gate.close()
    print(json.dumps(out, indent=2))
    sys.exit(0 if out["decision"].startswith("allow") else 3)


if __name__ == "__main__":
    main()
