# 34-new-window

New Window starts a window as a process of its own, with the arguments its action gives and a backend of its own; closing a window ends only its own process; on Linux and macOS Quit in any window ends every window's process, including windows whose opener has closed; on Windows Quit ends only its own window's process. `bun run test:smoke` runs it on Linux, Windows and macOS, and it takes no arguments.

See [run.md](../../run.md) for the runner and the other scenarios.
