const std = @import("std");
const builtin = @import("builtin");
const utils = @import("ziggy").utils;
const MuteLog = @import("ziggy").log.mute_log.MuteLog;
const MemoryLog = @import("ziggy").log.memory_log.MemoryLog;
const exec = @import("ziggy").exec.exec;

test "exec runs the command in the shell and returns its output" {
    // iOS does not let an app start a process, so this command has no shell to run in there.
    if (!std.process.can_spawn) {
        return error.SkipZigTest;
    }

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // The command runs in cmd.exe on Windows, which has its own syntax and ends lines with CRLF.
    if (builtin.os.tag == .windows) {
        const result = try exec(arena.allocator(), std.testing.io, "echo hello&& echo oops>&2");
        try std.testing.expectEqualStrings("hello\r\n", result.stdout);
        try std.testing.expectEqualStrings("oops\r\n", result.stderr);
    }
    else {
        const result = try exec(arena.allocator(), std.testing.io, "echo hello && echo oops 1>&2");
        try std.testing.expectEqualStrings("hello\n", result.stdout);
        try std.testing.expectEqualStrings("oops\n", result.stderr);
    }
}

test "exec fails with Node's message when the command exits with a non-zero code" {
    // iOS does not let an app start a process, so this command has no shell to run in there.
    if (!std.process.can_spawn) {
        return error.SkipZigTest;
    }

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // The command runs in cmd.exe on Windows, which has its own syntax and ends lines with CRLF.
    if (builtin.os.tag == .windows) {
        try std.testing.expectError(error.Thrown, exec(arena.allocator(), std.testing.io, "echo broken>&2& exit 3"));
        try std.testing.expectEqualStrings("Command failed: echo broken>&2& exit 3\nbroken\r\n", utils.errors.lastErrorMessage());
    }
    else {
        try std.testing.expectError(error.Thrown, exec(arena.allocator(), std.testing.io, "echo broken 1>&2; exit 3"));
        try std.testing.expectEqualStrings("Command failed: echo broken 1>&2; exit 3\nbroken\n", utils.errors.lastErrorMessage());
    }
}

test "exec passes process.env to the command" {
    // iOS does not let an app start a process, so this command has no shell to run in there.
    if (!std.process.can_spawn) {
        return error.SkipZigTest;
    }

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environ_map = std.process.Environ.Map.init(arena.allocator());
    try environ_map.put("PHOTOSPHERE_EXEC_TEST", "from-env");
    utils.process_env.setEnvironMap(&environ_map);
    defer utils.process_env.setEnvironMap(null);

    // cmd.exe on Windows expands %NAME% and ends lines with CRLF.
    if (builtin.os.tag == .windows) {
        const result = try exec(arena.allocator(), std.testing.io, "echo %PHOTOSPHERE_EXEC_TEST%");
        try std.testing.expectEqualStrings("from-env\r\n", result.stdout);
    }
    else {
        const result = try exec(arena.allocator(), std.testing.io, "echo $PHOTOSPHERE_EXEC_TEST");
        try std.testing.expectEqualStrings("from-env\n", result.stdout);
    }
}

test "execLogged returns the output of the command" {
    const console_log = MuteLog.init();
    // iOS does not let an app start a process, so this command has no shell to run in there.
    if (!std.process.can_spawn) {
        return error.SkipZigTest;
    }

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try @import("ziggy").exec.execLogged(arena.allocator(), std.testing.io, console_log, "echo", "echo hello", null);
    const expected = if (builtin.os.tag == .windows) "hello\r\n" else "hello\n";
    try std.testing.expectEqualStrings(expected, result.stdout);
}


test "execLogged writes the command, what the tool wrote and a failure to the log it is given" {
    // iOS does not let an app start a process, so this command has no shell to run in there.
    if (!std.process.can_spawn) {
        return error.SkipZigTest;
    }

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Verbose and tool lines are on, which the default console log leaves out, so they show that this log was the one written to.
    const memory = try MemoryLog.init(std.testing.allocator, .{
        .verbose = true,
        .debug = false,
        .tools = true,
    });
    defer memory.deinit();
    const given = memory.log;
    _ = try @import("ziggy").exec.execLogged(arena.allocator(), std.testing.io, given, "echo", "echo hello", null);
    try std.testing.expect(std.mem.indexOf(u8, memory.stdout(), "Executing echo with command: \"echo hello\"\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, memory.stdout(), "== echo stdout ==\nhello") != null);
    try std.testing.expectError(error.Thrown, @import("ziggy").exec.execLogged(arena.allocator(), std.testing.io, given, "sh", "exit 3", null));
    try std.testing.expect(std.mem.indexOf(u8, memory.stderr(), "Failed to execute command: exit 3\n") != null);
}
test "execLogged reports a command that fails as a failure to execute it" {
    const console_log = MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.Thrown, @import("ziggy").exec.execLogged(arena.allocator(), std.testing.io, console_log, "sh", "exit 3", null));
    try std.testing.expectEqualStrings("Failed to execute command: exit 3", utils.errors.lastErrorMessage());
}

//
// A validation that always fails.
//
fn failValidation(context: *anyopaque, allocator: std.mem.Allocator, io: std.Io) anyerror!?[]const u8 {
    _ = context;
    _ = allocator;
    _ = io;
    return "the output is missing";
}

test "execLogged reports a failed validation as a failure to execute the command" {
    const console_log = MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var unused: u8 = 0;
    try std.testing.expectError(error.Thrown, @import("ziggy").exec.execLogged(arena.allocator(), std.testing.io, console_log, "echo", "echo hello", .{ .context = &unused, .function = failValidation }));
    try std.testing.expectEqualStrings("Failed to execute command: echo hello", utils.errors.lastErrorMessage());
}

test "exec hands the quotes in the command to the shell untouched" {
    // iOS does not let an app start a process, so this command has no shell to run in there.
    if (!std.process.can_spawn) {
        return error.SkipZigTest;
    }

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Quoted arguments holding spaces and %, like `identify -format "%w %h" "<file>"`. cmd.exe on
    // Windows echoes the arguments as they reach it, quotes included, and ends lines with CRLF.
    if (builtin.os.tag == .windows) {
        const result = try exec(arena.allocator(), std.testing.io, "echo \"%w %h\" \"file name.jpg\"");
        try std.testing.expectEqualStrings("\"%w %h\" \"file name.jpg\"\r\n", result.stdout);
    }
    else {
        const result = try exec(arena.allocator(), std.testing.io, "echo \"%w %h\" \"file name.jpg\"");
        try std.testing.expectEqualStrings("%w %h file name.jpg\n", result.stdout);
    }
}

test "exec reads stdout and stderr together so a command filling stderr does not block" {
    // iOS does not let an app start a process, so this command has no shell to run in there.
    if (!std.process.can_spawn) {
        return error.SkipZigTest;
    }

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // More than a pipe buffer holds goes to stderr before anything goes to stdout.
    if (builtin.os.tag == .windows) {
        const result = try exec(arena.allocator(), std.testing.io, "(for /L %i in (1,1,10000) do @echo stderr line %i>&2)& echo done");
        try std.testing.expectEqualStrings("done\r\n", result.stdout);
        try std.testing.expect(result.stderr.len > 128 * 1024);
    }
    else {
        const result = try exec(arena.allocator(), std.testing.io, "i=0; while [ $i -lt 10000 ]; do echo stderr line $i 1>&2; i=$((i+1)); done; echo done");
        try std.testing.expectEqualStrings("done\n", result.stdout);
        try std.testing.expect(result.stderr.len > 128 * 1024);
    }
}

//
// Writes a file of the given number of bytes to a unique path under the package's .zig-cache directory.
//
fn writeFileOfSize(allocator: std.mem.Allocator, io: std.Io, size: usize) ![]const u8 {
    var random_bytes: [8]u8 = undefined;
    io.random(&random_bytes);
    const filePath = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/photosphere-exec-test-{x}.txt", .{std.mem.readInt(u64, &random_bytes, .little)});
    const data = try allocator.alloc(u8, size);
    @memset(data, 'a');
    try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(filePath).?);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = filePath,
        .data = data,
    });
    return filePath;
}

//
// Prints a file to stdout, or to stderr when toStderr is true, in the shell exec runs.
//
fn printFileCommand(allocator: std.mem.Allocator, filePath: []const u8, toStderr: bool) ![]const u8 {
    const printer = if (builtin.os.tag == .windows) "type" else "cat";
    const nativePath = if (builtin.os.tag == .windows) try std.mem.replaceOwned(u8, allocator, filePath, "/", "\\") else filePath;
    const redirect = if (toStderr) " 1>&2" else "";
    return std.fmt.allocPrint(allocator, "{s} \"{s}\"{s}", .{ printer, nativePath, redirect });
}

test "exec takes up to maxBuffer (1 MiB) of output, as Bun's exec does" {
    // iOS does not let an app start a process, so this command has no shell to run in there.
    if (!std.process.can_spawn) {
        return error.SkipZigTest;
    }

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const filePath = try writeFileOfSize(allocator, io, 1024 * 1024);
    defer std.Io.Dir.cwd().deleteFile(io, filePath) catch {};

    const toStdout = try exec(allocator, io, try printFileCommand(allocator, filePath, false));
    try std.testing.expectEqual(@as(usize, 1024 * 1024), toStdout.stdout.len);
    const toStderr = try exec(allocator, io, try printFileCommand(allocator, filePath, true));
    try std.testing.expectEqual(@as(usize, 1024 * 1024), toStderr.stderr.len);
}

test "exec fails with Bun's RangeError when the command writes more than maxBuffer to stdout or stderr" {
    // iOS does not let an app start a process, so this command has no shell to run in there.
    if (!std.process.can_spawn) {
        return error.SkipZigTest;
    }

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const filePath = try writeFileOfSize(allocator, io, 1024 * 1024 + 1);
    defer std.Io.Dir.cwd().deleteFile(io, filePath) catch {};

    try std.testing.expectError(error.Thrown, exec(allocator, io, try printFileCommand(allocator, filePath, false)));
    try std.testing.expectEqualStrings("RangeError", utils.errors.lastErrorName());
    try std.testing.expectEqualStrings("stdout maxBuffer length exceeded", utils.errors.lastErrorMessage());

    try std.testing.expectError(error.Thrown, exec(allocator, io, try printFileCommand(allocator, filePath, true)));
    try std.testing.expectEqualStrings("RangeError", utils.errors.lastErrorName());
    try std.testing.expectEqualStrings("stderr maxBuffer length exceeded", utils.errors.lastErrorMessage());
}

test "exec fails naming the reason where the system does not let an app start a process" {
    // Only iOS and its kind are covered: everywhere else starts the command, which the tests above check.
    if (std.process.can_spawn) {
        return error.SkipZigTest;
    }

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.Thrown, exec(arena.allocator(), std.testing.io, "echo hello"));
    try std.testing.expectEqualStrings("Command failed: echo hello\nOperationUnsupported", utils.errors.lastErrorMessage());
}
