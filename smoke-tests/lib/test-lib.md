# test-lib.sh

Gives each smoke test a directory of its own, so tests never share a scratch directory with each other or with another run on the same machine.

Sourced by a test runner, never run: `source "<repo>/smoke-tests/lib/test-lib.sh"`. It defines one function and deletes nothing.

- `ziggy_test_temp_dir <label>`: creates a new, uniquely named directory under `$TMPDIR/ziggy-tests` (`/tmp/ziggy-tests` when `TMPDIR` is not set) and prints its absolute path. The label goes into the name, with anything other than letters, digits, dots, dashes and underscores replaced by a dash, so a directory left behind can be traced back to the test that made it.

On Windows (Git Bash) the root is held in its native form, so a native program and the script see the same string for the same directory.
