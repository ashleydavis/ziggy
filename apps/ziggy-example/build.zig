const std = @import("std");
const ziggy_build = @import("ziggy");

//
// Builds the Ziggy example, an app built on Ziggy the way every app is: it takes Ziggy as the dependency named "ziggy" in
// build.zig.zon, builds its core as a library with the `ziggy-example-core` step, and its Linux and Windows shells with the
// `ziggy-example-linux` and `ziggy-example-windows` steps. The Xcode projects and the Android project are built by the app's scripts,
// which ask the `ziggy-example-core` step for the core's library. `test` runs the unit tests of the example's core.
//
pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    // Whether the test hooks (the test control connection) are built into the app. Never for a release.
    const test_hooks = b.option(bool, "test-hooks", "Build the test hooks (the test control connection) into the app (never for a release)") orelse false;
    // Whether the Windows shell is compiled without linking WebView2's loader, to check it on a machine that cannot link.
    const compile_only = b.option(bool, "compile-only", "Compile the Windows shell without linking the WebView2 loader, to check it on a machine that cannot link") orelse false;
    // ReleaseSafe by default: the tests keep the safety checks.
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Prioritize performance, safety, or binary size (default: ReleaseSafe)") orelse .ReleaseSafe;

    const ziggy = ziggy_build.dependency(b, target, optimize, test_hooks);
    const core = try ziggy_build.addAppCore(b, ziggy, .{
        .name = "ziggy-example",
        .title = "the Ziggy example",
        .root_source_file = "core/src/index.zig",
        .page_directory = "dist",
        .imports = &.{},
    }, target, optimize);
    const app: ziggy_build.IShellApp = .{
        .name = "ziggy-example",
        .title = "the Ziggy example",
        .directory = ".",
        .page_directory = "dist",
        .linux_icon = null,
        .windows_resource = null,
    };
    try ziggy_build.addLinuxShell(b, app, target, optimize, ziggy, core.static_library);
    try ziggy_build.addWindowsShell(b, app, compile_only, target, optimize, ziggy, core.static_library);

    // The unit tests of the example's core, which run it with Ziggy's test hooks compiled in.
    const test_ziggy = ziggy_build.dependency(b, target, optimize, true);
    const example_for_tests = b.createModule(.{
        .root_source_file = b.path("core/src/handlers.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    example_for_tests.addImport("ziggy", test_ziggy.module);
    example_for_tests.addImport("page-files", try ziggy_build.embedPage(b, test_ziggy.module, "ziggy", "dist"));
    const test_step = b.step("test", "Run the unit tests of the Ziggy example's core");
    const test_binary_step = b.step("test-binary-ziggy-example-core", "Build the unit test program of the Ziggy example's core and install it to test-bin without running it");
    try ziggy_build.addDirectoryTests(b, test_step, "core", &.{
        .{
            .name = "ziggy",
            .module = test_ziggy.module,
        },
        .{
            .name = "ziggy-example-core",
            .module = example_for_tests,
        },
    }, target, optimize, test_binary_step);
}
