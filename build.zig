const std = @import("std");
const android_libc = @import("packages-zig/android-libc.zig");

//
// Builds Ziggy, the shell its apps stand on, and registers its tests. As a dependency of an app's build it gives the app the
// modules "ziggy" (the core, which the app's code imports as @import("ziggy")) and "task-queue" (the task queue and the helpers it is
// written with, for code that queues tasks without the app shell), built for the target, optimize mode and test hooks the app asks
// for. The functions below that are `pub` are what an app's build.zig calls to build its core library and its Linux and Windows
// shells; it reaches them with @import("ziggy") in its build.zig.
//
pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    // Whether the test hooks (the test control connection) are built into the core. Never for a release.
    const test_hooks = b.option(bool, "test-hooks", "Build the test hooks (the test control connection) into the core (never for a release)") orelse false;
    // ReleaseSafe by default: the tests keep the safety checks.
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Prioritize performance, safety, or binary size (default: ReleaseSafe)") orelse .ReleaseSafe;

    const task_queue = b.addModule("task-queue", .{
        .root_source_file = b.path("packages/ziggy/task-queue/src/index.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const core = b.addModule("ziggy", .{
        .root_source_file = b.path("packages/ziggy/core/src/index.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    try configureCore(b, core, target, optimize, test_hooks, task_queue);

    // The unit tests of Ziggy's core, which run the core with the test hooks compiled in.
    const test_step = b.step("test", "Run the unit tests of Ziggy (the core, the task queue and the shells) and of the Ziggy example");
    const test_core = b.createModule(.{
        .root_source_file = b.path("packages/ziggy/core/src/index.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    try configureCore(b, test_core, target, optimize, true, task_queue);
    const core_test_binary_step = b.step("test-binary-ziggy-core", "Build the unit test program of Ziggy's core and install it to test-bin without running it");
    try addDirectoryTests(b, test_step, "packages/ziggy/core", &.{
        .{
            .name = "ziggy",
            .module = test_core,
        },
        .{
            .name = "task-queue",
            .module = task_queue,
        },
    }, target, optimize, core_test_binary_step);

    // The unit tests of the task queue and its helpers.
    try addDirectoryTests(b, test_step, "packages/ziggy/task-queue", &.{
        .{
            .name = "task-queue",
            .module = task_queue,
        },
    }, target, optimize, null);

    // The console writing to the real stdout, which a unit test cannot see: a program writes through it and the build checks what it
    // printed.
    const console_stdout_module = b.createModule(.{
        .root_source_file = b.path("packages/ziggy/task-queue/src/test/fixtures/console-stdout.zig"),
        .target = target,
        .optimize = optimize,
    });
    console_stdout_module.addImport("task-queue", task_queue);
    const run_console_stdout = b.addRunArtifact(b.addExecutable(.{
        .name = "console-stdout",
        .root_module = console_stdout_module,
    }));
    run_console_stdout.expectStdOutEqual("logged to stdout\ndebugged to stdout\n");
    test_step.dependOn(&run_console_stdout.step);

    // The unit tests of the parts of the shells that do not need the platform's libraries.
    const linux_tests_module = b.createModule(.{
        .root_source_file = b.path("packages/ziggy/native/linux/src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{
        .name = "ziggy-shell-linux",
        .root_module = linux_tests_module,
    })).step);
    const windows_tests_module = b.createModule(.{
        .root_source_file = b.path("packages/ziggy/native/windows/src/tests.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{
        .name = "ziggy-shell-windows",
        .root_module = windows_tests_module,
    })).step);

    // The tests of the Ziggy example, which is a build of its own that takes Ziggy as a dependency, as every app does. Its core embeds
    // its built UI, which its build reads when it starts, so the UI is built first and the example's build is then run as a program
    // of its own.
    const bundle_example_ui = b.addSystemCommand(&.{ "bun", "run", "bundle:ui" });
    bundle_example_ui.setCwd(b.path("apps/ziggy-example"));
    bundle_example_ui.has_side_effects = true;
    const test_example = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "test", "--summary", "all" });
    test_example.setCwd(b.path("apps/ziggy-example"));
    test_example.has_side_effects = true;
    test_example.step.dependOn(&bundle_example_ui.step);
    test_step.dependOn(&test_example.step);
}

//
// Gives the core module its build options and imports. The test hooks compile in the test control connection: they are off for a
// release and on for the tests and for the builds the smoke tests drive.
//
fn configureCore(
    b: *std.Build,
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    test_hooks: bool,
    task_queue: *std.Build.Module,
) !void {
    const options = b.addOptions();
    options.addOption(bool, "test_hooks", test_hooks);
    module.addOptions("build_options", options);
    module.addImport("task-queue", task_queue);
    module.addAnonymousImport("ziggy-inject", .{
        .root_source_file = b.path("packages/ziggy/bridge/inject/ziggy-inject.js"),
    });

    // The Android shell reaches the core through JNI, written in Zig against the NDK's own jni.h. Only an Android target has that
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

    // The core, which the app's code imports as @import("ziggy").
    module: *std.Build.Module,

    // The task queue and its helpers, which the app's code imports as @import("task-queue").
    task_queue: *std.Build.Module,
};

//
// Gets Ziggy for an app's build, from the dependency named "ziggy" in the app's build.zig.zon, built for the target and optimize mode,
// with the test hooks or without. A build that needs both (an app with test hooks off and its unit tests, which run with them on) asks
// twice.
//
pub fn dependency(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, test_hooks: bool) IZiggy {
    const ziggy_dependency = b.dependency("ziggy", .{
        .target = target,
        .optimize = optimize,
        .@"test-hooks" = test_hooks,
    });
    return .{
        .dependency = ziggy_dependency,
        .module = ziggy_dependency.module("ziggy"),
        .task_queue = ziggy_dependency.module("task-queue"),
    };
}

//
// What addAppCore needs to know about an app's core.
//
pub const IAppCore = struct {
    // The name of the app, which names its library (`lib<name with dashes as underscores>.a`) and its step (`<name>-core`).
    name: []const u8,
    // The name the step's description uses for the app, such as "the Ziggy example".
    title: []const u8,
    // The root source file of the app's core, relative to the app's build root.
    root_source_file: []const u8,
    // The directory of the app's built UI, relative to the app's build root, which is embedded in the core as "ui-files".
    ui_directory: []const u8,
    // The modules the app's core imports besides "ziggy" and "ui-files".
    imports: []const IImport,
};

//
// The libraries addAppCore builds.
//
pub const IAppCoreLibraries = struct {
    // The static library, which the shells link (the Linux and Windows shells here, and the Xcode projects).
    static_library: *std.Build.Step.Compile,
    // The shared library, for an Android target only, which the Android shell loads.
    shared_library: ?*std.Build.Step.Compile,
};

//
// Builds an app's core for the target, installed by the `<name>-core` step: a static library (with ziggy.h installed beside it) and,
// for Android, a shared one. The platform shells that are not Zig (the Xcode projects and the Android project) are built by the app's
// scripts, which ask this step for the libraries.
//
pub fn addAppCore(
    b: *std.Build,
    ziggy: IZiggy,
    app: IAppCore,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !IAppCoreLibraries {
    const core_step = b.step(b.fmt("{s}-core", .{app.name}), b.fmt("Build {s}'s core as a library for the target", .{app.title}));
    const library_name = try b.allocator.dupe(u8, app.name);
    std.mem.replaceScalar(u8, library_name, '-', '_');
    const static_library = b.addLibrary(.{
        .name = library_name,
        .root_module = try createAppCoreModule(b, ziggy, app, target, optimize),
        .linkage = .static,
    });
    // The Xcode linker is not Zig's, so the compiler runtime (for example ___zig_probe_stack) must travel inside the archive.
    static_library.bundle_compiler_rt = true;
    core_step.dependOn(&b.addInstallArtifact(static_library, .{}).step);
    core_step.dependOn(&b.addInstallFileWithDir(ziggy.dependency.path("packages/ziggy/core/src/lib/ziggy.h"), .header, "ziggy.h").step);
    var shared_library: ?*std.Build.Step.Compile = null;
    if (target.result.abi.isAndroid()) {
        const library = b.addLibrary(.{
            .name = library_name,
            .root_module = try createAppCoreModule(b, ziggy, app, target, optimize),
            .linkage = .dynamic,
        });
        // Android 15 and later can run with 16 KiB memory pages, and a library is loaded only when its segments are aligned to the page
        // size, so they are aligned to the larger one.
        library.link_z_max_page_size = 16384;
        core_step.dependOn(&b.addInstallArtifact(library, .{}).step);
        shared_library = library;
    }
    return .{
        .static_library = static_library,
        .shared_library = shared_library,
    };
}

//
// Makes the root module of an app's core library: the app's root source file, importing Ziggy's core, the app's built UI and the
// app's own modules.
//
fn createAppCoreModule(
    b: *std.Build,
    ziggy: IZiggy,
    app: IAppCore,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !*std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path(app.root_source_file),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addImport("ziggy", ziggy.module);
    module.addImport("ui-files", try embedUi(b, ziggy.module, "ziggy", app.ui_directory));
    for (app.imports) |import| {
        module.addImport(import.name, import.module);
    }
    return module;
}

//
// Makes the module of the list of the bundled UI's files and the lookup in it, which the shells of the platforms that embed the UI
// import as "ui-files".
//
fn createUiFilesModule(
    b: *std.Build,
    ziggy: IZiggy,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = ziggy.dependency.path("packages/ziggy/core/src/lib/ui-files.zig"),
        .target = target,
        .optimize = optimize,
    });
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
// Makes the module that holds an app's built UI, a list of every file under the UI's directory (a path relative to the root of
// the repository), each embedded with @embedFile. Pass the module to the app's shell code and give the list to AppConfig.ui_files.
// The directory is read every time the build runs, so whatever the UI build produced is what gets embedded, with no list of files
// to keep up to date. A changed file rebuilds the executable. When the directory is missing or has no index.html, which means the
// UI was not built first, the module does not compile and says so: the build of anything that does not use the UI is not
// affected.
//
pub fn embedUi(b: *std.Build, shell_module: *std.Build.Module, shell_import_name: []const u8, ui_directory: []const u8) !*std.Build.Module {
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
        try source.appendSlice(b.allocator, b.fmt("const shell = @import(\"{s}\");\n\npub const files = [_]shell.UiFile{{\n", .{shell_import_name}));
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
        // A UI directory that is missing means the UI was not built, which the compile error below says. Any other failure is
        // reported as it is.
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
        module.addImport(shell_import_name, shell_module);
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
// Finds an installed runtime library by its file name and returns its full path. Fails the build, saying which library is missing and
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
// from `directory`.
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
        try test_root_source.appendSlice(b.allocator, b.fmt("    _ = @import(\"src/test/{s}\");\n", .{entry.path}));
    }
    try test_root_source.appendSlice(b.allocator, "}\n");
    const test_module = b.createModule(.{
        .root_source_file = test_files.add("all-tests.zig", test_root_source.items),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    for (imports) |import| {
        test_module.addImport(import.name, import.module);
    }
    // Zig does not look in the iOS SDK for libSystem unless it is given the library directory, which --sysroot then makes the SDK's.
    // A test program for the iOS simulator failed to link with "unable to find libSystem system library" with only the sysroot given,
    // and linked past that once /usr/lib was added as a library path.
    if (target.result.os.tag == .ios) {
        test_module.addLibraryPath(.{
            .cwd_relative = "/usr/lib",
        });
    }
    const unit_test = b.addTest(.{
        .name = std.fs.path.basename(directory),
        .root_module = test_module,
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
// The shared libraries the Linux shell links, by their full file names, which is what a program built against the development packages
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
};

//
// What differs between the apps that Ziggy's Linux and Windows shells are built for.
//
pub const IShellApp = struct {
    // The name of the app, which names its executable and its steps (`<name>-linux`, `<name>-windows`, `<name>-windows-check`).
    name: []const u8,
    // The name the steps' descriptions use for the app, such as "the Ziggy example".
    title: []const u8,
    // The directory of the app relative to the app's build root ("." for the build root itself), under which its shells
    // (`shells/linux/src/main.zig`, `shells/windows/src/main.zig`) and the WebView2 SDK
    // (`webview2-sdk`) are.
    directory: []const u8,
    // The directory of the app's built UI, relative to the app's build root, which is embedded in the executable.
    ui_directory: []const u8,
    // The PNG file of the app's window icon on Linux, which the shell's `app-icon` import gives to the app's main file, or null for none.
    linux_icon: ?[]const u8,
    // The Windows resource script of the app's executable icon, or null for none.
    windows_resource: ?[]const u8,
};

//
// Builds an app's Linux shell, installed to zig-out/bin/<name> by the `<name>-linux` step. The shell is Zig that talks to GTK 3 and
// WebKitGTK 4.1 through their C headers, and to the core through ziggy.h. The built UI (made by `bun run bundle:ui`) is embedded in
// the executable, so the executable is the whole app.
//
pub fn addLinuxShell(
    b: *std.Build,
    app: IShellApp,
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
    const shell_module = b.createModule(.{
        .root_source_file = ziggy.dependency.path("packages/ziggy/native/linux/src/index.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    shell_module.addImport("c", translate_c.createModule());
    shell_module.addImport("ui-files", createUiFilesModule(b, ziggy, target, optimize));
    shell_module.addImport("host-reply", b.createModule(.{
        .root_source_file = ziggy.dependency.path("packages/ziggy/core/src/lib/host-reply.zig"),
        .target = target,
        .optimize = optimize,
    }));
    for (runtime_library_paths.items) |path| {
        shell_module.addObjectFile(.{
            .cwd_relative = path,
        });
    }

    const module = b.createModule(.{
        .root_source_file = b.path(appPath(b, app.directory, "shells/linux/src/main.zig")),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addImport("ziggy-shell-linux", shell_module);
    if (app.linux_icon) |icon| {
        module.addAnonymousImport("app-icon", .{
            .root_source_file = b.path(icon),
        });
    }
    module.addImport("ui-files", try embedUi(b, shell_module, "ziggy-shell-linux", app.ui_directory));
    module.linkLibrary(core_library);
    const executable = b.addExecutable(.{
        .name = app.name,
        .root_module = module,
    });
    step.dependOn(&b.addInstallArtifact(executable, .{}).step);
}

//
// Builds an app's Windows shell, installed to zig-out/<name>/<name>.exe by the `<name>-windows` step. The shell is Zig that talks to
// Win32 and to WebView2 through their C headers. The executable is the whole app: the built UI is embedded in it and WebView2's
// loader is linked into it. The UI is expected in the app's UI directory (bun run bundle:ui) and the loader's static library in the
// app's webview2-sdk directory (the setup script), and the build fails when either is missing. The `<name>-windows-check` step
// compiles the shell without linking it, for a machine that cannot link a Windows executable. With compile_only the loader is not
// linked, which is how that machine checks the shell.
//
pub fn addWindowsShell(
    b: *std.Build,
    app: IShellApp,
    compile_only: bool,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    ziggy: IZiggy,
    core_library: *std.Build.Step.Compile,
) !void {
    const step = b.step(b.fmt("{s}-windows", .{app.name}), b.fmt("Build {s} for Windows, installed to {s}/{s}.exe", .{ app.title, app.name, app.name }));
    const check_step = b.step(b.fmt("{s}-windows-check", .{app.name}), b.fmt("Compile {s}'s Windows shell for type errors without linking", .{app.title}));
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

    const shell_module = b.createModule(.{
        .root_source_file = ziggy.dependency.path("packages/ziggy/native/windows/src/index.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    shell_module.addImport("c", translate_c.createModule());
    shell_module.addImport("ui-files", createUiFilesModule(b, ziggy, target, optimize));
    shell_module.linkSystemLibrary("user32", .{});
    shell_module.linkSystemLibrary("kernel32", .{});
    shell_module.linkSystemLibrary("ole32", .{});
    shell_module.linkSystemLibrary("shell32", .{});
    shell_module.linkSystemLibrary("uuid", .{});
    // The WebView2 static loader reads the registry and writes event traces, which live in advapi32.
    shell_module.linkSystemLibrary("advapi32", .{});
    // Without the library the module still compiles, which is how a machine that cannot link a Windows executable checks the shell, but
    // nothing built from it links.
    if (!compile_only) {
        shell_module.addObjectFile(b.path(appPath(b, app.directory, b.fmt("webview2-sdk/{s}/WebView2LoaderStatic.lib", .{sdk_architecture}))));
    }

    const module = b.createModule(.{
        .root_source_file = b.path(appPath(b, app.directory, "shells/windows/src/main.zig")),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addImport("ziggy-shell-windows", shell_module);
    if (app.windows_resource) |resource| {
        module.addWin32ResourceFile(.{
            .file = b.path(resource),
        });
    }
    module.addImport("ui-files", try embedUi(b, shell_module, "ziggy-shell-windows", app.ui_directory));
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

    // Compiles the shell without linking it, for a machine that cannot link a Windows executable. The link needs Microsoft's toolchain
    // because the SDK's static loader is built with it.
    // The core library is not linked into the object: a COFF object cannot hold the library's objects, and the check has no link to
    // resolve.
    const check_module = b.createModule(.{
        .root_source_file = b.path(appPath(b, app.directory, "shells/windows/src/main.zig")),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    check_module.addImport("ziggy-shell-windows", shell_module);
    // The icon resource is left out: a resource is not Zig, so it has no type errors to find, and an object cannot hold it ("coff does
    // not support linking multiple objects into one").
    check_module.addImport("ui-files", try embedUi(b, shell_module, "ziggy-shell-windows", app.ui_directory));
    check_step.dependOn(&b.addObject(.{
        .name = b.fmt("{s}-check", .{app.name}),
        .root_module = check_module,
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
