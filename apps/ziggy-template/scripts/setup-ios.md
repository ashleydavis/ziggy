# setup-ios

Checks that Xcode 14.2 or newer, `xcrun simctl`, `jq` and `rsync` are present. It installs nothing, and CocoaPods are not used.

It is run on a Mac by `bun run --filter=ziggy-template setup` from the repository root, through `setup.sh`. It takes no arguments.

## See also

- [setup.sh](setup.md): the setup that runs this script.
