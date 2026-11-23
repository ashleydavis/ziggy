# Root cause: smoke-tests-android, AppDisconnected in 5-cancel-one-of-several-sources

## The failure

- Run: https://github.com/ashleydavis/ziggy/actions/runs/45080262385 (CI on e0b4c37), job `smoke-tests-android` (https://github.com/ashleydavis/ziggy/actions/runs/45080262385/job/137386996972).
- Failing lines:

```
22:58:23.5752762Z FAILED: get-text event-log failed: {"ok":false,"error":"AppDisconnected"}
22:58:23.5826615Z adb: error: device offline
22:58:23.5959093Z FAILED: 5-cancel-one-of-several-sources (exit 1).
22:58:23.9091237Z adb: device 'emulator-5554' not found
22:58:23.9092168Z FAILED: the app did not start
22:58:23.9234742Z FAILED: 6-edges (exit 1).
```

- The same failure of scenario 5 is in CI runs 44701976439 and 43652111838. It is intermittent.

## Root cause

The Android emulator (37.3.10, API 35 google_apis x86_64 image, on the ubuntu-24.04 runner) sometimes closes its adb connection to the host's adb server partway through forwarding a large adb packet from the device to the host. Every drop seen came during a packet of 65 KB or more. Scenario 5 makes those packets: its `get-text event-log` answers hold the whole event log, which the three running tasks grow to over 100 KB. The answer goes from the app to the remote control server through `adb reverse`, as one large adb `WRTE` packet. When the connection drops, the reverse tunnel goes with it, so the remote control server reports `AppDisconnected`. The device is `offline` or missing for a moment, which fails the next scenario's start (`6-edges`: `the app did not start`).

Neither adbd on the device nor the guest restarts. adbd keeps the pid it booted with and the guest's uptime runs on. The emulator process (`qemu-system-x86`) ends its side of the TCP connection on port 5555 after sending a packet's header and before its payload:

```
23:56:56.520 readx: fd=10 wanted=24 got=24 5752544526000000d50100006c2e0100 WRTE&.......l... [truncated]
23:56:56.520 readx: fd=10 wanted=77420
23:56:56.520 readx: fd=10 disconnected
23:56:56.520 transport.cpp:356 emulator-5554: read failed
23:56:56.520 transport.cpp:1226 emulator-5554: connection terminated: read failed
```

## The proof

Both sides run scenario 5 eight times in each of 20 jobs. Each side builds the app from this branch and runs it on the same emulator, with the adb server traced. The only difference is `small-get-text.patch` on the removed side. It makes the test app's `get-text` answer only the last 30,000 characters of the element's text. The event log grows at its end, so every line the scenario waits for is still in the answer. The app, its tasks, its events and its page are unchanged: only the size of the answer changes, and so the size of the adb packet. The two workflow files differ only in their name and in `SOURCE_PATCH`.

A job fails when the traced adb server logged `emulator-5554: read failed`, meaning the emulator's connection dropped. The criteria were stated before the runs: the present run fails, and the removed run has 0 drops in 20 jobs with every packet under 60,000 bytes.

| Run | Side | Jobs that dropped | Drops | AppDisconnected attempts | Largest packet per job |
|---|---|---|---|---|---|
| https://github.com/ashleydavis/ziggy/actions/runs/45090730827 | present | 4 of 20 (run failed) | 5 | 5 | 116,556 to 169,314 bytes |
| https://github.com/ashleydavis/ziggy/actions/runs/45090730783 | removed | 0 of 20 (run passed) | 0 | 0 | 34,178 to 34,179 bytes |
| https://github.com/ashleydavis/ziggy/actions/runs/45088833524 | present (second proof) | 2 of 20 (run failed) | 5 | 5 | 116,556 to 169,314 bytes |
| https://github.com/ashleydavis/ziggy/actions/runs/45088833563 | removed (second proof, 8,000 characters) | 0 of 20 (run passed) | 0 | 0 | 9,138 to 9,143 bytes |

The second proof's removed side is not a clean control. With only 8,000 characters, the awaited `task-completed hello-long-1 failed Cancelled` line could scroll out of the answer before the next poll, so 9 of its 160 attempts failed for that reason (see its commit). The third proof's 30,000 characters fixed that.

The same scenario runs without the patch in experiments 1b and 3 (https://github.com/ashleydavis/ziggy/actions/runs/45082839384, https://github.com/ashleydavis/ziggy/actions/runs/45085731955) dropped in 4 of 20 jobs each. Across those runs and the two present-side runs, 14 of 80 jobs dropped. A run of 20 with no drop then has a chance of about 2%. In experiment 3's four traced jobs, the emulator forwarded 275 packets of 60,000 bytes or more and 265 of 10,000 to 59,999 bytes. All 7 drops came on the large ones. The payloads in flight were 65,497, 77,420, 82,500, 87,566, 103,914, 109,246 and 127,462 bytes.

With no app at all, the emulator never dropped: 0 of 20 idle jobs in experiment 2 (https://github.com/ashleydavis/ziggy/actions/runs/45084649054).

## Other failures seen, not this one

Both sides also had attempts fail with no adb drop: `{"error":"UiDidNotAnswer"}` (3 present, 2 removed in the third proof), and `event-log never showed "task-completed hello-long-1 failed Cancelled"` where the full log held only the first task events (2 present). These are separate failures of scenario 5 and were not investigated here.

## Files

- `experiment.sh` and `proof.sh`: the scripts the experiment and proof workflows run on the emulator. `small-get-text.patch` is the removed side's one change.
- `../.github/workflows/proof-present.yml` and `proof-removed.yml`: the proof, which can be run again.
- `evidence/ci-failure/`: the full log of the failing CI job.
- `evidence/exp1b/`: the four job logs of run 45082839384 that reproduced the failure. For job 137394637797 it also holds the adb server log (`connection terminated: read failed`), the poller's adb states (`offline` then `device` within 0.2 s), the guest's uptime before and after, and the guest kernel's adbd lines (one adbd pid from boot until the script's own `adb root`).
- `evidence/exp2/`: every idle job's adb state (one `device` line each, 20 of 20) and one idle job's log.
- `evidence/exp3/`: the four job logs with drops, each job's adb states and host TCP connections on port 5555, the adb trace around every drop (`job*-adb-trace-at-drops.txt`, extracted from each job's full traced server log), and the remote control server log naming the app port of the reverse stream that dropped.
- `evidence/proof2-*` and `evidence/proof3-*`: every scenario job's log from the four proof runs, each ending with its largest packet, its count of large packets, its attempts passed and its drops.
