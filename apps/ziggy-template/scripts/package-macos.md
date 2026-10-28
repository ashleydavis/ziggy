# package-macos

Builds the MacOS app in Release and packs `out/macos/ziggy-template-<version>-macos-<arch>.dmg` (with a link to `/Applications`) and `out/macos/ziggy-template-<version>-macos-<arch>.zip`. The build files go in `native/macos/zig-out/package`. The version comes from `apps/ziggy-template/package.json`. The app is ad hoc signed, not notarized.

Run it on a Mac: `bash apps/ziggy-template/scripts/package-macos.sh`.

## Arguments

- `--arch <arm64|x86_64>`: default: this Mac's.
- `--output-dir <dir>`: where the packages go. Default: `out/macos`. When it is given, the app is also built under `<dir>/build`, so two runs given different directories share nothing.
