//
// Everything the test app adds to Ziggy's core library: its messages, each with the handler for it, its task types and the
// observers and error describer it gives the backend. Ziggy's build serves the app declared here.
//

const std = @import("std");
const ziggy = @import("ziggy");
pub const handlers = @import("lib/handlers.zig");
const ui = @import("ui-files");

//
// The test app, registered with Ziggy's core. The pickers wait on a native dialog, so each is answered by a task of the same name.
//
pub const app = ziggy.core.App(.{
    .messages = .{
        .ping = handlers.pingHandler,
        .@"payload-stats" = handlers.payloadStatsHandler,
        .@"file-roundtrip" = handlers.fileRoundtripHandler,
        .fail = handlers.failHandler,
        .refuse = handlers.refuseHandler,
        .@"queue-from-app" = handlers.queueFromAppHandler,
        .@"cancel-from-app" = handlers.cancelFromAppHandler,
        .@"pick-folder" = handlers.pickFolderMessageHandler,
        .@"pick-files" = handlers.pickFilesMessageHandler,
        .@"pick-file" = handlers.pickFileMessageHandler,
    },
    .tasks = .{
        .@"hello-short" = handlers.helloShortHandler,
        .@"hello-long" = handlers.helloLongHandler,
        .@"hello-child" = handlers.helloChildHandler,
        .@"hello-fail" = handlers.helloFailHandler,
        .@"os-version" = handlers.osVersionHandler,
        .@"describe-self" = handlers.describeSelfHandler,
        .@"run-in-turn" = handlers.runInTurnHandler,
        .@"media-server" = handlers.mediaServerHandler,
        .@"background-keep-alive" = .{
            .handler = handlers.backgroundCountHandler,
            .kind = .keep_alive,
        },
        .@"background-normal" = handlers.backgroundCountHandler,
        .@"pick-folder" = handlers.pickFolderHandler,
        .@"pick-files" = handlers.pickFilesHandler,
        .@"pick-file" = handlers.pickFileHandler,
    },
    .on_task_end = handlers.onTaskEnd,
    .on_task_event = handlers.onTaskEvent,
    .describe_error = handlers.describeError,
    .menu = handlers.menu,
    .ui_files = &ui.files,
    .ui_query = handlers.uiQuery,
});
