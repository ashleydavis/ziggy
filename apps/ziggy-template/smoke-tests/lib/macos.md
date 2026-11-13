# macos.sh

The macOS platform library of the smoke tests: it builds the app, starts it with `--remote-control` and, when `ZIGGY_THEME` is set,
`--theme`, and stops it. `common.sh` sources it. See [run.md](../run.md) for the runner and the scenarios.
