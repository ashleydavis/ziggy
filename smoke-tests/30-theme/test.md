# 30-theme

Proves the theme end to end: `--theme dark` reaches the page's `prefers-color-scheme` before its first script, the theme controls
change the setting and the page follows through `matchMedia`, and the setting is read back from the config file after a restart.

`run.sh` runs it with every other scenario. To run it alone:

```
ZIGGY_SMOKE_SCENARIO=30-theme bun run test:smoke
```
