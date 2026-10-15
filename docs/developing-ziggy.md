# Developing Ziggy

This guide is for working on Ziggy itself. To build an app on Ziggy, see the [quick start](quick-start.md) and the [user guide](user-guide.md).

## What is in this repository

- **Ziggy**, the package an app is built on, in `packages/ziggy`: Ziggy's core library with its task queue, the native app for each platform and the TypeScript types of `window.ziggy` for the UI. See [Packages](packages.md).
- **The Ziggy template**, in `apps/ziggy-template`: the hello world app a new app starts as a copy of. See its [README](../apps/ziggy-template/README.md).
- **Ziggy's test app**, in `apps/ziggy-test-app`: an app nobody copies, with a feature for each part of Ziggy. Ziggy's smoke tests, in `smoke-tests`, drive it on every platform, its unit tests check those features, and `scripts` holds the runners of Ziggy's phone and Android native app tests.

Nothing is published to npm or any other registry. An app uses Ziggy either from a checkout of this repository, by a local path, or from a version tag of this repository, by its git URL.

## Setting up

The tools are pinned in `mise.toml`. Install them with `mise trust` and `mise install`, then the dependencies with `bun install`, then the platform toolchains with `bun run setup` (the Android SDK and NDK on Linux and macOS, the WebView2 SDK and WiX Toolset on Windows and a check of Xcode on macOS).

## Commands

The commands are in [Commands](commands.md#commands-in-ziggys-repository).

## Guides

- [Packages](packages.md): each folder of the package, its language and why it is built separately.
- [Architecture](architecture.md): how the parts fit, the message protocol, tasks, channels, native calls, menus and test hooks.
- [Releasing Ziggy](releasing-ziggy.md): what the release workflow does on each push, and how a version of the package is released.
