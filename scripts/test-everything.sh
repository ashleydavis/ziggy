#!/usr/bin/env bash

# Runs the checks whose files changed since each last passed, as what-changed reports them, and records each check as it passes.
# The pre-commit hook runs this. See test-everything.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_DIR"

if ! command -v what-changed > /dev/null 2>&1; then
    echo "ERROR: what-changed is not installed. Run mise install from $REPO_DIR to install the version mise.toml locks." >&2
    exit 1
fi

FORCE=false
for argument in "$@"; do
    case "$argument" in
        --force)
            FORCE=true
            ;;
        *)
            echo "ERROR: unknown option \"$argument\". Usage: test-everything.sh [--force]" >&2
            exit 2
            ;;
    esac
done

# The one place a target name in what-changed.yaml turns into a command.
run_target() {
    case "$1" in
        compile)
            bun run compile
            ;;
        test)
            bun run test
            ;;
        compile-zig)
            bun run compile:zig
            ;;
        test-zig)
            bun run test:zig
            ;;
        smoke)
            bun run test:smoke
            ;;
        *)
            echo "ERROR: target \"$1\" is in what-changed.yaml but scripts/test-everything.sh has no command for it. Add one to run_target." >&2
            exit 1
            ;;
    esac
}

# "targets list" is every target that can run on this machine, "targets" only those with changes.
if [ "$FORCE" = true ]; then
    target_report="$(what-changed targets list)"
else
    target_report="$(what-changed targets)"
fi

targets=()
while IFS= read -r line; do
    if [ -n "$line" ]; then
        targets+=("$line")
    fi
done <<< "$target_report"

if [ ${#targets[@]} -eq 0 ]; then
    echo "Nothing to run: no target's files changed since it last passed."
    exit 0
fi

echo "Targets to run: ${targets[*]}"

# Each target is recorded as soon as it passes, and only that target. set -e stops the script at a failing target before its
# record, so a target is never marked as passed by a run that did not pass it.
for target in "${targets[@]}"; do
    echo ""
    echo "=== $target ==="
    run_target "$target"
    what-changed baseline capture "$target"
done

echo ""
echo "All targets passed: ${targets[*]}"
