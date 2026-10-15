# sync-windows.sh

Builds the template's UI (`bun run bundle:ui`) and the Windows native app (the `ziggy-template-windows` step of the template's `build.zig`), and installs everything the app needs into one directory, `<prefix>/ziggy-template`: `ziggy-template.exe`, which is the whole app. Run `bun run setup` first. It stops with a message saying what to do when `bun` or `zig` is not on PATH, when on Windows Microsoft's C++ toolchain or the Windows SDK is not installed or when the WebView2 SDK has not been fetched.

Run it as `bun run sync:windows -- [options]`, under Git Bash on Windows: linking the app needs Microsoft's C++ toolchain. On Linux, `bun run compile:zig` checks the Windows native app compiles, without linking it.

Options:

- `--arch <x64>`: the architecture to build for. Default `x64`. `arm64` is refused, see `package-windows.md`.
- `--prefix <dir>`: the install prefix. Default `apps/ziggy-template/shells/windows/zig-out`.
- `--optimize <Debug|ReleaseSafe|ReleaseFast|ReleaseSmall>`: the Zig optimize mode. Default `ReleaseSafe`.
- `--strip`: leaves the debug information out of the executable, which is what a release package wants.
- `--test-hooks`: builds the test control connection in. Never use it for something that ships.
