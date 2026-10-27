//
// The types that cross the C interface and the types handlers are written against.
//

const std = @import("std");

//
// Wakes the native app's UI thread to take the core's messages with ziggy_take_native_message (see native-message.zig). The core calls
// it from any of its threads after it posts a message for the native app. It only has the platform run code on the UI thread, and is
// given the native app's wake_data unread: the core never touches the native app's state.
//
pub const WakeFn = *const fn (wake_data: ?*anyopaque) callconv(.c) void;

//
// The kind of dialog a native app shows.
//
pub const PickKind = enum(i32) {
    // A dialog to choose one or more existing files to open.
    open_files = 0,
    // A dialog to choose where to save a file, with a suggested name.
    save_file = 1,
    // A dialog to choose a folder.
    folder = 2,
};

//
// What a native app returned for a native call.
//
pub const NativeCallResult = struct {
    // Whether the native app did what the method names.
    succeeded: bool,
    // The JSON text of the result when it succeeded, and the text of the reason when it did not.
    text: []const u8,
};

//
// What the native app passes to ziggy_create. Every pointer is copied by the core, so it need only be valid during the call.
// Declared with the same fields, in the same order, in ziggy.h.
//
pub const ZiggyConfig = extern struct {
    // What the native app gives wake: a value that reaches its UI thread through the platform, never its state. The core hands it to
    // wake unread.
    wake_data: ?*anyopaque,
    // Wakes the native app's UI thread to take the core's messages. Required.
    wake: ?WakeFn,
    // Whether the native app gives the operating system's version.
    has_os_version: bool,
    // Whether the native app can quit the application.
    has_quit: bool,
    // Whether the native app shows native file and folder dialogs.
    has_pick_paths: bool,
    // Whether the native app does menu actions as if their menu items had been chosen: false on a platform with no menu. Used only
    // by the test control connection.
    has_menu_action: bool,
    // Whether the native app keeps the app running for keep-alive tasks.
    has_keep_alive: bool,
    // Whether the native app does the things only the platform can do (a share sheet, a permission prompt, the keychain), by name.
    has_native_call: bool,
    // Whether the native app writes a PNG of its window to a file. Used only by the test control connection; without it a screenshot
    // is taken from outside the app.
    has_screenshot: bool,
    // The number of worker threads.
    worker_threads: u32,
    // The limit on child tasks in flight for any one parent task.
    max_concurrent_child_tasks: u32,
    // The URL prefix of the app's own bundled frontend, such as "ziggy-app://app/" or "https://ziggy-app.invalid/", the address the native app serves the frontend from (NUL terminated).
    app_url_prefix: [*:0]const u8,
    // The app's private data directory (NUL terminated).
    data_dir: [*:0]const u8,
    // Non-zero to start the test control connection. Used only in a test hooks build.
    test_mode: bool,
    // The file the test control connection writes its port to, or null for none. Used only in a test hooks build.
    test_port_file: ?[*:0]const u8,
    // The number of the native app's command-line arguments in `args`, after the program's name. 0 for a native app with none (Android,
    // iOS).
    arg_count: u32,
    // The native app's command-line arguments after the program's name (NUL terminated), or null when arg_count is 0. The app reads them
    // through `HandlerServices.arguments`.
    args: ?[*]const [*:0]const u8,
};

//
// The native app's command-line arguments from its configuration, as slices of its strings, in a list allocated with the arena. The
// strings are the configuration's, valid only as long as it is.
//
pub fn configArguments(arena: std.mem.Allocator, config: ZiggyConfig) ![]const []const u8 {
    if (config.arg_count == 0) {
        return &.{};
    }
    const args = config.args orelse return error.ArgumentsMissing;
    const arguments = try arena.alloc([]const u8, config.arg_count);
    for (arguments, 0..) |*argument, index| {
        argument.* = std.mem.span(args[index]);
    }
    return arguments;
}

//
// The result of a URL check.
//
pub const UrlDecision = enum(i32) {
    // The address is the app's own frontend.
    allow = 0,
    // The address is an external link, to open in the system browser.
    open_externally = 1,
    // The address must not be loaded.
    block = 2,
};

//
// How a task ended.
//
pub const TaskStatus = enum {
    succeeded,
    failed,
    cancelled,
};

//
// The completion of a task, as reported to the frontend and to a parent that awaits it.
//
pub const Completion = struct {
    // How the task ended.
    status: TaskStatus,
    // The JSON text of the result, when it succeeded with one.
    result_json: ?[]const u8,
    // The error name, when it failed.
    error_message: ?[]const u8,
};

//
// The error a handler returns when it stops because its task was cancelled.
//
pub const TaskError = error{
    Cancelled,
    UnknownTaskType,
    NativeCallMissing,
};

//
// A function that gives the text to report for an error a handler returned, or null to report the error's name. An app supplies
// one when its code records the reason for a failure somewhere other than the error's name, as a Zig error carries no message.
//
pub const ErrorDescriber = *const fn (err: anyerror) ?[]const u8;

//
// How a task ended, as reported to the app's observer: the task's type and input as well as its outcome, which the
// frontend's task-completed event does not carry on its own account (the frontend knows what task it queued).
//
pub const TaskEnd = struct {
    // The id of the task.
    task_id: []const u8,
    // The task type string.
    task_type: []const u8,
    // The source the task was queued under.
    source: []const u8,
    // The task's input data as JSON text.
    input_json: []const u8,
    // How the task ended.
    status: TaskStatus,
    // The text of the error, when it failed.
    error_message: ?[]const u8,
    // The JSON text of the result, when it succeeded with one.
    result_json: ?[]const u8,
    // Whether a handler was called for the task. A task cancelled while it waited in the queue never started, and no completion
    // is reported for one.
    started: bool,
};

//
// An event a task sent, as reported to the app's observer.
//
pub const TaskSentEvent = struct {
    // The id of the task.
    task_id: []const u8,
    // The task type string.
    task_type: []const u8,
    // The source the task was queued under.
    source: []const u8,
    // The event as JSON text.
    event_json: []const u8,
};

