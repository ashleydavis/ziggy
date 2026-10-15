# Integrating Ziggy

Terms are defined in the [glossary](glossary.md).

An app uses Ziggy in each kind of project it has: its Zig build (`build.zig.zon` and `build.zig`), its Xcode projects (MacOS and iOS), its Android Gradle project (`settings.gradle` and `app/build.gradle`) and its UI (`package.json`). Each can take Ziggy in one of two ways:

- **From a local path**: a checkout of this repository on the same machine. This is how the Ziggy template uses it (the path is the root of this repository), and how an app works against a change to Ziggy that is not released yet.
- **From a version tag**: the git URL of this repository and a version tag. This is how an app in another repository pins a released version. Nothing is published to a registry: every part is fetched from the repository at the tag.

The examples below put the app beside a checkout of Ziggy, so Ziggy is `../ziggy` from the app's root. Each path is measured from the file that holds it, so a file in `shells/<platform>` reaches Ziggy as `../../../ziggy`. They write `<tag>` for the version tag. Every part of one app must point at the same version of Ziggy. The latest release is the highest version tag, and the tag is the last part of the line this prints (`refs/tags/<tag>`):

```bash
git ls-remote --tags --refs --sort=-version:refname https://github.com/ashleydavis/ziggy 'v*' | head -n 1
```

## The Zig build

### build.zig.zon

From a local path:

```zig
.dependencies = .{
    .ziggy = .{
        .path = "../ziggy",
    },
},
```

From a version tag, the repository's git URL at the tag and its hash. `zig fetch --save=ziggy "git+https://github.com/ashleydavis/ziggy.git#<tag>"` writes both:

```zig
.dependencies = .{
    .ziggy = .{
        .url = "git+https://github.com/ashleydavis/ziggy.git#<tag>",
        .hash = "<the hash zig fetch printed>",
    },
},
```

The dependency must be named `ziggy`, because Ziggy's build functions look it up by that name.

### build.zig

An app's `build.zig` imports Ziggy's `build.zig` as `@import("ziggy")` and calls its `pub` functions. This is what every app needs, and the template's `build.zig` adds the unit tests of its backend:

```zig
const std = @import("std");
const ziggy_build = @import("ziggy");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const test_hooks = b.option(bool, "test-hooks", "Build the test hooks into the app (never for a release)") orelse false;
    const compile_only = b.option(bool, "compile-only", "Compile the Windows native app without linking the WebView2 loader") orelse false;
    const strip = b.option(bool, "strip", "Leave the debug information out of the desktop executables (for a release)") orelse false;
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimize mode (default: ReleaseSafe)") orelse .ReleaseSafe;

    // Ziggy built for this target, with the test hooks or without.
    const ziggy = ziggy_build.dependency(b, target, optimize, test_hooks);

    // The app's backend as a library (`my-app-backend` step): static for the desktop and Apple native apps, and shared for Android. It also
    // adds the dev host for dev mode (`my-app-dev-host` and `my-app-dev` steps).
    const core = try ziggy_build.addAppBackend(b, ziggy, .{
        .name = "my-app",
        .title = "My App",
        .backend_source_file = "backend/src/index.zig",
        .ui_directory = "dist",
        .imports = &.{},
    }, target, optimize);

    // The Linux and Windows native apps (`my-app-linux`, `my-app-windows` and `my-app-windows-check` steps).
    const app: ziggy_build.IShellApp = .{
        .name = "my-app",
        .title = "My App",
        .directory = ".",
        .linux_icon = null,
        .windows_resource = null,
    };
    try ziggy_build.addLinuxShell(b, app, strip, target, optimize, ziggy, core.static_library);
    try ziggy_build.addWindowsShell(b, app, compile_only, strip, target, optimize, ziggy, core.static_library);
}
```

What Ziggy's `build.zig` gives an app:

- `dependency(b, target, optimize, test_hooks)`: Ziggy for the target, as `IZiggy`: the dependency itself, `module` (the backend, which the app's code imports as `@import("ziggy-core")`). Ask twice for a build that needs both, such as an app built without the test hooks and its unit tests, which run with them.
- `addAppBackend(b, ziggy, app, target, optimize)`: builds the app's backend as a library, installed by the `<name>-backend` step with the app's built UI embedded in it as the `ui-files` import. For an Android target that is the shared library the Android native app loads, and for every other target a static library with `ziggy.h` beside it. It returns both libraries, so an app can link more into them (a system library, for one).
- `addLinuxShell` and `addWindowsShell`: the app's Linux executable (`<name>-linux`, installed to `bin/<name>`) and Windows executable (`<name>-windows`), each linking the app's backend with its UI embedded, without debug information when `strip` is true (a release package), and a step that compiles the Windows native app without linking it (`<name>-windows-check`), for a machine without Microsoft's toolchain.
- Dev mode comes with `addAppBackend`: `<name>-dev-host` builds the dev host, and `<name>-dev` runs the supervisor, which starts the app's dev server and the dev host in front of it and rebuilds the dev host as the Zig files change (see [Dev mode](#dev-mode-packagejson)).
- `embedUi`: the module that embeds a built UI, for a build that makes its own modules (an app's unit tests, for one).
- `addDirectoryTests`: compiles every `*.test.zig` under a directory's `src/test` into one test program and runs it, which is how the template runs its backend's tests.

The app's own options (`test-hooks`, `optimize`, `compile-only`) are passed on to Ziggy, so `zig build my-app-backend -Dtarget=aarch64-linux-android -Dtest-hooks=true` builds the backend and Ziggy for that target with the test hooks.

### backend/src/index.zig

`backend/src/index.zig` is the file the build of the backend starts from (the `backend_source_file` given to `addAppBackend`), and it pulls in the rest of the backend. It turns the app's handlers into the library the native app loads, and an app keeps it as it is:

```zig
const builtin = @import("builtin");
const ziggy = @import("ziggy-core");
const handlers = @import("handlers.zig");

pub const debug = if (builtin.os.tag == .ios) struct {
    pub const SelfInfo = void;
} else struct {};

comptime {
    ziggy.ziggy_api.exportApi(handlers.app);
    if (builtin.abi.isAndroid()) {
        ziggy.jni.exportJni(handlers.app);
    }
}
```

- `ziggy.ziggy_api.exportApi(handlers.app)` exports Ziggy's C interface (`ziggy_create`, `ziggy_post_message` and the rest), serving the app's handlers. The Linux, Windows, macOS and iOS native apps call the backend through it, and without it they do not link.
- `ziggy.jni.exportJni(handlers.app)` exports, for an Android target, the JNI entry points Ziggy's Android native app calls the backend through.
- `debug` switches off Zig's stack trace symbols on iOS, because Zig's symbolizer calls a function the iOS SDK does not export, and the backend would not link without it. A stack trace on iOS prints addresses only.

## The Xcode projects (MacOS and iOS)

From a local path: the project holds a folder reference to Ziggy's Swift package for that platform and links its product. Add `../../../ziggy/packages/ziggy/native/macos` (the MacOS project, in `shells/macos`) or `../../../ziggy/packages/ziggy/native/ios` (the iOS project, in `shells/ios`) to the project as a folder, which Xcode treats as a local package, then add the product `ZiggyNativeMacOS` or `ZiggyNativeIOS` to the app target's Frameworks, Libraries, and Embedded Content. The template's projects (`apps/ziggy-template/shells/macos` and `apps/ziggy-template/shells/ios`) do this with a relative path, which a copied project only has to adjust.

From a version tag: File > Add Package Dependencies, the repository's URL (`https://github.com/ashleydavis/ziggy`), the rule Exact Version with the version of the tag without its `v` (Swift Package Manager reads the tag `v1.2.3` as the version `1.2.3`) and the product `ZiggyNativeMacOS` or `ZiggyNativeIOS`. The package Xcode fetches is the `Package.swift` at the root of this repository, which holds both native apps.

Either way the app's project also links the app's backend library (`lib<name>.a`, built by the `<name>-backend` step) and finds `ziggy.h` beside it, as the template's sync scripts and projects do.

## The Android Gradle project

Ziggy's Android native app is a Gradle build of its own that produces the module `dev.ziggy:ziggy-native-android`. The app's `app/build.gradle` depends on it the same way in both cases:

```groovy
dependencies {
    implementation 'dev.ziggy:ziggy-native-android:<tag>'
}
```

From a local path, the app's `settings.gradle` includes Ziggy's Android build, and Gradle builds it from the checkout in place of the dependency, whatever version the dependency names:

```groovy
includeBuild('../../../ziggy/packages/ziggy/native/android') {
    name = 'ziggy-native-android'
}
```

From a version tag, the app's `settings.gradle` declares the repository as a source dependency, and Gradle checks it out at the tag the dependency's version names and builds Ziggy's Android native app from it:

```groovy
sourceControl {
    gitRepository(uri('https://github.com/ashleydavis/ziggy.git')) {
        producesModule('dev.ziggy:ziggy-native-android')
        rootDir = 'packages/ziggy/native/android'
    }
}
```

The app must use the same version of the Android Gradle plugin as Ziggy's Android native app (see `packages/ziggy/native/android/build.gradle`), because Gradle does not allow two versions of it in one build. Ziggy's Android native app sets its own `compileSdkVersion` and `minSdkVersion`, and the app's `minSdkVersion` must be at least Ziggy's. Nothing is published to a Maven repository, and none of Ziggy's native app source is copied into the app.

## The UI (package.json)

The UI imports Ziggy's types from `ziggy-ui`.

From a local path:

```json
"dependencies": {
    "ziggy-ui": "file:../ziggy/packages/ziggy/ui"
}
```

From a version tag, the repository itself, whose root `package.json` points at `packages/ziggy/ui`:

```json
"dependencies": {
    "ziggy-ui": "git+https://github.com/ashleydavis/ziggy.git#<tag>"
}
```

Inside this repository the template uses `"ziggy-ui": "workspace:*"`, because `ziggy-ui` is a workspace of the same repository.

### Dev mode (package.json)

Ziggy works with whatever bundler the app uses, and the bundler's config has nothing of Ziggy's in it. Dev mode needs two scripts in the app's `package.json`:

```json
"dev": "zig build my-app-dev",
"dev:ui": "vite"
```

`dev:ui` runs the bundler's dev server (`rsbuild dev` for Rsbuild), and the supervisor gives it `--port <port> --host 127.0.0.1`.

## Moving to a newer version

The `/ziggy:upgrade` Claude Code command follows these steps for an app.

1. Read the release notes of the new version and the changes to the guides, for anything an app has to change.
2. In `build.zig.zon`, run `zig fetch --save=ziggy "git+https://github.com/ashleydavis/ziggy.git#<tag>"` with the new tag, which replaces the URL and the hash.
3. In each Xcode project, change the package's exact version.
4. In `app/build.gradle`, change the version of `dev.ziggy:ziggy-native-android` to the new tag.
5. In `package.json`, change the tag after `#`, and run `bun install`.
6. Build the app and run its unit tests and smoke tests on every platform.

An app on a local path moves by checking out the new version in its Ziggy checkout.

## See also

- [The template's build.zig](../apps/ziggy-template/build.zig): a complete app build, with the unit tests of its backend.
- [The dev host's README](../packages/ziggy/dev/README.md): what dev mode can and cannot do.
- [Claude Code commands](claude-code-commands.md): `/ziggy:upgrade` and the other slash commands.
