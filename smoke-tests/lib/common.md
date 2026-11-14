# common.sh

The helpers every smoke scenario sources. It defines functions only, and it sources the platform library the runner chose. The interface the platform libraries implement is the comment at the top of the file. It also documents `ZIGGY_THEME`, which starts the app with `--theme` (the `ziggy.theme` extra on Android).

A scenario starts with `source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"`, then calls `start_test_app` and the helpers it needs. `wait_for_opened_url` waits until the system was asked to open an address that holds the text, and the window helpers wait for a window's process or its log and find the process ids a window's log records. See [run.md](../run.md) for the runner and the scenarios.
