# proof.sh

Runs Android smoke scenario 5 eight times on the emulator the workflow started, with the host's adb server restarted under `ADB_TRACE=all`. Run by `.github/workflows/proof-present.yml` and `proof-removed.yml` as the emulator runner's script. It takes no arguments.

- `EVIDENCE_DIR`: where the adb server's log is saved.
- `ZIGGY_SMOKE_BUILD`, `ZIGGY_ANDROID_DEVICES`: as for `smoke-tests/run.sh`.

It prints the attempts passed, the largest adb packet the emulator forwarded, the payload in flight at each drop and the number of drops. It fails when the emulator's adb connection dropped at least once. See `README.md`.
