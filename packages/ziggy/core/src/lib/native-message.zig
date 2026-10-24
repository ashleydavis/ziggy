//
// The messages the core sends the native app, and the results the native app sends back (see ziggy.h). The core posts each message
// to the native app's queue and wakes the native app's UI thread, which takes them with ziggy_take_native_message, so only that thread
// touches the native app's state. A message of the kind `deliver` is a message for the frontend, which the native app passes to the
// web view unread. A message of the kind `call` is a JSON object whose "type" names what the native app is to do. A call that has
// a result gets it on the UI thread through ziggy_native_result, and the result reaches the thread that made the call as a message on
// that thread's own queue.
//
// This file uses nothing but std, so the native apps written in Zig import it too.
//

const std = @import("std");

//
// The kind of a message for the native app, as ziggy_take_native_message gives it.
//
pub const Kind = enum(i32) {
    // A message for the frontend.
    deliver = 0,
    // A call: something the native app is to do.
    call = 1,
    // Any other kind is never sent by the core: a fake native app's test sends its own (see fake-native-app.zig).
    _,
};

//
// What a call has the native app show, for a file or folder dialog.
//
pub const PickPaths = struct {
    // The kind of dialog: 0 to open files, 1 to save a file, 2 to choose a folder (see types.PickKind).
    kind: i32,
    // The dialog's title, or null.
    title: ?[]const u8,
    // For a save dialog the suggested file name, and for the others the folder the dialog starts in, or null.
    initial_name: ?[]const u8,
};

//
// What a call has the native app do that only the platform can do, by name.
//
pub const NativeCall = struct {
    // The method's name ("exportFile", "secureStoreGet", ...).
    method: []const u8,
    // The JSON text of the method's argument.
    request: []const u8,
};

//
// A call: what the native app is to do.
//
pub const Call = union(enum) {
    // Quit the application. No result.
    quit,
    // Do a menu action as if its menu item had been chosen, by the path the menu item takes in the native app. No result.
    menu_action: []const u8,
    // Keep the app running (true), because tasks marked keep-alive are queued or running, or stop (false). No result.
    keep_alive: bool,
    // Give the operating system's version: the result is the JSON text of a string.
    os_version,
    // Show a file or folder dialog: the result is the JSON text of an array of the paths chosen, "[]" when the user cancelled.
    pick_paths: PickPaths,
    // Do one thing only the platform can do: the result is the JSON text the method gives.
    native_call: NativeCall,
    // Write a PNG of the app's window to the file at the path: the result is empty.
    screenshot: []const u8,
    // The core's main thread has stopped and sends nothing more. Only the core's own side of the queue reads it (see NativeSide).
    stopped,
};

//
// A call as it is written: one JSON object, with only the fields of its type.
//
const Wire = struct {
    type: []const u8,
    callId: ?u64 = null,
    action: ?[]const u8 = null,
    keepRunning: ?bool = null,
    kind: ?i32 = null,
    title: ?[]const u8 = null,
    initialName: ?[]const u8 = null,
    method: ?[]const u8 = null,
    request: ?[]const u8 = null,
    outputPath: ?[]const u8 = null,
};

//
// The JSON text of a call, allocated with the allocator. `call_id` is the number the caller's result comes back under, or null for a
// call with no result.
//
pub fn encode(allocator: std.mem.Allocator, call: Call, call_id: ?u64) ![]u8 {
    var wire: Wire = .{
        .type = typeName(call),
        .callId = call_id,
    };
    switch (call) {
        .quit, .os_version, .stopped => {},
        .menu_action => |action| wire.action = action,
        .keep_alive => |keep_running| wire.keepRunning = keep_running,
        .pick_paths => |pick| {
            wire.kind = pick.kind;
            wire.title = pick.title;
            wire.initialName = pick.initial_name;
        },
        .native_call => |native_call| {
            wire.method = native_call.method;
            wire.request = native_call.request;
        },
        .screenshot => |output_path| wire.outputPath = output_path,
    }
    return try std.json.Stringify.valueAlloc(allocator, wire, .{
        .emit_null_optional_fields = false,
    });
}

//
// Reads the JSON text of a call, with its strings in the arena.
//
pub fn parse(arena: std.mem.Allocator, text: []const u8) !Call {
    const wire = try std.json.parseFromSliceLeaky(Wire, arena, text, .{});
    if (std.mem.eql(u8, wire.type, "quit")) {
        return .quit;
    }
    if (std.mem.eql(u8, wire.type, "menu-action")) {
        return .{
            .menu_action = wire.action orelse return error.InvalidCall,
        };
    }
    if (std.mem.eql(u8, wire.type, "keep-alive")) {
        return .{
            .keep_alive = wire.keepRunning orelse return error.InvalidCall,
        };
    }
    if (std.mem.eql(u8, wire.type, "os-version")) {
        return .os_version;
    }
    if (std.mem.eql(u8, wire.type, "pick-paths")) {
        return .{
            .pick_paths = .{
                .kind = wire.kind orelse return error.InvalidCall,
                .title = wire.title,
                .initial_name = wire.initialName,
            },
        };
    }
    if (std.mem.eql(u8, wire.type, "native-call")) {
        return .{
            .native_call = .{
                .method = wire.method orelse return error.InvalidCall,
                .request = wire.request orelse return error.InvalidCall,
            },
        };
    }
    if (std.mem.eql(u8, wire.type, "screenshot")) {
        return .{
            .screenshot = wire.outputPath orelse return error.InvalidCall,
        };
    }
    if (std.mem.eql(u8, wire.type, "stopped")) {
        return .stopped;
    }
    return error.InvalidCall;
}

//
// The number a call's result comes back under, or null for a call with no result.
//
pub fn callId(arena: std.mem.Allocator, text: []const u8) !?u64 {
    const wire = try std.json.parseFromSliceLeaky(Wire, arena, text, .{});
    return wire.callId;
}

//
// The JSON text of a call's result as it reaches the thread that made the call, allocated with the allocator: a
// `native-app-response` (worker-messages.zig's INativeAppResponseMessage) with the call's number as its request id, and the text as
// its result when the native app did what the call names, or as its error, the reason, when it could not.
//
pub fn resultJson(allocator: std.mem.Allocator, call_id: u64, succeeded: bool, text: []const u8) ![]u8 {
    if (succeeded) {
        return try std.json.Stringify.valueAlloc(allocator, .{
            .type = "native-app-response",
            .requestId = call_id,
            .result = text,
        }, .{});
    }
    return try std.json.Stringify.valueAlloc(allocator, .{
        .type = "native-app-response",
        .requestId = call_id,
        .@"error" = text,
    }, .{});
}

//
// The name a call is written with.
//
fn typeName(call: Call) []const u8 {
    return switch (call) {
        .quit => "quit",
        .menu_action => "menu-action",
        .keep_alive => "keep-alive",
        .os_version => "os-version",
        .pick_paths => "pick-paths",
        .native_call => "native-call",
        .screenshot => "screenshot",
        .stopped => "stopped",
    };
}
