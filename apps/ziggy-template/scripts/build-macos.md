# build-macos

Runs `sync-macos.sh`, then `xcodebuild` on `native/macos/ZiggyTemplate.xcodeproj`, producing `<build-dir>/Build/Products/<configuration>/ZiggyTemplate.app`. The app is ad hoc signed.

Run it on a Mac with Xcode: `bash apps/ziggy-template/scripts/build-macos.sh`.

## Arguments

- `--arch <arm64|x86_64>`: default: this Mac's.
- `--native-dir <dir>`: passed to the sync script and to Xcode as `ZIGGY_NATIVE_DIR`. Default: `native/macos/zig-out`.
- `--build-dir <dir>`: Xcode's derived data directory. Default: `native/macos/zig-out/xcode`.
- `--configuration <Debug|Release>`: default: `Debug`.
- `--optimize <mode>`: the Zig optimize mode. Default: `ReleaseSafe`.
