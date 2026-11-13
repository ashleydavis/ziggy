# 32-text-box-keys

Proves that a typing shortcut, one with no Ctrl, Alt or Cmd, runs its action while no text box has the focus, and that a focused text box keeps the key. The Escape, Enter and Down actions run outside the text area; inside it, Escape and Down run no action and Enter types a newline. `listActions` reports the Down action's shortcut.

It takes no arguments. `run.sh` runs it on a desktop platform. To run it alone:

```
ZIGGY_SMOKE_SCENARIO=32-text-box-keys bun run test:smoke
```

See [the run documentation](../../run.md).
