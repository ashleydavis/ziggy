# open-macos

Runs `sync-macos.sh`, then opens `native/macos/ZiggyTemplate.xcodeproj` in Xcode, so a build from Xcode finds the library and the UI.

Run it on a Mac: `bash apps/ziggy-template/scripts/open-macos.sh`.

## Arguments

Every argument goes to `sync-macos.sh` (`--arch`, `--native-dir`, `--test-hooks`, `--optimize`). When you change `--native-dir`, set the `ZIGGY_NATIVE_DIR` build setting in Xcode to the same directory.
