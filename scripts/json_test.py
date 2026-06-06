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

    print()
    print(f"{passed} passed, {len(failed)} failed")
    if failed:
        for f in failed:
            print(f"  FAIL: {f}")
        sys.exit(1)


if __name__ == "__main__":
    main()
