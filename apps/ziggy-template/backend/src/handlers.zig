//
// Everything the template adds to Ziggy's core library: the messages its UI sends and the tasks it queues, each with the Zig function that
// handles it.
//

const ziggy = @import("ziggy-core");
const hello_world_backend = @import("lib/hello-world-backend.zig");
const menu = @import("lib/menu.zig");
const ui_query = @import("lib/ui-query.zig");
const ui = @import("ui-files");

//
// The template's channels and task types, its menu and its built UI.
//
pub const app = ziggy.core.AppHandlers{
    .channels = &[_]ziggy.core.ChannelEntry{
        .{
            .name = "hello-world",
            .handler = hello_world_backend.helloWorldHandler,
        },
    },
    .task_channels = &[_]ziggy.core.TaskChannelEntry{},
    .tasks = &[_]ziggy.task_runner.TaskHandlerEntry{
        .{
            .name = "hello-world-task",
            .handler = hello_world_backend.helloWorldTaskHandler,
        },
    },
    .menu_json = menu.menu_json,
    .ui_files = &ui.files,
    .ui_query = ui_query.uiQuery,
};
