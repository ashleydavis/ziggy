# 36-window-targeting

The remote control server numbers the apps connected to it as windows and sends each command to the window it names, with window 1 when a command names none, and closing window 1 leaves window 2 working. The scenario starts a second app process itself, so it runs before any new-window work exists.

The runner runs it as `bun run test:smoke 36-window-targeting`, and it is never run directly. It takes no arguments.

See [run.md](../../run.md) for the runner and the other scenarios.
