# ios-device.sh

The platform library for a connected iPhone or iPad, which replaces the simulator functions of `ios.sh`. It installs and launches
the app through `ios-device.ts` with `--remote-control` and, when `ZIGGY_THEME` is set, `--theme`. No command changes the device's
appearance, so `ziggy_platform_changes_appearance` returns non-zero and the appearance-only scenarios are not listed. See
[run.md](../run.md).
