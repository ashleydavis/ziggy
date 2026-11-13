# ios.sh

The iOS simulator platform library of the smoke tests: it builds the app, installs it, launches it with `--remote-control` and, when
`ZIGGY_THEME` is set, `--theme`, and stops it. When a device is connected, `ios-device.sh` replaces these functions. `common.sh`
sources it. See [run.md](../run.md).
