# 30-system-theme

Proves that with the setting `system`, a change of the device's appearance reaches the page while the app stays in front: the core
applies the new system theme, tells the page through `config-changed`, and the page reads it with `getSystemTheme`. It runs on Linux,
Windows, macOS, Android and the iOS simulator, and is not listed on a connected iPhone or iPad, where no command changes the appearance.

`run.sh` runs it with every other scenario on those platforms. To run it alone:

```
ZIGGY_SMOKE_SCENARIO=30-system-theme bun run test:smoke
```
