//
// The file log: the main thread's log once a program starts it. It writes every line to a log file and every error, exception and
// warning to an error log file as well, and passes each line on to a console log with the program's console options. The files belong
// to the thread that started the log, which alone writes them. A worker's lines reach that thread as messages and are written there
// through this log's ordinary functions. See docs/user-guide/logging.md.
//
// The log keeps no Io and no allocator: a log function is given neither, so each write makes its own for the call, as a worker's log
// does (thread-log.zig).
//

const std = @import("std");
const builtin = @import("builtin");
const log_lib = @import("log.zig");
const console = @import("console.zig");
const wrapped_error = @import("utils").wrapped_error;
const temp_dir = @import("utils").temp_dir;
const timestamp_provider = @import("utils").timestamp_provider;
const ThreadAllocator = @import("utils").thread_allocator.ThreadAllocator;

const ILog = log_lib.ILog;
const ILogDetails = log_lib.ILogDetails;
const ILogLine = log_lib.ILogLine;
const IToolOutput = log_lib.IToolOutput;
const LogLevel = log_lib.LogLevel;
const ConsoleLog = log_lib.ConsoleLog;
const Date = timestamp_provider.Date;

//
// The line of '=' characters that frames the headers and footers.
//
const rule_line = "=" ** 80;

//
// The line that ends the header of the log file, which readLogDetails reads up to.
//
const log_start_marker = "--- Log Start ---";

//
// How a program configures its file log.
//
pub const IFileLogConfig = struct {
    // The start of both file names: <file_prefix>-<start time>.log and <file_prefix>-<start time>-errors.log.
    file_prefix: []const u8,
    // The first line of the log file's header. The error file's is this followed by " (errors)".
    title: []const u8,
    // The directory both files go in, created when it is not there.
    logs_dir: []const u8,
    // The command line written into the header as "Command:", or null to leave the line out.
    command: ?[]const u8,
    // The program's version, written into the header, or null for a program that gives none, whose header has no version line.
    version: ?[]const u8,
    // Extra lines for the header, after the system information, such as the versions of the tools the program runs.
    header_lines: []const []const u8,
    // Shows verbose lines on the console.
    verbose: bool,
    // Shows debug lines on the console.
    debug: bool,
    // Shows the output of tools on the console.
    tools: bool,
};

//
// The file log. Make one with start.
//
pub const FileLog = struct {
    // The path of the log file.
    log_file: []const u8,
    // The path of the error log file.
    error_log_file: []const u8,
    // When the log was started, in milliseconds since the Unix epoch.
    start_ms: i64,
    // True once close was called, after which nothing more is written to the files.
    is_closed: bool,
    // True once an error, an exception or a warning has been written to the error log file.
    has_errors: bool,
    // The console log every line is passed on to, with the program's console options.
    console_log: ConsoleLog,

    //
    // Creates the logs directory when it is not there and writes both files with their headers. It does not install the log anywhere:
    // the caller passes `ilog()` to whatever logs to it. The log and its paths are allocated with the allocator, which stop frees them
    // with.
    //
    pub fn start(allocator: std.mem.Allocator, io: std.Io, config: IFileLogConfig) !*FileLog {
        const start_ms = std.Io.Clock.real.now(io).toMilliseconds();
        try std.Io.Dir.cwd().createDirPath(io, config.logs_dir);
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const start_iso = try (Date{ .epochMilliseconds = start_ms }).toISOString(arena);
        const file_timestamp = try arena.dupe(u8, start_iso[0..19]);
        std.mem.replaceScalar(u8, file_timestamp, ':', '-');
        std.mem.replaceScalar(u8, file_timestamp, '.', '-');
        const log_file = try std.fs.path.join(allocator, &.{ config.logs_dir, try std.mem.concat(arena, u8, &.{ config.file_prefix, "-", file_timestamp, ".log" }) });
        errdefer allocator.free(log_file);
        const error_log_file = try std.fs.path.join(allocator, &.{ config.logs_dir, try std.mem.concat(arena, u8, &.{ config.file_prefix, "-", file_timestamp, "-errors.log" }) });
        errdefer allocator.free(error_log_file);
        const logger = try allocator.create(FileLog);
        errdefer allocator.destroy(logger);
        logger.* = .{
            .log_file = log_file,
            .error_log_file = error_log_file,
            .start_ms = start_ms,
            .is_closed = false,
            .has_errors = false,
            .console_log = .{
                .verbose_enabled = config.verbose,
                .debug_enabled = config.debug,
                .tools_enabled = config.tools,
            },
        };
        const common_header = try buildCommonHeader(arena, io, config, start_iso);
        try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = log_file,
            .data = try std.mem.concat(arena, u8, &.{ rule_line, "\n", config.title, "\n", common_header, log_start_marker, "\n" }),
        });
        try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = error_log_file,
            .data = try std.mem.concat(arena, u8, &.{
                rule_line,
                "\n",
                config.title,
                " (errors)\n",
                common_header,
                "If this file contains nothing below, it means there were no errors.\n\n--- Error Log Start ---\n",
            }),
        });
        return logger;
    }

    //
    // Closes the log, reporting on stderr a failure to write the footers, and frees the log. Nothing may log to it afterwards, so a
    // caller that made it a thread's log puts that log back first. Call it on the thread that started the log, with the allocator it was
    // started with.
    //
    pub fn stop(self: *FileLog, allocator: std.mem.Allocator, io: std.Io) void {
        self.close(io) catch |err| {
            console.errorFormat("Could not write the end of the log file {s}: {s}", .{ self.log_file, @errorName(err) });
        };
        allocator.free(self.log_file);
        allocator.free(self.error_log_file);
        allocator.destroy(self);
    }

    //
    // Writes the footers and stops writing to the files. When the error log file has entries, prints its path. Calling it again does
    // nothing. Every write is tried and the first failure is returned.
    //
    pub fn close(self: *FileLog, io: std.Io) !void {
        if (self.is_closed) {
            return;
        }
        self.is_closed = true;
        var thread_allocator: ThreadAllocator = .init;
        defer thread_allocator.deinit();
        var arena_state = std.heap.ArenaAllocator.init(thread_allocator.allocator());
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const end_ms = std.Io.Clock.real.now(io).toMilliseconds();
        const end_iso = try (Date{ .epochMilliseconds = end_ms }).toISOString(arena);
        const duration_ms = end_ms - self.start_ms;
        const footer = try std.fmt.allocPrint(arena, "\n--- Log End ---\nCompleted: {s}\nDuration: {d}ms ({d:.2}s)\n{s}\n", .{
            end_iso,
            duration_ms,
            @as(f64, @floatFromInt(duration_ms)) / 1000.0,
            rule_line,
        });
        var first_error: ?anyerror = null;
        appendToFile(io, self.log_file, footer) catch |err| {
            first_error = err;
        };
        if (self.has_errors) {
            const error_footer = try std.fmt.allocPrint(arena, "\n--- Error Log End ---\nCompleted: {s}\n{s}\n", .{ end_iso, rule_line });
            appendToFile(io, self.error_log_file, error_footer) catch |err| {
                first_error = first_error orelse err;
            };
            console.log("");
            console.logFormat("Errors, warnings and exceptions were logged to: {s}", .{self.error_log_file});
        }
        if (first_error) |err| {
            return err;
        }
    }

    //
    // Gets the ILog interface for this log.
    //
    pub fn ilog(self: *FileLog) ILog {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    //
    // The path of the log file.
    //
    pub fn getLogFilePath(self: *const FileLog) []const u8 {
        return self.log_file;
    }

    //
    // The path of the error log file.
    //
    pub fn getErrorLogFilePath(self: *const FileLog) []const u8 {
        return self.error_log_file;
    }

    //
    // True once an error, an exception or a warning has been written to the error log file.
    //
    pub fn hasLoggedErrors(self: *const FileLog) bool {
        return self.has_errors;
    }

    //
    // Writes a line to the files, then to the console.
    //
    fn writeLine(self: *FileLog, line: ILogLine) void {
        if (!self.is_closed) {
            var thread_allocator: ThreadAllocator = .init;
            defer thread_allocator.deinit();
            var arena_state = std.heap.ArenaAllocator.init(thread_allocator.allocator());
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            var threaded: std.Io.Threaded = .init_single_threaded;
            threaded.allocator = arena;
            defer threaded.deinit();
            const io = threaded.io();
            const now_ms = std.Io.Clock.real.now(io).toMilliseconds();
            switch (line.level) {
                .tool => if (line.tool_output) |output| {
                    self.writeToolStream(io, arena, now_ms, line.message, "stdout", output.stdout);
                    self.writeToolStream(io, arena, now_ms, line.message, "stderr", output.stderr);
                },
                .exception => {
                    var text = line.message;
                    if (line.error_text) |error_text| {
                        if (error_text.len > 0) {
                            text = std.fmt.allocPrint(arena, "{s}\n{s}", .{ line.message, error_text }) catch @panic("out of memory writing a log line");
                        }
                    }
                    self.writeEntry(io, arena, now_ms, line.level, text);
                },
                else => self.writeEntry(io, arena, now_ms, line.level, line.message),
            }
        }
        self.console_log.writeLine(line);
    }

    //
    // Writes `== <tool> <stream> ==` and what the tool wrote to it, when it wrote anything, as one entry of the log file.
    //
    fn writeToolStream(self: *FileLog, io: std.Io, arena: std.mem.Allocator, now_ms: i64, tool_name: []const u8, stream: []const u8, text: ?[]const u8) void {
        const written = text orelse return;
        if (written.len == 0) {
            return;
        }
        const entry_text = std.fmt.allocPrint(arena, "== {s} {s} ==\n{s}", .{ tool_name, stream, written }) catch @panic("out of memory writing a log line");
        self.writeEntry(io, arena, now_ms, .tool, entry_text);
    }

    //
    // Appends one entry to the log file, and to the error log file for an error, an exception or a warning. A failed write is reported
    // on stderr, because logging must never stop what is being logged.
    //
    fn writeEntry(self: *FileLog, io: std.Io, arena: std.mem.Allocator, now_ms: i64, level: LogLevel, text: []const u8) void {
        const entry = formatEntry(arena, now_ms, level, text) catch @panic("out of memory writing a log line");
        appendToFile(io, self.log_file, entry) catch |err| {
            console.errorFormat("Could not write to the log file {s}: {s}", .{ self.log_file, @errorName(err) });
        };
        if (level == .@"error" or level == .exception or level == .warn) {
            self.has_errors = true;
            appendToFile(io, self.error_log_file, entry) catch |err| {
                console.errorFormat("Could not write to the log file {s}: {s}", .{ self.error_log_file, @errorName(err) });
            };
        }
    }

    //
    // The ILog functions of the file log.
    //
    const vtable: ILog.VTable = .{
        .info = info,
        .verbose = verbose,
        .@"error" = logError,
        .exception = exception,
        .warn = warn,
        .debug = debug,
        .tool = tool,
        .event = event,
        .verboseEnabled = verboseEnabled,
        .getLogDetails = getLogDetails,
        .logFilePath = logFilePath,
    };

    //
    // Writes a line the calling thread logged.
    //
    fn writeOwn(ptr: *anyopaque, level: LogLevel, message: []const u8) void {
        const self: *FileLog = @ptrCast(@alignCast(ptr));
        self.writeLine(.{
            .level = level,
            .message = message,
            .error_text = null,
            .tool_output = null,
        });
    }

    //
    // ILog.info.
    //
    fn info(ptr: *anyopaque, message: []const u8) void {
        writeOwn(ptr, .info, message);
    }

    //
    // ILog.verbose: always written to the file, shown on the console only when verbose lines are on.
    //
    fn verbose(ptr: *anyopaque, message: []const u8) void {
        writeOwn(ptr, .verbose, message);
    }

    //
    // ILog.error.
    //
    fn logError(ptr: *anyopaque, message: []const u8) void {
        writeOwn(ptr, .@"error", message);
    }

    //
    // ILog.exception: the message, then the error's cause chain.
    //
    fn exception(ptr: *anyopaque, message: []const u8, err: anyerror) void {
        const self: *FileLog = @ptrCast(@alignCast(ptr));
        // The chain, however long, is written with an allocator made for the call.
        var thread_allocator: ThreadAllocator = .init;
        defer thread_allocator.deinit();
        var arena_state = std.heap.ArenaAllocator.init(thread_allocator.allocator());
        defer arena_state.deinit();
        const chain = wrapped_error.formatErrorChain(arena_state.allocator(), err) catch @panic("out of memory writing an error");
        self.writeLine(.{
            .level = .exception,
            .message = message,
            .error_text = chain,
            .tool_output = null,
        });
    }

    //
    // ILog.warn.
    //
    fn warn(ptr: *anyopaque, message: []const u8) void {
        writeOwn(ptr, .warn, message);
    }

    //
    // ILog.debug: always written to the file, shown on the console only when debug lines are on.
    //
    fn debug(ptr: *anyopaque, message: []const u8) void {
        writeOwn(ptr, .debug, message);
    }

    //
    // ILog.tool: always written to the file, shown on the console only when the output of tools is on.
    //
    fn tool(ptr: *anyopaque, tool_name: []const u8, data: IToolOutput) void {
        const self: *FileLog = @ptrCast(@alignCast(ptr));
        self.writeLine(.{
            .level = .tool,
            .message = tool_name,
            .error_text = null,
            .tool_output = data,
        });
    }

    //
    // ILog.event.
    //
    fn event(ptr: *anyopaque, message: []const u8) void {
        writeOwn(ptr, .event, message);
    }

    //
    // ILog.verboseEnabled: whether verbose lines are shown on the console.
    //
    fn verboseEnabled(ptr: *anyopaque) bool {
        const self: *FileLog = @ptrCast(@alignCast(ptr));
        return self.console_log.verbose_enabled;
    }

    //
    // ILog.getLogDetails: the path of the log file and its header, read from the file.
    //
    fn getLogDetails(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) anyerror!ILogDetails {
        const self: *FileLog = @ptrCast(@alignCast(ptr));
        return readLogDetails(allocator, io, self.log_file);
    }

    //
    // ILog.logFilePath: the path of the log file.
    //
    fn logFilePath(ptr: *anyopaque) ?[]const u8 {
        const self: *FileLog = @ptrCast(@alignCast(ptr));
        return self.log_file;
    }
};

//
// The directory a program's logs go in by default: <the operating system's temporary directory>/<program_name>/logs. Allocated with
// the allocator.
//
pub fn defaultLogsDir(allocator: std.mem.Allocator, program_name: []const u8) ![]const u8 {
    const tmp = try temp_dir.osTmpDir(allocator);
    defer allocator.free(tmp);
    return std.fs.path.join(allocator, &.{ tmp, program_name, "logs" });
}

//
// The path of a log file and its header: everything up to and including "--- Log Start ---", or the first 50 lines when the file has
// no such line. Both are allocated with the allocator.
//
pub fn readLogDetails(allocator: std.mem.Allocator, io: std.Io, log_file_path: []const u8) !ILogDetails {
    const file = try std.Io.Dir.cwd().openFile(io, log_file_path, .{});
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &buffer);
    var head: std.ArrayList(u8) = .empty;
    defer head.deinit(allocator);
    // The header is a few hundred bytes, so a megabyte bounds the read without limiting the header.
    reader.interface.appendRemaining(allocator, &head, .limited(1024 * 1024)) catch |err| switch (err) {
        error.StreamTooLong => {},
        error.ReadFailed => return reader.err orelse err,
        else => return err,
    };
    var end: usize = head.items.len;
    if (std.mem.indexOf(u8, head.items, log_start_marker)) |marker_at| {
        end = marker_at + log_start_marker.len;
    }
    else {
        var newline_count: usize = 0;
        for (head.items, 0..) |character, index| {
            if (character == '\n') {
                newline_count += 1;
                if (newline_count == 50) {
                    end = index;
                    break;
                }
            }
        }
    }
    return .{
        .logFilePath = try allocator.dupe(u8, log_file_path),
        .logHeader = try allocator.dupe(u8, head.items[0..end]),
    };
}

//
// Formats an entry of a log file: [<time>] [<LEVEL>] <text> and a newline.
//
fn formatEntry(arena: std.mem.Allocator, now_ms: i64, level: LogLevel, text: []const u8) ![]const u8 {
    const timestamp = try (Date{ .epochMilliseconds = now_ms }).toISOString(arena);
    const upper_level = try std.ascii.allocUpperString(arena, @tagName(level));
    return std.fmt.allocPrint(arena, "[{s}] [{s}] {s}\n", .{ timestamp, upper_level, text });
}

//
// Appends text to the end of a file, creating it when it is not there.
//
fn appendToFile(io: std.Io, file_path: []const u8, content: []const u8) !void {
    // Opened for reading as well, because Windows refuses the length of a file opened for writing alone.
    const file = try std.Io.Dir.cwd().createFile(io, file_path, .{
        .truncate = false,
        .read = true,
    });
    defer file.close(io);
    const length = try file.length(io);
    try file.writePositionalAll(io, content, length);
}

//
// The part of both headers after the title: the start time, the command line, the working directory, the system information and
// the program's own lines, ending with a blank line.
//
fn buildCommonHeader(arena: std.mem.Allocator, io: std.Io, config: IFileLogConfig, start_iso: []const u8) ![]const u8 {
    var allocating_writer = std.Io.Writer.Allocating.init(arena);
    const writer = &allocating_writer.writer;
    try writer.print("Started: {s}\n", .{start_iso});
    if (config.command) |command| {
        try writer.print("Command: {s}\n", .{command});
    }
    try writer.print("Working Directory: {s}\n", .{try std.process.currentPathAlloc(io, arena)});
    try writer.print("{s}\n\n", .{rule_line});
    try writer.writeAll("--- System Information ---\n");
    try writer.print("Platform: {s}\n", .{platformName()});
    try writer.print("Architecture: {s}\n", .{architectureName()});
    try writer.print("OS Release: {s}\n", .{try osRelease(arena)});
    try writer.print("Zig Version: {s}\n", .{builtin.zig_version_string});
    if (config.version) |version| {
        try writer.print("Version: {s}\n", .{version});
    }
    try writer.writeAll("\n");
    if (config.header_lines.len > 0) {
        for (config.header_lines) |line| {
            try writer.print("{s}\n", .{line});
        }
        try writer.writeAll("\n");
    }
    return allocating_writer.written();
}

//
// The name of the platform, as Node names it (`os.platform()`), with android and ios told apart.
//
fn platformName() []const u8 {
    return switch (builtin.os.tag) {
        .linux => if (builtin.abi.isAndroid()) "android" else "linux",
        .macos => "darwin",
        .windows => "win32",
        else => @tagName(builtin.os.tag),
    };
}

//
// The name of the CPU architecture, as Node names it (`os.arch()`).
//
fn architectureName() []const u8 {
    return switch (builtin.cpu.arch) {
        .x86_64 => "x64",
        .aarch64 => "arm64",
        .x86 => "ia32",
        .arm => "arm",
        else => @tagName(builtin.cpu.arch),
    };
}

//
// The release of the operating system (`os.release()`).
//
fn osRelease(arena: std.mem.Allocator) ![]const u8 {
    if (builtin.os.tag == .windows) {
        var version_info: std.os.windows.RTL_OSVERSIONINFOW = undefined;
        version_info.dwOSVersionInfoSize = @sizeOf(std.os.windows.RTL_OSVERSIONINFOW);
        if (std.os.windows.ntdll.RtlGetVersion(&version_info) != .SUCCESS) {
            return "unknown";
        }
        return std.fmt.allocPrint(arena, "{d}.{d}.{d}", .{ version_info.dwMajorVersion, version_info.dwMinorVersion, version_info.dwBuildNumber });
    }
    const uname = std.posix.uname();
    return arena.dupe(u8, std.mem.sliceTo(&uname.release, 0));
}
