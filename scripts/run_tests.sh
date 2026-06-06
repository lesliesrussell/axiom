#!/bin/sh
# axiom-vr8
# Full regression run: build, then every self-checking suite.
#
#   scripts/run_tests.sh [path-to-axiom-binary]
set -e
cd "$(dirname "$0")/.."

BIN="${1:-./zig-out/bin/axiom}"

zig build
python3 scripts/json_test.py "$BIN"
python3 scripts/kyc_test.py "$BIN"
python3 scripts/pty_test.py "$BIN"
python3 scripts/axiom_gate.py --selftest --axiom "$BIN"
python3 scripts/security_conformance_test.py "$BIN"

echo
echo "regression run: all suites green"
