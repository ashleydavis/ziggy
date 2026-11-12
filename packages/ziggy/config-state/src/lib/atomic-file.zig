//
// The one way either file is written: take a lock file beside it, read it again, apply only this call's change, write a temporary file in
// the same directory and rename it over the old one only when the file has not changed since the read, so two writers that change
// different keys both keep their change and no reader ever sees a half-written file.
//

const std = @import("std");
const builtin = @import("builtin");
const utils = @import("utils");
const errors = utils.errors;

//
// Sleeps for the given number of milliseconds. It takes fractional milliseconds, which the randomized backoff passes.
//
fn sleep(io: std.Io, timeMs: f64) !void {
    try io.sleep(.fromNanoseconds(@intFromFloat(timeMs * std.time.ns_per_ms)), .awake);
}

//
// The base delay before an optimistic update retries after losing to another writer. Retrying immediately makes things worse: the
// losers re-read and re-write straight away, which keeps the file changing and starves everyone, so a burst of concurrent writers
// exhausts its retries instead of making progress. The wait doubles with each attempt and is randomized, so writers that collided
// spread out rather than colliding again in lockstep.
//
const UPDATE_BACKOFF_BASE_MS = 5;

//
// The longest a single backoff waits, so a busy file never stalls a writer for long.
//
const UPDATE_BACKOFF_MAX_MS = 250;

//
// How long an update lock may sit untouched before it is treated as abandoned by a process that died holding it, and broken. Far longer
// than any read-modify-write takes.
//
const LOCK_STALE_MS = 30000;

//
// How many times to poll for the update lock before giving up on it. Waiting for the lock is not the same as losing a write race: the
// holder is making progress and we simply have to wait our turn, so this is deliberately generous and counted separately from the
// caller's retry budget. Spending the caller's retries on waiting would make a slow write by one process look like a failure to every
// other process.
//
const LOCK_WAIT_ATTEMPTS = 50;

//
// How many times a rename into place is retried when the operating system refuses it, and the base wait between tries. The waits grow,
// so ten attempts cover a little over a second in total.
//
const RENAME_RETRY_ATTEMPTS = 10;

//
// The base wait between tries of a refused rename (see RENAME_RETRY_ATTEMPTS).
//
const RENAME_RETRY_DELAY_MS = 20;

//
// A random version 4 UUID, which names a temporary or unreadable copy so that two of them never share a name.
//
fn randomUUID(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    var generator: utils.random_uuid_generator.RandomUuidGenerator = .{};
    return generator.generate(allocator, io);
}

//
// Renames a file over its target on Windows the way Zig 0.16 std's rename does (dirRenameWindowsInner in lib/std/Io/Threaded.zig),
// mapping every status to the error std maps it to, with one difference: STATUS_SHARING_VIOLATION is error.FileBusy. std returns
// error.Unexpected for it, and it is what a rename gets while another handle holds the target open without sharing delete access, so the
// retry in renameIntoPlace would never happen for it. libuv reports the same refusal as EBUSY and the TypeScript retries it.
//
fn renameWindows(tempPath: []const u8, filePath: []const u8) !void {
    const windows = std.os.windows;
    const cwdHandle = std.Io.Dir.cwd().handle;
    const tempPathSpace = try std.Io.Threaded.sliceToPrefixedFileW(cwdHandle, tempPath, .{});
    const tempPathWide = tempPathSpace.span();
    const filePathSpace = try std.Io.Threaded.sliceToPrefixedFileW(cwdHandle, filePath, .{});
    const filePathWide = filePathSpace.span();

    // The source is opened with delete access, which a rename needs, and without following a symlink, as std opens it.
    var sourceHandle: windows.HANDLE = undefined;
    var openStatusBlock: windows.IO_STATUS_BLOCK = undefined;
    const openStatus = windows.ntdll.NtCreateFile(
        &sourceHandle,
        .{
            .GENERIC = .{
                .WRITE = true,
            },
            .STANDARD = .{
                .RIGHTS = .{
                    .DELETE = true,
                },
                .SYNCHRONIZE = true,
            },
        },
        &.{
            .RootDirectory = if (std.fs.path.isAbsoluteWindowsWtf16(tempPathWide)) null else cwdHandle,
            .ObjectName = @constCast(&windows.UNICODE_STRING.init(tempPathWide)),
        },
        &openStatusBlock,
        null,
        .{
            .NORMAL = true,
        },
        .VALID_FLAGS,
        .OPEN,
        .{
            .IO = .ASYNCHRONOUS,
            .OPEN_REPARSE_POINT = true,
        },
        null,
        0,
    );
    switch (openStatus) {
        .SUCCESS => {},
        // std retries these two a few times for a kernel bug and then returns FileBusy, which renameIntoPlace retries anyway.
        .SHARING_VIOLATION => return error.FileBusy,
        .DELETE_PENDING => return error.FileBusy,
        .OBJECT_NAME_INVALID => return error.BadPathName,
        .OBJECT_NAME_NOT_FOUND => return error.FileNotFound,
        .OBJECT_PATH_NOT_FOUND => return error.FileNotFound,
        .BAD_NETWORK_PATH => return error.NetworkNotFound,
        .BAD_NETWORK_NAME => return error.NetworkNotFound,
        .NO_MEDIA_IN_DEVICE => return error.NoDevice,
        .ACCESS_DENIED => return error.AccessDenied,
        .PIPE_BUSY => return error.PipeBusy,
        .PIPE_NOT_AVAILABLE => return error.NoDevice,
        // std's rename turns its PathAlreadyExists into Unexpected.
        .OBJECT_NAME_COLLISION => return windows.unexpectedStatus(openStatus),
        .FILE_IS_A_DIRECTORY => return error.IsDir,
        .NOT_A_DIRECTORY => return error.NotDir,
        .USER_MAPPED_FILE => return error.AccessDenied,
        .VIRUS_INFECTED, .VIRUS_DELETED => return error.AntivirusInterference,
        .INVALID_PARAMETER, .OBJECT_PATH_SYNTAX_BAD, .INVALID_HANDLE => return windows.statusBug(openStatus),
        else => return windows.unexpectedStatus(openStatus),
    }
    defer windows.CloseHandle(sourceHandle);

    // FileRenameInformationEx is tried first, and FileRenameInformation without the extra flags where the filesystem or the operating
    // system does not support it, as std does.
    var renameStatus = setRenameInformation(sourceHandle, cwdHandle, filePathWide, .{
        .REPLACE_IF_EXISTS = true,
        .POSIX_SEMANTICS = true,
        .IGNORE_READONLY_ATTRIBUTE = true,
    }, .RenameEx);
    if (renameStatus == .INVALID_PARAMETER or renameStatus == .INVALID_INFO_CLASS or renameStatus == .NOT_SUPPORTED) {
        renameStatus = setRenameInformation(sourceHandle, cwdHandle, filePathWide, .{
            .REPLACE_IF_EXISTS = true,
        }, .Rename);
    }
    switch (renameStatus) {
        .SUCCESS => {},
        .SHARING_VIOLATION => return error.FileBusy,
        .INVALID_HANDLE, .INVALID_PARAMETER, .OBJECT_PATH_SYNTAX_BAD => return windows.statusBug(renameStatus),
        .ACCESS_DENIED => return error.AccessDenied,
        .OBJECT_NAME_NOT_FOUND => return error.FileNotFound,
        .OBJECT_PATH_NOT_FOUND => return error.FileNotFound,
        .NOT_SAME_DEVICE => return error.CrossDevice,
        // std's rename turns its PathAlreadyExists into Unexpected.
        .OBJECT_NAME_COLLISION => return windows.unexpectedStatus(renameStatus),
        .DIRECTORY_NOT_EMPTY => return error.DirNotEmpty,
        .FILE_IS_A_DIRECTORY => return error.IsDir,
        .NOT_A_DIRECTORY => return error.NotDir,
        else => return windows.unexpectedStatus(renameStatus),
    }
}

//
// Asks Windows to rename the file behind a handle to a path, through the given rename information class.
//
fn setRenameInformation(
    sourceHandle: std.os.windows.HANDLE,
    cwdHandle: std.os.windows.HANDLE,
    filePathWide: []const u16,
    flags: std.os.windows.FILE.RENAME_INFORMATION.FLAGS,
    informationClass: std.os.windows.FILE.INFORMATION_CLASS,
) std.os.windows.NTSTATUS {
    const windows = std.os.windows;
    var renameInformation: windows.FILE.RENAME_INFORMATION = .init(.{
        .Flags = flags,
        .RootDirectory = if (std.fs.path.isAbsoluteWindowsWtf16(filePathWide)) null else cwdHandle,
        .FileName = filePathWide,
    });
    const renameInformationBuffer = renameInformation.toBuffer();
    var statusBlock: windows.IO_STATUS_BLOCK = undefined;
    return windows.ntdll.NtSetInformationFile(
        sourceHandle,
        &statusBlock,
        renameInformationBuffer.ptr,
        @intCast(renameInformationBuffer.len),
        informationClass,
    );
}

//
// Renames a freshly written temporary file over its target, retrying the refusals Windows gives while something else has the target open.
//
// Writing to a temporary file and renaming it over the target is atomic on POSIX whatever else is reading, and is how every write here
// is made safe. Windows does not allow it: a rename onto a path another handle has open fails outright with EPERM, and virus scanners
// and the search indexer open files behind your back, so the refusal is transient and arrives without warning.
//
// Only the refusals that come of contention are retried. Anything else, a missing directory or a bad path, is thrown on the first
// attempt as it always was.
//
pub noinline fn renameIntoPlace(io: std.Io, tempPath: []const u8, filePath: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    var attempt: u32 = 0;
    while (true) : (attempt += 1) {
        // On Windows std 0.16 returns error.Unexpected for STATUS_SHARING_VIOLATION on rename, so a target held open without delete
        // sharing would never be retried, where libuv reports it as EBUSY and the TypeScript retries it. renameWindows renames as std
        // does but reports that refusal as FileBusy.
        const renamed = if (builtin.os.tag == .windows) renameWindows(tempPath, filePath) else cwd.rename(tempPath, cwd, filePath, io);
        renamed catch |err| {
            // EPERM is PermissionDenied, EACCES is AccessDenied and EBUSY is FileBusy.
            const refusedForContention = err == error.PermissionDenied or err == error.AccessDenied or err == error.FileBusy;
            if (!refusedForContention or attempt >= RENAME_RETRY_ATTEMPTS) {
                return err;
            }
            try sleep(io, @floatFromInt(RENAME_RETRY_DELAY_MS * (attempt + 1)));
            continue;
        };
        return;
    }
}

//
// Ensures that the directory exists. If the directory structure does not exist, it is created.
//
fn ensureDir(io: std.Io, dirPath: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, dirPath) catch |err| {
        // A path that already exists as a directory is fine. Zig reports a path that exists as a file as NotDir where Node reports
        // EEXIST.
        if (err == error.PathAlreadyExists or err == error.NotDir) {
            const stats = try cwd.statFile(io, dirPath, .{});
            if (stats.kind != .directory) {
                return errors.throwError("Path exists but is not a directory: {s}", .{dirPath});
            }
        }
        else {
            return err;
        }
    };
}

//
// Ensures that the directory containing the file exists. If the directory structure does not exist, it is created.
//
fn ensureFileDir(io: std.Io, filePath: []const u8) !void {
    const dirPath = std.fs.path.dirname(filePath) orelse ".";
    return ensureDir(io, dirPath);
}

//
// Reads a file's text, or null when it does not exist, failing with `error.FileTooLarge` when it is over `limit_bytes`. The limit is what
// stops a wrong file exhausting memory, and it is checked before the whole file is read.
//
pub noinline fn readLimited(arena: std.mem.Allocator, io: std.Io, path: []const u8, limit_bytes: u32) !?[]const u8 {
    std.debug.assert(path.len > 0);
    std.debug.assert(limit_bytes > 0);
    return std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(limit_bytes)) catch |err| switch (err) {
        error.FileNotFound => null,
        error.StreamTooLong => error.FileTooLarge,
        else => return err,
    };
}

//
// A cheap fingerprint of a file used to detect whether it changed between our read and our write without re-reading its contents. It
// uses only fields available on every platform we target: size and last-modified time.
//
const IFileFingerprint = struct {
    // Last-modified time in milliseconds since the epoch.
    modifiedMs: i64,

    // File size in bytes.
    size: u64,
};

//
// Returns a fingerprint of the file at the given path, or null when it does not exist. The single stat is deliberate: checking for the
// file and then stat'ing it would be two steps, and a file that is deleted in between (an update lock being released, for instance)
// would make the stat fail even though "it is not there" is an answer this is meant to return.
//
pub fn fileFingerprint(io: std.Io, filePath: []const u8) !?IFileFingerprint {
    const stats = std.Io.Dir.cwd().statFile(io, filePath, .{}) catch |err| {
        if (err == error.FileNotFound) {
            return null;
        }
        return err;
    };
    // The modification time in whole milliseconds, truncated towards zero.
    return .{
        .modifiedMs = stats.mtime.toMilliseconds(),
        .size = stats.size,
    };
}

//
// Reports whether two fingerprints describe the same file state. Two absent files (both null) count as unchanged.
//
pub fn fingerprintsMatch(before: ?IFileFingerprint, after: ?IFileFingerprint) bool {
    if (before == null or after == null) {
        return before == null and after == null;
    }
    return before.?.modifiedMs == after.?.modifiedMs and before.?.size == after.?.size;
}

//
// Equivalent of `fs.rm(targetPath, { force: true })` for a file: a missing file is not an error.
//
noinline fn removeFileForce(io: std.Io, targetPath: []const u8) !void {
    std.Io.Dir.cwd().deleteFile(io, targetPath) catch |err| {
        if (err != error.FileNotFound) {
            return err;
        }
    };
}

//
// Tries to take the exclusive lock guarding updates to a file, without waiting. Creating the lock file with the 'wx' flag is a single
// atomic operation in the filesystem: exactly one caller can create it, and everyone else gets EEXIST. That is what makes the update
// safe. A check-then-create would not be, because two callers could both pass the check before either created the file.
//
// A lock left behind by a process that died while holding it would otherwise block every later update forever, so a lock older than
// LOCK_STALE_MS is broken. The threshold is far longer than any read-modify-write takes, so a live holder is never robbed of its lock.
//
pub fn tryTakeUpdateLock(io: std.Io, lockPath: []const u8) !bool {
    if (std.Io.Dir.cwd().createFile(io, lockPath, .{ .exclusive = true })) |lockHandle| {
        lockHandle.close(io);
        return true;
    }
    else |err| {
        // Anything other than "someone else holds it" is a real problem.
        if (err != error.PathAlreadyExists) {
            return err;
        }
    }

    const lockFingerprint = try fileFingerprint(io, lockPath);
    if (lockFingerprint != null and std.Io.Timestamp.now(io, .real).toMilliseconds() - lockFingerprint.?.modifiedMs > LOCK_STALE_MS) {
        try removeFileForce(io, lockPath);
    }

    return false;
}

//
// Equivalent of `Math.random()`: a random number in [0, 1).
//
noinline fn mathRandom(io: std.Io) f64 {
    var random_bytes: [8]u8 = undefined;
    io.random(&random_bytes);
    const random_bits = std.mem.readInt(u64, &random_bytes, .little) >> 11;
    return @as(f64, @floatFromInt(random_bits)) / @as(f64, @floatFromInt(@as(u64, 1) << 53));
}

//
// Returns how long to wait before another attempt: a randomized delay that grows with each one.
//
fn updateBackoffMs(io: std.Io, attempt: u32) f64 {
    return mathRandom(io) * @min(@as(f64, UPDATE_BACKOFF_MAX_MS), UPDATE_BACKOFF_BASE_MS * std.math.pow(f64, 2, @floatFromInt(attempt)));
}

//
// Waits for the exclusive lock guarding updates to a file, and reports whether it was taken.
//
pub fn takeUpdateLock(io: std.Io, lockPath: []const u8) !bool {
    var attempt: u32 = 0;
    while (attempt < LOCK_WAIT_ATTEMPTS) : (attempt += 1) {
        if (try tryTakeUpdateLock(io, lockPath)) {
            return true;
        }

        try sleep(io, updateBackoffMs(io, attempt));
    }

    return false;
}

//
// The two counts an update takes, as a struct so that they cannot be swapped: the most of the file it reads, and how many times it
// starts again when the file changes under it.
//
pub const UpdateOptions = struct {
    // The most of the file that is read, past which the update fails with `error.FileTooLarge` and leaves the file as it is.
    limit_bytes: u32,
    // How many times the change is re-applied after the file changed under the writer.
    retries: u32,
};

//
// One pass of the body of `update`, run while the update lock is held. Returns true when the result was published.
//
fn updateAttempt(arena: std.mem.Allocator, io: std.Io, path: []const u8, limit_bytes: u32, change: anytype) !bool {
    const fingerprintBefore = try fileFingerprint(io, path);
    const currentBytes = try readLimited(arena, io, path, limit_bytes);
    const updatedBytes = try change.run(arena, io, currentBytes);

    const tempPath = try std.mem.concat(arena, u8, &.{ path, ".tmp-", try randomUUID(arena, io) });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tempPath, .data = updatedBytes });

    // If the file is unchanged since we read it, publish our version atomically. Otherwise a writer that ignored the lock won; drop the
    // temp and start over.
    const fingerprintAfter = try fileFingerprint(io, path);
    if (fingerprintsMatch(fingerprintBefore, fingerprintAfter)) {
        try renameIntoPlace(io, tempPath, path);
        return true;
    }
    try removeFileForce(io, tempPath);
    return false;
}

//
// Updates a file's raw bytes as a read-modify-write that is safe against other processes doing the same thing at the same time. It takes
// an exclusive lock beside the file, reads the current bytes (or passes null to the change when the file does not exist yet), applies
// the change, writes the result to a temp file whose name carries a fresh UUID, and moves it into place. The lock is what makes
// concurrent updates lossless: without it two writers can both read the same contents and both publish, and whichever renames second
// silently discards the other's work.
//
// Holding the lock is not enough on its own, because a writer that does not take the lock can still change the file underneath us, so
// just before the atomic move it re-checks a cheap fingerprint (a stat, not a second full read) and retries from the fresh contents if
// the file moved on. `retries` bounds those conflicts only, not the wait for the lock, which is bounded separately: a slow write by one
// process is not a failure for the others, it is just their turn coming later. Waiting and retrying both back off with a randomized,
// growing delay, so writers that collide spread out instead of colliding again in lockstep.
//
// Zig has no closures, so the change is a value with a method `run(self, arena, io, current: ?[]const u8) ![]const u8`.
//
pub fn update(arena: std.mem.Allocator, io: std.Io, path: []const u8, options: UpdateOptions, change: anytype) !void {
    std.debug.assert(path.len > 0);
    std.debug.assert(options.limit_bytes > 0);
    // The lock lives beside the file, so the directory has to exist before we can take it.
    try ensureFileDir(io, path);
    const lockPath = try std.mem.concat(arena, u8, &.{ path, ".lock" });

    var attempt: u32 = 0;
    while (attempt <= options.retries) : (attempt += 1) {
        if (!try takeUpdateLock(io, lockPath)) {
            return errors.throwError("Failed to update {s}: could not take the update lock after {d} attempts.", .{ path, LOCK_WAIT_ATTEMPTS });
        }

        const published = updateAttempt(arena, io, path, options.limit_bytes, change);

        // Released on the way out however we leave, so a failed change does not strand the lock and make every other writer wait out
        // the staleness timeout.
        try removeFileForce(io, lockPath);

        if (try published) {
            return;
        }

        // Back off before trying again so the writers that collided do not collide again.
        try sleep(io, updateBackoffMs(io, attempt));
    }
    return errors.throwError("Failed to update {s}: the file kept changing under concurrent writers after {d} retries.", .{ path, options.retries });
}
