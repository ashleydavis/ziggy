const std = @import("std");
const ziggy = @import("ziggy");
const utils = @import("utils");
const ConsoleLog = @import("log").ConsoleLog;
const console = @import("log").console;
const errors = utils.errors;
const file_log = @import("log").file_log;
const FileLog = file_log.FileLog;

//
// A file log's configuration for a test, writing in the directory given, with every console option off.
//
fn testConfig(logs_dir: []const u8) file_log.IFileLogConfig {
    return .{
        .file_prefix = "test-app",
        .title = "Test App Log",
        .logs_dir = logs_dir,
        .command = null,
        .version = "9.8.7",
        .header_lines = &.{},
        .verbose = false,
        .debug = false,
        .tools = false,
    };
}

//
// The path of a directory inside the test's temporary directory, which the file log is to create.
//
fn logsDirOf(allocator: std.mem.Allocator, tmp: *const std.testing.TmpDir) ![]const u8 {
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/logs", .{&tmp.sub_path});
}

//
// Reads a whole file.
//
fn readAll(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1024 * 1024));
}

//
// Captures the console of the calling thread for a test.
//
const ConsoleCapture = struct {
    // What was written to stdout.
    stdout: std.Io.Writer.Allocating,
    // What was written to stderr.
    stderr: std.Io.Writer.Allocating,

    //
    // Makes the capture. Call begin once it is where it will stay.
    //
    fn init() ConsoleCapture {
        return .{
            .stdout = std.Io.Writer.Allocating.init(std.testing.allocator),
            .stderr = std.Io.Writer.Allocating.init(std.testing.allocator),
        };
    }

    //
    // Sends the calling thread's console lines to the capture.
    //
    fn begin(self: *ConsoleCapture) void {
        console.setCapture(&self.stdout.writer, &self.stderr.writer);
    }

    //
    // Gives the console back and frees what was captured.
    //
    fn deinit(self: *ConsoleCapture) void {
        console.setCapture(null, null);
        self.stdout.deinit();
        self.stderr.deinit();
    }
};

//
// Throws an error with the message "root cause".
//
fn throwRootCause() errors.ThrownError!void {
    return errors.throwError("root cause", .{});
}

test "start creates the logs directory and both files named with the prefix" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var capture = ConsoleCapture.init();
    defer capture.deinit();
    capture.begin();
    const allocator = std.testing.allocator;
    const logs_dir = try logsDirOf(allocator, &tmp);
    defer allocator.free(logs_dir);

    const logger = try FileLog.start(allocator, std.testing.io, testConfig(logs_dir));
    defer logger.stop(allocator, std.testing.io);

    const log_name = std.fs.path.basename(logger.getLogFilePath());
    const error_name = std.fs.path.basename(logger.getErrorLogFilePath());
    try std.testing.expect(std.mem.startsWith(u8, log_name, "test-app-"));
    try std.testing.expect(std.mem.endsWith(u8, log_name, ".log"));
    try std.testing.expect(!std.mem.endsWith(u8, log_name, "-errors.log"));
    try std.testing.expectEqual(@as(usize, "test-app-2026-10-26T09-15-04.log".len), log_name.len);
    try std.testing.expect(std.mem.startsWith(u8, error_name, "test-app-"));
    try std.testing.expect(std.mem.endsWith(u8, error_name, "-errors.log"));
    try std.testing.expectEqualStrings(std.fs.path.dirname(logger.getLogFilePath()).?, logs_dir);
    try std.Io.Dir.cwd().access(std.testing.io, logger.getErrorLogFilePath(), .{});
}

test "the header holds the title, the version, the program's lines and the command only when given" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var capture = ConsoleCapture.init();
    defer capture.deinit();
    capture.begin();
    const allocator = std.testing.allocator;
    const logs_dir = try logsDirOf(allocator, &tmp);
    defer allocator.free(logs_dir);

    var config = testConfig(logs_dir);
    config.command = "test-app import ./photos";
    config.header_lines = &.{ "--- Tool Versions ---", "Magick: 7.1" };
    const with_command = try FileLog.start(allocator, std.testing.io, config);
    const header = try readAll(allocator, with_command.getLogFilePath());
    defer allocator.free(header);
    const error_header = try readAll(allocator, with_command.getErrorLogFilePath());
    defer allocator.free(error_header);
    with_command.stop(allocator, std.testing.io);

    try std.testing.expect(std.mem.startsWith(u8, header, "=" ** 80 ++ "\nTest App Log\nStarted: "));
    try std.testing.expect(std.mem.indexOf(u8, header, "\nCommand: test-app import ./photos\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "\nWorking Directory: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "\n--- System Information ---\nPlatform: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "\nVersion: 9.8.7\n\n--- Tool Versions ---\nMagick: 7.1\n\n--- Log Start ---\n") != null);
    try std.testing.expect(std.mem.startsWith(u8, error_header, "=" ** 80 ++ "\nTest App Log (errors)\nStarted: "));
    try std.testing.expect(std.mem.indexOf(u8, error_header, "If this file contains nothing below, it means there were no errors.\n\n--- Error Log Start ---\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, error_header, "--- Log Start ---") == null);

    // Started again in another directory, so the files are new, without a command.
    const other_dir = try std.fmt.allocPrint(allocator, "{s}/other", .{logs_dir});
    defer allocator.free(other_dir);
    const without_command = try FileLog.start(allocator, std.testing.io, testConfig(other_dir));
    const plain_header = try readAll(allocator, without_command.getLogFilePath());
    defer allocator.free(plain_header);
    without_command.stop(allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, plain_header, "Command:") == null);
    try std.testing.expect(std.mem.indexOf(u8, plain_header, "\nVersion: 9.8.7\n\n--- Log Start ---\n") != null);
}

test "every level reaches the log file, and errors, exceptions and warnings the error file too, whatever the console shows" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var capture = ConsoleCapture.init();
    defer capture.deinit();
    capture.begin();
    const allocator = std.testing.allocator;
    const logs_dir = try logsDirOf(allocator, &tmp);
    defer allocator.free(logs_dir);

    const logger = try FileLog.start(allocator, std.testing.io, testConfig(logs_dir));
    const log = logger.ilog();
    log.info("info line");
    log.verbose("verbose line");
    log.@"error"("error line");
    throwRootCause() catch |err| {
        log.exception("exception line", err);
    };
    log.warn("warn line");
    log.debug("debug line");
    log.tool("magick", .{
        .stdout = "tool out",
        .stderr = "",
    });
    log.event("event line");
    const written = try readAll(allocator, logger.getLogFilePath());
    defer allocator.free(written);
    const errors_written = try readAll(allocator, logger.getErrorLogFilePath());
    defer allocator.free(errors_written);
    try std.testing.expect(logger.hasLoggedErrors());
    logger.stop(allocator, std.testing.io);

    const body = written[std.mem.indexOf(u8, written, "--- Log Start ---\n").? + "--- Log Start ---\n".len ..];
    var lines = std.mem.splitScalar(u8, body, '\n');
    const expected = [_][]const u8{
        "] [INFO] info line",
        "] [VERBOSE] verbose line",
        "] [ERROR] error line",
        "] [EXCEPTION] exception line",
        "Error: root cause",
        "] [WARN] warn line",
        "] [DEBUG] debug line",
        "] [TOOL] == magick stdout ==",
        "tool out",
        "] [EVENT] event line",
    };
    for (expected) |ending| {
        const line = lines.next().?;
        try std.testing.expect(std.mem.endsWith(u8, line, ending));
    }
    try std.testing.expect(std.mem.startsWith(u8, body, "[20"));
    try std.testing.expect(std.mem.indexOf(u8, errors_written, "] [ERROR] error line\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, errors_written, "] [EXCEPTION] exception line\nError: root cause\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, errors_written, "] [WARN] warn line\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, errors_written, "info line") == null);
    try std.testing.expect(std.mem.indexOf(u8, errors_written, "debug line") == null);

    // The console options are off, so the console showed none of the verbose, debug and tool lines.
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout.written(), "info line\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout.written(), "verbose line") == null);
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout.written(), "tool out") == null);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr.written(), "debug line") == null);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr.written(), "error line\n") != null);
}

test "the console options of a file log decide what the console shows" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var capture = ConsoleCapture.init();
    defer capture.deinit();
    capture.begin();
    const allocator = std.testing.allocator;
    const logs_dir = try logsDirOf(allocator, &tmp);
    defer allocator.free(logs_dir);

    var config = testConfig(logs_dir);
    config.verbose = true;
    config.debug = true;
    config.tools = true;
    const logger = try FileLog.start(allocator, std.testing.io, config);
    defer logger.stop(allocator, std.testing.io);
    const log = logger.ilog();
    log.verbose("verbose line");
    log.debug("debug line");
    log.tool("magick", .{
        .stdout = "tool out",
        .stderr = null,
    });
    try std.testing.expect(log.verboseEnabled());
    try std.testing.expectEqualStrings("verbose line\n== magick stdout ==\ntool out\n", capture.stdout.written());
    try std.testing.expectEqualStrings("debug line\n", capture.stderr.written());
}

test "close writes the footers, prints the error file's path only when it has entries and does nothing a second time" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var capture = ConsoleCapture.init();
    defer capture.deinit();
    capture.begin();
    const allocator = std.testing.allocator;
    const logs_dir = try logsDirOf(allocator, &tmp);
    defer allocator.free(logs_dir);

    const quiet = try FileLog.start(allocator, std.testing.io, testConfig(logs_dir));
    quiet.ilog().info("all well");
    try quiet.close(std.testing.io);
    try quiet.close(std.testing.io);
    quiet.ilog().info("after close");
    const quiet_written = try readAll(allocator, quiet.getLogFilePath());
    defer allocator.free(quiet_written);
    const quiet_errors = try readAll(allocator, quiet.getErrorLogFilePath());
    defer allocator.free(quiet_errors);
    quiet.stop(allocator, std.testing.io);
    try std.testing.expect(std.mem.endsWith(u8, quiet_written, "=" ** 80 ++ "\n"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, quiet_written, "\n--- Log End ---\nCompleted: "));
    try std.testing.expect(std.mem.indexOf(u8, quiet_written, "\nDuration: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, quiet_written, "after close") == null);
    try std.testing.expect(std.mem.indexOf(u8, quiet_errors, "--- Error Log End ---") == null);
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout.written(), "were logged to") == null);

    const other_dir = try std.fmt.allocPrint(allocator, "{s}/other", .{logs_dir});
    defer allocator.free(other_dir);
    const noisy = try FileLog.start(allocator, std.testing.io, testConfig(other_dir));
    noisy.ilog().warn("careful");
    try noisy.close(std.testing.io);
    const noisy_errors = try readAll(allocator, noisy.getErrorLogFilePath());
    defer allocator.free(noisy_errors);
    const expected_message = try std.fmt.allocPrint(allocator, "Errors, warnings and exceptions were logged to: {s}\n", .{noisy.getErrorLogFilePath()});
    defer allocator.free(expected_message);
    noisy.stop(allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, noisy_errors, "\n--- Error Log End ---\nCompleted: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout.written(), expected_message) != null);
}

test "close returns a failure to write the footer and a failed line is reported on stderr" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var capture = ConsoleCapture.init();
    defer capture.deinit();
    capture.begin();
    const allocator = std.testing.allocator;
    const logs_dir = try logsDirOf(allocator, &tmp);
    defer allocator.free(logs_dir);

    const logger = try FileLog.start(allocator, std.testing.io, testConfig(logs_dir));
    defer logger.stop(allocator, std.testing.io);
    // A directory where the log file was, which a file cannot be opened over.
    try std.Io.Dir.cwd().deleteFile(std.testing.io, logger.getLogFilePath());
    try std.Io.Dir.cwd().createDirPath(std.testing.io, logger.getLogFilePath());
    logger.ilog().info("lost line");
    const expected_report = try std.fmt.allocPrint(allocator, "Could not write to the log file {s}: ", .{logger.getLogFilePath()});
    defer allocator.free(expected_report);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr.written(), expected_report) != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout.written(), "lost line\n") != null);
    try std.testing.expect(std.meta.isError(logger.close(std.testing.io)));
}

test "logFilePath gives a file log's log file and null for a console log" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var capture = ConsoleCapture.init();
    defer capture.deinit();
    capture.begin();
    const allocator = std.testing.allocator;
    const logs_dir = try logsDirOf(allocator, &tmp);
    defer allocator.free(logs_dir);

    const logger = try FileLog.start(allocator, std.testing.io, testConfig(logs_dir));
    defer logger.stop(allocator, std.testing.io);
    try std.testing.expectEqualStrings(logger.getLogFilePath(), logger.ilog().logFilePath().?);
    const console_log = ConsoleLog.initWith(.{
        .verbose = false,
        .debug = false,
        .tools = false,
    });
    try std.testing.expect(console_log.logFilePath() == null);
}

test "readLogDetails and getLogDetails give the path and the header up to the start of the log" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var capture = ConsoleCapture.init();
    defer capture.deinit();
    capture.begin();
    const allocator = std.testing.allocator;
    const logs_dir = try logsDirOf(allocator, &tmp);
    defer allocator.free(logs_dir);

    const logger = try FileLog.start(allocator, std.testing.io, testConfig(logs_dir));
    defer logger.stop(allocator, std.testing.io);
    logger.ilog().info("a line after the header");
    const details = try file_log.readLogDetails(allocator, std.testing.io, logger.getLogFilePath());
    defer allocator.free(details.logFilePath.?);
    defer allocator.free(details.logHeader);
    try std.testing.expectEqualStrings(logger.getLogFilePath(), details.logFilePath.?);
    try std.testing.expect(std.mem.startsWith(u8, details.logHeader, "=" ** 80 ++ "\nTest App Log\n"));
    try std.testing.expect(std.mem.endsWith(u8, details.logHeader, "--- Log Start ---"));

    const through_log = try logger.ilog().getLogDetails(allocator, std.testing.io);
    defer allocator.free(through_log.logFilePath.?);
    defer allocator.free(through_log.logHeader);
    try std.testing.expectEqualStrings(details.logHeader, through_log.logHeader);
}

test "readLogDetails gives the first 50 lines of a file with no start of log" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    for (0..60) |index| {
        try text.print(allocator, "line {d}\n", .{index});
    }
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "plain.log",
        .data = text.items,
    });
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/plain.log", .{&tmp.sub_path});
    defer allocator.free(path);
    const details = try file_log.readLogDetails(allocator, std.testing.io, path);
    defer allocator.free(details.logFilePath.?);
    defer allocator.free(details.logHeader);
    try std.testing.expect(std.mem.startsWith(u8, details.logHeader, "line 0\n"));
    try std.testing.expect(std.mem.endsWith(u8, details.logHeader, "\nline 49"));
}

test "defaultLogsDir is the program's logs directory under the temporary directory the environment names" {
    var environ_map = std.process.Environ.Map.init(std.testing.allocator);
    defer environ_map.deinit();
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) {
        try environ_map.put("TEMP", "C:\\Temp\\");
    }
    else {
        try environ_map.put("TMPDIR", "/var/tmp/");
    }
    utils.process_env.setEnvironMap(&environ_map);
    defer utils.process_env.setEnvironMap(null);
    const logs_dir = try file_log.defaultLogsDir(std.testing.allocator, "my-app");
    defer std.testing.allocator.free(logs_dir);
    const expected = try std.fs.path.join(std.testing.allocator, &.{ if (builtin.os.tag == .windows) "C:\\Temp" else "/var/tmp", "my-app", "logs" });
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, logs_dir);
}

test "a file log writes an error chain longer than 16 KB whole" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var capture = ConsoleCapture.init();
    defer capture.deinit();
    capture.begin();
    const allocator = std.testing.allocator;
    const logs_dir = try logsDirOf(allocator, &tmp);
    defer allocator.free(logs_dir);

    const logger = try FileLog.start(allocator, std.testing.io, testConfig(logs_dir));
    const longText = try allocator.alloc(u8, 12000);
    defer allocator.free(longText);
    @memset(longText, 'x');
    errors.recordError("Error", "{s}", .{longText});
    logger.ilog().exception("Something failed", errors.throwErrorWithCause("{s}", .{longText}));
    const written = try readAll(allocator, logger.getLogFilePath());
    defer allocator.free(written);
    logger.stop(allocator, std.testing.io);
    const expected = try std.mem.concat(allocator, u8, &.{ "] [EXCEPTION] Something failed\nError: ", longText, "\nCaused by:\nError: ", longText, "\n" });
    defer allocator.free(expected);
    try std.testing.expect(std.mem.indexOf(u8, written, expected) != null);
}
