# package-macos

Builds the MacOS app in Release and packs `out/macos/ziggy-test-app-<version>-macos-<arch>.dmg` (with a link to `/Applications`) and `out/macos/ziggy-test-app-<version>-macos-<arch>.zip`. The build files go in `shells/macos/zig-out/package`. The version comes from `apps/ziggy-test-app/package.json`. The app is ad hoc signed, not notarized.

Run it on a Mac: `bash apps/ziggy-test-app/scripts/package-macos.sh`.

## Arguments

- `--arch <arm64|x86_64>`: default: this Mac's.
- `--output-dir <dir>`: where the packages go. Default: `out/macos`.
