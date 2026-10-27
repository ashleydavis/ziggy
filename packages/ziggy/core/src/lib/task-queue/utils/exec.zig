const std = @import("std");
const builtin = @import("builtin");
const utils = @import("../utils.zig");
const errors = utils.errors;
const process_env = @import("process-env.zig");

//
// The output of a command run with exec.
//
pub const ExecResult = struct {
    // Everything the command wrote to stdout.
    stdout: []const u8,

    // Everything the command wrote to stderr.
    stderr: []const u8,
};

//
// The most bytes exec takes from each of stdout and stderr (its `maxBuffer`). A command that writes
// more is killed and fails with a RangeError.
//
const maxBuffer: usize = 1024 * 1024;

//
// Executes a command using the specified tool.
// The command runs in the shell (/bin/sh -c, or cmd.exe on Windows)
// with the environment of `process.env` (see process-env.zig), and fails when the command cannot be
// started or exits with a non-zero code. The error message is "Command failed: <command>\n<stderr>".
//
pub fn exec(allocator: std.mem.Allocator, io: std.Io, command: []const u8) !ExecResult {
    if (builtin.os.tag == .windows) {
        return execWindows(allocator, command);
    }
    const result = runShell(allocator, io, command) catch |err| {
        if (err == error.Thrown) {
            return error.Thrown;
        }
        return errors.throwError("Command failed: {s}\n{s}", .{ command, @errorName(err) });
    };
    const succeeded = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!succeeded) {
        return errors.throwError("Command failed: {s}\n{s}", .{ command, result.stderr });
    }
    return .{ .stdout = result.stdout, .stderr = result.stderr };
}

//
// Records the RangeError exec fails with when a command writes more than maxBuffer bytes to a stream.
//
fn maxBufferExceeded(streamName: []const u8) errors.ThrownError {
    errors.recordError("RangeError", "{s} maxBuffer length exceeded", .{streamName});
    return error.Thrown;
}

//
// The command gets an empty stdin, so a command that reads stdin ends at once.
//
// Runs the command in /bin/sh with the environment of `process.env` and reads its stdout and stderr to their ends, failing when
// either has more than maxBuffer bytes. Both pipes are read on the calling thread: it waits on both at once with poll and reads
// whichever has data, so a command that fills one pipe while nothing reads the other never blocks.
//
fn runShell(allocator: std.mem.Allocator, io: std.Io, command: []const u8) !std.process.RunResult {
    var child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", command },
        .environ_map = process_env.getEnvironMap(),
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);

    var outputs = [2]std.ArrayList(u8){ .empty, .empty };
    defer outputs[0].deinit(allocator);
    defer outputs[1].deinit(allocator);
    const streamNames = [2][]const u8{ "stdout", "stderr" };
    var fds = [2]std.posix.pollfd{
        .{
            .fd = child.stdout.?.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        },
        .{
            .fd = child.stderr.?.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        },
    };
    var open: usize = fds.len;
    var buffer: [16 * 1024]u8 = undefined;
    while (open > 0) {
        _ = try std.posix.poll(&fds, -1);
        for (&fds, 0..) |*fd, index| {
            if (fd.fd < 0 or fd.revents == 0) {
                continue;
            }
            const count = try std.posix.read(fd.fd, &buffer);
            if (count == 0) {
                // The command closed its end of this pipe. A negative descriptor is one poll leaves out.
                fd.fd = -1;
                open -= 1;
                continue;
            }
            try outputs[index].appendSlice(allocator, buffer[0..count]);
            if (outputs[index].items.len > maxBuffer) {
                return maxBufferExceeded(streamNames[index]);
            }
        }
    }

    const term = try child.wait(io);
    return .{
        .stdout = try outputs[0].toOwnedSlice(allocator),
        .stderr = try outputs[1].toOwnedSlice(allocator),
        .term = term,
    };
}

//
// The Windows version of exec. It runs `cmd.exe /d /s /c "<command>"` with that command line
// passed verbatim, so the quotes inside the command reach cmd.exe
// untouched. std.process quotes each argument instead, turning those quotes into \", so the process is
// created here with CreateProcessW.
//
fn execWindows(allocator: std.mem.Allocator, command: []const u8) !ExecResult {
    const result = runCmdExe(allocator, command) catch |err| {
        if (err == error.Thrown) {
            return error.Thrown;
        }
        return errors.throwError("Command failed: {s}\n{s}", .{ command, @errorName(err) });
    };
    if (result.exitCode != 0) {
        return errors.throwError("Command failed: {s}\n{s}", .{ command, result.stderr });
    }
    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

//
// The Windows API functions runCmdExe calls that std.os.windows does not declare.
//
const kernel32 = struct {
    // Creates the server end of a named pipe.
    extern "kernel32" fn CreateNamedPipeW(
        lpName: [*:0]const u16,
        dwOpenMode: std.os.windows.DWORD,
        dwPipeMode: std.os.windows.DWORD,
        nMaxInstances: std.os.windows.DWORD,
        nOutBufferSize: std.os.windows.DWORD,
        nInBufferSize: std.os.windows.DWORD,
        nDefaultTimeOut: std.os.windows.DWORD,
        lpSecurityAttributes: ?*std.os.windows.SECURITY_ATTRIBUTES,
    ) callconv(.winapi) std.os.windows.HANDLE;

    // Opens a file or, here, the client end of a named pipe.
    extern "kernel32" fn CreateFileW(
        lpFileName: [*:0]const u16,
        dwDesiredAccess: std.os.windows.DWORD,
        dwShareMode: std.os.windows.DWORD,
        lpSecurityAttributes: ?*std.os.windows.SECURITY_ATTRIBUTES,
        dwCreationDisposition: std.os.windows.DWORD,
        dwFlagsAndAttributes: std.os.windows.DWORD,
        hTemplateFile: ?std.os.windows.HANDLE,
    ) callconv(.winapi) std.os.windows.HANDLE;

    // Creates an anonymous pipe, here for the child's stdin.
    extern "kernel32" fn CreatePipe(
        hReadPipe: *std.os.windows.HANDLE,
        hWritePipe: *std.os.windows.HANDLE,
        lpPipeAttributes: ?*std.os.windows.SECURITY_ATTRIBUTES,
        nSize: std.os.windows.DWORD,
    ) callconv(.winapi) std.os.windows.BOOL;

    // Sets the properties of a handle, here whether child processes inherit it.
    extern "kernel32" fn SetHandleInformation(
        hObject: std.os.windows.HANDLE,
        dwMask: std.os.windows.DWORD,
        dwFlags: std.os.windows.DWORD,
    ) callconv(.winapi) std.os.windows.BOOL;

    // Starts a read from a file or a pipe, which completes later when the handle was opened for overlapped reads.
    extern "kernel32" fn ReadFile(
        hFile: std.os.windows.HANDLE,
        lpBuffer: [*]u8,
        nNumberOfBytesToRead: std.os.windows.DWORD,
        lpNumberOfBytesRead: ?*std.os.windows.DWORD,
        lpOverlapped: ?*kernel32.OVERLAPPED,
    ) callconv(.winapi) std.os.windows.BOOL;

    // Gets how an overlapped read ended.
    extern "kernel32" fn GetOverlappedResult(
        hFile: std.os.windows.HANDLE,
        lpOverlapped: *kernel32.OVERLAPPED,
        lpNumberOfBytesTransferred: *std.os.windows.DWORD,
        bWait: std.os.windows.BOOL,
    ) callconv(.winapi) std.os.windows.BOOL;

    // Creates an event, which an overlapped read signals when it completes.
    extern "kernel32" fn CreateEventW(
        lpEventAttributes: ?*std.os.windows.SECURITY_ATTRIBUTES,
        bManualReset: std.os.windows.BOOL,
        bInitialState: std.os.windows.BOOL,
        lpName: ?[*:0]const u16,
    ) callconv(.winapi) ?std.os.windows.HANDLE;

    // Waits until one of the objects (here the events of the reads) is signaled.
    extern "kernel32" fn WaitForMultipleObjects(
        nCount: std.os.windows.DWORD,
        lpHandles: [*]const std.os.windows.HANDLE,
        bWaitAll: std.os.windows.BOOL,
        dwMilliseconds: std.os.windows.DWORD,
    ) callconv(.winapi) std.os.windows.DWORD;

    // Waits until the object (here a process) is signaled.
    extern "kernel32" fn WaitForSingleObject(
        hHandle: std.os.windows.HANDLE,
        dwMilliseconds: std.os.windows.DWORD,
    ) callconv(.winapi) std.os.windows.DWORD;

    // Ends a process.
    extern "kernel32" fn TerminateProcess(
        hProcess: std.os.windows.HANDLE,
        uExitCode: std.os.windows.UINT,
    ) callconv(.winapi) std.os.windows.BOOL;

    // Gets the exit code of a process.
    extern "kernel32" fn GetExitCodeProcess(
        hProcess: std.os.windows.HANDLE,
        lpExitCode: *std.os.windows.DWORD,
    ) callconv(.winapi) std.os.windows.BOOL;

    // Gets the id of the calling process.
    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) std.os.windows.DWORD;

    // Gets the id of the calling thread.
    extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) std.os.windows.DWORD;

    // What an overlapped read is: where it is in the file (unused for a pipe) and the event it signals when it completes, as
    // OVERLAPPED is laid out in minwinbase.h.
    const OVERLAPPED = extern struct {
        Internal: usize,
        InternalHigh: usize,
        Offset: std.os.windows.DWORD,
        OffsetHigh: std.os.windows.DWORD,
        hEvent: ?std.os.windows.HANDLE,
    };

    // The flag of SetHandleInformation that makes a handle inherited by child processes.
    const HANDLE_FLAG_INHERIT: std.os.windows.DWORD = 0x00000001;

    // The timeout of WaitForSingleObject and WaitForMultipleObjects that waits for ever.
    const INFINITE: std.os.windows.DWORD = 0xFFFFFFFF;

    // The value WaitForSingleObject and WaitForMultipleObjects return when they fail.
    const WAIT_FAILED: std.os.windows.DWORD = 0xFFFFFFFF;

    // The value WaitForMultipleObjects returns for its first object; the second is one more, and so on.
    const WAIT_OBJECT_0: std.os.windows.DWORD = 0;

    // A pipe the server end of which only reads.
    const PIPE_ACCESS_INBOUND: std.os.windows.DWORD = 0x00000001;

    // Opens a handle for overlapped reads and writes.
    const FILE_FLAG_OVERLAPPED: std.os.windows.DWORD = 0x40000000;

    // Lets only one instance of a named pipe be made, so nothing else can take the name between its creation and its use.
    const FILE_FLAG_FIRST_PIPE_INSTANCE: std.os.windows.DWORD = 0x00080000;

    // A pipe of bytes, whose reads wait for data.
    const PIPE_TYPE_BYTE: std.os.windows.DWORD = 0x00000000;
    const PIPE_WAIT: std.os.windows.DWORD = 0x00000000;

    // Writing, for CreateFileW.
    const GENERIC_WRITE: std.os.windows.DWORD = 0x40000000;

    // Opens what is there, for CreateFileW.
    const OPEN_EXISTING: std.os.windows.DWORD = 3;

    // An ordinary file, for CreateFileW.
    const FILE_ATTRIBUTE_NORMAL: std.os.windows.DWORD = 0x00000080;
};

//
// The output and the exit code of a command run by runCmdExe.
//
const ICmdExeResult = struct {
    // Everything the command wrote to stdout.
    stdout: []const u8,

    // Everything the command wrote to stderr.
    stderr: []const u8,

    // The exit code of cmd.exe.
    exitCode: std.os.windows.DWORD,
};

//
// A pipe between this process and a child process.
//
const IChildPipe = struct {
    // The end this process keeps, which the child process does not inherit.
    parentEnd: std.os.windows.HANDLE,

    // The end the child process inherits.
    childEnd: std.os.windows.HANDLE,
};

//
// Numbers the pipes the calling thread makes, so each one's name is its own. Each thread has its own count, and the name holds the
// thread's id too.
//
threadlocal var nextPipeNumber: u32 = 0;

//
// Creates a pipe the child writes to (its stdout or stderr) and this process reads from with overlapped reads. An anonymous pipe
// cannot be read that way, so it is a named pipe whose name holds this process's id, this thread's id and a number of this thread's.
//
fn createOutputPipe(allocator: std.mem.Allocator) !IChildPipe {
    const windows = std.os.windows;
    nextPipeNumber += 1;
    const name = try std.fmt.allocPrint(allocator, "\\\\.\\pipe\\ziggy-exec-{d}-{d}-{d}", .{ kernel32.GetCurrentProcessId(), kernel32.GetCurrentThreadId(), nextPipeNumber });
    defer allocator.free(name);
    const wideName = try std.unicode.utf8ToUtf16LeAllocZ(allocator, name);
    defer allocator.free(wideName);
    const readEnd = kernel32.CreateNamedPipeW(
        wideName.ptr,
        kernel32.PIPE_ACCESS_INBOUND | kernel32.FILE_FLAG_OVERLAPPED | kernel32.FILE_FLAG_FIRST_PIPE_INSTANCE,
        kernel32.PIPE_TYPE_BYTE | kernel32.PIPE_WAIT,
        1,
        0,
        64 * 1024,
        0,
        null,
    );
    if (readEnd == windows.INVALID_HANDLE_VALUE) {
        return windows.unexpectedError(windows.GetLastError());
    }
    errdefer windows.CloseHandle(readEnd);
    var inheritable: windows.SECURITY_ATTRIBUTES = .{
        .nLength = @sizeOf(windows.SECURITY_ATTRIBUTES),
        .lpSecurityDescriptor = null,
        .bInheritHandle = .TRUE,
    };
    const writeEnd = kernel32.CreateFileW(wideName.ptr, kernel32.GENERIC_WRITE, 0, &inheritable, kernel32.OPEN_EXISTING, kernel32.FILE_ATTRIBUTE_NORMAL, null);
    if (writeEnd == windows.INVALID_HANDLE_VALUE) {
        return windows.unexpectedError(windows.GetLastError());
    }
    return .{
        .parentEnd = readEnd,
        .childEnd = writeEnd,
    };
}

//
// Creates the pipe the child reads its stdin from, which this process closes at once so the child reads nothing.
//
fn createInputPipe() !IChildPipe {
    const windows = std.os.windows;
    var inheritable: windows.SECURITY_ATTRIBUTES = .{
        .nLength = @sizeOf(windows.SECURITY_ATTRIBUTES),
        .lpSecurityDescriptor = null,
        .bInheritHandle = .TRUE,
    };
    var readEnd: windows.HANDLE = undefined;
    var writeEnd: windows.HANDLE = undefined;
    if (kernel32.CreatePipe(&readEnd, &writeEnd, &inheritable, 0) == .FALSE) {
        return windows.unexpectedError(windows.GetLastError());
    }
    if (kernel32.SetHandleInformation(writeEnd, kernel32.HANDLE_FLAG_INHERIT, 0) == .FALSE) {
        return windows.unexpectedError(windows.GetLastError());
    }
    return .{
        .parentEnd = writeEnd,
        .childEnd = readEnd,
    };
}

//
// One of the child's output pipes as this process reads it: an overlapped read is always in flight on it until the child closes its end.
//
const IPipeRead = struct {
    // The end of the pipe this process reads.
    handle: std.os.windows.HANDLE,

    // Signaled when the read in flight completes.
    event: std.os.windows.HANDLE,

    // The read in flight.
    overlapped: kernel32.OVERLAPPED,

    // Where the read in flight puts what it reads.
    buffer: [16 * 1024]u8,

    // Everything read so far.
    output: std.ArrayList(u8),

    // Set once the child has closed its end of the pipe.
    closed: bool,

    //
    // Starts the next read. A pipe whose child end has closed is marked closed instead.
    //
    fn start(self: *IPipeRead) !void {
        const windows = std.os.windows;
        self.overlapped = std.mem.zeroes(kernel32.OVERLAPPED);
        self.overlapped.hEvent = self.event;
        if (kernel32.ReadFile(self.handle, &self.buffer, self.buffer.len, null, &self.overlapped) == .FALSE) {
            const lastError = windows.GetLastError();
            if (lastError == .IO_PENDING) {
                return;
            }
            if (lastError == .BROKEN_PIPE) {
                self.closed = true;
                return;
            }
            return windows.unexpectedError(lastError);
        }
    }

    //
    // Takes what the read in flight, which has completed, read and starts the next one. Fails with MaxBufferExceeded when the
    // output has grown past maxBuffer.
    //
    fn finish(self: *IPipeRead, allocator: std.mem.Allocator) !void {
        const windows = std.os.windows;
        var count: windows.DWORD = 0;
        if (kernel32.GetOverlappedResult(self.handle, &self.overlapped, &count, .FALSE) == .FALSE) {
            const lastError = windows.GetLastError();
            if (lastError == .BROKEN_PIPE) {
                self.closed = true;
                return;
            }
            return windows.unexpectedError(lastError);
        }
        try self.output.appendSlice(allocator, self.buffer[0..count]);
        if (self.output.items.len > maxBuffer) {
            return error.MaxBufferExceeded;
        }
        try self.start();
    }
};

//
// Runs `cmd.exe /d /s /c "<command>"` with the environment of `process.env`, stdin reading nothing and stdout and stderr read to their
// ends, then waits for it to exit. Both pipes are read on the calling thread: an overlapped read is kept in flight on each, and the
// thread waits for whichever completes first, so a command that fills one pipe while nothing reads the other never blocks.
//
fn runCmdExe(allocator: std.mem.Allocator, command: []const u8) !ICmdExeResult {
    const windows = std.os.windows;
    const commandLine = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, try std.fmt.allocPrint(allocator, "cmd.exe /d /s /c \"{s}\"", .{command}));
    const environmentBlock: ?[*:0]const u16 = if (process_env.getEnvironMap()) |environMap|
        (try environMap.createWindowsBlock(allocator, .{})).slice.ptr
    else
        null;

    const stdinPipe = try createInputPipe();
    const stdoutPipe = try createOutputPipe(allocator);
    const stderrPipe = try createOutputPipe(allocator);
    var startupInfo: windows.STARTUPINFOW = .{
        .cb = @sizeOf(windows.STARTUPINFOW),
        .lpReserved = null,
        .lpDesktop = null,
        .lpTitle = null,
        .dwX = 0,
        .dwY = 0,
        .dwXSize = 0,
        .dwYSize = 0,
        .dwXCountChars = 0,
        .dwYCountChars = 0,
        .dwFillAttribute = 0,
        .dwFlags = windows.STARTF_USESTDHANDLES,
        .wShowWindow = 0,
        .cbReserved2 = 0,
        .lpReserved2 = null,
        .hStdInput = stdinPipe.childEnd,
        .hStdOutput = stdoutPipe.childEnd,
        .hStdError = stderrPipe.childEnd,
    };
    var processInformation: windows.PROCESS.INFORMATION = undefined;
    const created = windows.kernel32.CreateProcessW(
        null,
        commandLine.ptr,
        null,
        null,
        .TRUE,
        .{
            .create_unicode_environment = true,
            .create_no_window = true,
        },
        environmentBlock,
        null,
        &startupInfo,
        &processInformation,
    );
    const createError = windows.GetLastError();

    // The child process has its own copies of its ends of the pipes, and stdin is closed so it reads nothing.
    windows.CloseHandle(stdinPipe.childEnd);
    windows.CloseHandle(stdoutPipe.childEnd);
    windows.CloseHandle(stderrPipe.childEnd);
    windows.CloseHandle(stdinPipe.parentEnd);
    defer windows.CloseHandle(stdoutPipe.parentEnd);
    defer windows.CloseHandle(stderrPipe.parentEnd);
    if (created == .FALSE) {
        return windows.unexpectedError(createError);
    }
    windows.CloseHandle(processInformation.hThread);
    defer windows.CloseHandle(processInformation.hProcess);

    var reads: [2]IPipeRead = undefined;
    const pipes = [2]windows.HANDLE{ stdoutPipe.parentEnd, stderrPipe.parentEnd };
    for (&reads, pipes) |*read, handle| {
        const event = kernel32.CreateEventW(null, .TRUE, .FALSE, null) orelse {
            return windows.unexpectedError(windows.GetLastError());
        };
        read.* = .{
            .handle = handle,
            .event = event,
            .overlapped = undefined,
            .buffer = undefined,
            .output = .empty,
            .closed = false,
        };
    }
    defer for (&reads) |*read| {
        windows.CloseHandle(read.event);
        read.output.deinit(allocator);
    };
    const streamNames = [2][]const u8{ "stdout", "stderr" };
    for (&reads) |*read| {
        try read.start();
    }
    while (!reads[0].closed or !reads[1].closed) {
        var waiting: [2]windows.HANDLE = undefined;
        var waitingIndex: [2]usize = undefined;
        var count: usize = 0;
        for (&reads, 0..) |*read, index| {
            if (read.closed) {
                continue;
            }
            waiting[count] = read.event;
            waitingIndex[count] = index;
            count += 1;
        }
        const waited = kernel32.WaitForMultipleObjects(@intCast(count), &waiting, .FALSE, kernel32.INFINITE);
        if (waited == kernel32.WAIT_FAILED or waited >= kernel32.WAIT_OBJECT_0 + count) {
            return windows.unexpectedError(windows.GetLastError());
        }
        const index = waitingIndex[waited - kernel32.WAIT_OBJECT_0];
        reads[index].finish(allocator) catch |err| {
            if (err == error.MaxBufferExceeded) {
                // A command that writes too much is killed.
                _ = kernel32.TerminateProcess(processInformation.hProcess, 1);
                return maxBufferExceeded(streamNames[index]);
            }
            return err;
        };
    }

    if (kernel32.WaitForSingleObject(processInformation.hProcess, kernel32.INFINITE) == kernel32.WAIT_FAILED) {
        return windows.unexpectedError(windows.GetLastError());
    }
    var exitCode: windows.DWORD = 0;
    if (kernel32.GetExitCodeProcess(processInformation.hProcess, &exitCode) == .FALSE) {
        return windows.unexpectedError(windows.GetLastError());
    }
    return .{
        .stdout = try allocator.dupe(u8, reads[0].output.items),
        .stderr = try allocator.dupe(u8, reads[1].output.items),
        .exitCode = exitCode,
    };
}

//
// Checks the result of a command run with execLogged: returns the reason it failed, or null when it did not
// The check is optional.
//
pub const IValidate = struct {
    // The state the check reads.
    context: *anyopaque,

    // The check.
    function: *const fn (context: *anyopaque, allocator: std.mem.Allocator, io: std.Io) anyerror!?[]const u8,
};

//
// Runs the command and logs it, its failure and what the tool wrote to the log given.
//
pub fn execLogged(allocator: std.mem.Allocator, io: std.Io, log: utils.log.ILog, tool: []const u8, command: []const u8, validate: ?IValidate) !ExecResult {
    log.verbose(try std.fmt.allocPrint(allocator, "Executing {s} with command: \"{s}\"", .{ tool, command }));
    return execLoggedInner(allocator, io, log, tool, command, validate) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Failed to execute command: {s}", .{command});
        log.exception(msg, err);
        return errors.throwError("{s}", .{msg});
    };
}

//
// The body of the try block of execLogged.
//
fn execLoggedInner(allocator: std.mem.Allocator, io: std.Io, log: utils.log.ILog, tool: []const u8, command: []const u8, validate: ?IValidate) !ExecResult {
    const result = try exec(allocator, io, command);
    log.tool(tool, .{ .stdout = result.stdout, .stderr = result.stderr });
    if (validate) |check| {
        const validationFailedReason = try check.function(check.context, allocator, io);
        if (validationFailedReason) |reason| {
            const msg = try std.fmt.allocPrint(allocator, "Validation failed for command: {s}\nReason: {s}", .{ command, reason });
            log.@"error"(msg);
            log.info(try std.fmt.allocPrint(allocator, "===\nCommand: {s}\nCommand stdout:\n{s}\nCommand stderr:\n{s}\n===", .{
                command,
                if (result.stdout.len > 0) result.stdout else "No output",
                if (result.stderr.len > 0) result.stderr else "No error",
            }));
            return errors.throwError("{s}", .{msg});
        }
    }
    return result;
}
