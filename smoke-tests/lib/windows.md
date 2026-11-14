# windows.sh

The Windows platform library of the smoke tests: it builds the app, starts it with `--remote-control` and, when `ZIGGY_THEME` is set, `--theme`, and stops it and every window it opened. Windows has no process groups, so it ends each window by the process id the app's log records, in the `Started a new window, process <pid>.` line and in the window's own log file name. It also changes the desktop's appearance in the registry for the workflows-only scenarios, putting the value it found back. Those scenarios run only in the workflow, or when one is named. `common.sh` sources it. See [run.md](../run.md) for the runner and the scenarios.

`ziggy_platform_wait_app_log` waits for a line in the app's log, which holds the app's standard error. A Quit here closes only its own window, so `ziggy_platform_quit_ends_every_window` fails, and `ziggy_platform_os_process_alive` asks `tasklist` for a process id.
