# android.sh

The Android platform library of the smoke tests: it claims a device, installs and starts the app with the `ziggy.remoteControl`
extra and, when `ZIGGY_THEME` is set, the `ziggy.theme` extra, and stops it. It also changes the device's night mode for the
workflows-only scenarios. `ziggy_platform_opened_urls` prints the lines of the device log that show the system was asked to open
an address. `common.sh` sources it. See [run.md](../run.md).
