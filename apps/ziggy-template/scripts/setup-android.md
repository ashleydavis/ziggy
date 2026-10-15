# setup-android.sh

One-time setup for building the template for Android. It runs the repository's `install-android-sdk.sh --install` (which installs the SDK packages and the pinned NDK) and then checks the JDK 17, SDK and NDK are where the build looks for them. It installs nothing of its own.

It is run on Linux and MacOS by `bun run --filter=ziggy-template setup` from the repository root, through `setup.sh`. No arguments.

Needs `zig`, `bun`, `jq`, `unzip` and `curl` on the PATH.

## See also

- [install-android-sdk.sh](install-android-sdk.md): what the install puts where.
- [setup.sh](setup.md): the setup that runs this script.
