# Integrating Ziggy

An app uses Ziggy in each kind of project it has: its Zig build (`build.zig.zon` and `build.zig`), its Xcode projects (MacOS and iOS), its Android Gradle project (`settings.gradle` and `app/build.gradle`) and its UI (`package.json`). Each can take Ziggy in one of two ways:

- **From a local path**: a checkout of this repository on the same machine. This is how the Ziggy example uses it (the path is the root of this repository), and how an app works against a change to Ziggy that is not released yet.
- **From a version tag**: the git URL of this repository and a version tag, such as `v0.1.0`. This is how an app in another repository pins a released version. Nothing is published to a registry: every part is fetched from the repository at the tag.

The examples below put the app beside a checkout of Ziggy (`../ziggy` from the app's root), and use `https://github.com/<owner>/ziggy` for the repository's URL and `v0.1.0` for the tag. Use the real path, URL and tag. Every part of one app must point at the same version of Ziggy.

The lines for a version tag cannot be tried until the repository is published, and have not been tried yet. The lines for a local path are the ones the Ziggy example and the test app built from it use.

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

From a version tag, the archive GitHub makes of the tag and its hash. `zig fetch --save=ziggy https://github.com/<owner>/ziggy/archive/refs/tags/v0.1.0.tar.gz` writes both:

```zig
.dependencies = .{
    .ziggy = .{
        .url = "https://github.com/<owner>/ziggy/archive/refs/tags/v0.1.0.tar.gz",
        .hash = "<the hash zig fetch printed>",
    },
},
```

The dependency must be named `ziggy`, because Ziggy's build functions look it up by that name.

### build.zig

An app's `build.zig` imports Ziggy's `build.zig` as `@import("ziggy")` and calls its `pub` functions. The example's [build.zig](../apps/ziggy-example/build.zig) is the whole of it:

```zig
const std = @import("std");
const ziggy_build = @import("ziggy");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const test_hooks = b.option(bool, "test-hooks", "Build the test hooks into the app (never for a release)") orelse false;
    const compile_only = b.option(bool, "compile-only", "Compile the Windows shell without linking the WebView2 loader") orelse false;
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimize mode (default: ReleaseSafe)") orelse .ReleaseSafe;

    // Ziggy built for this target, with the test hooks or without.
    const ziggy = ziggy_build.dependency(b, target, optimize, test_hooks);

    // The app's core as a library (`my-app-core` step): static for the desktop and Apple shells, and shared for Android.
    const core = try ziggy_build.addAppCore(b, ziggy, .{
        .name = "my-app",
        .title = "My App",
        .root_source_file = "core/src/index.zig",
        .ui_directory = "dist",
        .imports = &.{},
    }, target, optimize);

    // The Linux and Windows shells (`my-app-linux`, `my-app-windows` and `my-app-windows-check` steps).
    const app: ziggy_build.IShellApp = .{
        .name = "my-app",
        .title = "My App",
        .directory = ".",
        .ui_directory = "dist",
        .linux_icon = null,
        .windows_resource = null,
    };
    try ziggy_build.addLinuxShell(b, app, target, optimize, ziggy, core.static_library);
    try ziggy_build.addWindowsShell(b, app, compile_only, target, optimize, ziggy, core.static_library);
}
```

What Ziggy's `build.zig` gives an app:

- `dependency(b, target, optimize, test_hooks)`: Ziggy for the target, as `IZiggy`: the dependency itself, `module` (the core, which the app's code imports as `@import("ziggy-core")`). Ask twice for a build that needs both, such as an app built without the test hooks and its unit tests, which run with them.
- `addAppCore(b, ziggy, app, target, optimize)`: builds the app's core as a library, installed by the `<name>-core` step with the app's built UI embedded in it as the `ui-files` import. For an Android target that is the shared library the Android native app loads, and for every other target a static library with `ziggy.h` beside it. It returns both libraries, so an app can link more into them (a system library, for one).
- `addLinuxShell` and `addWindowsShell`: the app's Linux executable (`<name>-linux`, installed to `bin/<name>`) and Windows executable (`<name>-windows`), each with the UI embedded, and a step that compiles the Windows native app without linking it (`<name>-windows-check`), for a machine without Microsoft's toolchain.
- `embedUi`: the module that embeds a built UI, for a build that makes its own modules (an app's unit tests, for one).
- `addDirectoryTests`: compiles every `*.test.zig` under a directory's `src/test` into one test program and runs it, which is how the example runs its core's tests.

The app's own options (`test-hooks`, `optimize`, `compile-only`) are passed on to Ziggy, so `zig build my-app-core -Dtarget=aarch64-linux-android -Dtest-hooks=true` builds the core and Ziggy for that target with the test hooks.

## The Xcode projects (MacOS and iOS)

From a local path: the project holds a folder reference to Ziggy's Swift package for that platform and links its product. Add `../ziggy/packages/ziggy/native/macos` (the MacOS project) or `../ziggy/packages/ziggy/native/ios` (the iOS project) to the project as a folder, which Xcode treats as a local package, then add the product `ZiggyNativeMacOS` or `ZiggyNativeIOS` to the app target's Frameworks, Libraries, and Embedded Content. The example's projects (`apps/ziggy-example/shells/macos` and `apps/ziggy-example/shells/ios`) do this with a relative path, which a copied project only has to adjust.

From a version tag: File > Add Package Dependencies, the repository's URL (`https://github.com/<owner>/ziggy`), the rule Exact Version with the version of the tag without its `v` (Swift Package Manager reads `v0.1.0` as the version `0.1.0`) and the product `ZiggyNativeMacOS` or `ZiggyNativeIOS`. The package Xcode fetches is the `Package.swift` at the root of this repository, which holds both native apps.

Either way the app's project also links the app's core library (`lib<name>.a`, built by the `<name>-core` step) and finds `ziggy.h` beside it, as the example's sync scripts and projects do.

## The Android Gradle project

Ziggy's Android native app is a Gradle build of its own that produces the module `dev.ziggy:ziggy-native-android`. The app's `app/build.gradle` depends on it the same way in both cases:

```groovy
dependencies {
    implementation 'dev.ziggy:ziggy-native-android:v0.1.0'
}
```

From a local path, the app's `settings.gradle` includes Ziggy's Android build, and Gradle builds it from the checkout in place of the dependency, whatever version the dependency names:

```groovy
includeBuild('../ziggy/packages/ziggy/native/android') {
    name = 'ziggy-native-android'
}
```

From a version tag, the app's `settings.gradle` declares the repository as a source dependency, and Gradle checks it out at the tag the dependency's version names and builds Ziggy's Android native app from it:

```groovy
sourceControl {
    gitRepository(uri('https://github.com/<owner>/ziggy.git')) {
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
    "ziggy-ui": "git+https://github.com/<owner>/ziggy.git#v0.1.0"
}
```

Inside this repository the example uses `"ziggy-ui": "workspace:*"`, because `ziggy-ui` is a workspace of the same repository.

## Moving to a newer version

1. Read the release notes of the new version and the changes to the guides, for anything an app has to change.
2. In `build.zig.zon`, run `zig fetch --save=ziggy <the new tag's archive URL>`, which replaces the URL and the hash.
3. In each Xcode project, change the package's exact version.
4. In `app/build.gradle`, change the version of `dev.ziggy:ziggy-native-android` to the new tag.
5. In `package.json`, change the tag after `#`, and run `bun install`.
6. Build and run the app's unit and smoke tests on every platform.

An app on a local path moves by checking out the new version in its Ziggy checkout.
