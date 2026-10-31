const std = @import("std");
const android_libc = @import("build/android-libc.zig");

//
// Builds Ziggy and registers its tests. As a dependency of an app's build it gives the app the
// module "ziggy" (the core, with its task queue, which the app's code imports as @import("ziggy")), built for the target,
// optimize mode and test hooks the app passes in. The functions below that are `pub` are what an app's build.zig calls to build its
// core library and its Linux and Windows native apps; it reaches them with @import("ziggy") in its build.zig.
//
pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    // Whether the test hooks (the test control connection) are built into the core. Never for a release.
    const test_hooks = b.option(bool, "test-hooks", "Build the test hooks (the test control connection) into the core (never for a release)") orelse false;
    // ReleaseSafe by default: the tests keep the safety checks.
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Prioritize performance, safety, or binary size (default: ReleaseSafe)") orelse .ReleaseSafe;
    // The name of the app this core is built for, which names its log files. dependency sets it from the app's app.zon.
    const app_name = b.option([]const u8, "app-name", "The name of the app the core is built for, which names its log files") orelse null;
    // The title of that app, which heads its log files. dependency sets it from the app's app.zon.
    const app_title = b.option([]const u8, "app-title", "The title of the app the core is built for, which heads its log files") orelse null;
    // The version of that app, which its log files give. dependency sets it from the app's app.zon.
    const app_version = b.option([]const u8, "app-version", "The version of the app the core is built for, which its log files give") orelse null;

    const core = b.addModule("ziggy", .{
        .root_source_file = b.path("packages/ziggy/core/src/index.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    try configureCore(b, core, createPackages(b, target, optimize), target, optimize, test_hooks, app_name, app_title, app_version);

    // The unit tests of Ziggy's core and its task queue, which run the core with the test hooks compiled in.
    const test_step = b.step("test", "Run the unit tests of Ziggy (the core, the utils, the log, the native apps and the dev host), of the Ziggy template and of Ziggy's test app");
    const test_core = b.createModule(.{
        .root_source_file = b.path("packages/ziggy/core/src/index.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const test_packages = createPackages(b, target, optimize);
    try configureCore(b, test_core, test_packages, target, optimize, true, null, null, null);
    const test_filters = testFilters(b);
    const core_test_binary_step = b.step("test-binary-ziggy-core", "Build the unit test program of Ziggy's core and install it to test-bin without running it");
    try addFilteredDirectoryTests(b, test_step, "packages/ziggy/core", &.{
        .{
            .name = "ziggy",
            .module = test_core,
        },
        // The Windows native app's list of the actions it does itself, which the menu's tests compare with the core's list.
        .{
            .name = "ziggy-native-windows-actions",
            .module = b.createModule(.{
                .root_source_file = b.path("packages/ziggy/native/windows/src/lib/actions.zig"),
                .target = target,
                .optimize = optimize,
            }),
        },
    }, target, optimize, core_test_binary_step, test_filters);

    // The unit tests of the utils and of the log. Some of them start threads, which talk through the core's message queue, so they import
    // the core too.
    for ([_][]const u8{ "utils", "log" }) |package_name| {
        const package_test_binary_step = b.step(
            b.fmt("test-binary-ziggy-{s}", .{package_name}),
            b.fmt("Build the unit test program of Ziggy's {s} and install it to test-bin without running it", .{package_name}),
        );
        try addFilteredDirectoryTests(b, test_step, b.fmt("packages/ziggy/{s}", .{package_name}), &.{
            .{
                .name = "ziggy",
                .module = test_core,
            },
            .{
                .name = "utils",
                .module = test_packages.utils,
            },
            .{
                .name = "log",
                .module = test_packages.log,
            },
        }, target, optimize, package_test_binary_step, test_filters);
    }

    // The console writing to the real stdout, which a unit test cannot see: a program writes through it and the build checks what it
    // printed.
    const console_stdout = b.createModule(.{
        .root_source_file = b.path("packages/ziggy/log/src/test/fixtures/console-stdout.zig"),
        .target = target,
        .optimize = optimize,
    });
    console_stdout.addImport("log", test_packages.log);
    const run_console_stdout = b.addRunArtifact(b.addExecutable(.{
        .name = "console-stdout",
        .root_module = console_stdout,
    }));
    run_console_stdout.expectStdOutEqual("logged to stdout\ndebugged to stdout\n");
    test_step.dependOn(&run_console_stdout.step);

    // The unit tests of the parts of the native apps that do not need the platform's libraries.
    const linux_tests = b.createModule(.{
        .root_source_file = b.path("packages/ziggy/native/linux/src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{
        .name = "ziggy-native-linux",
        .root_module = linux_tests,
    })).step);
    const dev_host_tests = b.createModule(.{
        .root_source_file = b.path("packages/ziggy/dev/src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{
        .name = "ziggy-dev",
        .root_module = dev_host_tests,
    })).step);
    const windows_tests = b.createModule(.{
        .root_source_file = b.path("packages/ziggy/native/windows/src/tests.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{
        .name = "ziggy-native-windows",
        .root_module = windows_tests,
    })).step);

    // The tests of the Ziggy template and of Ziggy's test app, each a build of its own that takes Ziggy as a dependency, as every app
    // does. Each backend embeds its built frontend, which its build reads when it starts, so the frontend is built first and the app's
    // build is then run as a program of its own.
    for ([_][]const u8{ "apps/ziggy-template", "apps/ziggy-test-app" }) |app_directory| {
        const bundle_app_ui = b.addSystemCommand(&.{ "bun", "run", "bundle:ui" });
        bundle_app_ui.setCwd(b.path(app_directory));
        bundle_app_ui.has_side_effects = true;
        const test_app = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "test", "--summary", "all" });
        test_app.setCwd(b.path(app_directory));
        test_app.has_side_effects = true;
        test_app.step.dependOn(&bundle_app_ui.step);
        test_step.dependOn(&test_app.step);
    }
}

//
// The packages the core is built on, each a module of its own. The app reaches them through the core, as @import("ziggy").utils and
// @import("ziggy").log.
//
const IPackages = struct {
    // The utils package, imported as "utils".
    utils: *std.Build.Module,
    // The log package, imported as "log". It is built on the utils.
    log: *std.Build.Module,
};

//
// Makes the modules of the packages the core is built on, for the target and optimize mode.
//
fn createPackages(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) IPackages {
    const utils = b.createModule(.{
        .root_source_file = b.path("packages/ziggy/utils/src/index.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const log = b.createModule(.{
        .root_source_file = b.path("packages/ziggy/log/src/index.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    log.addImport("utils", utils);
    return .{
        .utils = utils,
        .log = log,
    };
}

//
// Gives the core module its build options and imports. The test hooks compile in the test control connection: they are off for a
// release and on for the tests and for the builds the smoke tests drive. The app's name, title and version, null for Ziggy's own tests, name and head its log files.
//
fn configureCore(
    b: *std.Build,
    module: *std.Build.Module,
    packages: IPackages,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    test_hooks: bool,
    app_name: ?[]const u8,
    app_title: ?[]const u8,
    app_version: ?[]const u8,
) !void {
    module.addImport("utils", packages.utils);
    module.addImport("log", packages.log);
    const options = b.addOptions();
    options.addOption(bool, "test_hooks", test_hooks);
    options.addOption(?[]const u8, "app_name", app_name);
    options.addOption(?[]const u8, "app_title", app_title);
    options.addOption(?[]const u8, "app_version", app_version);
    module.addOptions("build_options", options);

    // The Android native app reaches the core through JNI, written in Zig against the NDK's own jni.h. Only an Android target has that
    // header, so the import exists only for one.
    if (target.result.abi.isAndroid()) {
        const jni_translate_c = b.addTranslateC(.{
            .root_source_file = b.path("packages/ziggy/core/src/lib/jni-c.h"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        try android_libc.addLibcIncludes(b, jni_translate_c, target);
        module.addImport("jni-c", jni_translate_c.createModule());
    }
}

//
// Ziggy as an app's build has it: the dependency, for the files of Ziggy the app's build needs, and the modules it gives.
//
pub const IZiggy = struct {
    // The dependency named "ziggy" in the app's build.zig.zon.
    dependency: *std.Build.Dependency,

    // The core, with its task queue, which the app's code imports as @import("ziggy").
    module: *std.Build.Module,
};

//
// Gets Ziggy for an app's build, from the dependency named "ziggy" in the app's build.zig.zon, built for the target and optimize mode,
// with the test hooks or without, and for the app its app.zon describes (see readAppDetails). A build that needs both (an app with test
// hooks off and its unit tests, which run with them on) calls it twice.
//
pub fn dependency(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, test_hooks: bool) IZiggy {
    const details = readAppDetails(b);
    const ziggy_dependency = b.dependency("ziggy", .{
        .target = target,
        .optimize = optimize,
        .@"test-hooks" = test_hooks,
        .@"app-name" = details.name,
        .@"app-title" = details.title,
        .@"app-version" = details.version,
    });
    return .{
        .dependency = ziggy_dependency,
        .module = ziggy_dependency.module("ziggy"),
    };
}

//
// An app's details, as its app.zon gives them.
//
const IAppDetails = struct {
    // The app's name, such as "ziggy-template", which names its log files.
    name: []const u8,
    // The app's name as people read it, such as "Ziggy template", which heads its log files.
    title: []const u8,
    // The app's version, which its log files give, or null for an app that gives none. A release build writes it into app.zon.
    version: ?[]const u8 = null,
};

//
// Reads the app's details from the app.zon beside its build.zig, with Zig's own ZON parser. An app.zon that is missing, does not parse,
// lacks a required field or has a field IAppDetails does not have fails the build, naming the problem.
//
fn readAppDetails(b: *std.Build) IAppDetails {
    const source = b.build_root.handle.readFileAllocOptions(b.graph.io, "app.zon", b.allocator, .limited(1024 * 1024), .of(u8), 0) catch |err| {
        std.debug.panic("Ziggy could not read the app's app.zon, which gives its name, title and version: {s}", .{@errorName(err)});
    };
    var diagnostics: std.zon.parse.Diagnostics = .{};
    return std.zon.parse.fromSliceAlloc(IAppDetails, b.allocator, source, &diagnostics, .{}) catch |err| switch (err) {
        error.OutOfMemory => @panic("out of memory reading the app's app.zon"),
        error.ParseZon => std.debug.panic("the app's app.zon is not valid:\n{f}", .{diagnostics}),
    };
}

//
// What addAppBackend needs to know about an app's backend.
//
pub const IAppBackend = struct {
    // The name of the app, which names its library (`lib<name with dashes as underscores>.a`) and its step (`<name>-backend`).
    name: []const u8,
    // The name the step's description uses for the app, such as "the Ziggy template".
    title: []const u8,
    // The app's backend source file, relative to the app's folder: the file that declares `pub const app = ziggy.core.App(.{ ... });`.
    backend_source_file: []const u8,
    // The directory of the app's built frontend, relative to the app's build root, which is embedded in the core as "ui-files".
    ui_directory: []const u8,
    // The modules the app's backend imports besides "ziggy" and "ui-files".
    imports: []const IImport,
};

//
// The libraries addAppBackend builds.
//
pub const IAppBackendLibraries = struct {
    // The static library, which the native apps link (the Linux and Windows native apps here, and the Xcode projects).
    static_library: *std.Build.Step.Compile,
    // The shared library, for an Android target only, which the Android native app loads.
    shared_library: ?*std.Build.Step.Compile,
};

//
// Builds an app's backend for the target, installed by the `<name>-backend` step: a static library with ziggy.h installed beside it or,
// for Android, a shared one. The platform native apps that are not Zig (the Xcode projects and the Android project) are built by the app's
// scripts, which run this step to build the libraries. It also adds the app's dev mode, the `<name>-dev` and `<name>-dev-host` steps (see
// addDevMode), so an app gets dev mode with nothing more to do.
//
pub fn addAppBackend(
    b: *std.Build,
    ziggy: IZiggy,
    app: IAppBackend,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !IAppBackendLibraries {
    const core_step = b.step(b.fmt("{s}-backend", .{app.name}), b.fmt("Build {s}'s backend as a library for the target", .{app.title}));
    const library_name = try b.allocator.dupe(u8, app.name);
    std.mem.replaceScalar(u8, library_name, '-', '_');
    const static_library = b.addLibrary(.{
        .name = library_name,
        .root_module = try createAppBackendModule(b, ziggy, app, target, optimize, try embedUi(b, ziggy.module, "ziggy", app.ui_directory)),
        .linkage = .static,
    });
    // The Xcode linker is not Zig's, so the compiler runtime (for example ___zig_probe_stack) must travel inside the archive.
    static_library.bundle_compiler_rt = true;
    var shared_library: ?*std.Build.Step.Compile = null;
    if (!target.result.abi.isAndroid()) {
        core_step.dependOn(&b.addInstallArtifact(static_library, .{}).step);
        core_step.dependOn(&b.addInstallFileWithDir(ziggy.dependency.path("packages/ziggy/core/src/lib/ziggy.h"), .header, "ziggy.h").step);
    }
    else {
        const library = b.addLibrary(.{
            .name = library_name,
            .root_module = try createAppBackendModule(b, ziggy, app, target, optimize, try embedUi(b, ziggy.module, "ziggy", app.ui_directory)),
            .linkage = .dynamic,
        });
        // Android 15 and later can run with 16 KiB memory pages, and a library is loaded only when its segments are aligned to the page
        // size, so they are aligned to the larger one.
        library.link_z_max_page_size = 16384;
        core_step.dependOn(&b.addInstallArtifact(library, .{}).step);
        shared_library = library;
    }
    try addDevMode(b, app, target, optimize, ziggy);
    return .{
        .static_library = static_library,
        .shared_library = shared_library,
    };
}

//
// Makes the module an app's backend library is built from. Its root is Ziggy's app-root.zig, which exports Ziggy's C interface (and,
// for Android, the JNI entry points) for the `app` the app's backend source file declares, so the app writes no exports of its own.
// The backend source file is imported as "app-backend", and it imports Ziggy's core, the module of the app's frontend
// (its built frontend, or none for the dev host) and the app's own modules.
//
fn createAppBackendModule(
    b: *std.Build,
    ziggy: IZiggy,
    app: IAppBackend,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    ui_files: *std.Build.Module,
) !*std.Build.Module {
    const backend = b.createModule(.{
        .root_source_file = b.path(app.backend_source_file),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    backend.addImport("ziggy", ziggy.module);
    backend.addImport("ui-files", ui_files);
    for (app.imports) |import| {
        backend.addImport(import.name, import.module);
    }
    const module = b.createModule(.{
        .root_source_file = ziggy.dependency.path("packages/ziggy/core/src/app-root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addImport("ziggy", ziggy.module);
    module.addImport("app-backend", backend);
    return module;
}

//
// A path under an app's directory. The directory is relative to the app's build root, and "." is the build root itself.
//
fn appPath(b: *std.Build, directory: []const u8, sub_path: []const u8) []const u8 {
    if (std.mem.eql(u8, directory, ".")) {
        return sub_path;
    }
    return b.fmt("{s}/{s}", .{ directory, sub_path });
}

//
// Makes the module that holds an app's built frontend, a list of every file under the frontend's directory (a path relative
// to the root of the repository), each embedded with @embedFile. Pass the module to the app's backend, which gives the list to
// the `ui_files` field of its ziggy.core.App.
// The directory is read every time the build runs, so whatever the frontend build produced is what gets embedded, with no list
// of files to keep up to date. A changed file rebuilds the executable. When the directory is missing or has no index.html,
// which means the frontend was not built first, the module does not compile and reports why: the build of anything that does
// not use the frontend is not affected.
//
pub fn embedUi(b: *std.Build, native_app: *std.Build.Module, native_app_import_name: []const u8, ui_directory: []const u8) !*std.Build.Module {
    const io = b.graph.io;
    var source: std.ArrayList(u8) = .empty;
    var embedded_names: std.ArrayList([]const u8) = .empty;
    var embedded_paths: std.ArrayList([]const u8) = .empty;
    var has_index = false;
    if (b.build_root.handle.openDir(io, ui_directory, .{
        .iterate = true,
    })) |opened| {
        var directory = opened;
        defer directory.close(io);
        try source.appendSlice(b.allocator, b.fmt("const native_app = @import(\"{s}\");\n\npub const files = [_]native_app.UiFile{{\n", .{native_app_import_name}));
        var walker = try directory.walk(b.allocator);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) {
                continue;
            }
            const path = b.dupe(entry.path);
            std.mem.replaceScalar(u8, path, '\\', '/');
            const import_name = b.fmt("ui-file-{d}", .{embedded_names.items.len});
            try embedded_names.append(b.allocator, import_name);
            try embedded_paths.append(b.allocator, b.fmt("{s}/{s}", .{ ui_directory, path }));
            try source.appendSlice(b.allocator, b.fmt("    .{{\n        .path = \"{s}\",\n        .content = @embedFile(\"{s}\"),\n    }},\n", .{ path, import_name }));
            if (std.mem.eql(u8, path, "index.html")) {
                has_index = true;
            }
        }
        try source.appendSlice(b.allocator, "};\n");
    } else |err| {
        // A frontend directory that is missing means the frontend was not built, which the compile error below reports. Any
        // other failure is reported as it is.
        if (err != error.FileNotFound) {
            return err;
        }
    }
    if (!has_index) {
        source.clearRetainingCapacity();
        embedded_names.clearRetainingCapacity();
        embedded_paths.clearRetainingCapacity();
        try source.appendSlice(b.allocator, b.fmt("comptime {{\n    @compileError(\"The built UI is not in {s}, or has no index.html. Build the UI first.\");\n}}\n", .{ui_directory}));
    }

    const generated = b.addWriteFiles();
    const module = b.createModule(.{
        .root_source_file = generated.add("ui-files.zig", source.items),
    });
    if (has_index) {
        module.addImport(native_app_import_name, native_app);
    }
    for (embedded_names.items, embedded_paths.items) |import_name, file_path| {
        module.addAnonymousImport(import_name, .{
            .root_source_file = b.path(file_path),
        });
    }
    return module;
}

//
// The directories a Linux system keeps its shared libraries in, checked in this order.
//
const library_directories = [_][]const u8{
    "/usr/lib/x86_64-linux-gnu",
    "/usr/lib/aarch64-linux-gnu",
    "/lib/x86_64-linux-gnu",
    "/lib/aarch64-linux-gnu",
    "/usr/lib64",
    "/usr/lib",
    "/lib64",
    "/lib",
};

//
// Finds an installed runtime library by its file name and returns its full path. Fails the build, naming the missing library and
// where it looked, when it is in none of the usual directories.
//
fn findRuntimeLibrary(b: *std.Build, file_name: []const u8) ![]const u8 {
    for (library_directories) |directory| {
        const path = b.fmt("{s}/{s}", .{ directory, file_name });
        std.Io.Dir.cwd().access(b.graph.io, path, .{}) catch {
            continue;
        };
        return path;
    }
    std.debug.print("The runtime library {s} is not installed. Looked in:\n", .{file_name});
    for (library_directories) |directory| {
        std.debug.print("  {s}\n", .{directory});
    }
    return error.RuntimeLibraryMissing;
}

//
// Compiles the test files under `<directory>/src/test` into one test program whose modules are given, and returns the run step. The
// src directory is copied next to the generated root so that the imports of the tests resolve as they do in src/test. The program runs
// from `directory`. -Dtest-filter=<text> runs only the tests whose names contain the text, and may be given more than once. Every test
// runs without it.
//
pub fn addDirectoryTests(
    b: *std.Build,
    test_step: *std.Build.Step,
    directory: []const u8,
    imports: []const IImport,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    test_binary_step: ?*std.Build.Step,
) !void {
    try addFilteredDirectoryTests(b, test_step, directory, imports, target, optimize, test_binary_step, testFilters(b));
}

//
// The texts -Dtest-filter gives, or none. A build declares the option once, so a build that adds the tests of several directories reads
// it once and gives it to addFilteredDirectoryTests for each.
//
fn testFilters(b: *std.Build) []const []const u8 {
    return b.option([]const []const u8, "test-filter", "Run only the unit tests whose names contain this text") orelse &.{};
}

//
// addDirectoryTests, running only the tests whose names contain one of the filters, or every test when there are none.
//
fn addFilteredDirectoryTests(
    b: *std.Build,
    test_step: *std.Build.Step,
    directory: []const u8,
    imports: []const IImport,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    test_binary_step: ?*std.Build.Step,
    filters: []const []const u8,
) !void {
    const test_files = b.addWriteFiles();
    _ = test_files.addCopyDirectory(b.path(b.fmt("{s}/src", .{directory})), "src", .{});
    var test_root_source: std.ArrayList(u8) = .empty;
    try test_root_source.appendSlice(b.allocator, "test {\n");
    var test_dir = try b.build_root.handle.openDir(b.graph.io, b.fmt("{s}/src/test", .{directory}), .{
        .iterate = true,
    });
    defer test_dir.close(b.graph.io);
    var walker = try test_dir.walk(b.allocator);
    defer walker.deinit();
    while (try walker.next(b.graph.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".test.zig")) {
            continue;
        }
        // The walker gives the path with the system's separator, and a Windows backslash in a Zig string starts an escape, so the
        // import is written with the forward slashes an import path takes on every system.
        const import_path = try b.allocator.dupe(u8, entry.path);
        std.mem.replaceScalar(u8, import_path, std.fs.path.sep, '/');
        try test_root_source.appendSlice(b.allocator, b.fmt("    _ = @import(\"src/test/{s}\");\n", .{import_path}));
    }
    try test_root_source.appendSlice(b.allocator, "}\n");
    const tests = b.createModule(.{
        .root_source_file = test_files.add("all-tests.zig", test_root_source.items),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    for (imports) |import| {
        tests.addImport(import.name, import.module);
    }
    // Zig does not look in the iOS SDK for libSystem unless it is given the library directory, which --sysroot then makes the SDK's.
    // A test program for the iOS simulator failed to link with "unable to find libSystem system library" with only the sysroot given,
    // and linked past that once /usr/lib was added as a library path.
    if (target.result.os.tag == .ios) {
        tests.addLibraryPath(.{
            .cwd_relative = "/usr/lib",
        });
    }
    const unit_test = b.addTest(.{
        .name = std.fs.path.basename(directory),
        .filters = filters,
        .root_module = tests,
    });
    // The NDK has no libc.a for the sysroot's API level directory Zig looks in, only libc.so, so a test program for Android is linked
    // dynamically. Zig's build failed with "failed to parse archive: FileNotFound" on libc.a, libm.a and libdl.a.
    if (target.result.abi.isAndroid()) {
        unit_test.linkage = .dynamic;
    }
    // Installs the unit test program without running it, under test-bin, for a target that cannot run it here: the Android and iOS test
    // scripts build it for their target and run it on the emulator or simulator.
    if (test_binary_step) |step| {
        step.dependOn(&b.addInstallArtifact(unit_test, .{
            .dest_dir = .{
                .override = .{
                    .custom = "test-bin",
                },
            },
        }).step);
    }
    const run_test = b.addRunArtifact(unit_test);
    run_test.setCwd(b.path(directory));
    test_step.dependOn(&run_test.step);
}

//
// A module a test program imports, and the name it imports it under.
//
pub const IImport = struct {
    // The name the tests import the module under.
    name: []const u8,

    // The module.
    module: *std.Build.Module,
};

//

//
// The shared libraries the Linux native app links, by their full file names, which is what a program built against the development packages
// ends up needing at run time anyway. Nothing but the runtime libraries has to be installed.
//
const linux_runtime_libraries = [_][]const u8{
    "libglib-2.0.so.0",
    "libgobject-2.0.so.0",
    "libgio-2.0.so.0",
    "libgdk-3.so.0",
    "libgtk-3.so.0",
    "libgdk_pixbuf-2.0.so.0",
    "libjavascriptcoregtk-4.1.so.0",
    "libwebkit2gtk-4.1.so.0",
    "libcairo.so.2",
    "libgbm.so.1",
    "libEGL.so.1",
};

//
// What differs between the apps that Ziggy's Linux and Windows native apps are built for.
//
pub const INativeApp = struct {
    // The name of the app, which names its executable and its steps (`<name>-linux`, `<name>-windows`, `<name>-windows-check`).
    name: []const u8,
    // The name the steps' descriptions use for the app, such as "the Ziggy template".
    title: []const u8,
    // The directory of the app relative to the app's build root ("." for the build root itself), under which its native apps
    // (`native/linux/src/main.zig`, `native/windows/src/main.zig`) and the WebView2 SDK
    // (`webview2-sdk`) are.
    directory: []const u8,
    // The PNG file of the app's window icon on Linux, which the native app's `app-icon` import gives to the app's main file, or null for none.
    linux_icon: ?[]const u8,
    // The Windows resource script of the app's executable icon, or null for none.
    windows_resource: ?[]const u8,
};

//
// Builds an app's Linux native app, installed to zig-out/bin/<name> by the `<name>-linux` step. The native app is Zig that talks to GTK 3 and
// WebKitGTK 4.1 through their C headers, and to the core through ziggy.h. The built frontend (made by `bun run bundle:ui`) is embedded in
// the executable, so the executable is the whole app.
//
pub fn addLinuxNativeApp(
    b: *std.Build,
    app: INativeApp,
    strip: bool,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    ziggy: IZiggy,
    core_library: *std.Build.Step.Compile,
) !void {
    const step = b.step(b.fmt("{s}-linux", .{app.name}), b.fmt("Build {s} for Linux, installed to bin/{s}", .{ app.title, app.name }));
    if (target.result.os.tag != .linux) {
        step.dependOn(&b.addFail(b.fmt("The {s}-linux step builds for a Linux target.", .{app.name})).step);
        return;
    }
    var runtime_library_paths: std.ArrayList([]const u8) = .empty;
    for (linux_runtime_libraries) |library| {
        const path = findRuntimeLibrary(b, library) catch {
            step.dependOn(&b.addFail(b.fmt("The runtime library {s} is not installed.", .{library})).step);
            return;
        };
        try runtime_library_paths.append(b.allocator, path);
    }

    const translate_c = b.addTranslateC(.{
        .root_source_file = ziggy.dependency.path("packages/ziggy/native/linux/src/c.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    translate_c.addIncludePath(ziggy.dependency.path("packages/ziggy/core/src/lib"));
    const native_app = b.createModule(.{
        .root_source_file = ziggy.dependency.path("packages/ziggy/native/linux/src/index.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    native_app.addImport("c", translate_c.createModule());
    // The messages the core sends the native app, which the native app reads.
    native_app.addImport("native-message", b.createModule(.{
        .root_source_file = ziggy.dependency.path("packages/ziggy/core/src/lib/native-message.zig"),
        .target = target,
        .optimize = optimize,
    }));
    for (runtime_library_paths.items) |path| {
        native_app.addObjectFile(.{
            .cwd_relative = path,
        });
    }

    const module = b.createModule(.{
        .root_source_file = b.path(appPath(b, app.directory, "native/linux/src/main.zig")),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = strip,
    });
    module.addImport("ziggy-native-linux", native_app);
    if (app.linux_icon) |icon| {
        module.addAnonymousImport("app-icon", .{
            .root_source_file = b.path(icon),
        });
    }
    module.linkLibrary(core_library);
    const executable = b.addExecutable(.{
        .name = app.name,
        .root_module = module,
    });
    step.dependOn(&b.addInstallArtifact(executable, .{}).step);
}

//
// Builds an app's Windows native app, installed to zig-out/<name>/<name>.exe by the `<name>-windows` step. The native app is Zig that talks to
// Win32 and to WebView2 through their C headers. The executable is the whole app: the built frontend is embedded in it and WebView2's
// loader is linked into it. The frontend is expected in the app's frontend directory (bun run bundle:ui) and the loader's static
// library in the app's webview2-sdk directory (the setup script), and the build fails when either is missing. The `<name>-windows-check` step
// compiles the native app without linking it, for a machine that cannot link a Windows executable. With compile_only the loader is not
// linked, which is how that machine checks the native app.
//
pub fn addWindowsNativeApp(
    b: *std.Build,
    app: INativeApp,
    compile_only: bool,
    strip: bool,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    ziggy: IZiggy,
    core_library: *std.Build.Step.Compile,
) !void {
    const step = b.step(b.fmt("{s}-windows", .{app.name}), b.fmt("Build {s} for Windows, installed to {s}/{s}.exe", .{ app.title, app.name, app.name }));
    const check_step = b.step(b.fmt("{s}-windows-check", .{app.name}), b.fmt("Compile {s}'s Windows native app for type errors without linking", .{app.title}));
    if (target.result.os.tag != .windows) {
        const message = b.fmt("The {s}-windows steps build for a Windows target.", .{app.name});
        step.dependOn(&b.addFail(message).step);
        check_step.dependOn(&b.addFail(message).step);
        return;
    }
    const sdk_architecture = switch (target.result.cpu.arch) {
        .x86_64 => "x64",
        .aarch64 => "arm64",
        else => return error.UnsupportedArchitecture,
    };

    // The headers are translated for the -gnu ABI of the target's architecture, so that they come from the mingw headers Zig bundles.
    // With the -msvc target on a machine that has the Windows SDK, Zig would hand translate-c the SDK's own headers, which its C front
    // end cannot parse (MSVC extensions such as __ptr64 in basetsd.h). The two ABIs share the calling convention and struct layout on
    // Windows, so the declarations are the same, and the executable is still built and linked for the -msvc target.
    var translate_query = target.query;
    translate_query.abi = .gnu;
    const translate_c = b.addTranslateC(.{
        .root_source_file = ziggy.dependency.path("packages/ziggy/native/windows/src/c.h"),
        .target = b.resolveTargetQuery(translate_query),
        .optimize = optimize,
        .link_libc = true,
    });
    translate_c.addIncludePath(ziggy.dependency.path("packages/ziggy/core/src/lib"));
    translate_c.addIncludePath(b.path(appPath(b, app.directory, "webview2-sdk/include")));

    const native_app = b.createModule(.{
        .root_source_file = ziggy.dependency.path("packages/ziggy/native/windows/src/index.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    native_app.addImport("c", translate_c.createModule());
    // The messages the core sends the native app, which the native app reads.
    native_app.addImport("native-message", b.createModule(.{
        .root_source_file = ziggy.dependency.path("packages/ziggy/core/src/lib/native-message.zig"),
        .target = target,
        .optimize = optimize,
    }));
    native_app.linkSystemLibrary("user32", .{});
    native_app.linkSystemLibrary("kernel32", .{});
    native_app.linkSystemLibrary("ole32", .{});
    native_app.linkSystemLibrary("shell32", .{});
    native_app.linkSystemLibrary("uuid", .{});
    // The WebView2 static loader reads the registry and writes event traces, which live in advapi32.
    native_app.linkSystemLibrary("advapi32", .{});
    // Without the library the module still compiles, which is how a machine that cannot link a Windows executable checks the native app, but
    // nothing built from it links.
    if (!compile_only) {
        native_app.addObjectFile(b.path(appPath(b, app.directory, b.fmt("webview2-sdk/{s}/WebView2LoaderStatic.lib", .{sdk_architecture}))));
    }

    const module = b.createModule(.{
        .root_source_file = b.path(appPath(b, app.directory, "native/windows/src/main.zig")),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = strip,
    });
    module.addImport("ziggy-native-windows", native_app);
    if (app.windows_resource) |resource| {
        module.addWin32ResourceFile(.{
            .file = b.path(resource),
        });
    }
    module.linkLibrary(core_library);
    const executable = b.addExecutable(.{
        .name = app.name,
        .root_module = module,
    });
    executable.subsystem = .windows;
    // The windows subsystem keeps a console from opening, but its default entry point in the MSVC C runtime calls WinMain. Zig's main is
    // exported as the C main, so the entry point is the C runtime's one that calls main.
    executable.entry = .{
        .symbol_name = "mainCRTStartup",
    };

    // Compiles the native app without linking it, for a machine that cannot link a Windows executable. The link needs Microsoft's toolchain
    // because the SDK's static loader is built with it.
    // The core library is not linked into the object: a COFF object cannot hold the library's objects, and the check has no link to
    // resolve.
    const check = b.createModule(.{
        .root_source_file = b.path(appPath(b, app.directory, "native/windows/src/main.zig")),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    check.addImport("ziggy-native-windows", native_app);
    // The icon resource is left out: a resource is not Zig, so it has no type errors to find, and an object cannot hold it ("coff does
    // not support linking multiple objects into one").
    check_step.dependOn(&b.addObject(.{
        .name = b.fmt("{s}-check", .{app.name}),
        .root_module = check,
    }).step);
    step.dependOn(&b.addInstallArtifact(executable, .{
        .dest_dir = .{
            .override = .{
                .custom = app.name,
            },
        },
        .pdb_dir = .disabled,
    }).step);
}

//
// Adds an app's dev mode, for addAppBackend. In dev mode the frontend runs in an ordinary browser and the core runs in the dev
// host: Ziggy's dev host linked with the app's backend, which runs the core as a program of its own. The browser opens the
// dev host, which serves /__ziggy itself, carries the page's messages to the core and forwards everything else to the app's
// own dev server, putting Ziggy's scripts in each page on the way through. The `<name>-dev-host` step builds the dev host,
// installed to bin/<name>-dev-host. Its core embeds no frontend, because the dev server serves the frontend, so dev mode needs
// no frontend built. The `<name>-dev` step runs the supervisor, which starts the app's dev server (its `dev:ui` package script),
// builds and starts the dev host, opens the browser and rebuilds and restarts the dev host when a Zig file of the app or of Ziggy
// changes. Options after `--` go to the supervisor: `--no-open` leaves the browser closed, `--port <port>` serves the app on that
// port and `--test-hooks` builds the dev host with the test hooks.
// Nothing else links the dev host, so no native app and no release build includes it.
//
fn addDevMode(
    b: *std.Build,
    app: IAppBackend,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    ziggy: IZiggy,
) !void {
    const host_name = b.fmt("{s}-dev-host", .{app.name});
    const host_step = b.step(host_name, b.fmt("Build {s}'s dev host for dev mode, installed to bin/{s}", .{ app.title, host_name }));
    const dev_step = b.step(b.fmt("{s}-dev", .{app.name}), b.fmt("Run {s} in dev mode: its dev server and dev host, in the browser, rebuilt as its files change", .{app.title}));

    // The app's core with no frontend embedded in it.
    const no_ui_files = b.addWriteFiles();
    const no_ui = b.createModule(.{
        .root_source_file = no_ui_files.add("ui-files.zig", "const ziggy = @import(\"ziggy\");\n\npub const files = [_]ziggy.UiFile{};\n"),
    });
    no_ui.addImport("ziggy", ziggy.module);
    const core_library = b.addLibrary(.{
        .name = b.fmt("{s}-dev-host-backend", .{app.name}),
        .root_module = try createAppBackendModule(b, ziggy, app, target, optimize, no_ui),
        .linkage = .static,
    });

    const translate_c = b.addTranslateC(.{
        .root_source_file = ziggy.dependency.path("packages/ziggy/core/src/lib/ziggy.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const dev_host = b.createModule(.{
        .root_source_file = ziggy.dependency.path("packages/ziggy/dev/src/index.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    dev_host.addImport("c", translate_c.createModule());
    // The core's queue of messages, which the dev host's threads talk with too.
    dev_host.addImport("message-queue", b.createModule(.{
        .root_source_file = ziggy.dependency.path("packages/ziggy/core/src/lib/message-queue.zig"),
        .target = target,
        .optimize = optimize,
    }));
    // The allocator each of the dev host's threads makes for itself, and the messages the core sends the native app, which the dev
    // host reads as a native app does.
    dev_host.addImport("thread-allocator", b.createModule(.{
        .root_source_file = ziggy.dependency.path("packages/ziggy/core/src/lib/thread-allocator.zig"),
        .target = target,
        .optimize = optimize,
    }));
    dev_host.addImport("native-message", b.createModule(.{
        .root_source_file = ziggy.dependency.path("packages/ziggy/core/src/lib/native-message.zig"),
        .target = target,
        .optimize = optimize,
    }));
    const dev_app = b.addOptions();
    dev_app.addOption([]const u8, "title", app.title);
    const module = b.createModule(.{
        .root_source_file = ziggy.dependency.path("packages/ziggy/dev/src/dev-host-main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addImport("ziggy-dev", dev_host);
    module.addOptions("dev_app", dev_app);
    module.linkLibrary(core_library);
    const executable = b.addExecutable(.{
        .name = host_name,
        .root_module = module,
    });
    host_step.dependOn(&b.addInstallArtifact(executable, .{}).step);

    // The supervisor runs on the machine the developer works on, whatever the target.
    const supervisor = b.addExecutable(.{
        .name = "ziggy-dev",
        .root_module = b.createModule(.{
            .root_source_file = ziggy.dependency.path("packages/ziggy/dev/src/supervisor-main.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    // The core's queue of messages, which the supervisor's progress thread is told the build has finished through.
    supervisor.root_module.addImport("message-queue", b.createModule(.{
        .root_source_file = ziggy.dependency.path("packages/ziggy/core/src/lib/message-queue.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    }));
    // The allocator the supervisor's progress thread makes for itself.
    supervisor.root_module.addImport("thread-allocator", b.createModule(.{
        .root_source_file = ziggy.dependency.path("packages/ziggy/core/src/lib/thread-allocator.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    }));
    const run_supervisor = b.addRunArtifact(supervisor);
    run_supervisor.addArgs(&.{
        "--zig",       b.graph.zig_exe,
        "--app-dir",   b.pathFromRoot("."),
        "--ziggy-dir", ziggy.dependency.builder.pathFromRoot("."),
        "--host-step", host_name,
        "--host-name", host_name,
    });
    if (b.args) |supervisor_args| {
        run_supervisor.addArgs(supervisor_args);
    }
    run_supervisor.stdio = .inherit;
    dev_step.dependOn(&run_supervisor.step);
}
