//
// The system messages: Ziggy's own messages, which only Ziggy's frontend script and the native apps send (a message whose kind is
// "system") and which never reach the app. There is no list of them: each part of Ziggy registers its own with the core's registry of
// system messages (the files under system-messages/), while the core is being created or at any later point, from any thread, and the
// core looks a system message's name up there. A system message handler takes the same forms as an app's (see handlers.zig). Nothing
// the app reaches names the registry: the core holds it untyped, and no public declaration of Ziggy's core names this file.
//

const core_lib = @import("core.zig");
const message_registry = @import("message-registry.zig");

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
// The system messages of the test hooks (test-result, test-ui-ready), registered only in a test hooks build.
//
pub const test_hooks = @import("system-messages/test-hooks.zig");

//
// The core's registry of system messages, where a part of Ziggy (or, in future, a plugin) registers its own with `register(name,
// handler)`.
//
pub fn registry(core: *core_lib.Core) *message_registry.Registry {
    return @ptrCast(@alignCast(core.system_messages));
}
