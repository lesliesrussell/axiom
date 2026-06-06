#!/usr/bin/env python3
# axiom-zy8
# Real-world scenario test: KYC/AML customer onboarding.
#
# Banks run rule engines for exactly this. The scenario exercises the
# whole language against one realistic domain, end to end:
#
#   * facts + rules in plain English        (customers, ownership)
#   * recursion                             (control through ownership chains)
#   * integers + spaced comparisons        (risk scores)
#   * closed-world declarations             (the sanctions list is complete)
#   * safe negation                         (high-risk without EDD clearance)
#   * labeled decision rules, deny-overrides(Should X onboard?)
#   * the guardrail loop                    (deny -> why not -> remediate -> allow)
#   * proof trees                           (:why shows the ownership chain)
#
# Self-checking: exits nonzero if any answer deviates.
#
#   python3 scripts/kyc_test.py [path-to-axiom-binary]
import json
import subprocess
import sys

BIN = sys.argv[1] if len(sys.argv) > 1 else "./zig-out/bin/axiom"

proc = subprocess.Popen(
    [BIN, "--json"],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1,
)

passed = 0
failed = []


def say(line):
    """Send one statement, read one JSON response back."""
    proc.stdin.write(line + "\n")
    proc.stdin.flush()
    return json.loads(proc.stdout.readline())


def check(name, cond, ctx=None):
    global passed
    if cond:
        passed += 1
        print(f"  ok  {name}")
    else:
        failed.append(name)
        print(f"FAIL  {name}")
        if ctx is not None:
            print(f"      {json.dumps(ctx)}"[:300])


# ── 1. The customer graph ────────────────────────────────────────────────
# Three onboarding applicants and the people behind them. Ownership is a
# chain: Viktor -> Shell Holdco -> Meridian Trading. Nobody at the bank
# typed "Viktor controls Meridian" anywhere — the engine derives it.

for stmt in [
    # applicants
    "Volt_energy is a company.",
    "Meridian_trading is a company.",
    "Nimbus_logistics is a company.",
    # people
    "Ada is a person.",
    "Viktor is a person.",
    "Priya is a person.",
    # ownership (direct edges only — control is derived)
    "Ada is an owner of Volt_energy.",
    "Viktor is an owner of Shell_holdco.",
    "Shell_holdco is an owner of Meridian_trading.",
    "Priya is an owner of Nimbus_logistics.",
    # jurisdiction risk scores, straight from the compliance team
    "Volt_energy has risk_score 20.",
    "Meridian_trading has risk_score 45.",
    "Nimbus_logistics has risk_score 80.",
]:
    obj = say(stmt)
    check(f"assert: {stmt}", obj["type"] == "ok", obj)

# ── 2. The compliance rulebook ───────────────────────────────────────────

for stmt in [
    # control = transitive closure over ownership (the recursion)
    "X is a controller of Y if X is an owner of Y.",
    "X is a controller of Z if X is an owner of Y and Y is a controller of Z.",
    # a beneficial owner is a person who controls the company, however indirectly
    "P is a beneficial_owner of C if P is a person and P is a controller of C.",
    # the sanctions list is complete: absence of proof means clean
    "Viktor is sanctioned.",
    "Predicate sanctioned is closed_world.",
    "Predicate edd_cleared is closed_world.",
    # risk tiers via integer comparison (spaced form)
    "C is high_risk if C has risk_score S and S is bigger than 70.",
]:
    obj = say(stmt)
    check(f"rule: {stmt}", obj["type"] == "ok", obj)

# ── 3. Compliance questions an analyst would actually ask ────────────────

# Does anyone sanctioned sit behind Meridian? Two hops of ownership.
obj = say("Is Viktor a beneficial_owner of Meridian_trading?")
check("ownership chain derives beneficial owner",
      obj["type"] == "yesno" and obj["answer"] is True, obj)

# The audit trail: the proof tree must show the actual chain,
# not just "yes" — controller recursion as nested rule nodes.
obj = say(":why")


def tree_goals(node, acc):
    acc.append(node["goal"])
    for c in node.get("children", []):
        tree_goals(c, acc)
    return acc


goals = tree_goals(obj["trees"][0], []) if obj.get("trees") else []
check("proof tree walks the chain viktor -> shell_holdco -> meridian",
      obj["type"] == "proof"
      and "owner(viktor, shell_holdco)" in goals
      and "owner(shell_holdco, meridian_trading)" in goals, obj)

# Clean customer screens clean — and the No is closed-world, not a shrug.
obj = say("Is Volt_energy sanctioned?")
check("sanctions screen: No by closed-world assumption",
      obj["type"] == "yesno" and obj["answer"] is False and obj["cwa"] is True,
      obj)

# Who is high-risk? Only Nimbus crosses the threshold.
obj = say("Who is high_risk?")
who = {s["Who"] for s in obj.get("solutions", [])}
check("risk threshold flags exactly nimbus_logistics",
      obj["type"] == "solutions" and who == {"nimbus_logistics"}, obj)

# ── 4. The onboarding policy: labeled rules, deny-overrides ──────────────

obj = say("Onboard is an action.")
check("policy: onboard is an action", obj["type"] == "ok", obj)

# label comments ride immediately above the rule, in the same write
for label, rule in [
    ("companies_may_onboard",
     "D has outcome allow if D has subject C and D has action onboard"
     " and C is a company."),
    ("sanctioned_ownership_blocks",
     "D has outcome deny if D has subject C and P is a beneficial_owner of C"
     " and P is sanctioned."),
    ("high_risk_needs_edd",
     "D has outcome deny if D has subject C and C is high_risk"
     " and C is not edd_cleared."),
]:
    obj = say(f"% id: {label}\n{rule}")
    check(f"policy rule labeled: {label}",
          obj["type"] == "ok" and obj["added"].get("label") == label, obj)

# ── 5. Three onboarding decisions ────────────────────────────────────────

# Clean, low-risk: straight allow.
obj = say("Should volt_energy onboard?")
check("clean customer onboards",
      obj["type"] == "decision" and obj["outcome"] == "allow"
      and "companies_may_onboard" in obj["reasons"], obj)

# Sanctioned beneficial owner two hops up: deny beats the allow.
obj = say("Should meridian_trading onboard?")
check("hidden sanctioned owner denies onboarding",
      obj["type"] == "decision" and obj["outcome"] == "deny"
      and "sanctioned_ownership_blocks" in obj["reasons"], obj)

# The analyst asks why — and gets the rule label plus the evidence chain.
obj = say("Why not?")
denies = obj.get("denies", [])
check("why-not names the sanctions rule with evidence",
      obj["type"] == "whynot"
      and any(d["rule"] == "sanctioned_ownership_blocks" for d in denies)
      and any("viktor" in e for d in denies for e in d["evidence"]), obj)

# ── 6. The guardrail loop: deny -> why not -> remediate -> retry ─────────

# High-risk Nimbus is denied until enhanced due diligence clears.
obj = say("Should nimbus_logistics onboard?")
check("high-risk customer denied pending EDD",
      obj["type"] == "decision" and obj["outcome"] == "deny"
      and "high_risk_needs_edd" in obj["reasons"], obj)

obj = say("Why not?")
check("why-not points at the EDD gap",
      obj["type"] == "whynot"
      and any(d["rule"] == "high_risk_needs_edd" for d in obj["denies"]), obj)

# Compliance completes enhanced due diligence — one new fact.
obj = say("Nimbus_logistics is edd_cleared.")
check("EDD clearance recorded", obj["type"] == "ok", obj)

# Same question, different world, different answer.
obj = say("Should nimbus_logistics onboard?")
check("cleared customer now onboards",
      obj["type"] == "decision" and obj["outcome"] == "allow", obj)

# ── 7. Portfolio view + hygiene ──────────────────────────────────────────

obj = say("Which actions can volt_energy perform?")
check("action universe resolves for clean customer",
      obj["type"] == "actions" and "onboard" in obj["actions"], obj)

# The rulebook itself passes the engine's static checks (safe negation etc).
obj = say(":check")
check("rulebook passes :check", obj["type"] == "check", obj)

# ── verdict ──────────────────────────────────────────────────────────────
proc.stdin.close()
proc.wait(timeout=10)

print(f"\n{passed} passed, {len(failed)} failed")
if failed:
    for name in failed:
        print(f"  FAIL: {name}")
    sys.exit(1)
print("KYC scenario: all checks green.")
