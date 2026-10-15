const std = @import("std");
const ziggy_build = @import("ziggy");

//
// Builds the Ziggy test app, an app built on Ziggy the way every app is: it takes Ziggy as the dependency named "ziggy" in
// build.zig.zon, builds its backend as a library with the `ziggy-test-app-backend` step, and its Linux and Windows shells with the
// `ziggy-test-app-linux` and `ziggy-test-app-windows` steps. The Xcode projects and the Android project are built by the app's scripts,
// which run the `ziggy-test-app-backend` step to build the backend's library. `ziggy-test-app-dev` runs it in dev mode, with the UI in a browser, which comes
// with the backend. `test` runs the unit tests of the test app's backend.
//
pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    // Whether the test hooks (the test control connection) are built into the app. Never for a release.
    const test_hooks = b.option(bool, "test-hooks", "Build the test hooks (the test control connection) into the app (never for a release)") orelse false;
    // Whether the Windows shell is compiled without linking WebView2's loader, to check it on a machine that cannot link.
    const compile_only = b.option(bool, "compile-only", "Compile the Windows shell without linking the WebView2 loader, to check it on a machine that cannot link") orelse false;
    // Whether the desktop executables leave out their debug information. Only the release packages do: a dev or test build keeps it, so
    // a panic there prints where it happened.
    const strip = b.option(bool, "strip", "Leave the debug information out of the desktop executables (for a release)") orelse false;
    // ReleaseSafe by default: the tests keep the safety checks.
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Prioritize performance, safety, or binary size (default: ReleaseSafe)") orelse .ReleaseSafe;

    const ziggy = ziggy_build.dependency(b, target, optimize, test_hooks);
    const core = try ziggy_build.addAppBackend(b, ziggy, .{
        .name = "ziggy-test-app",
        .title = "the Ziggy test app",
        .backend_source_file = "backend/src/index.zig",
        .ui_directory = "dist",
        .imports = &.{},
    }, target, optimize);
    const app: ziggy_build.IShellApp = .{
        .name = "ziggy-test-app",
        .title = "the Ziggy test app",
        .directory = ".",
        .linux_icon = null,
        .windows_resource = null,
    };
    try ziggy_build.addLinuxShell(b, app, strip, target, optimize, ziggy, core.static_library);
    try ziggy_build.addWindowsShell(b, app, compile_only, strip, target, optimize, ziggy, core.static_library);

    // The unit tests of the test app's backend, which run it with Ziggy's test hooks compiled in.
    const test_ziggy = ziggy_build.dependency(b, target, optimize, true);
    const template_for_tests = b.createModule(.{
        .root_source_file = b.path("backend/src/handlers.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    template_for_tests.addImport("ziggy-core", test_ziggy.module);
    template_for_tests.addImport("ui-files", try ziggy_build.embedUi(b, test_ziggy.module, "ziggy-core", "dist"));
    const test_step = b.step("test", "Run the unit tests of the Ziggy test app's core");
    const test_binary_step = b.step("test-binary-ziggy-test-app-backend", "Build the unit test program of the Ziggy test app's core and install it to test-bin without running it");
    try ziggy_build.addDirectoryTests(b, test_step, "backend", &.{
        .{
            .name = "ziggy-core",
            .module = test_ziggy.module,
        },
        .{
            .name = "ziggy-test-app-backend",
            .module = template_for_tests,
        },
    }, target, optimize, test_binary_step);
}
