# setup.sh

Runs the setup scripts that apply to this machine: iOS and Android on a Mac, Windows under Git Bash and Android on Linux. Linux needs nothing more than `mise install`. The Windows script fetches the pinned WebView2 SDK and WiX Toolset, and installs Microsoft's C++ toolchain and the Windows SDK when they are missing. No arguments. The root `bun run setup` reaches it through this package's `setup` script.

## See also

- [setup-windows.sh](setup-windows.md): what the Windows setup installs and why.
