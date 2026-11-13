# 33-browser-keys

Proves that Ctrl+= and Ctrl+Plus zoom in on the app rather than on the page, Ctrl+Minus zooms out and Ctrl+0 resets, and that a key the app does not define, F5, does nothing. It also checks that `listActions` reports the zoom actions.

It takes no arguments. `run.sh` runs it on a desktop platform. To run it alone:

```
ZIGGY_SMOKE_SCENARIO=33-browser-keys bun run test:smoke
```

See [the run documentation](../../run.md).
