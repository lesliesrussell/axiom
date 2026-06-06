#!/usr/bin/env python3
# axiom-764
# An AI agent's session with Axiom, narrated.
#
# This is the agent's side of the conversation: it spawns `axiom --json`,
# builds a policy through the protocol, makes mistakes on purpose (and
# reads the hints), gets denied (and asks why not), fixes the world, and
# retries. Everything a coding-agent skill does, in ~100 lines.
#
# Self-checking: exits nonzero if any response deviates.
#
#   python3 examples/agent_demo.py [path-to-axiom-binary]
import json
import subprocess
import sys

BIN = sys.argv[1] if len(sys.argv) > 1 else "axiom"

proc = subprocess.Popen(
    [BIN, "--json"],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1,
)

failures = []


def say(line):
    """Send one statement, read one JSON object back."""
    print(f"\n→ {line}")
    proc.stdin.write(line + "\n")
    proc.stdin.flush()
    obj = json.loads(proc.stdout.readline())
    pretty = {k: v for k, v in obj.items() if k not in ("v", "input")}
    print(f"← {json.dumps(pretty)}")
    return obj


def expect(obj, what, cond):
    if not cond:
        failures.append(what)
        print(f"  ✘ expected: {what}")


# ── 1. Build the harbor policy through the protocol ─────────────────────
print("=== Building a harbor policy, one statement at a time ===")

obj = say("Pelican is a tugboat.")
expect(obj, "assert returns ok", obj["type"] == "ok" and obj["added"]["pred"] == "tugboat")

for stmt in [
    "Osprey is a ferry.",
    "Pelican has draft 3.",
    "Osprey has draft 7.",
    "Osprey is overdue_for_inspection.",
    "Predicate overdue_for_inspection is closed_world.",
    # today's spaced comparison form — 'less than', not less_than
    "S is shallow_safe if S has draft D and D is less than 5.",
    "Enter_harbor is an action.",
    "Refuel is an action.",
]:
    say(stmt)

# ── 2. Make the mistakes a model makes; read the hints ───────────────────
print("\n=== The error hints do the teaching ===")

obj = say("Tugboats are vessels.")
expect(obj, "plural gets a hint", obj["type"] == "error" and "plural" in obj.get("hint", ""))

obj = say("Is Pelican not overdue_for_inspection?")
expect(obj, "negated query gets the design hint",
       obj["type"] == "error" and "positive form" in obj.get("hint", ""))

# today's type warning: a boat is not a number — the warning rides in notes[]
obj = say("Is Pelican less than 5?")
expect(obj, "type confusion warned in notes",
       obj["type"] == "yesno" and obj["answer"] is False and
       any("expects integers" in n for n in obj.get("notes", [])))

# closed-world No is annotated structurally
obj = say("Is Pelican overdue_for_inspection?")
expect(obj, "closed-world No sets cwa", obj["answer"] is False and obj["cwa"] is True)

# ── 3. Decision rules (labels ride a comment line above the rule) ────────
print("\n=== Loading labeled decision rules ===")

for label, rule in [
    ("shallow_boats_enter",
     "D has outcome allow if D has subject S and D has action enter_harbor and S is shallow_safe."),
    ("anyone_refuels",
     "D has outcome allow if D has subject S and D has action refuel."),
    ("inspection_holds",
     "D has outcome deny if D has subject S and S is overdue_for_inspection."),
]:
    proc.stdin.write(f"% id: {label}\n{rule}\n")
    proc.stdin.flush()
    obj = json.loads(proc.stdout.readline())
    expect(obj, f"rule {label} labeled", obj["type"] == "ok" and obj["added"].get("label") == label)
    print(f"→ (% id: {label}) {rule[:50]}…")
    print(f"← added {obj['added']['pred']}/{obj['added']['arity']} label={obj['added'].get('label')}")

# ── 4. The guardrail loop ────────────────────────────────────────────────
print("\n=== Guardrail loop: gate → why not → fix → retry ===")

obj = say("Should osprey enter_harbor?")
expect(obj, "osprey denied", obj["outcome"] == "deny" and "inspection_holds" in obj["reasons"])

obj = say("Why not?")
expect(obj, "whynot names the lever",
       any("overdue_for_inspection" in e for d in obj["denies"] for e in d["evidence"]) and
       any("shallow_safe" in m["blocker"] for m in obj["near_misses"]))

obj = say("Which actions can pelican perform?")
expect(obj, "pelican's menu", set(obj["actions"]) == {"enter_harbor", "refuel"})

# the agent "fixes the world": inspection done, fact retracted
obj = say(":show facts")
idx = next(c["index"] for c in obj["clauses"] if "overdue" in c["text"])
obj = say(f":retract {idx}")
expect(obj, "retract echoes", obj["type"] == "retracted" and "overdue" in obj["text"])

obj = say("Should osprey enter_harbor?")
expect(obj, "still blocked: ferry draws 7", obj["outcome"] == "indeterminate")

obj = say("Why not?")
expect(obj, "blocker is now the draft",
       any("shallow_safe" in m["blocker"] for m in obj["near_misses"]))

obj = say("Should osprey refuel?")
expect(obj, "refuel allowed after fix", obj["outcome"] == "allow" and
       "anyone_refuels" in obj["reasons"])

# ── 5. Proof, for the audit log ──────────────────────────────────────────
print("\n=== Proof tree for the record ===")

say("Is Pelican shallow_safe?")
obj = say(":why")
tree = obj["trees"][0]
expect(obj, "proof: rule with builtin leaf",
       tree["kind"] == "rule" and
       any(c["kind"] == "builtin" for c in tree["children"]))

say(":quit")
proc.wait(timeout=10)

print()
if failures:
    print(f"✘ {len(failures)} expectation(s) failed")
    sys.exit(1)
print("=== agent demo passed: every response matched ===")
