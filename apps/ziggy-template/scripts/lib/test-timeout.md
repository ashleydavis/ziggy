# test-timeout.sh

Caps how long a smoke test or a whole suite may run, so a stuck test fails with a clear message instead of hanging the run.

Sourced by a test runner, never run: `source "<app>/scripts/lib/test-timeout.sh"`. It sources [process-control.sh](process-control.md), and is safe to source twice.

- `run_test_with_timeout <seconds> <command...>`: runs one test with job control on and kills its whole process tree when it runs past the limit. Returns the test's exit code, or 124 when it timed out.
- `test_timed_out <exit code>`: succeeds when the code is the timeout code.
- `run_test_function_with_timeout <name> <function>`: the same for a shell function.
- `start_suite_watchdog <name> [seconds]` and `stop_suite_watchdog`: a ceiling on a whole suite.
- `report_test_timeout <name> <seconds> <log> [variable]`: prints what timed out and which variable raises the limit.

The limits come from `ZIGGY_PER_TEST_TIMEOUT` (seconds per test, default 600) and `ZIGGY_SUITE_TIMEOUT` (seconds per suite, default 1500).
