//
// Everything the test app adds to Ziggy's core library: its messages, each with the handler for it, its task types, and the state,
// observers and error describer it gives the backend. Ziggy's build serves the app declared here.
//

const std = @import("std");
const ziggy = @import("ziggy-core");
const messages = @import("lib/messages.zig");
const hello_tasks = @import("lib/hello-tasks.zig");
pub const media_server = @import("lib/media-server.zig");
const menu = @import("lib/menu.zig");
const ui_query = @import("lib/ui-query.zig");
const pickers = @import("lib/pickers.zig");
const app_state = @import("lib/app-state.zig");
const ui = @import("ui-files");

//
// The test app, registered with Ziggy's core. The pickers wait on a native dialog, so each is answered by a task of the same name.
//
pub const app = ziggy.core.App(.{
    .messages = .{
        .ping = messages.pingHandler,
        .@"payload-stats" = messages.payloadStatsHandler,
        .@"file-roundtrip" = messages.fileRoundtripHandler,
        .fail = messages.failHandler,
        .refuse = app_state.refuseHandler,
        .@"task-stats" = app_state.taskStatsHandler,
        .@"queue-from-app" = app_state.queueFromAppHandler,
        .@"cancel-from-app" = app_state.cancelFromAppHandler,
        .@"pick-folder" = pickers.pickFolderMessageHandler,
        .@"pick-files" = pickers.pickFilesMessageHandler,
        .@"pick-file" = pickers.pickFileMessageHandler,
    },
    .tasks = .{
        .@"hello-short" = hello_tasks.helloShortHandler,
        .@"hello-long" = hello_tasks.helloLongHandler,
        .@"hello-child" = hello_tasks.helloChildHandler,
        .@"hello-fail" = hello_tasks.helloFailHandler,
        .@"os-version" = hello_tasks.osVersionHandler,
        .@"describe-self" = app_state.describeSelfHandler,
        .@"run-in-turn" = app_state.runInTurnHandler,
        .@"media-server" = media_server.mediaServerHandler,
        .@"background-keep-alive" = .{
            .handler = hello_tasks.backgroundCountHandler,
            .kind = .keep_alive,
        },
        .@"background-normal" = hello_tasks.backgroundCountHandler,
        .@"pick-folder" = pickers.pickFolderHandler,
        .@"pick-files" = pickers.pickFilesHandler,
        .@"pick-file" = pickers.pickFileHandler,
    },
    .state = app_state.state_hooks,
    .on_task_end = app_state.onTaskEnd,
    .on_task_message = app_state.onTaskMessage,
    .describe_error = app_state.describeError,
    .menu_json = menu.menu_json,
    .ui_files = &ui.files,
    .ui_query = ui_query.uiQuery,
});
