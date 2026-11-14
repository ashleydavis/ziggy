# macos.sh

The macOS platform library of the smoke tests: it builds the app, starts it with `--remote-control` and, when `ZIGGY_THEME` is set, `--theme`, and stops it. It also changes the desktop's appearance with System Events for the workflows-only scenarios, putting the value it found back. Those scenarios run only in the workflow, or when one is named. `common.sh` sources it. See [run.md](../run.md) for the runner and the scenarios.

`ziggy_platform_quit_ends_every_window` succeeds here, where Quit ends every window of the app, and `ziggy_platform_os_process_alive` checks a process id directly.
