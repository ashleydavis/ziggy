//
// The system messages: Ziggy's own messages, which only Ziggy's frontend script and the native apps send (a message whose kind is
// "system") and which never reach the app. Each part of Ziggy has a file under system-messages/ with a function for each of its
// messages, which is given only the piece of the main thread's state it uses, and the main thread finds a system message's function by
// its name (see `names` and core.zig).
//

//
// The system messages of the task runner (add-task, cancel-tasks).
//
pub const tasks = @import("system-messages/tasks.zig");

//
// The system message of the platform (get-platform).
//
pub const platform = @import("system-messages/platform.zig");

//
// The system message of the menu (menu-action).
//
pub const menu = @import("system-messages/menu.zig");

//
// The system message of the dropped files (get-dropped-paths).
//
pub const dropped_files = @import("system-messages/dropped-files.zig");

//
// The system message of the log (log).
//
pub const log = @import("system-messages/log.zig");

//
// The system messages of the remote control connection (test-result, test-ui-ready).
//
pub const remote_control = @import("system-messages/remote-control.zig");

//
// The name of every system message the main thread handles, other than those of the remote control connection.
//
pub const names = [_][]const u8{
    "add-task",
    "cancel-tasks",
    "get-platform",
    "menu-action",
    "get-dropped-paths",
    "log",
};

//
// The names of the system messages of the remote control connection, which the main thread handles as well.
//
pub const remote_control_names = [_][]const u8{
    "test-result",
    "test-ui-ready",
};
