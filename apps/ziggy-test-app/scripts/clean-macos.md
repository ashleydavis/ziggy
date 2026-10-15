# clean-macos

Runs `xcodebuild clean` for the Debug and Release configurations and removes the synced `lib/libziggy_test_app.a` and `include/ziggy.h`, and the files of the packages in `out/macos`, one at a time.

Run it on a Mac: `bash apps/ziggy-test-app/scripts/clean-macos.sh`.

## Arguments

- `--native-dir <dir>`: default: `native/macos/zig-out`.
- `--build-dir <dir>`: Xcode's derived data directory. Default: `native/macos/zig-out/xcode`.
