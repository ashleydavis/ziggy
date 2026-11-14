# 30-system-theme

Proves that with the setting `system`, a change of the system's appearance reaches the page while the app stays in front: the core
applies the new system theme, tells the page through `config-changed`, and the page reads it with `getSystemTheme`.

It is an extra: `run.sh` runs it only when given `--extras`, and only where the platform library can change the system's appearance,
which a connected iPhone or iPad cannot. It changes the desktop's appearance while it runs and puts the value it found back at the end.

To run it alone:

```
bun run test:smoke -- --extras 30-system-theme
```
