# experiment.sh

The script of experiments 1 to 3 (see the branch's commits and `README.md`), run as the emulator runner's script. It takes no arguments.

- `EVIDENCE_DIR`: where the adb state log, the host's TCP connections on port 5555, the adb server's log, the device's logcat and dmesg and the scenario directories are saved.
- `IDLE_SECONDS`: when set, it runs no scenario and waits this long with only the adb state poller running (experiment 2). Otherwise it runs scenario 5 eight times.

The adb server is restarted under `ADB_TRACE=all` (experiments 2 and 3).
