# package-ios

Runs `xcodebuild archive` for a device with code signing off (`CODE_SIGNING_ALLOWED=NO`), producing `ziggy-test-app-<version>-ios-arm64.xcarchive`, and packs the unsigned app from it as `ziggy-test-app-<version>-ios-arm64.ipa`, both in `out/ios`. The build files go in `shells/ios/zig-out/package`. The version comes from `apps/ziggy-test-app/package.json`. The artifacts must be signed before they install on a device.

Run it on a Mac: `bash apps/ziggy-test-app/scripts/package-ios.sh`.

## Arguments

- `--output-dir <dir>`: where the packages go. Default: `out/ios`.
