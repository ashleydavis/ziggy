//
// The one way either file is written: the update lock, the fingerprint check, the temporary file and the rename, and the words they fail
// with.
//

const std = @import("std");
const builtin = @import("builtin");
const atomic_file = @import("config_state").atomic_file;
const utils = @import("utils");

const Change = atomic_file.UpdateOptions;

test "atomic file: update creates the directory and the file, then replaces it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory_path, "nested", "config.toml" });
    defer std.testing.allocator.free(path);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try atomic_file.update(arena, std.testing.io, path, .{ .limit_bytes = 1024, .retries = 3 }, ReplaceChange{ .data = "first" });
    const first = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, arena, .limited(1024));
    try std.testing.expectEqualStrings("first", first);

    try atomic_file.update(arena, std.testing.io, path, .{ .limit_bytes = 1024, .retries = 3 }, ReplaceChange{ .data = "second" });
    const second = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, arena, .limited(1024));
    try std.testing.expectEqualStrings("second", second);

    const nested_path = try std.fs.path.join(std.testing.allocator, &.{ directory_path, "nested" });
    defer std.testing.allocator.free(nested_path);
    try expectOnlyFile(nested_path, "config.toml");
}

test "atomic file: a change that fails leaves the file and removes the lock" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory_path, "config.toml" });
    defer std.testing.allocator.free(path);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try atomic_file.update(arena, std.testing.io, path, .{ .limit_bytes = 1024, .retries = 3 }, ReplaceChange{ .data = "kept" });
    try std.testing.expectError(error.Refused, atomic_file.update(arena, std.testing.io, path, .{ .limit_bytes = 1024, .retries = 3 }, FailChange{}));
    const kept = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, arena, .limited(1024));
    try std.testing.expectEqualStrings("kept", kept);
    try expectOnlyFile(directory_path, "config.toml");

    try atomic_file.update(arena, std.testing.io, path, .{ .limit_bytes = 1024, .retries = 3 }, ReplaceChange{ .data = "after" });
    const after = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, arena, .limited(1024));
    try std.testing.expectEqualStrings("after", after);
}

test "atomic file: a lock older than 30 seconds is broken" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory_path, "config.toml" });
    defer std.testing.allocator.free(path);
    const lock_path = try std.mem.concat(std.testing.allocator, u8, &.{ path, ".lock" });
    defer std.testing.allocator.free(lock_path);

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config.toml.lock", .data = "" });
    const lock_file = try std.Io.Dir.cwd().openFile(std.testing.io, lock_path, .{ .mode = .read_write });
    defer lock_file.close(std.testing.io);
    try lock_file.setTimestamps(std.testing.io, .{
        .modify_timestamp = .{ .new = std.Io.Timestamp.now(std.testing.io, .real).subDuration(.fromMilliseconds(31000)) },
    });

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try atomic_file.update(arena_state.allocator(), std.testing.io, path, .{ .limit_bytes = 1024, .retries = 3 }, ReplaceChange{ .data = "written" });
    const written = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, arena_state.allocator(), .limited(1024));
    try std.testing.expectEqualStrings("written", written);
    try expectOnlyFile(directory_path, "config.toml");
}

test "atomic file: a writer that does not take the lock makes the change run again with the new bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory_path, "config.toml" });
    defer std.testing.allocator.free(path);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const seen: *std.ArrayList([]const u8) = try arena.create(std.ArrayList([]const u8));
    seen.* = .empty;

    const calls: *usize = try arena.create(usize);
    calls.* = 0;
    const change = InterferingChange{ .path = path, .calls = calls, .seen = seen };
    try atomic_file.update(arena, std.testing.io, path, .{ .limit_bytes = 1024, .retries = 3 }, change);
    try std.testing.expectEqual(@as(usize, 2), seen.items.len);
    try std.testing.expectEqualStrings("", seen.items[0]);
    try std.testing.expectEqualStrings("other bytes", seen.items[1]);
    const written = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, arena, .limited(1024));
    try std.testing.expectEqualStrings("final", written);
    try expectOnlyFile(directory_path, "config.toml");
}

test "atomic file: a writer that always changes the file exhausts the retries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory_path, "config.toml" });
    defer std.testing.allocator.free(path);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const calls: *usize = try arena.create(usize);
    calls.* = 0;

    try std.testing.expectError(error.Thrown, atomic_file.update(arena, std.testing.io, path, .{ .limit_bytes = 1024, .retries = 3 }, AlwaysInterferingChange{ .path = path, .calls = calls }));
    try std.testing.expectEqual(@as(usize, 4), calls.*);
    try std.testing.expect(std.mem.indexOf(u8, utils.errors.lastErrorMessage(), "after 3 retries") != null);
    try expectOnlyFile(directory_path, "config.toml");
}

test "atomic file: fingerprints tell a missing file from a present one" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory_path, "config.toml" });
    defer std.testing.allocator.free(path);

    try std.testing.expect(try atomic_file.fileFingerprint(std.testing.io, path) == null);
    try std.testing.expect(atomic_file.fingerprintsMatch(null, null));
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config.toml", .data = "x" });
    const present = try atomic_file.fileFingerprint(std.testing.io, path);
    try std.testing.expect(present != null);
    try std.testing.expect(!atomic_file.fingerprintsMatch(null, present));
}

test "atomic file: two threads appending to one file keep every line" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory_path, "config.toml" });
    defer std.testing.allocator.free(path);

    var first_errors: ?anyerror = null;
    var second_errors: ?anyerror = null;
    const first = try std.Thread.spawn(.{}, appendThread, .{ path, "first", &first_errors });
    const second = try std.Thread.spawn(.{}, appendThread, .{ path, "second", &second_errors });
    first.join();
    second.join();
    try std.testing.expect(first_errors == null);
    try std.testing.expect(second_errors == null);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, arena_state.allocator(), .limited(1024 * 1024));
    var lines: usize = 0;
    var iterator = std.mem.splitScalar(u8, text, '\n');
    while (iterator.next()) |line| {
        if (line.len > 0) {
            lines += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 200), lines);
}

test "atomic file: readLimited reports a missing file and refuses one over the limit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory_path, "config.toml" });
    defer std.testing.allocator.free(path);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expect(try atomic_file.readLimited(arena_state.allocator(), std.testing.io, path, 1024) == null);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config.toml", .data = "12345" });
    try std.testing.expectError(error.FileTooLarge, atomic_file.readLimited(arena_state.allocator(), std.testing.io, path, 4));
}

test "atomic file: update refuses a file over the limit before the change runs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory_path, "config.toml" });
    defer std.testing.allocator.free(path);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config.toml", .data = "12345" });

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const called: *bool = try arena.create(bool);
    called.* = false;

    try std.testing.expectError(error.FileTooLarge, atomic_file.update(arena, std.testing.io, path, .{ .limit_bytes = 4, .retries = 3 }, CountingChange{ .called = called }));
    try std.testing.expect(!called.*);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, arena, .limited(1024));
    try std.testing.expectEqualStrings("12345", bytes);
    try expectOnlyFile(directory_path, "config.toml");
}

test "atomic file: update refuses a directory that is a file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory_path);
    const blocked_path = try std.fs.path.join(std.testing.allocator, &.{ directory_path, "blocked" });
    defer std.testing.allocator.free(blocked_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ blocked_path, "config.toml" });
    defer std.testing.allocator.free(path);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "blocked", .data = "a file, not a directory" });

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectError(error.Thrown, atomic_file.update(arena_state.allocator(), std.testing.io, path, .{ .limit_bytes = 1024, .retries = 3 }, ReplaceChange{ .data = "never" }));
    try std.testing.expect(std.mem.indexOf(u8, utils.errors.lastErrorMessage(), "not a directory") != null);
}

test "atomic file: tryTakeUpdateLock sees a fresh lock and takeUpdateLock gives up after 50 tries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory_path, "config.toml" });
    defer std.testing.allocator.free(path);
    const lock_path = try std.mem.concat(std.testing.allocator, u8, &.{ path, ".lock" });
    defer std.testing.allocator.free(lock_path);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config.toml", .data = "kept" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config.toml.lock", .data = "" });

    try std.testing.expect(!try atomic_file.tryTakeUpdateLock(std.testing.io, lock_path));
    try std.testing.expect(!try atomic_file.takeUpdateLock(std.testing.io, lock_path));

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectError(error.Thrown, atomic_file.update(arena, std.testing.io, path, .{ .limit_bytes = 1024, .retries = 3 }, ReplaceChange{ .data = "never" }));
    try std.testing.expect(std.mem.indexOf(u8, utils.errors.lastErrorMessage(), "could not take the update lock after 50 attempts") != null);
    const kept = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, arena, .limited(1024));
    try std.testing.expectEqualStrings("kept", kept);
    try std.Io.Dir.cwd().access(std.testing.io, lock_path, .{});
}

test "atomic file: renameIntoPlace retries a refused rename and succeeds once it is allowed" {
    if (builtin.os.tag == .windows) {
        try renameRefusedOnWindows();
    }
    else {
        try renameRefusedOnPosix();
    }
}

//
// The POSIX refusal: a directory whose permissions leave out writing refuses the rename for as long as they are off.
//
fn renameRefusedOnPosix() !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory_path, "config.toml" });
    defer std.testing.allocator.free(path);
    const temp_path = try std.fs.path.join(std.testing.allocator, &.{ directory_path, "config.toml.tmp-test" });
    defer std.testing.allocator.free(temp_path);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config.toml", .data = "old" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config.toml.tmp-test", .data = "new" });

    try std.Io.Dir.cwd().setFilePermissions(std.testing.io, directory_path, @enumFromInt(0o555), .{});
    const started_ms = std.Io.Timestamp.now(std.testing.io, .real).toMilliseconds();
    try std.testing.expectError(error.AccessDenied, atomic_file.renameIntoPlace(std.testing.io, temp_path, path));
    const elapsed_ms = std.Io.Timestamp.now(std.testing.io, .real).toMilliseconds() - started_ms;
    try std.testing.expect(elapsed_ms >= 1100);
    try std.Io.Dir.cwd().setFilePermissions(std.testing.io, directory_path, @enumFromInt(0o755), .{});

    try atomic_file.renameIntoPlace(std.testing.io, temp_path, path);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, arena_state.allocator(), .limited(1024));
    try std.testing.expectEqualStrings("new", text);
}

//
// The Windows refusal: a handle without delete sharing makes the rename a sharing violation until it is closed.
//
fn renameRefusedOnWindows() !void {
    const windows = std.os.windows;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory_path, "config.toml" });
    defer std.testing.allocator.free(path);
    const temp_path = try std.fs.path.join(std.testing.allocator, &.{ directory_path, "config.toml.tmp-test" });
    defer std.testing.allocator.free(temp_path);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config.toml", .data = "old" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config.toml.tmp-test", .data = "new" });

    const cwd_handle = std.Io.Dir.cwd().handle;
    const path_space = try std.Io.Threaded.sliceToPrefixedFileW(cwd_handle, path, .{});
    const path_wide = path_space.span();
    var handle: windows.HANDLE = undefined;
    var status_block: windows.IO_STATUS_BLOCK = undefined;
    const status = windows.ntdll.NtCreateFile(
        &handle,
        .{
            .GENERIC = .{ .READ = true },
            .STANDARD = .{ .RIGHTS = .{ .SYNCHRONIZE = true } },
        },
        &.{
            .RootDirectory = if (std.fs.path.isAbsoluteWindowsWtf16(path_wide)) null else cwd_handle,
            .ObjectName = @constCast(&windows.UNICODE_STRING.init(path_wide)),
        },
        &status_block,
        null,
        .{ .NORMAL = true },
        .{ .READ = true },
        .OPEN,
        .{ .IO = .ASYNCHRONOUS },
        null,
        0,
    );
    try std.testing.expectEqual(windows.NTSTATUS.SUCCESS, status);
    try std.testing.expectError(error.FileBusy, atomic_file.renameIntoPlace(std.testing.io, temp_path, path));
    windows.CloseHandle(handle);

    try atomic_file.renameIntoPlace(std.testing.io, temp_path, path);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, arena_state.allocator(), .limited(1024));
    try std.testing.expectEqualStrings("new", text);
}

//
// Expects the directory at the path to hold exactly one entry, the named one.
//
fn expectOnlyFile(directory_path: []const u8, file_name: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var directory = try std.Io.Dir.cwd().openDir(std.testing.io, directory_path, .{ .iterate = true });
    defer directory.close(std.testing.io);
    var walker = try directory.walk(arena);
    defer walker.deinit();
    var names: std.ArrayList([]const u8) = .empty;
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind == .file) {
            try names.append(arena, try arena.dupe(u8, std.fs.path.basename(entry.path)));
        }
    }
    try std.testing.expectEqual(@as(usize, 1), names.items.len);
    try std.testing.expectEqualStrings(file_name, names.items[0]);
}

//
// Appends its lines to the file from a thread with an allocator and an Io of its own.
//
fn appendThread(path: []const u8, prefix: []const u8, failure: *?anyerror) void {
    var thread_allocator: utils.thread_allocator.ThreadAllocator = .init;
    defer thread_allocator.deinit();
    const allocator = thread_allocator.allocator();
    var threaded: std.Io.Threaded = .init_single_threaded;
    threaded.allocator = allocator;
    defer threaded.deinit();
    const io = threaded.io();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var number: usize = 0;
    while (number < 100) : (number += 1) {
        const line = std.fmt.allocPrint(arena, "{s} {d}\n", .{ prefix, number }) catch @panic("out of memory building a line");
        atomic_file.update(arena, io, path, .{ .limit_bytes = 1024 * 1024, .retries = 3 }, AppendChange{ .line = line }) catch |err| {
            failure.* = err;
            return;
        };
    }
}

//
// A change that replaces the file's bytes.
//
const ReplaceChange = struct {
    // The bytes to write.
    data: []const u8,

    //
    // Writes the bytes.
    //
    pub fn run(self: *const @This(), arena: std.mem.Allocator, io: std.Io, current: ?[]const u8) ![]const u8 {
        _ = io;
        _ = current;
        return arena.dupe(u8, self.data);
    }
};

//
// A change that appends one line.
//
const AppendChange = struct {
    // The line to append.
    line: []const u8,

    //
    // Appends the line to the bytes it is handed.
    //
    pub fn run(self: *const @This(), arena: std.mem.Allocator, io: std.Io, current: ?[]const u8) ![]const u8 {
        _ = io;
        if (current) |bytes| {
            return std.mem.concat(arena, u8, &.{ bytes, self.line });
        }
        return arena.dupe(u8, self.line);
    }
};

//
// A change that fails.
//
const FailChange = struct {
    //
    // Fails.
    //
    pub fn run(self: *const @This(), arena: std.mem.Allocator, io: std.Io, current: ?[]const u8) ![]const u8 {
        _ = self;
        _ = arena;
        _ = io;
        _ = current;
        return error.Refused;
    }
};

//
// A change that records the bytes it is handed and changes the file behind the lock on its first call only.
//
const InterferingChange = struct {
    // The file to write behind the lock on the first call.
    path: []const u8,
    // How many times the change has run.
    calls: *usize,
    // The bytes the change was handed on each run.
    seen: *std.ArrayList([]const u8),

    //
    // Records the bytes; on the first run writes different bytes to the file itself, and afterwards publishes its own result.
    //
    pub fn run(self: *const @This(), arena: std.mem.Allocator, io: std.Io, current: ?[]const u8) ![]const u8 {
        try self.seen.append(arena, try arena.dupe(u8, current orelse ""));
        self.calls.* += 1;
        if (self.calls.* == 1) {
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = self.path, .data = "other bytes" });
        }
        return arena.dupe(u8, "final");
    }
};

//
// A change that writes different-length bytes to the file on every run.
//
const AlwaysInterferingChange = struct {
    // The file to write behind the lock on every run.
    path: []const u8,
    // How many times the change has run.
    calls: *usize,

    //
    // Writes bytes whose length grows, so the fingerprint always changes, and publishes its own result.
    //
    pub fn run(self: *const @This(), arena: std.mem.Allocator, io: std.Io, current: ?[]const u8) ![]const u8 {
        _ = current;
        self.calls.* += 1;
        var buffer: [64]u8 = undefined;
        @memset(buffer[0..self.calls.*], 'x');
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = self.path, .data = buffer[0..self.calls.*] });
        return arena.dupe(u8, "never published");
    }
};

//
// A change that records whether it ran.
//
const CountingChange = struct {
    // Whether the change ran.
    called: *bool,

    //
    // Records that it ran.
    //
    pub fn run(self: *const @This(), arena: std.mem.Allocator, io: std.Io, current: ?[]const u8) ![]const u8 {
        _ = io;
        self.called.* = true;
        return arena.dupe(u8, current orelse "");
    }
};
