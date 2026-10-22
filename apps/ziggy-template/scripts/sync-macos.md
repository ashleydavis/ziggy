# sync-macos

Builds the template's frontend (`bun run bundle:ui`) and puts what the MacOS Xcode project needs into a native directory: `lib/libziggy_template.a` and `include/ziggy.h` (built with Zig for the macOS target, deployment target 11.0). The frontend is embedded in the library, so the app has no frontend files of its own.

Run it on a Mac: `bash apps/ziggy-template/scripts/sync-macos.sh`.

## Arguments

- `--arch <arm64|x86_64>`: the architecture to build. Default: this Mac's.
- `--native-dir <dir>`: where to put the files. Default: `native/macos/zig-out`.
- `--test-hooks`: build the library with the test control connection. Never use it for a release.
- `--optimize <mode>`: the Zig optimize mode. Default: `ReleaseSafe`.
