# test-timeout.sh

Caps how long a smoke test may run, so a stuck test fails with a clear message instead of hanging the run.

Sourced by a test runner, never run: `source "<repo>/smoke-tests/lib/test-timeout.sh"`. It sources `process-control.sh`, and is safe to source twice.

- `run_test_with_timeout <seconds> <command...>`: runs one test with job control on and kills its whole process tree when it runs past the limit. Returns the test's exit code, or 124 when it timed out.
- `test_timed_out <exit code>`: succeeds when the code is the timeout code.
- `run_test_function_with_timeout <name> <function>`: the same for a shell function.
- `report_test_timeout <name> <seconds> <log> [variable]`: prints what timed out and which variable raises the limit.

The limit comes from `ZIGGY_PER_TEST_TIMEOUT` (seconds per test, default 600).

## See also

- [process-control.sh](process-control.md): starting and stopping the processes a test runs.
