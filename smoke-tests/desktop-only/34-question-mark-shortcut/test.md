# 34-question-mark-shortcut

Proves that `?` is a shortcut an action can have: `listActions` reports it, it runs the action while no text box has the focus, and a focused text area keeps it and types a question mark.

It takes no arguments. `run.sh` runs it on a desktop platform. To run it alone:

```
ZIGGY_SMOKE_SCENARIO=34-question-mark-shortcut bun run test:smoke
```

See [the run documentation](../../run.md).
