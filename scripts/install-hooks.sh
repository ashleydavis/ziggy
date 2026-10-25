#!/usr/bin/env bash

# Installs the checked-in pre-commit hook (.githooks/pre-commit) into this clone, as a link in the hooks directory git runs hooks
# from. Changes no git configuration. See install-hooks.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$REPO_DIR/.githooks/pre-commit"

if [ ! -x "$HOOK" ]; then
    echo "ERROR: $HOOK is missing or not executable." >&2
    exit 1
fi

# The common directory is the main clone's .git, which every worktree shares, so one install covers them all.
hooks_dir="$(cd "$REPO_DIR" && cd "$(git rev-parse --git-common-dir)" && pwd)/hooks"
link="$hooks_dir/pre-commit"

if [ -L "$link" ] && [ "$(readlink "$link")" = "$HOOK" ]; then
    echo "The pre-commit hook is already installed: $link links to $HOOK."
    exit 0
fi

if [ -e "$link" ] || [ -L "$link" ]; then
    echo "Replacing the existing $link."
fi

mkdir -p "$hooks_dir"
ln -sfn "$HOOK" "$link"
echo "Installed the pre-commit hook: $link links to $HOOK."
