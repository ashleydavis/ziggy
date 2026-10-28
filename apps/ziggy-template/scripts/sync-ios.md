# sync-ios

Builds the template's frontend (`bun run bundle:ui`) and puts what the iOS Xcode project needs into a native directory: `lib/libziggy_template.a` and `include/ziggy.h` (built with Zig for iOS 14.0, the simulator or the device). The frontend is embedded in the library, so the app has no frontend files of its own.

Run it on a Mac: `bash apps/ziggy-template/scripts/sync-ios.sh`.

## Arguments

- `--sdk <simulator|device>`: default: `simulator`. A device build is arm64 only.
- `--arch <arm64|x86_64>`: default: this Mac's (the simulator runs the Mac's architecture).
- `--native-dir <dir>`: default: `native/ios/zig-out`. The library there is for one SDK and architecture, so sync again after changing either.
- `--optimize <mode>`: default: `ReleaseSafe`.
