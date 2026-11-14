# common.sh

The helpers every scenario sources: starting and stopping the test app, talking to the remote control connection, waiting for text, clicking elements and pressing keys. It takes no arguments.

A scenario sources it with `source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"`, or `../../lib/common.sh` from a scenario in `desktop-only` or `native-only`. Each helper has a comment above it giving its usage.

See [the run documentation](../run.md) for how the scenarios are run.
