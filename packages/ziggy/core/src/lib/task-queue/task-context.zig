//
// TaskContext: implements ITaskContext for a single worker task.
//
const std = @import("std");
const utils = @import("utils.zig");
const types = @import("types.zig");
const ITaskContext = types.ITaskContext;
const IUuidGenerator = utils.uuid_generator.IUuidGenerator;
const ITimestampProvider = utils.timestamp_provider.ITimestampProvider;

//
// The function that sends a task's event back to the caller. The event is only valid during the call.
//
pub const SendEventFn = struct {
    // The state of the function, passed to function.
    context: ?*anyopaque,

    // Sends the event, with the calling thread's Io and allocator.
    function: *const fn (context: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, event: std.json.Value) void,

    //
    // Invokes the function.
    //
    pub fn call(self: SendEventFn, io: std.Io, allocator: std.mem.Allocator, event: std.json.Value) void {
        self.function(self.context, io, allocator, event);
    }
};

//
// Implements ITaskContext for a single worker task.
//
pub const TaskContext = struct {
    //
    // Generates unique identifiers.
    //
    uuidGenerator: IUuidGenerator,

    //
    // Provides the current timestamp.
    //
    timestampProvider: ITimestampProvider,

    //
    // Unique identifier for the session this task belongs to.
    //
    sessionId: []const u8,

    //
    // The unique ID of the currently executing task.
    //
    taskId: []const u8,

    //
    // How many child tasks this task may have running at once.
    //
    maxConcurrentChildTasks: u32,

    //
    // Whether this task has been cancelled. The context is used only on the thread that runs the task.
    //
    _isCancelled: bool,

    //
    // Sends an event back to the caller.
    //
    sendEventFn: SendEventFn,

    //
    // Creates the context of a task.
    //
    pub fn init(
        uuidGenerator: IUuidGenerator,
        timestampProvider: ITimestampProvider,
        sessionId: []const u8,
        taskId: []const u8,
        sendEventFn: SendEventFn,
        maxConcurrentChildTasks: u32,
    ) TaskContext {
        return .{
            .uuidGenerator = uuidGenerator,
            .timestampProvider = timestampProvider,
            .sessionId = sessionId,
            .taskId = taskId,
            .maxConcurrentChildTasks = maxConcurrentChildTasks,
            ._isCancelled = false,
            .sendEventFn = sendEventFn,
        };
    }

    //
    // Gets the ITaskContext interface for this context (the TaskContext must not move while it is used).
    //
    pub fn taskContext(self: *TaskContext) ITaskContext {
        return .{
            .uuidGenerator = self.uuidGenerator,
            .timestampProvider = self.timestampProvider,
            .sessionId = self.sessionId,
            .taskId = self.taskId,
            .maxConcurrentChildTasks = self.maxConcurrentChildTasks,
            .nativeCaller = null,
            .ptr = self,
            .vtable = &vtable,
        };
    }

    //
    // The ITaskContext functions of this context.
    //
    const vtable: ITaskContext.VTable = .{
        .sendEvent = sendEventErased,
        .isCancelled = isCancelledErased,
    };

    //
    // Sends an event back to the caller via the main process.
    //
    pub fn sendEvent(self: *TaskContext, io: std.Io, allocator: std.mem.Allocator, event: std.json.Value) void {
        self.sendEventFn.call(io, allocator, event);
    }

    //
    // Marks this task as cancelled.
    //
    pub fn cancel(self: *TaskContext) void {
        self._isCancelled = true;
    }

    //
    // Returns true if this task has been cancelled.
    //
    pub fn isCancelled(self: *TaskContext) bool {
        return self._isCancelled;
    }

    //
    // ITaskContext.sendEvent for this implementation.
    //
    fn sendEventErased(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, log: utils.log.ILog, event: std.json.Value) void {
        _ = log;
        const self: *TaskContext = @ptrCast(@alignCast(ptr));
        self.sendEvent(io, allocator, event);
    }

    //
    // ITaskContext.isCancelled for this implementation.
    //
    fn isCancelledErased(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator) bool {
        _ = io;
        _ = allocator;
        const self: *TaskContext = @ptrCast(@alignCast(ptr));
        return self.isCancelled();
    }
};
