# build-linux.sh

Runs `sync-linux.sh`, which produces the template's Linux executable, with its frontend embedded, in `native/linux/zig-out/bin`. Runs on Linux. Passes its arguments on, so `--test-hooks` builds the test hooks in.
