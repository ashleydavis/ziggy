# linux.sh

The Linux platform library of the smoke tests: it builds the app, starts it on a virtual display with `--remote-control` and, when
`ZIGGY_THEME` is set, `--theme`, and stops it. It also changes the desktop's colour scheme with `gsettings` for the appearance-only
scenarios, putting the value it found back. `common.sh` sources it. See [run.md](../run.md) for the runner and the scenarios.
