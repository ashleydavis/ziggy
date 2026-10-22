//
// The core: everything behind one handle. It owns the task runner, knows the app's message handlers and the host callbacks,
// and routes every message from the frontend: a system message (Ziggy's own) to Ziggy's handlers and an app message to the app's handler for its name.
//

const std = @import("std");
const build_options = @import("build_options");
const types = @import("types.zig");
const json = @import("json.zig");
const task_runner = @import("task-runner.zig");
const queue_backend = @import("queue-backend.zig");
const task_queue = @import("task-queue.zig");
const origin_check = @import("origin-check.zig");
const test_control = @import("test-control.zig");
const ui_files = @import("ui-files.zig");
const dropped_files = @import("dropped-files.zig");
const system_messages = @import("system-messages.zig");
const app_lib = @import("app.zig");
const handlers_lib = @import("handlers.zig");
const message_registry = @import("message-registry.zig");
const menu_lib = @import("menu.zig");

const ZiggyConfig = types.ZiggyConfig;

//
// One app message from the frontend, unparsed, as the core hands it to a message handler whose request is ziggy.core.Message (see App).
//
pub const Message = struct {
    // The message's id, which its message response carries back to the frontend, or null for a message sent with send, which
    // gets no message response. A handler that answers with a task passes the message on to answerWithTask unread.
    id: ?std.json.Value,
    // The message's name, which the frontend gave as the first argument of invoke or send and which chose the handler. It is
    // never empty: the core refuses a message without one, with MissingMessageName, before any handler runs. It lives in the
    // arena the handler is given.
    name: []const u8,
    // The data the frontend sent, the app's own to lay out, or null when it sent none. It lives in the arena the handler is given.
    data: std.json.Value,
};

//
// What a message handler that takes ziggy.core.Message did about the message response.
//
pub const MessageResult = union(enum) {
    // The JSON text of the message response, allocated with the arena. It is sent when the message has an id.
    response: []const u8,
    // There is nothing to send back. A message with an id still gets a successful message response holding null, so the
    // frontend's invoke never waits for ever.
    none,
    // The message is answered elsewhere, so nothing is sent now: by a task answerWithTask queued, whose result is sent when the
    // task ends, or (for a handler App wrapped) later through the handler's Reply.
    answered_by_task,
};

//
// A message whose handler took a Reply and has not answered yet, as the core keeps it.
//
const LaterReply = struct {
    // The JSON text of the message's id, owned by the core, or null for a message with no id.
    id_json: ?[]u8,
    // The message's name, owned by the core, which an unanswered message is reported by.
    name: []u8,
};

//
// Registers an app with the core: see app.zig.
//
pub const App = app_lib.App;

//
// What a message handler returns when it answers with a task or later: see handlers.zig.
//
pub const Answer = handlers_lib.Answer;

//
// The task that answers a message, in an Answer: see handlers.zig.
//
pub const AnswerTask = handlers_lib.AnswerTask;

//
// The handle a message handler that answers later takes: see handlers.zig.
//
pub const Reply = handlers_lib.Reply;

//
// An app as App registered it: what the app adds to the core. An app makes it with App and never writes one itself.
//
pub const RegisteredApp = struct {
    // The app's message handlers by message name, each wrapped by App. Only app messages reach them, never a system message. A
    // handler that fails returns an error, which becomes an error message response (or a core-error event for a message with no
    // id).
    messages: []const handlers_lib.MessageEntry,
    // The app's task types.
    tasks: []const task_runner.TaskHandlerEntry,
    // The desktop menu as JSON, which App makes from the app's `.menu` (see menuJson in menu.zig). "[]" for an app with no menu.
    // Native apps show it on desktop only. See "Menus" in the architecture document.
    menu_json: []const u8,
    // What the core does for each menu item a native app posts as menu-action, by the item's name, which App makes from the app's
    // `.menu` (see menuTargets in menu.zig).
    menu_targets: menu_lib.MenuTargets,
    // The files of the app's bundled frontend, embedded in the app's library, for a native app that serves the frontend by
    // calling the core for each file (the MacOS, iOS and Android native apps). Empty for an app whose native app embeds the
    // frontend itself.
    ui_files: []const ui_files.UiFile,
    // Turns the error the message handler returned into the text of the error reply, for an app whose code reports the reason for
    // a failure somewhere other than the error's name (a Zig error carries no message). It returns null when it has nothing to
    // add about the error, and the reply then carries the error's name. It is called on the thread that handled the message,
    // straight after the handler failed, and the text is used before the call returns.
    describe_error: ?ErrorDescriber = null,
    // Called when a task has ended, after the frontend has been told, from the thread that ran it, with no lock held. The
    // values are valid only during the call.
    on_task_end: ?*const fn (core: *Core, end: types.TaskEnd) void = null,
    // Called when a task has sent an event, after the frontend has been told, from the thread that sent it, with no lock held.
    // The values are valid only during the call.
    on_task_event: ?*const fn (core: *Core, sent: types.TaskSentEvent) void = null,
    // Gives the query text the native app appends to the address of the frontend, after the question mark, so the frontend's
    // first render already holds what the app tells it at start-up. Null for an app whose frontend needs no query. See `UiQuery`.
    ui_query: ?UiQuery = null,
    // Called twice while the core is destroyed, on the thread that destroys it: with `.before_tasks_stop` while tasks can still
    // be queued, so the app can stop its own threads, and with `.after_tasks_stopped` once every task has ended, so the app can free
    // its own resources. The core is destroyed whenever the native app ends the backend, which is not only when the app quits (an
    // Android activity's onDestroy, for one), and in tests. Null for an app with nothing to do then. See `DestroyPhase`.
    on_destroy: ?*const fn (core: *Core, phase: DestroyPhase) void = null,
};

//
// The point of the core's destruction at which the app's `on_destroy` is called.
//
pub const DestroyPhase = enum {
    // First, before the task runner stops: tasks can still be queued and the ones running are still running. For stopping the
    // app's own threads, which may still queue tasks or use the core.
    before_tasks_stop,
    // Second, after the task runner has stopped: every task has ended and no task can be queued, but the core is not yet freed.
    // For freeing what the app's own code allocated, now that no task can use it.
    after_tasks_stopped,
};

//
// An app's function for the query of the frontend's address. The core calls it when the native app calls ziggy_ui_query (the native app calls it once the core exists,
// before it loads the frontend), with whether the test mode switch is on, which the app puts in the query however it likes. It returns
// the text after the question mark, such as `restApiUrl=...&testMode=1`, or an empty string for no query, allocated with the
// allocator given, which is an arena that is released when the call returns. Ziggy passes the text through unread, so no native app
// composes a query and Ziggy names none of its parts.
//
pub const UiQuery = *const fn (core: *Core, allocator: std.mem.Allocator, test_mode: bool) anyerror![]const u8;

//
// A function that gives the text of the error reply for an error a handler returned, or null to use the error's name.
//
pub const ErrorDescriber = types.ErrorDescriber;

//
// One running core.
//
pub const Core = struct {
    // Allocates everything the core owns.
    allocator: std.mem.Allocator,
    // The Io used for sleeping, waiting, files and sockets. It lives here so that its address is stable.
    threaded: std.Io.Threaded,
    // The app messages, registered from the app's App when the core is created and with registerMessage while it runs.
    app_messages: message_registry.Registry,
    // The system messages, which the parts of Ziggy register (see system-messages.zig). It is a message_registry.Registry the core
    // owns, held untyped so that nothing an app reaches from the core names the registry of system messages.
    system_messages: *anyopaque,
    // The number of messages answered by a task so far, which names the next one's task. A message's own id cannot name it: the
    // frontend numbers its messages from 1 again when it reloads, while a task of the last page can still be running.
    next_request_task: std.atomic.Value(u64),
    // The desktop menu as JSON, owned by the app.
    menu_json: []const u8,
    // What the core does for each menu item a native app posts, by the item's name, owned by the app.
    menu_targets: menu_lib.MenuTargets,
    // The files of the app's bundled frontend, owned by the app.
    ui_files: []const ui_files.UiFile,
    // Gives the text of an error reply, or null to use the error's name. Owned by the app.
    describe_error: ?ErrorDescriber,
    // The app's function for a task that ended, or null.
    on_task_end: ?*const fn (core: *Core, end: types.TaskEnd) void,
    // The app's function for an event a task sent, or null.
    on_task_event: ?*const fn (core: *Core, sent: types.TaskSentEvent) void,
    // The app's function for the query of the frontend's address, or null.
    ui_query: ?UiQuery,
    // The app's function called before tasks stop and after they have stopped when the core is destroyed, or null.
    on_destroy: ?*const fn (core: *Core, phase: DestroyPhase) void,
    // The text the last call to `uiQuery` returned, owned by the core, or null before the first call.
    ui_query_text: ?[:0]u8,
    // The native app's configuration. The strings in it are copies owned by the core.
    config: ZiggyConfig,
    // The owned copy of the app's URL prefix.
    app_url_prefix: [:0]u8,
    // The owned copy of the data directory.
    data_dir: [:0]u8,
    // The task runner.
    runner: task_runner.TaskRunner,
    // The IQueueBackend that code written against the task queue talks to, backed by the runner.
    queue_backend: *queue_backend.ZiggyQueueBackend,
    // The files the user last dropped on the window, for getPathForFile.
    dropped: dropped_files.DroppedFiles,
    // The test control connection, only in a test hooks build and only when the native app is in test mode.
    control: ?*test_control.TestControl,
    // The messages whose handlers took a Reply and have not answered yet, by the serial each Reply carries.
    later_replies: std.AutoHashMapUnmanaged(u64, LaterReply),
    // Guards later_replies and next_later_reply, which handlers and the threads they hand a Reply to use at once.
    later_mutex: std.Io.Mutex,
    // The serial of the next message recorded in later_replies.
    next_later_reply: u64,

    //
    // Creates a core. The returned pointer is the handle.
    //
    pub fn create(allocator: std.mem.Allocator, config: ZiggyConfig, app: RegisteredApp) !*Core {
        if (config.deliver == null) {
            return error.DeliverCallbackMissing;
        }
        const core = try allocator.create(Core);
        errdefer allocator.destroy(core);
        core.allocator = allocator;
        core.threaded = .init_single_threaded;
        // An app's retry (Photosphere's, for one) runs its operations against a timer, which needs the Io to start a task of its own. Everything else
        // still runs on the calling thread, and a cancel request still has no effect on it.
        core.threaded.allocator = allocator;
        core.threaded.concurrent_limit = .unlimited;
        core.app_messages = message_registry.Registry.init(allocator, core.threaded.io(), "app");
        errdefer core.app_messages.deinit();
        for (app.messages) |entry| {
            try core.app_messages.registerWrapped(entry.name, entry.handler);
        }
        const system = try allocator.create(message_registry.Registry);
        errdefer allocator.destroy(system);
        system.* = message_registry.Registry.init(allocator, core.threaded.io(), "system");
        errdefer system.deinit();
        core.system_messages = system;
        try system_messages.platform.register(system);
        try system_messages.menu.register(system);
        if (build_options.test_hooks) {
            try system_messages.test_hooks.register(system);
        }
        core.next_request_task = .init(0);
        core.menu_json = app.menu_json;
        core.menu_targets = app.menu_targets;
        core.ui_files = app.ui_files;
        core.describe_error = app.describe_error;
        core.on_task_end = app.on_task_end;
        core.on_task_event = app.on_task_event;
        core.ui_query = app.ui_query;
        core.on_destroy = app.on_destroy;
        core.ui_query_text = null;
        core.config = config;
        core.app_url_prefix = try allocator.dupeZ(u8, std.mem.span(config.app_url_prefix));
        errdefer allocator.free(core.app_url_prefix);
        core.data_dir = try allocator.dupeZ(u8, std.mem.span(config.data_dir));
        errdefer allocator.free(core.data_dir);
        // The native app's own strings are valid only during the call, so everything that keeps the configuration keeps it pointing at the copies.
        core.config.app_url_prefix = core.app_url_prefix.ptr;
        core.config.data_dir = core.data_dir.ptr;
        core.dropped = dropped_files.DroppedFiles.init(allocator);
        errdefer core.dropped.deinit();
        try system_messages.dropped_files.register(system);
        core.control = null;
        core.later_replies = .empty;
        core.later_mutex = .init;
        core.next_later_reply = 0;
        core.queue_backend = try queue_backend.ZiggyQueueBackend.create(allocator, core.threaded.io(), &core.runner);
        errdefer core.queue_backend.destroy();
        try core.runner.start(allocator, core.threaded.io(), .{
            .user_data = core,
            .emit = emitFromRunner,
        }, app.tasks, .{
            .worker_threads = config.worker_threads,
            .max_concurrent_child_tasks = config.max_concurrent_child_tasks,
            .describe_error = app.describe_error,
            .fallback_handler = queue_backend.fallbackHandler(core.queue_backend),
            .observer = .{
                .user_data = core,
                .on_task_end = observeTaskEnd,
                .on_task_event = observeTaskEvent,
            },
        }, core.config);
        errdefer core.runner.stop();
        try system_messages.tasks.register(system);
        task_queue.queue_backend.setQueueBackend(core.queue_backend.queueBackend());
        errdefer task_queue.queue_backend.setQueueBackend(null);
        if (build_options.test_hooks) {
            if (config.test_mode) {
                const control = try allocator.create(test_control.TestControl);
                errdefer allocator.destroy(control);
                try control.start(allocator, core.threaded.io(), config, emitFromRunner, core, filesDroppedFromControl);
                core.control = control;
                core.runner.pick_override = .{
                    .user_data = control,
                    .take = test_control.TestControl.takePickAnswer,
                };
            }
        }
        return core;
    }

    //
    // Cancels every running task, waits for the workers to stop and releases everything. Calls the app's `on_destroy` with
    // `.before_tasks_stop` first and with `.after_tasks_stopped` once the runner has stopped.
    //
    pub fn destroy(self: *Core) void {
        if (self.on_destroy) |on_destroy| {
            on_destroy(self, .before_tasks_stop);
        }
        if (self.control) |control| {
            control.stop();
            self.allocator.destroy(control);
        }
        self.runner.stop();
        self.reportUnansweredReplies();
        if (self.on_destroy) |on_destroy| {
            on_destroy(self, .after_tasks_stopped);
        }
        task_queue.queue_backend.setQueueBackend(null);
        self.queue_backend.destroy();
        self.threaded.deinit();
        self.dropped.deinit();
        self.app_messages.deinit();
        const system = system_messages.registry(self);
        system.deinit();
        self.allocator.destroy(system);
        if (self.ui_query_text) |text| {
            self.allocator.free(text);
        }
        self.allocator.free(self.app_url_prefix);
        self.allocator.free(self.data_dir);
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    //
    // Decides what to do with an address the web view is about to load.
    //
    pub fn checkUrl(self: *Core, url: []const u8) types.UrlDecision {
        return origin_check.checkUrl(self.app_url_prefix, url);
    }

    //
    // Calls the app's function for the query of the frontend's address and returns the text after the question mark, empty when the app has none. The
    // text is owned by the core and stays valid until the next call or until the core is destroyed. The native app calls it once the core
    // exists, before it loads the frontend.
    //
    pub fn uiQuery(self: *Core) ![:0]const u8 {
        const ui_query = self.ui_query orelse {
            return "";
        };
        // The app allocates from an arena that goes when the call returns, so it need not free what it uses to make the text.
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const text = try ui_query(self, arena_state.allocator(), self.config.test_mode);
        const owned = try self.allocator.dupeZ(u8, text);
        if (self.ui_query_text) |old| {
            self.allocator.free(old);
        }
        self.ui_query_text = owned;
        return owned;
    }

    //
    // Finds the bundled frontend's file for the path of a request, or null when the frontend has no such file. See ui-files.zig.
    //
    pub fn uiFile(self: *Core, request_path: []const u8) ?*const ui_files.UiFile {
        return ui_files.findFile(self.ui_files, request_path);
    }

    //
    // Records the files the user dropped on the window, replacing the last drop. The native app calls it when the drop happens, before the
    // frontend's own drop event, with the paths as the JSON text of an array of strings.
    //
    pub fn filesDropped(self: *Core, paths_json: []const u8) !void {
        try self.dropped.replace(self.io(), paths_json);
    }

    //
    // The Io the core's threads sleep and wait with.
    //
    pub fn io(self: *Core) std.Io {
        return self.threaded.io();
    }

    //
    // Sends a JSON message to the native app, and so to the frontend.
    //
    pub fn deliver(self: *Core, message: []const u8) void {
        const deliver_fn = self.config.deliver.?;
        deliver_fn(self.config.user_data, message.ptr, message.len);
    }

    //
    // Handles one message from the frontend or the native app: the one entry point into the core for both kinds of message. It
    // parses the envelope and passes it on by its kind, "app" to postAppMessage and "system" to postSystemMessage, and does
    // nothing else. A message that is not a JSON object, or has no kind or any other kind, is refused as InvalidMessage, reported as a
    // core-error system event.
    //
    pub fn postMessage(self: *Core, message: []const u8) void {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, message, .{}) catch {
            self.reportError(arena, null, "InvalidMessage");
            return;
        };
        if (parsed != .object) {
            self.reportError(arena, null, "InvalidMessage");
            return;
        }
        const kind = parsed.object.get("kind") orelse .null;
        if (kind == .string and std.mem.eql(u8, kind.string, "app")) {
            self.postAppMessage(arena, parsed);
            return;
        }
        if (kind == .string and std.mem.eql(u8, kind.string, "system")) {
            self.postSystemMessage(arena, parsed);
            return;
        }
        self.reportError(arena, null, "InvalidMessage");
    }

    //
    // Handles an app message: runs the app's handler for its name and replies when it carries an id. It must carry a name, a
    // string that is not empty, or it is refused with MissingMessageName, and a name no app message is registered under is
    // UnknownMessageName; neither runs a handler.
    //
    fn postAppMessage(self: *Core, arena: std.mem.Allocator, parsed: std.json.Value) void {
        const request_id: ?std.json.Value = parsed.object.get("id");
        const name = messageName(parsed) orelse {
            self.reportError(arena, request_id, "MissingMessageName");
            return;
        };
        const handler = self.app_messages.find(name) orelse {
            self.reportError(arena, request_id, "UnknownMessageName");
            return;
        };
        self.runHandler(arena, handler, request_id, name, parsed);
    }

    //
    // The name of a message, or null when it has none, an empty one or one that is not a string.
    //
    fn messageName(parsed: std.json.Value) ?[]const u8 {
        const value = parsed.object.get("name") orelse {
            return null;
        };
        if (value != .string or value.string.len == 0) {
            return null;
        }
        return value.string;
    }

    //
    // Handles a system message: runs the handler a part of Ziggy registered for its name (see system-messages.zig) and replies
    // when it carries an id. It never reaches the app's handlers. A message with no name is InvalidMessage, and a name no system
    // message is registered under is UnknownSystemMessage.
    //
    fn postSystemMessage(self: *Core, arena: std.mem.Allocator, parsed: std.json.Value) void {
        const request_id: ?std.json.Value = parsed.object.get("id");
        const name = messageName(parsed) orelse {
            self.reportError(arena, request_id, "InvalidMessage");
            return;
        };
        const handler = system_messages.registry(self).find(name) orelse {
            self.reportError(arena, request_id, "UnknownSystemMessage");
            return;
        };
        self.runHandler(arena, handler, request_id, name, parsed);
    }

    //
    // Runs a message handler, app or system, and replies to the message when it carries an id: with the response, with an error
    // response when the handler failed, or with the InvalidMessageData text when the data did not fit the handler's request (the
    // handler then did not run). A failure of a message that has no id is reported as a core-error system event, never dropped
    // silently. A message answered by a task or later gets its reply then.
    //
    fn runHandler(self: *Core, arena: std.mem.Allocator, handler: handlers_lib.WrappedHandler, request_id: ?std.json.Value, name: []const u8, parsed: std.json.Value) void {
        const outcome = handler(self, arena, .{
            .id = request_id,
            .name = name,
            .data = parsed.object.get("data") orelse .null,
        }) catch |err| {
            self.reportHandlerError(arena, request_id, err);
            return;
        };
        const result = switch (outcome) {
            .result => |returned| returned,
            .answered_twice => |text| {
                self.reportError(arena, null, text);
                return;
            },
            .invalid_data => |text| {
                self.reportError(arena, request_id, text);
                return;
            },
        };
        const id = request_id orelse {
            return;
        };
        const reply_data = switch (result) {
            .response => |text| text,
            .none => "null",
            .answered_by_task => {
                return;
            },
        };
        self.sendReply(arena, id, reply_data) catch |err| {
            self.reportError(arena, null, @errorName(err));
        };
    }

    //
    // Registers an app message while the core runs, from any thread, in any of the handler forms of an App's `.messages` (see
    // handlers.zig). It is handled from then on. A name registered already, by App or by an earlier call, is the error
    // DuplicateMessage, and the name is printed. It only ever adds app messages, never a system message.
    //
    pub fn registerMessage(self: *Core, name: []const u8, comptime handler: anytype) !void {
        try self.app_messages.registerWrapped(name, handlers_lib.wrap(handler));
    }

    //
    // Registers a task type while the core runs, from any thread: `task` is a task handler, or `.{ .handler = ..., .kind = ... }`
    // as in an App's `.tasks`. It can be queued from then on. A task type registered already is the error DuplicateTaskType, and
    // its name is printed.
    //
    pub fn registerTask(self: *Core, name: []const u8, comptime task: anytype) !void {
        try self.runner.registerTaskType(app_lib.taskEntry("a task type registered while the core runs", name, task));
    }

    //
    // Records a message whose handler takes a Reply, before the handler runs, and returns the serial its Reply carries. App's wrapper
    // calls it; an app never does.
    //
    pub fn openLaterReply(self: *Core, message: Message) !u64 {
        const id_json: ?[]u8 = if (message.id) |id| try json.stringify(self.allocator, id) else null;
        errdefer if (id_json) |text| {
            self.allocator.free(text);
        };
        const name = try self.allocator.dupe(u8, message.name);
        errdefer self.allocator.free(name);
        self.later_mutex.lockUncancelable(self.io());
        defer self.later_mutex.unlock(self.io());
        const serial = self.next_later_reply;
        self.next_later_reply += 1;
        try self.later_replies.put(self.allocator, serial, .{
            .id_json = id_json,
            .name = name,
        });
        return serial;
    }

    //
    // Forgets a message recorded by openLaterReply without answering it, for a handler that answered by what it returned. It is the
    // error MessageAlreadyAnswered when the message was answered through its Reply already.
    //
    pub fn closeLaterReply(self: *Core, serial: u64) !void {
        const later = try self.takeLaterReply(serial);
        self.freeLaterReply(later);
    }

    //
    // Answers a message recorded by openLaterReply with the response response_json, JSON text, when it has an id. It is the error
    // MessageAlreadyAnswered when the message was answered already.
    //
    pub fn sendLaterReply(self: *Core, serial: u64, response_json: []const u8) !void {
        const later = try self.takeLaterReply(serial);
        defer self.freeLaterReply(later);
        const id_json = later.id_json orelse {
            return;
        };
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const reply = try json.stringify(arena_state.allocator(), .{
            .id = json.Raw{
                .text = id_json,
            },
            .ok = true,
            .data = json.Raw{
                .text = response_json,
            },
        });
        self.deliver(reply);
    }

    //
    // Answers a message recorded by openLaterReply with an error response: the text describe_error gives for the error, or else its
    // name, as a core-error event for a message with no id. It is the error MessageAlreadyAnswered when the message was answered
    // already.
    //
    pub fn failLaterReply(self: *Core, serial: u64, err: anyerror) !void {
        const later = try self.takeLaterReply(serial);
        defer self.freeLaterReply(later);
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const id: ?std.json.Value = if (later.id_json) |text| try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) else null;
        self.reportHandlerError(arena, id, err);
    }

    //
    // Removes a message recorded by openLaterReply, or fails with MessageAlreadyAnswered when it is no longer recorded.
    //
    fn takeLaterReply(self: *Core, serial: u64) !LaterReply {
        self.later_mutex.lockUncancelable(self.io());
        defer self.later_mutex.unlock(self.io());
        const entry = self.later_replies.fetchRemove(serial) orelse {
            return error.MessageAlreadyAnswered;
        };
        return entry.value;
    }

    //
    // Releases what openLaterReply copied.
    //
    fn freeLaterReply(self: *Core, later: LaterReply) void {
        if (later.id_json) |text| {
            self.allocator.free(text);
        }
        self.allocator.free(later.name);
    }

    //
    // Reports every message whose handler chose to answer later and never did, each as a core-error event naming
    // MessageNotAnswered and the message's name, and releases them. The core calls it when it is destroyed.
    //
    fn reportUnansweredReplies(self: *Core) void {
        var iterator = self.later_replies.iterator();
        while (iterator.next()) |entry| {
            var arena_state = std.heap.ArenaAllocator.init(self.allocator);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            const text = std.fmt.allocPrint(arena, "MessageNotAnswered: {s}", .{entry.value_ptr.name}) catch {
                @panic("out of memory reporting an unanswered message");
            };
            self.reportError(arena, null, text);
            self.freeLaterReply(entry.value_ptr.*);
        }
        self.later_replies.deinit(self.allocator);
    }

    // Answers a message with a task: queues a task of the type, with data_json as its input, and returns at once. The task's result
    // is the message's response, sent when the task ends, and a task that fails or is cancelled gives an error message response. The
    // app's message handler, one that takes ziggy.core.Message, calls it and returns what it returns. A message that has no id, one sent with send, has nothing to
    // answer, so it is an error (MessageHasNoId) and nothing is queued. The task runs under the source "request".
    //
    pub fn answerWithTask(self: *Core, message: Message, task_type: []const u8, data_json: []const u8) !MessageResult {
        const id = message.id orelse {
            return error.MessageHasNoId;
        };
        const id_json = try json.stringify(self.allocator, id);
        defer self.allocator.free(id_json);
        var task_id_buffer: [32]u8 = undefined;
        const task_id = try std.fmt.bufPrint(&task_id_buffer, "request-{d}", .{self.next_request_task.fetchAdd(1, .monotonic)});
        try self.runner.addTask(task_id, task_type, "request", data_json, .interactive, id_json);
        return .answered_by_task;
    }

    //
    // Sends the frontend an event of the app's own, whose data is the JSON text data_json, which the frontend's onEvent listeners
    // receive.
    //
    pub fn sendEvent(self: *Core, arena: std.mem.Allocator, data_json: []const u8) !void {
        const event = try json.stringify(arena, .{
            .kind = "app",
            .data = json.Raw{
                .text = data_json,
            },
        });
        self.deliver(event);
    }

    //
    // Reports the error a handler returned: the text the app's describe_error gives for it, or else its name.
    //
    fn reportHandlerError(self: *Core, arena: std.mem.Allocator, request_id: ?std.json.Value, err: anyerror) void {
        const described: ?[]const u8 = if (self.describe_error) |describe| describe(err) else null;
        self.reportError(arena, request_id, described orelse @errorName(err));
    }

    //
    // Sends the successful reply to a request.
    //
    fn sendReply(self: *Core, arena: std.mem.Allocator, id: std.json.Value, reply_data: []const u8) !void {
        const reply = try json.stringify(arena, .{
            .id = id,
            .ok = true,
            .data = json.Raw{
                .text = reply_data,
            },
        });
        self.deliver(reply);
    }

    //
    // Replies to a request with an error reply, or, when there is nothing to reply to, sends a core-error event.
    //
    fn reportError(self: *Core, arena: std.mem.Allocator, id: ?std.json.Value, error_name: []const u8) void {
        if (id) |id_value| {
            const reply = json.stringify(arena, .{
                .id = id_value,
                .ok = false,
                .@"error" = error_name,
            }) catch {
                @panic("out of memory building an error message");
            };
            self.deliver(reply);
            return;
        }
        const event = json.stringify(arena, .{
            .kind = "system",
            .name = "core-error",
            .data = .{
                .@"error" = error_name,
            },
        }) catch {
            @panic("out of memory building an error message");
        };
        self.deliver(event);
    }
};

//
// The runner calls this when a task has ended: tells the queue backend, then the app.
//
fn observeTaskEnd(user_data: ?*anyopaque, end: types.TaskEnd) void {
    const core: *Core = @ptrCast(@alignCast(user_data.?));
    core.queue_backend.taskEnded(end);
    if (core.on_task_end) |on_task_end| {
        on_task_end(core, end);
    }
}

//
// The runner calls this when a task has sent an event: tells the queue backend, then the app.
//
fn observeTaskEvent(user_data: ?*anyopaque, sent: types.TaskSentEvent) void {
    const core: *Core = @ptrCast(@alignCast(user_data.?));
    core.queue_backend.eventSent(sent);
    if (core.on_task_event) |on_task_event| {
        on_task_event(core, sent);
    }
}

//
// Delivers a message the runner or the test control connection produced to the native app.
//
fn emitFromRunner(user_data: ?*anyopaque, message: []const u8) void {
    const core: *Core = @ptrCast(@alignCast(user_data.?));
    core.deliver(message);
}

//
// What the test control connection calls for its drop command: records the files as the native app does when the user drops them.
//
fn filesDroppedFromControl(user_data: ?*anyopaque, paths_json: []const u8) anyerror!void {
    const core: *Core = @ptrCast(@alignCast(user_data.?));
    try core.filesDropped(paths_json);
}
