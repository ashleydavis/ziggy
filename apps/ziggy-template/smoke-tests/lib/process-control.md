# process-control.sh

Starts, records and stops the processes a test suite runs, by their process IDs and their descendants, never by matching a command line, so a suite never touches another run's processes.

Sourced, never run: `source "<repo>/smoke-tests/lib/process-control.sh"`. It defines functions only.

- `launch_in_process_group <command...>`: starts a command in a process group of its own, in the background, and records the group in the file `ZIGGY_LAUNCHED_GROUPS` names, when that is set.
- `kill_process_tree <pid>` and `kill_process_group <pgid>`: stop a process and everything it started.
- `wait_for_process_group_exit <pgid> <seconds>`, `process_group_of <pid>`, `process_group_alive <pgid>`, `process_children <pid>`, `process_tree_pids <pid>`: what the stopping is built from.
- `list_leaked_launches`: prints every recorded launch that is still running, which a runner reports as a failure at the end of a run.
- `process_control_verify_job_control`: checks the shell can start process groups.
