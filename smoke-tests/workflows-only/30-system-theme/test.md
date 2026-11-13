# 30-system-theme

Proves that with the setting `system`, a change of the system's appearance reaches the page while the app stays in front: the core
applies the new system theme, tells the page through `config-changed`, and the page reads it with `getSystemTheme`.

It changes the system's appearance, which on a desktop is the developer's own screen, so it runs only in the workflow and is never
part of an unfiltered local run. On a connected iPhone or iPad it exits with the skipped code, because no host command changes the
device's appearance.

To run it locally, name it:

```
ZIGGY_SMOKE_SCENARIO=30-system-theme bun run test:smoke
```

It changes the desktop's appearance while it runs and puts the value it found back at the end.
