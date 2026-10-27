//
// Worker infrastructure for task execution
// This module provides the core worker functionality that can be imported
// by application-specific worker files
//

const std = @import("std");
const utils = @import("utils.zig");
const types = @import("types.zig");
const TaskHandler = types.TaskHandler;
const ITaskContext = types.ITaskContext;
const errors = utils.errors;
const Timers = @import("../timers.zig").Timers;

//
// A task type and the handler that runs it, as an app lists its handlers. There is no list of handlers shared by the threads of the
// process: whoever runs a task is given the list the app declared.
//
pub const IHandlerEntry = struct {
    // The task type.
    type: []const u8,
    // The handler for it.
    handler: TaskHandler,
};

//
// Gets the handler for a task type from the list, or null when it has none.
//
pub fn getHandler(handlers: []const IHandlerEntry, @"type": []const u8) ?TaskHandler {
    for (handlers) |entry| {
        if (std.mem.eql(u8, entry.type, @"type")) {
            return entry.handler;
        }
    }
    return null;
}

//
// Shared function to execute a task handler
// Returns the handler outputs, or throws an error if the handler is not found or execution fails
//
pub fn executeTaskHandler(allocator: std.mem.Allocator, io: std.Io, timers: Timers, log: utils.log.ILog, handlers: []const IHandlerEntry, taskType: []const u8, data: std.json.Value, context: ITaskContext) !std.json.Value {
    const handler = getHandler(handlers, taskType) orelse {
        var registeredTypes: std.ArrayList([]const u8) = .empty;
        for (handlers) |entry| {
            try registeredTypes.append(allocator, entry.type);
        }
        const joined = try std.mem.join(allocator, ", ", registeredTypes.items);
        return errors.throwError("No handler registered for task type: {s}. Available handlers: {s}", .{ taskType, joined });
    };

    return handler(allocator, io, timers, log, data, context);
}
