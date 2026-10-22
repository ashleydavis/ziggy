//
// The dev host's file and folder dialogs. A browser gives a page no path a user chose, so the dev host shows the dialog itself. On
// Linux it runs zenity, the desktop's dialog program, and reads the chosen paths from what it prints, one to a line.
//

const std = @import("std");

//
// What a dialog is for, numbered as ziggy.h numbers ZIGGY_PICK_OPEN_FILES, ZIGGY_PICK_SAVE_FILE and ZIGGY_PICK_FOLDER.
//
pub const Kind = enum(i32) {
    // One or more existing files to open.
    open_files = 0,
    // Where to save a file.
    save_file = 1,
    // A folder.
    folder = 2,
};

//
// The kind of dialog the core passed, or null for a number ziggy.h does not give.
//
pub fn kindFromInt(value: i32) ?Kind {
    return std.enums.fromInt(Kind, value);
}

//
// The zenity command line that shows the dialog. The title defaults as the native Linux app's does, and the initial name is used
// only to save. Every string is allocated with the allocator given, so an arena frees them together.
//
pub fn zenityArgv(allocator: std.mem.Allocator, kind: Kind, title: ?[]const u8, initial_name: ?[]const u8) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    const default_title = switch (kind) {
        .open_files => "Select Files",
        .save_file => "Save As",
        .folder => "Select Folder",
    };
    try argv.appendSlice(allocator, &.{
        "zenity",
        "--file-selection",
        try std.fmt.allocPrint(allocator, "--title={s}", .{title orelse default_title}),
    });
    switch (kind) {
        .open_files => {
            try argv.appendSlice(allocator, &.{ "--multiple", "--separator=\n" });
        },
        .save_file => {
            try argv.append(allocator, "--save");
            if (initial_name) |name| {
                try argv.append(allocator, try std.fmt.allocPrint(allocator, "--filename={s}", .{name}));
            }
        },
        .folder => {
            try argv.append(allocator, "--directory");
        },
    }
    return argv.toOwnedSlice(allocator);
}

//
// The paths a dialog program printed, one to a line, as a JSON array. Empty lines are left out.
//
pub fn pathsJsonFromOutput(allocator: std.mem.Allocator, output: []const u8) ![]u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(allocator);
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const path = std.mem.trimEnd(u8, line, "\r");
        if (path.len > 0) {
            try paths.append(allocator, path);
        }
    }
    return std.json.Stringify.valueAlloc(allocator, paths.items, .{});
}

//
// Shows the dialog with zenity, waits for the user and returns what they chose as a JSON array of paths, "[]" when they
// cancelled. Fails with why on stderr when zenity is not installed or reports an error.
//
pub fn pick(io: std.Io, allocator: std.mem.Allocator, kind: Kind, title: ?[]const u8, initial_name: ?[]const u8) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const argv = try zenityArgv(arena.allocator(), kind, title, initial_name);
    const result = std.process.run(arena.allocator(), io, .{
        .argv = argv,
    }) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("ziggy dev host: a file or folder dialog needs zenity, which is not installed. Install it with the system's package manager.\n", .{});
        }
        return err;
    };
    switch (result.term) {
        .exited => |code| switch (code) {
            0 => return pathsJsonFromOutput(allocator, result.stdout),
            // zenity exits with 1 when the user cancels.
            1 => return allocator.dupe(u8, "[]"),
            else => {
                std.debug.print("ziggy dev host: zenity failed with exit code {d}: {s}\n", .{ code, result.stderr });
                return error.DialogFailed;
            },
        },
        else => {
            std.debug.print("ziggy dev host: zenity ended without an exit code: {s}\n", .{result.stderr});
            return error.DialogFailed;
        },
    }
}
