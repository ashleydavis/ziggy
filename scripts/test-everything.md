# test-everything.sh

Runs the checks whose files changed since each one last passed, and records each check as it passes. The pre-commit hook (`.githooks/pre-commit`) runs it before every commit.

Run it from the root of the repository as `bun run test:everything`.

- `--force`: runs every check, whether or not its files changed.

It asks [what-changed](https://github.com/ashleydavis/what-changed) which checks to run. `what-changed.yaml` names each check and the paths it watches. The checks are the ones the CI workflow runs on the desktop:

| Target | Command |
|---|---|
| `compile` | `bun run compile` |
| `test` | `bun run test` |
| `compile-zig` | `bun run compile:zig` |
| `test-zig` | `bun run test:zig` |
| `smoke` | `bun run test:smoke` |
| `smoke-dev` | `bun run test:smoke:dev` |

It runs them in the order `what-changed.yaml` lists them and stops at the first that fails. After each one passes it runs `what-changed baseline capture <target>`, so a check is recorded as passed only by a run that passed it. The records are in `.what-changed/`, which git ignores.

It stops when what-changed is not installed. `mise install` installs the version `mise.toml` locks.

A target added to `what-changed.yaml` needs its command added to `run_target` in this script.
