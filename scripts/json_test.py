#!/usr/bin/env python3
# axiom-47h
# Protocol tests for `axiom --json`: every stdout line must parse as JSON
# with the v/input/type envelope; spot-checks each response type.
#
# Usage: python3 scripts/json_test.py [path-to-axiom-binary]
import json
import subprocess
import sys
import tempfile
import os

BIN = sys.argv[1] if len(sys.argv) > 1 else "./zig-out/bin/axiom"

passed = 0
failed = []


def check(name, cond, ctx=""):
    global passed
    if cond:
        passed += 1
        print(f"  ok  {name}")
    else:
        failed.append(name)
        print(f"FAIL  {name}")
        if ctx:
            print(f"      {ctx!r}"[:300])


def run(stdin_text, args=None):
    """Run axiom --json, return list of parsed objects. Asserts purity."""
    cmd = [BIN, "--json"] + (args or [])
    out = subprocess.run(cmd, input=stdin_text, capture_output=True,
                         text=True, timeout=30).stdout
    objs = []
    for line in out.splitlines():
        if not line.strip():
            check("no blank protocol lines", False, out)
            continue
        try:
            objs.append(json.loads(line))
        except json.JSONDecodeError:
            check("line parses as JSON", False, line)
    return objs, out


def main():
    # ── purity + envelope across a kitchen-sink session ──
    session = (
        "Socrates is a man.\n"
        "X is mortal if X is a man.\n"
        "Is Socrates mortal?\n"
        "Who is a man?\n"
        ":why\n"
        ":show\n"
        ":show english\n"
        "Predicate banned is closed_world.\n"
        "Is Socrates banned?\n"
        "Dogs are animals.\n"
        ":check\n"
        ":quit\n"
    )
    objs, raw = run(session)
    check("all lines are JSON", "\x1b" not in raw and all("v" in o for o in objs), raw)
    check("envelope on every object",
          all(o.get("v") == 1 and "input" in o and "type" in o for o in objs))

    by_type = {}
    for o in objs:
        by_type.setdefault(o["type"], []).append(o)

    check("assert -> ok.added", by_type.get("ok", [{}])[0].get("added", {}).get("pred") == "man")
    yn = by_type.get("yesno", [])
    check("yesno answer true", yn and yn[0]["answer"] is True)
    check("cwa flag on closed-world No",
          any(o.get("cwa") is True and o["answer"] is False for o in yn))
    sols = by_type.get("solutions", [{}])[0]
    check("solutions bind Who", sols.get("solutions") == [{"Who": "socrates"}])
    proof = by_type.get("proof", [{}])[0]
    # :why follows "Who is a man?" — a fact-only proof
    check("proof tree shape",
          proof.get("trees", [{}])[0].get("kind") == "fact", str(proof))
    check("clauses listing", len(by_type.get("clauses", [{}])[0].get("clauses", [])) == 2)
    err = by_type.get("error", [{}])[0]
    check("parse error structured", err.get("kind") == "parse" and "hint" in err and err.get("col") == 6)
    check("check warnings array", "warnings" in by_type.get("check", [{}])[0])

    # ── decisions, whynot, actions over the starport example ──
    session2 = (
        ":load examples/starport.axm\n"
        "Should thane dock?\n"
        "Why not?\n"
        "Which actions can mirelle perform?\n"
        ":quit\n"
    )
    objs2, _ = run(session2)
    t2 = {o["type"]: o for o in objs2}
    check("loaded counts", t2["loaded"]["clauses"] == 46 and t2["loaded"]["skipped"] == 0)
    check("decision deny + reasons",
          t2["decision"]["outcome"] == "deny" and
          "flagged_ships_grounded" in t2["decision"]["reasons"], str(t2.get("decision")))
    check("whynot near-miss blocker",
          any("freight_class_a" in m["blocker"] for m in t2["whynot"]["near_misses"]),
          str(t2.get("whynot")))
    check("actions list", set(t2["actions"]["actions"]) ==
          {"dock", "refuel", "unload_cargo"}, str(t2.get("actions")))

    # ── notes capture: trace text rides in notes[], protocol stays valid ──
    session3 = (
        "Socrates is a man.\n"
        ":trace on\n"
        "Is Socrates a man?\n"
        ":quit\n"
    )
    objs3, raw3 = run(session3)
    yn3 = [o for o in objs3 if o["type"] == "yesno"]
    check("trace rides in notes", yn3 and any("CALL" in n for n in yn3[0].get("notes", [])), raw3)

    # ── :json toggle round-trip in text mode ──
    out4 = subprocess.run([BIN], input=":json\nSocrates is a man.\n:json\nPlato is a man.\n:quit\n",
                          capture_output=True, text=True, timeout=30).stdout
    lines4 = out4.splitlines()
    # the mode object shares a line with the prompt printed before the
    # toggle was read; strip any prefix before the brace
    json_lines = [l[l.index("{"):] for l in lines4 if '{"v"' in l]
    check(":json toggle emits mode + ok", len(json_lines) == 2 and
          json.loads(json_lines[0])["type"] == "mode", out4)
    check(":json off returns to text", "Added: man/1" in out4 and "JSON mode off." in out4, out4)

    # ── diff / whatif ──
    session5 = (
        ":diff examples/starport.axm examples/starport_v2.axm\n"
        ":whatif examples/starport.axm examples/starport_v2.axm examples/starport_inputs.txt\n"
        ":quit\n"
    )
    objs5, _ = run(session5)
    t5 = {o["type"]: o for o in objs5}
    check("diff three changes", len(t5["diff"]["changes"]) == 3, str(t5.get("diff")))
    check("whatif delta", t5["whatif"]["changed"][0]["subject"] == "orsk" and
          t5["whatif"]["total"] == 4, str(t5.get("whatif")))

    # ── file args with --json emit loaded objects ──
    objs6, _ = run(":quit\n", args=["examples/starport.axm"])
    check("--json file arg emits loaded", objs6[0]["type"] == "loaded")

    # ── axiom-7yv: resolution budgets — recursion errors, never hangs ──
    objs7, _ = run(
        "X is stuck if X is stuck.\n"
        "Bob is a person.\n"
        "Is Bob stuck?\n"
        "Who is a person?\n"  # engine stays usable after a limit error
        ":quit\n"
    )
    limit = [o for o in objs7 if o["type"] == "error" and o.get("kind") == "limit"]
    check("self-recursion errors with kind=limit", len(limit) == 1, objs7)
    check("limit message names the predicate",
          limit and "stuck/1" in limit[0]["message"], limit)
    after = [o for o in objs7 if o["type"] == "solutions"]
    check("session survives a limit error",
          after and after[0]["solutions"] == [{"Who": "bob"}], objs7)

    objs8, _ = run(
        "X is odd if X is not even.\n"
        "X is even if X is not odd.\n"
        "Is three odd?\n"
        ":quit\n"
    )
    check("unstratified negation errors with kind=limit",
          any(o["type"] == "error" and o.get("kind") == "limit" for o in objs8), objs8)

    # ── axiom-sek: occurs check — X = [X] fails instead of crashing ──
    objs9, _ = run(
        "X is weird if X is same_as [X].\n"
        "X is fine if X is same_as X.\n"
        "Who is weird?\n"
        "Is foo fine?\n"
        ":quit\n"
    )
    sols9 = [o for o in objs9 if o["type"] == "solutions"]
    check("cyclic unification yields zero solutions, no crash",
          sols9 and sols9[0]["count"] == 0, objs9)
    check("same-variable unification stays trivially true",
          any(o["type"] == "yesno" and o["answer"] is True for o in objs9), objs9)

    # ── axiom-rhc: string terms + like/2 glob matching ──
    objs10, _ = run(
        'Probe has target "/proc/self/environ".\n'
        'Safe has target "/etc/hosts".\n'
        'X is procfs_read if X has target T and T is like "/proc/*/environ".\n'
        'X is offpath if X has target T and T is not like "/proc/*".\n'
        "Who is procfs_read?\n"
        "Is Safe offpath?\n"
        'Who has target "/proc/self/environ"?\n'
        "Is Probe procfs_read?\n"
        ":why\n"
        ":quit\n"
    )
    sols10 = [o for o in objs10 if o["type"] == "solutions"]
    check("glob rule matches procfs path",
          sols10 and sols10[0]["solutions"] == [{"Who": "probe"}], objs10)
    check("negated glob holds for non-matching path",
          any(o["type"] == "yesno" and o["answer"] is True for o in objs10), objs10)
    check("string fact is queryable by exact value",
          len(sols10) > 1 and sols10[1]["solutions"] == [{"Who": "probe"}], objs10)
    proof10 = [o for o in objs10 if o["type"] == "proof"]
    check("proof tree shows like builtin leaf",
          proof10 and any("like(" in c["goal"] for c in proof10[0]["trees"][0]["children"]),
          proof10)

    # ── axiom-2fx: extended decision outcomes with precedence ──
    objs11, _ = run(
        "T is a thing.\n"
        "Act is an action.\n"
        "% id: base_allow\n"
        "D has outcome allow if D has subject C and C is a thing.\n"
        "% id: sandbox_gate\n"
        "D has outcome allow_with_sandbox if D has subject C and C is a thing.\n"
        "Should t act?\n"
        "% id: confirm_gate\n"
        "D has outcome require_confirmation if D has subject C and C is a thing.\n"
        "Should t act?\n"
        "Why not?\n"
        "% id: hard_deny\n"
        "D has outcome deny if D has subject C and C is a thing.\n"
        "Should t act?\n"
        ":quit\n"
    )
    dec11 = [o for o in objs11 if o["type"] == "decision"]
    check("outcome precedence sandbox > allow",
          dec11 and dec11[0]["outcome"] == "allow_with_sandbox", dec11)
    check("outcome precedence confirmation > sandbox",
          len(dec11) > 1 and dec11[1]["outcome"] == "require_confirmation"
          and "confirm_gate" in dec11[1]["reasons"], dec11)
    check("outcome precedence deny wins",
          len(dec11) > 2 and dec11[2]["outcome"] == "deny"
          and "hard_deny" in dec11[2]["reasons"], dec11)
    wn11 = [o for o in objs11 if o["type"] == "whynot"]
    check("whynot tags gated outcomes",
          wn11 and any(d.get("outcome") == "require_confirmation" and d["rule"] == "confirm_gate"
                       for d in wn11[0]["denies"]), wn11)

    print()
    print(f"{passed} passed, {len(failed)} failed")
    if failed:
        for f in failed:
            print(f"  FAIL: {f}")
        sys.exit(1)


if __name__ == "__main__":
    main()
