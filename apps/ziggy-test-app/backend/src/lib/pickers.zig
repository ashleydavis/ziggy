//
// The test app's file and folder pickers. They answer the pick-folder, pick-files and pick-file messages, each handler answering with the task of its name: a
// cancelled dialog is a reply of null. Each runs as a task, because a dialog waits for the user and must not hold up the thread that handles UI
// messages.
//

const std = @import("std");
const ziggy = @import("ziggy-core");

const TaskContext = ziggy.task_runner.TaskContext;
const json = ziggy.json;

//
// Shows a dialog and returns the first path chosen as a JSON string, or null when the user cancelled.
//
fn firstPath(context: *TaskContext, kind: ziggy.types.PickKind, title: ?[]const u8, initial_name: ?[]const u8) !?[]const u8 {
    const answer = try context.pickPaths(kind, title, initial_name);
    const paths = try std.json.parseFromSliceLeaky(std.json.Value, context.arena, answer, .{});
    if (paths != .array or paths.array.items.len == 0) {
        return try context.arena.dupe(u8, "null");
    }
    return try json.stringify(context.arena, paths.array.items[0]);
}

//
// pick-folder: data is an options object that may name a "title", or null. The reply is the
// folder's path, or null.
//
pub fn pickFolderHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    const title = json.getString(data, "title") orelse "Select Folder";
    return try firstPath(context, .folder, title, null);
}

//
// pick-files: data is the dialog's title, a string. The reply is the array of the paths chosen, or null.
//
pub fn pickFilesHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    const title: []const u8 = if (data == .string) data.string else "Select Files";
    const answer = try context.pickPaths(.open_files, title, null);
    const paths = try std.json.parseFromSliceLeaky(std.json.Value, context.arena, answer, .{});
    if (paths != .array or paths.array.items.len == 0) {
        return try context.arena.dupe(u8, "null");
    }
    return answer;
}

//
// pick-file: a save dialog, where data is the suggested file name, a string. The reply is the path chosen to
// save to, or null.
//
pub fn pickFileHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    const initial_name: []const u8 = if (data == .string) data.string else "";
    return try firstPath(context, .save_file, "Save As", initial_name);
}

//
// The data of pick-folder.
//
pub const PickFolderRequest = struct {
    // The dialog's title, or null for the default.
    title: ?[]const u8 = null,
};

//
// pick-folder: answered by the pick-folder task, which is given the request. The response is the folder's path, or null.
//
pub fn pickFolderMessageHandler(core: *ziggy.core.Core, arena: std.mem.Allocator, request: PickFolderRequest) !ziggy.core.Answer(?[]const u8) {
    _ = core;
    return .{
        .task = .{
            .task_type = "pick-folder",
            .data = try json.stringify(arena, request),
        },
    };
}

//
// The data of pick-files.
//
pub const PickFilesRequest = struct {
    // The dialog's title, or null for the default.
    title: ?[]const u8 = null,
};

//
// pick-files: answered by the pick-files task, which is given the title. The response is the paths chosen, or null.
//
pub fn pickFilesMessageHandler(core: *ziggy.core.Core, arena: std.mem.Allocator, request: PickFilesRequest) !ziggy.core.Answer(?[]const []const u8) {
    _ = core;
    return .{
        .task = .{
            .task_type = "pick-files",
            .data = try json.stringify(arena, request.title),
        },
    };
}

//
// The data of pick-file.
//
pub const PickFileRequest = struct {
    // The suggested file name, or null for none.
    name: ?[]const u8 = null,
};

//
// pick-file: answered by the pick-file task, which is given the suggested name. The response is the path chosen, or null.
//
pub fn pickFileMessageHandler(core: *ziggy.core.Core, arena: std.mem.Allocator, request: PickFileRequest) !ziggy.core.Answer(?[]const u8) {
    _ = core;
    return .{
        .task = .{
            .task_type = "pick-file",
            .data = try json.stringify(arena, request.name),
        },
    };
}
