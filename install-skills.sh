#!/bin/sh
# axiom-o2b
# Install the Axiom agent skill into whichever coding agents are present.
# Idempotent; pass --dry-run to see actions without writing.
#
#   ./install-skills.sh [--dry-run]
set -e

DRY=0
[ "$1" = "--dry-run" ] && DRY=1

HERE=$(cd "$(dirname "$0")" && pwd)
SRC="$HERE/skills/axiom"

if [ ! -f "$SRC/SKILL.md" ]; then
    echo "error: $SRC/SKILL.md not found (run from the axiom repo)" >&2
    exit 1
fi

install_to() {
    # $1 = agent name, $2 = detect dir, $3 = target dir
    if [ ! -d "$2" ]; then
        echo "skipped  $1 (not detected: $2)"
        return
    fi
    if [ "$DRY" = "1" ]; then
        echo "would install  $1 -> $3/"
        return
    fi
    mkdir -p "$3"
    cp "$SRC/SKILL.md" "$3/SKILL.md"
    echo "installed  $1 -> $3/SKILL.md"
}

# Claude Code: native skill format, verified.
install_to "claude-code" "$HOME/.claude" "$HOME/.claude/skills/axiom"

# Other agents: same markdown dropped into their conventional config
# trees as reference instructions (formats vary; the content is plain
# markdown and degrades gracefully).
install_to "codex" "$HOME/.codex" "$HOME/.codex/skills/axiom"
install_to "pi.dev" "$HOME/.pi" "$HOME/.pi/skills/axiom"
install_to "hermes" "$HOME/.hermes" "$HOME/.hermes/skills/axiom"

if [ "$DRY" = "1" ]; then
    echo "(dry run — nothing written)"
fi
