# clean-ios

Runs `xcodebuild clean` for the Debug and Release configurations and removes the synced `lib/libziggy_template.a` and `include/ziggy.h`, and the files of the packages in `out/ios`, one at a time.

Run it on a Mac: `bash apps/ziggy-template/scripts/clean-ios.sh`.

## Arguments

- `--native-dir <dir>`: default: `native/ios/zig-out`.
- `--build-dir <dir>`: default: `native/ios/zig-out/xcode`.
