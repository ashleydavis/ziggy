# build-ios

Runs `sync-ios.sh`, then `xcodebuild` on `native/ios/ZiggyTemplate.xcodeproj`, with code signing off for the simulator and automatic signing by the Xcode account's team (or `ZIGGY_IOS_TEAM`) for a device, producing `<build-dir>/Build/Products/<configuration>-iphonesimulator/ZiggyTemplate.app` (or `-iphoneos`).

Run it on a Mac with Xcode: `bash apps/ziggy-template/scripts/build-ios.sh`.

## Arguments

- `--sdk <simulator|device>`: default: `simulator`.
- `--arch <arm64|x86_64>`: default: this Mac's.
- `--native-dir <dir>`: default: `native/ios/zig-out`.
- `--build-dir <dir>`: default: `native/ios/zig-out/xcode`.
- `--configuration <Debug|Release>`: default: `Debug`.
- `--optimize <mode>`: default: `ReleaseSafe`.
