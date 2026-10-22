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

    // Sends the event.
    function: *const fn (context: ?*anyopaque, event: std.json.Value) void,

    //
    // Invokes the function.
    //
    pub fn call(self: SendEventFn, event: std.json.Value) void {
        self.function(self.context, event);
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
    // Whether this task has been cancelled (atomic: cancel is called from another thread than the task's).
    //
    _isCancelled: std.atomic.Value(bool),

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
            ._isCancelled = std.atomic.Value(bool).init(false),
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
            .hostRequester = null,
            .toolRunner = null,
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
    pub fn sendEvent(self: *TaskContext, event: std.json.Value) void {
        self.sendEventFn.call(event);
    }

    //
    // Marks this task as cancelled.
    //
    pub fn cancel(self: *TaskContext) void {
        self._isCancelled.store(true, .release);
    }

    //
    // Returns true if this task has been cancelled.
    //
    pub fn isCancelled(self: *TaskContext) bool {
        return self._isCancelled.load(.acquire);
    }

    //
    // ITaskContext.sendEvent for this implementation.
    //
    fn sendEventErased(ptr: *anyopaque, event: std.json.Value) void {
        const self: *TaskContext = @ptrCast(@alignCast(ptr));
        self.sendEvent(event);
    }

    //
    // ITaskContext.isCancelled for this implementation.
    //
    fn isCancelledErased(ptr: *anyopaque) bool {
        const self: *TaskContext = @ptrCast(@alignCast(ptr));
        return self.isCancelled();
    }
};
