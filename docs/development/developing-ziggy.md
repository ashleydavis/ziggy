# Developing Ziggy

This guide is for [Ziggy developers](../glossary.md), the people working on Ziggy itself. To build an app on Ziggy, see the [quick start](../quick-start.md) and the [user guide](../user-guide.md).

## What is in this repository

- **Ziggy**, the package an app is built on, in `packages/ziggy`: Ziggy's core library with its task queue, the native app for each platform and the TypeScript types of `window.ziggy` for the frontend. See [Packages](packages.md).
- **The Ziggy template**, in `apps/ziggy-template`: the hello world app a new app starts as a copy of. See its [README](../../apps/ziggy-template/README.md).
- **Ziggy's test app**, in `apps/ziggy-test-app`: an app nobody copies, with a feature for each part of Ziggy. Ziggy's smoke tests, in `smoke-tests`, drive it on every platform, its unit tests check those features, and `scripts` holds the runners of Ziggy's mobile and Android native app tests.

Nothing is published to npm or any other registry. An app uses Ziggy either from a checkout of this repository, by a local path, or from a version tag of this repository, by its git URL.

## Setting up

The tools are pinned in `mise.toml`. Install them with `mise trust` and `mise install`, then the dependencies with `bun install`, then the platform toolchains with `bun run setup` (the Android SDK and NDK on Linux and macOS, the WebView2 SDK and WiX Toolset on Windows and a check of Xcode on macOS).

A Ziggy developer needs everything an app developer needs, listed in [Dependencies](../user-guide/dependencies.md), and these as well:

| Dependency | What it is | Why it is needed | Where it comes from |
|---|---|---|---|
| Chrome or Chromium | A web browser | Ziggy's dev mode smoke tests run the frontend in it without a window, and `bun run diagrams` draws the docs' diagrams in it | Install it yourself |
| Mermaid CLI (`@mermaid-js/mermaid-cli`) | The command line tool that draws Mermaid diagrams | `bun run diagrams` draws the docs' diagrams with it | Fetched by `bunx`, at the version `scripts/render-diagrams.sh` pins |

## Using Ziggy from a local path

The template and the test app take Ziggy from this repository by a local path. An app outside the repository does the same to work against a change to Ziggy that is not released yet. The examples below put the app beside a checkout of Ziggy, so Ziggy is `../ziggy` from the app's root. Each path is measured from the file that holds it, so a file in `native/<platform>` reaches Ziggy as `../../../ziggy`. Every part of the app must point at the same Ziggy.

- `build.zig.zon`:

  ```zig
  .dependencies = .{
      .ziggy = .{
          .path = "../ziggy",
      },
  },
  ```

- `package.json`:

  ```json
  "dependencies": {
      "ziggy": "file:../ziggy/packages/ziggy/frontend"
  }
  ```

  Inside this repository the template uses `"ziggy": "workspace:*"`, because `ziggy` is a workspace of the same repository.

- `native/android/settings.gradle`: include Ziggy's Android build in place of the `sourceControl` block. Gradle builds it from the checkout in place of the dependency `app/build.gradle` declares, whatever version that names:

  ```groovy
  includeBuild('../../../ziggy/packages/ziggy/native/android') {
      name = 'ziggy-native-android'
  }
  ```

- The Xcode projects: in place of the package dependency, add `../../../ziggy/packages/ziggy/native/macos` (in `native/macos`) or `../../../ziggy/packages/ziggy/native/ios` (in `native/ios`) to the project as a folder, which Xcode treats as a local package, then add the product `ZiggyNativeMacOS` or `ZiggyNativeIOS` to the app target's Frameworks, Libraries, and Embedded Content.

The app moves to another version of Ziggy by checking that version out in the Ziggy checkout.

## Commands

The commands are in [Commands in Ziggy's repository](commands.md).

## Adding one of Ziggy's own native calls

1. Declare its function pointer in `ziggy.h` and add it to the end of `ziggy_config`, so a native app that fills the struct with zeroes needs no change.
2. Implement it in every native app that supports it, on the native app's UI thread.
3. Call it from the backend and write its unit test with a test implementation of the native call.

An app's own native calls need none of this: they go through `host_request` (see [Native calls](../user-guide/native-calls.md)).

## Guides

- [Packages](packages.md): each directory of the package, its language and why it is built separately.
- [Architecture](architecture.md): how the parts of an app fit together.
- [Dev mode](dev-mode.md): how the dev backend and the supervisor work.
- [Releasing Ziggy](releasing-ziggy.md): what the release workflow does on each push, and how a version of the package is released.
