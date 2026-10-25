# install-hooks.sh

Installs the pre-commit hook, `.githooks/pre-commit`, into this clone. Git runs hooks only from the clone's own hooks directory, which is not checked in, so every clone runs this once.

Run it from the root of the repository as `bun run install-hooks`. No arguments.

It links `<git common dir>/hooks/pre-commit` to `.githooks/pre-commit`. It changes no git configuration. The common directory is shared by every worktree of the clone, so one install covers them all. It replaces any other `pre-commit` hook already there, and says so. Run again, it reports the hook is already installed.

The hook runs `scripts/test-everything.sh` (see [test-everything.md](test-everything.md)) and refuses the commit when a check fails.
