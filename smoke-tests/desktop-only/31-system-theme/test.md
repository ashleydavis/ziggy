# 31-system-theme

Proves that with the setting `system`, the page's theme is the operating system's theme: light when the system is light and dark when
it is dark. It reads the system's theme on Linux with `gsettings`, on macOS with `defaults read -g AppleInterfaceStyle` and on Windows
with the `AppsUseLightTheme` registry value.

`run.sh` runs it on a desktop platform. To run it alone:

```
ZIGGY_SMOKE_SCENARIO=31-system-theme bun run test:smoke
```
