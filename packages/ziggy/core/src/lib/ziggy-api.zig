//
// The C interface to the core. Ziggy's app-root.zig, the root of every app's backend library, calls exportApi with the app registered with App and the functions below are exported
// from its library, so every native app reaches the core the same way. The declarations are in ziggy.h.
//
// ziggy_create returns the main thread's queue, which every other function is given and posts to. Every function is called on the
// native app's UI thread, and what they keep lives in the few variables below, at the edge of the system, for as long as the core runs:
// the UI thread's allocator and Io, the main thread, to wait for it to end, the native app's side of its queue, and copies of the app's
// URL prefix and of the last query of the frontend's address. A process runs one core at a time.
//

const std = @import("std");
const build_options = @import("build_options");
const types = @import("types.zig");
const core = @import("core.zig");
const accelerator = @import("accelerator.zig");
const ui_files = @import("ui-files.zig");
const origin_check = @import("origin-check.zig");
const inject_script = @import("inject-script.zig");
const native_side_lib = @import("native-side.zig");
const ThreadAllocator = @import("utils").thread_allocator.ThreadAllocator;

const MessageQueue = core.MessageQueue;

//
// The native app's UI thread's own allocator, made by ziggy_create, which allocates the queues and the copies.
//
var ui_allocator: ThreadAllocator = .init;

//
// The native app's UI thread's own Io, made by ziggy_create.
//
var ui_threaded: std.Io.Threaded = undefined;

//
// The main thread's queue, which ziggy_create returns.
//
var main_queue: MessageQueue = undefined;

//
// The native app's queue, which the core's threads post to.
//
var native_queue: MessageQueue = undefined;

//
// The native app's side of its queue, which ziggy_take_native_message takes from.
//
var native_side: native_side_lib.NativeSide = undefined;

//
// The main thread, or null when no core runs.
//
var main_thread: ?std.Thread = null;

//
// The native app's copy of the app's URL prefix, which ziggy_check_url reads, or null when no core runs.
//
var app_url_prefix: ?[:0]u8 = null;

//
// The text the last call to ziggy_ui_query returned, or null before the first call.
//
var ui_query_text: ?[:0]u8 = null;

//
// What ziggy_ui_file gives back for a file of the bundled frontend. Laid out like ziggy_ui_file_result in ziggy.h.
//
const UiFileResult = extern struct {
    // The file's bytes, which stay valid for as long as the library is loaded.
    content: [*]const u8,
    // The number of bytes.
    content_length: usize,
    // The file's content type, NUL terminated, which stays valid for as long as the library is loaded.
    content_type: [*:0]const u8,
};

//
// Exports every function declared in ziggy.h (ziggy_create, ziggy_destroy, ziggy_send_message, ziggy_check_url, ziggy_menu_json,
// ziggy_ui_file, ziggy_inject_script, ziggy_parse_accelerator, ziggy_test_hooks_enabled, ziggy_files_dropped, ziggy_ui_query,
// ziggy_take_native_message and ziggy_native_result) from the library
// that calls this, serving the app registered with App. It is called once, from app-root.zig.
//
pub fn exportApi(comptime app: core.RegisteredApp) void {
    const Api = struct {
        //
        // ziggy_create: starts the core's main thread serving the app and returns its queue, or returns null after printing why it
        // could not.
        //
        fn create(config: *const types.ZiggyConfig) callconv(.c) ?*MessageQueue {
            if (main_thread != null) {
                std.debug.print("ziggy_create failed: a core runs already\n", .{});
                return null;
            }
            ui_allocator = .init;
            const allocator = ui_allocator.allocator();
            ui_threaded = .init_single_threaded;
            ui_threaded.allocator = allocator;
            const prefix = allocator.dupeZ(u8, std.mem.span(config.app_url_prefix)) catch |err| {
                std.debug.print("ziggy_create failed: {s}\n", .{@errorName(err)});
                endUiThreadState();
                return null;
            };
            main_queue = MessageQueue.init();
            native_queue = MessageQueue.init();
            native_side = .init(&native_queue);
            main_thread = core.start(allocator, &main_queue, &native_queue, config.*, app) catch |err| {
                std.debug.print("ziggy_create failed: {s}\n", .{@errorName(err)});
                native_side.deinit(allocator);
                native_queue.deinit();
                main_queue.deinit();
                allocator.free(prefix);
                endUiThreadState();
                return null;
            };
            app_url_prefix = prefix;
            return &main_queue;
        }

        //
        // ziggy_destroy: stops the core's main thread, failing every call meanwhile with ShuttingDown, waits for it and releases the
        // queues and the copies.
        //
        fn destroy(queue: ?*MessageQueue) callconv(.c) void {
            const given = queue orelse {
                return;
            };
            const allocator = ui_allocator.allocator();
            core.stop(allocator, given, &native_side, null, main_thread.?);
            main_thread = null;
            native_side.deinit(allocator);
            native_queue.deinit();
            given.deinit();
            if (ui_query_text) |text| {
                allocator.free(text);
            }
            ui_query_text = null;
            allocator.free(app_url_prefix.?);
            app_url_prefix = null;
            endUiThreadState();
        }

        //
        // ziggy_take_native_message: takes the next message the core sent the native app, or returns null when there is none.
        //
        fn takeNativeMessage(queue: ?*MessageQueue, length: *usize, kind: *i32, reply: *u64) callconv(.c) ?[*]const u8 {
            if (queue == null) {
                @panic("ziggy_take_native_message called with a null pointer");
            }
            const taken = native_side.take(ui_threaded.io(), ui_allocator.allocator(), .{
                .duration = .{
                    .raw = .zero,
                    .clock = .awake,
                },
            }) orelse {
                return null;
            };
            length.* = taken.text.len;
            kind.* = @intFromEnum(taken.kind);
            reply.* = taken.reply;
            return taken.text.ptr;
        }

        //
        // ziggy_native_result: gives the result of the call taken under the number reply.
        //
        fn nativeResult(queue: ?*MessageQueue, reply: u64, ok: bool, text_ptr: [*]const u8, text_len: usize) callconv(.c) void {
            if (queue == null) {
                @panic("ziggy_native_result called with a null pointer");
            }
            native_side.result(ui_threaded.io(), ui_allocator.allocator(), reply, ok, text_ptr[0..text_len]) catch |err| {
                std.debug.panic("ziggy_native_result failed: {s}", .{@errorName(err)});
            };
        }

        //
        // ziggy_send_message: passes a message from the frontend to the main thread and returns at once.
        //
        fn sendMessage(queue: ?*MessageQueue, message_ptr: [*]const u8, message_len: usize) callconv(.c) void {
            const given = queue orelse {
                @panic("ziggy_send_message called with a null pointer");
            };
            core.sendMessage(ui_allocator.allocator(), given, message_ptr[0..message_len]);
        }

        //
        // ziggy_check_url: decides what to do with an address the web view is about to load.
        //
        fn checkUrl(queue: ?*MessageQueue, url_ptr: [*]const u8, url_len: usize) callconv(.c) i32 {
            if (queue == null) {
                @panic("ziggy_check_url called with a null pointer");
            }
            return @intFromEnum(origin_check.checkUrl(app_url_prefix.?, url_ptr[0..url_len]));
        }

        //
        // ziggy_menu_json: gives the desktop menu as JSON text and writes its length to the pointer given.
        //
        fn menuJson(queue: ?*MessageQueue, length: *usize) callconv(.c) [*]const u8 {
            if (queue == null) {
                @panic("ziggy_menu_json called with a null pointer");
            }
            length.* = app.menu_json.len;
            return app.menu_json.ptr;
        }

        //
        // ziggy_ui_file: finds a file of the bundled frontend by the path of a request, and returns whether the frontend has it.
        //
        fn uiFile(queue: ?*MessageQueue, path_ptr: [*]const u8, path_len: usize, result: *UiFileResult) callconv(.c) bool {
            if (queue == null) {
                @panic("ziggy_ui_file called with a null pointer");
            }
            const file = ui_files.findFile(app.ui_files, path_ptr[0..path_len]) orelse {
                return false;
            };
            result.* = .{
                .content = file.content.ptr,
                .content_length = file.content.len,
                .content_type = ui_files.contentType(file.path).ptr,
            };
            return true;
        }

        //
        // ziggy_inject_script: gives the script to inject into the frontend before it loads and writes its length to the pointer
        // given.
        //
        fn injectScript(length: *usize) callconv(.c) [*:0]const u8 {
            length.* = inject_script.text.len;
            return inject_script.text.ptr;
        }

        //
        // ziggy_parse_accelerator: parses the text of a keyboard shortcut, and returns whether it was one.
        //
        fn parseAccelerator(text_ptr: [*]const u8, text_len: usize, result: *accelerator.Accelerator) callconv(.c) bool {
            result.* = accelerator.parse(text_ptr[0..text_len]) catch {
                return false;
            };
            return true;
        }

        //
        // ziggy_files_dropped: checks the files the user dropped on the window, has the main thread record them, and returns whether the
        // paths were files that can be read.
        //
        fn filesDropped(queue: ?*MessageQueue, paths_ptr: [*]const u8, paths_len: usize) callconv(.c) bool {
            const given = queue orelse {
                @panic("ziggy_files_dropped called with a null pointer");
            };
            core.filesDropped(ui_allocator.allocator(), given, paths_ptr[0..paths_len]) catch |err| {
                std.debug.print("ziggy_files_dropped failed: {s}\n", .{@errorName(err)});
                return false;
            };
            return true;
        }

        //
        // ziggy_ui_query: gives the query of the frontend's address, or null when the app could not make it. The text stays valid until
        // the next call or until the core is destroyed.
        //
        fn uiQuery(queue: ?*MessageQueue, length: *usize) callconv(.c) ?[*:0]const u8 {
            const given = queue orelse {
                @panic("ziggy_ui_query called with a null pointer");
            };
            const text = core.uiQuery(ui_allocator.allocator(), given) catch |err| {
                std.debug.print("ziggy_ui_query failed: {s}\n", .{@errorName(err)});
                return null;
            };
            if (ui_query_text) |old| {
                ui_allocator.allocator().free(old);
            }
            ui_query_text = text;
            length.* = text.len;
            return text.ptr;
        }

        //
        // ziggy_test_hooks_enabled: returns whether this library was built with the test hooks.
        //
        fn testHooksEnabled() callconv(.c) bool {
            return build_options.test_hooks;
        }
    };
    @export(&Api.create, .{
        .name = "ziggy_create",
    });
    @export(&Api.destroy, .{
        .name = "ziggy_destroy",
    });
    @export(&Api.sendMessage, .{
        .name = "ziggy_send_message",
    });
    @export(&Api.checkUrl, .{
        .name = "ziggy_check_url",
    });
    @export(&Api.menuJson, .{
        .name = "ziggy_menu_json",
    });
    @export(&Api.uiFile, .{
        .name = "ziggy_ui_file",
    });
    @export(&Api.injectScript, .{
        .name = "ziggy_inject_script",
    });
    @export(&Api.parseAccelerator, .{
        .name = "ziggy_parse_accelerator",
    });
    @export(&Api.testHooksEnabled, .{
        .name = "ziggy_test_hooks_enabled",
    });
    @export(&Api.filesDropped, .{
        .name = "ziggy_files_dropped",
    });
    @export(&Api.uiQuery, .{
        .name = "ziggy_ui_query",
    });
    @export(&Api.takeNativeMessage, .{
        .name = "ziggy_take_native_message",
    });
    @export(&Api.nativeResult, .{
        .name = "ziggy_native_result",
    });
}

//
// Releases the UI thread's Io and allocator, once nothing else made on them is left.
//
fn endUiThreadState() void {
    ui_threaded.deinit();
    ui_allocator.deinit();
}
