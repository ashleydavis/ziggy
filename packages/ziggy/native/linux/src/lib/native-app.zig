//
// Ziggy's Linux native app. It creates the window, hosts WebKitGTK, injects window.ziggy, loads the app's bundled
// frontend, calls the core through the C interface and moves messages between the frontend and the core.
//
// Only the GTK main thread touches the native app's state. The core posts its messages for the native app to the native app's queue
// and wakes the main thread, which takes them (see native-message.zig in the core): it passes each message for the frontend to the web
// view and does each call, giving the core the result of each call that has one.
//

const std = @import("std");
const c = @import("gtk.zig");
const z = @import("c");
const menu_keys = @import("menu-keys.zig");
const geometry_lib = @import("geometry.zig");
const render_device = @import("render-device.zig");
const native_message = @import("native-message");

// The URL scheme the bundled frontend is served under. WebKitGTK calls the native app's scheme handler for each file instead of reading a directory.
const app_scheme = "ziggy-app";

// The URL prefix of the bundled frontend, with a trailing slash. It is what the core allows the web view to navigate to.
const app_url_prefix = app_scheme ++ "://app/";

//
// What a native call handler can call on the native app.
//
pub const NativeCallContext = struct {
    // The native app the native call came to.
    native_app: *NativeApp,

    //
    // Holds the computer from suspending, or lets it go again. Calls nest: the computer may suspend again once every hold has been
    // let go.
    //
    pub fn holdAwake(self: NativeCallContext, awake: bool) void {
        if (awake) {
            holdAwakeOnMainThread(self.native_app);
        }
        else {
            releaseAwakeOnMainThread(self.native_app);
        }
    }
};

//
// Handles one native call. Gives the JSON text of the result, null when the app does not know the method, or an error, whose name is
// the reason the native call failed. Called on the GTK main thread, so it must not wait for long.
//
pub const NativeCallFn = *const fn (context: NativeCallContext, method: []const u8, request_json: []const u8) anyerror!?[]const u8;

//
// What an app tells the native app about itself.
//
pub const AppConfig = struct {
    // Handles the requests only the platform can do, by method name, or null when the app has none.
    native_call: ?NativeCallFn,
    // The application id, which also names the app's private data directory.
    app_id: [:0]const u8,
    // The window title.
    title: [:0]const u8,
    // The window's width when the command line does not give one.
    default_width: c_int,
    // The window's height when the command line does not give one.
    default_height: c_int,
    // The PNG file of the window icon, or null when the app has none and the window shows the desktop's generic one.
    icon_png: ?[]const u8,
};

//
// Everything one running native app owns. It lives on the stack of run and every callback is given its address. Only the GTK main
// thread touches it.
//
const NativeApp = struct {
    // The configuration the app passed in.
    app_config: AppConfig,
    // The GTK application.
    application: *c.GtkApplication,
    // The command line, for the geometry option.
    args: []const [:0]const u8,
    // The web view, once the window exists.
    web_view: ?*c.WebKitWebView,
    // The core's handle, until it is destroyed.
    core: ?*anyopaque,
    // The file dialog that is showing, or null.
    open_pick: ?*PickDialog,
    // The screenshot whose snapshot is being made, or null.
    open_screenshot: ?*Screenshot,
    // Whether a test hooks build was started in test mode.
    test_mode: bool,
    // The window, once it exists.
    window: ?*c.GtkWindow,
    // Whether the developer tools window is showing.
    inspector_open: bool,
    // Whether the window is full screen.
    fullscreen: bool,
    // How many holds on the computer staying awake are in place. Only the main thread touches it.
    awake_holds: u32,
    // The cookie of the suspend inhibit, while there is one.
    inhibit_cookie: c_uint,
};

//
// Runs the app and returns the process's exit code.
//
pub fn run(app_config: AppConfig, args: []const [:0]const u8) !u8 {
    // Before GTK starts any thread, because choosing the card forks.
    try render_device.chooseRenderDevice();
    const application = c.gtk_application_new(app_config.app_id.ptr, c.G_APPLICATION_NON_UNIQUE) orelse {
        return error.GtkApplicationFailed;
    };
    defer c.g_object_unref(application);
    var native_app = NativeApp{
        .app_config = app_config,
        .application = application,
        .args = args,
        .web_view = null,
        .core = null,
        .open_pick = null,
        .open_screenshot = null,
        .test_mode = false,
        .window = null,
        .inspector_open = false,
        .fullscreen = false,
        .awake_holds = 0,
        .inhibit_cookie = 0,
    };
    _ = c.g_signal_connect_data(application, "activate", @ptrCast(&onActivate), &native_app, null, 0);
    _ = c.g_signal_connect_data(application, "shutdown", @ptrCast(&onShutdown), &native_app, null, 0);
    const status = c.g_application_run(@ptrCast(application), 0, null);
    if (status < 0 or status > 255) {
        return error.GtkApplicationFailed;
    }
    return @intCast(status);
}

//
// Sets the window's icon from the bytes of a PNG file.
//
fn setWindowIcon(window: *c.GtkWindow, icon_png: []const u8) void {
    const loader = c.gdk_pixbuf_loader_new_with_type("png", null) orelse {
        fatal("could not create the icon loader", .{});
    };
    defer c.g_object_unref(loader);
    if (c.gdk_pixbuf_loader_write(loader, icon_png.ptr, icon_png.len, null) == 0) {
        fatal("could not read the window icon", .{});
    }
    if (c.gdk_pixbuf_loader_close(loader, null) == 0) {
        fatal("could not finish reading the window icon", .{});
    }
    c.gtk_window_set_icon(window, c.gdk_pixbuf_loader_get_pixbuf(loader));
}

//
// Reports why the native app cannot go on and ends the program with a failure code.
//
fn fatal(comptime format: []const u8, arguments: anytype) noreturn {
    std.debug.print("ziggy native app: " ++ format ++ "\n", arguments);
    std.process.exit(1);
}

//
// WebKitGTK runs its web process in a bubblewrap sandbox, which needs the program to be allowed to create a user
// namespace. Some systems do not allow that to an ordinary program (Ubuntu's default restriction on user namespaces is one),
// and the web view then cannot start at all. This runs the same bubblewrap setup WebKitGTK does, and when it fails turns the
// sandbox off for this process through the environment variable WebKitGTK documents for it, and reports it on standard error.
// The app loads only its own bundled frontend and refuses every other navigation, which is what limits what runs without
// the sandbox. A setting made in the environment is left alone, so it can still be set either way from outside.
//
fn turnSandboxOffWhenItCannotStart() !void {
    if (c.g_getenv("WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS") != null) {
        return;
    }
    if (c.system("bwrap --ro-bind / / --unshare-user true > /dev/null 2>&1") == 0) {
        return;
    }
    std.debug.print("ziggy native app: the web view's sandbox cannot start on this system (bubblewrap is not allowed to create a user namespace), so it is turned off for this run.\n", .{});
    if (c.setenv("WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS", "1", 1) != 0) {
        return error.SetEnvironmentFailed;
    }
}

//
// Serves a web view request for one of the bundled frontend's files, from the files the core holds. A path that is not
// one of them gets a not found error. The frontend is loaded only once the core exists.
//
fn onUriSchemeRequest(request: *c.WebKitURISchemeRequest, user_data: c.gpointer) callconv(.c) void {
    const native_app: *NativeApp = @ptrCast(@alignCast(user_data.?));
    const request_path = std.mem.span(c.webkit_uri_scheme_request_get_path(request));
    const core = native_app.core orelse {
        fatal("the web view requested {s} before the core existed", .{request_path});
    };
    var file: z.ziggy_ui_file_result = undefined;
    if (!z.ziggy_ui_file(core, request_path.ptr, request_path.len, &file)) {
        const not_found = c.g_error_new_literal(c.g_io_error_quark(), c.G_IO_ERROR_NOT_FOUND, "the UI has no such file");
        c.webkit_uri_scheme_request_finish_error(request, not_found);
        c.g_error_free(not_found);
        return;
    }
    // The bytes live in the executable for as long as it runs, so the stream is told not to free them.
    const stream = c.g_memory_input_stream_new_from_data(file.content, @intCast(file.content_length), null);
    c.webkit_uri_scheme_request_finish(request, stream, @intCast(file.content_length), file.content_type);
    c.g_object_unref(stream);
}

//
// GTK calls this when the application starts: creates the window and the web view.
//
fn onActivate(application: *c.GtkApplication, user_data: ?*anyopaque) callconv(.c) void {
    const native_app: *NativeApp = @ptrCast(@alignCast(user_data.?));
    start(native_app, application) catch |err| {
        fatal("could not start: {s}", .{@errorName(err)});
    };
}

//
// Creates the window and the web view, creates the core and loads the frontend.
//
fn start(native_app: *NativeApp, application: *c.GtkApplication) !void {
    const test_hooks = z.ziggy_test_hooks_enabled();
    native_app.test_mode = test_hooks and c.g_getenv("ZIGGY_TEST_MODE") != null;

    // The frontend's own scripts are classic scripts, but a frontend may also fetch its files, which needs the scheme to
    // be allowed to make cross-origin style requests and to count as a secure context like https does.
    const web_context = c.webkit_web_context_get_default();
    c.webkit_web_context_register_uri_scheme(web_context, app_scheme, onUriSchemeRequest, native_app, null);
    const security_manager = c.webkit_web_context_get_security_manager(web_context);
    c.webkit_security_manager_register_uri_scheme_as_secure(security_manager, app_scheme);
    c.webkit_security_manager_register_uri_scheme_as_cors_enabled(security_manager, app_scheme);

    const data_directory = c.g_build_filename(c.g_get_user_data_dir(), native_app.app_config.app_id.ptr, @as([*c]const u8, null));
    defer c.g_free(data_directory);
    if (c.g_mkdir_with_parents(data_directory, 0o755) != 0) {
        return error.DataDirectoryFailed;
    }

    var width = native_app.app_config.default_width;
    var height = native_app.app_config.default_height;
    for (native_app.args) |argument| {
        if (std.mem.startsWith(u8, argument, "-geometry=")) {
            const geometry = geometry_lib.parseGeometry(argument["-geometry=".len..]) orelse {
                return error.InvalidGeometry;
            };
            width = geometry.width;
            height = geometry.height;
        }
    }

    const window_widget = c.gtk_application_window_new(application);
    const window: *c.GtkWindow = @ptrCast(@alignCast(window_widget));
    native_app.window = window;
    c.gtk_window_set_title(window, native_app.app_config.title.ptr);
    c.gtk_window_set_default_size(window, width, height);
    if (native_app.app_config.icon_png) |icon_png| {
        setWindowIcon(window, icon_png);
    }

    try turnSandboxOffWhenItCannotStart();
    const web_view_widget = c.webkit_web_view_new();
    const web_view: *c.WebKitWebView = @ptrCast(@alignCast(web_view_widget));
    native_app.web_view = web_view;
    c.webkit_settings_set_enable_developer_extras(c.webkit_web_view_get_settings(web_view), 1);
    _ = c.g_signal_connect_data(c.webkit_web_view_get_inspector(web_view), "closed", @ptrCast(&onInspectorClosed), native_app, null, 0);
    const box_widget = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
    c.gtk_container_add(window_widget, box_widget);
    c.gtk_box_pack_start(box_widget, web_view_widget, 1, 1, 0);

    const content_manager = c.webkit_web_view_get_user_content_manager(web_view);
    if (c.webkit_user_content_manager_register_script_message_handler(content_manager, "ziggy") == 0) {
        return error.ScriptMessageHandlerFailed;
    }
    _ = c.g_signal_connect_data(content_manager, "script-message-received::ziggy", @ptrCast(&onScriptMessage), native_app, null, 0);
    var inject_script_length: usize = 0;
    const inject_script = z.ziggy_inject_script(&inject_script_length);
    const user_script = c.webkit_user_script_new(@ptrCast(inject_script), c.WEBKIT_USER_CONTENT_INJECT_TOP_FRAME, c.WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START, null, null);
    c.webkit_user_content_manager_add_script(content_manager, user_script);
    c.webkit_user_script_unref(user_script);
    _ = c.g_signal_connect_data(web_view, "decide-policy", @ptrCast(&onDecidePolicy), native_app, null, 0);
    _ = c.g_signal_connect_data(window, "delete-event", @ptrCast(&onDeleteEvent), native_app, null, 0);
    _ = c.g_signal_connect_data(web_view, "drag-data-received", @ptrCast(&onDragDataReceived), native_app, null, 0);

    var config = std.mem.zeroes(z.ziggy_config);
    // GLib hands the native app's address back to the main thread with the idle callback, unread.
    config.wake_data = native_app;
    config.wake = wake;
    config.has_os_version = true;
    config.has_quit = true;
    config.has_pick_paths = true;
    config.has_menu_action = true;
    config.has_screenshot = true;
    config.has_native_call = native_app.app_config.native_call != null;
    config.worker_threads = c.g_get_num_processors();
    config.max_concurrent_child_tasks = 10;
    config.app_url_prefix = app_url_prefix;
    config.data_dir = data_directory;
    if (native_app.test_mode) {
        config.test_mode = true;
        config.test_port_file = c.g_getenv("ZIGGY_TEST_PORT_FILE");
    }
    // The command-line arguments after the program's name, which the core copies, for the app to read its own options from.
    const app_args = native_app.args[@min(native_app.args.len, 1)..];
    const argument_pointers = try std.heap.c_allocator.alloc([*:0]const u8, app_args.len);
    defer std.heap.c_allocator.free(argument_pointers);
    for (app_args, argument_pointers) |argument, *pointer| {
        pointer.* = argument.ptr;
    }
    config.arg_count = @intCast(argument_pointers.len);
    config.args = @ptrCast(argument_pointers.ptr);
    native_app.core = z.ziggy_create(&config) orelse {
        return error.CoreCreateFailed;
    };

    try buildMenu(native_app, box_widget, window);

    // The app supplies the query unread, and the core names none of its parts.
    var query_length: usize = 0;
    const query_pointer = z.ziggy_ui_query(native_app.core, &query_length) orelse {
        return error.UiQueryFailed;
    };
    const query = query_pointer[0..query_length];
    const query_separator: []const u8 = if (query.len > 0) "?" else "";
    const ui_url = try std.fmt.allocPrintSentinel(std.heap.c_allocator, "{s}index.html{s}{s}", .{ app_url_prefix, query_separator, query }, 0);
    defer std.heap.c_allocator.free(ui_url);
    c.webkit_web_view_load_uri(web_view, ui_url.ptr);
    c.gtk_widget_show_all(window_widget);
    c.gtk_window_present(window);
}

//
// A message from the frontend: hands it to the core.
//
fn onScriptMessage(content_manager: *c.WebKitUserContentManager, result: *c.WebKitJavascriptResult, user_data: ?*anyopaque) callconv(.c) void {
    _ = content_manager;
    const native_app: *NativeApp = @ptrCast(@alignCast(user_data.?));
    const core = native_app.core orelse {
        return;
    };
    const text = c.jsc_value_to_string(c.webkit_javascript_result_get_js_value(result)) orelse {
        fatal("the UI posted a message that is not a string", .{});
    };
    defer c.g_free(text);
    const slice = std.mem.span(@as([*:0]const u8, @ptrCast(text)));
    z.ziggy_send_message(core, slice.ptr, slice.len);
}

//
// Decides every navigation with the core's origin check: the app's own frontend loads, external links open in the
// system browser, and everything else is blocked.
//
fn onDecidePolicy(web_view: *c.WebKitWebView, decision: *c.WebKitPolicyDecision, decision_type: c.WebKitPolicyDecisionType, user_data: ?*anyopaque) callconv(.c) c.gboolean {
    _ = web_view;
    const native_app: *NativeApp = @ptrCast(@alignCast(user_data.?));
    if (decision_type != c.WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION and decision_type != c.WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION) {
        return 0;
    }
    const navigation_decision: *c.WebKitNavigationPolicyDecision = @ptrCast(@alignCast(decision));
    const action = c.webkit_navigation_policy_decision_get_navigation_action(navigation_decision);
    const request = c.webkit_navigation_action_get_request(action);
    const uri = std.mem.span(@as([*:0]const u8, @ptrCast(c.webkit_uri_request_get_uri(request))));
    const verdict = z.ziggy_check_url(native_app.core, uri.ptr, uri.len);
    if (verdict == z.ZIGGY_URL_ALLOW and decision_type == c.WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION) {
        c.webkit_policy_decision_use(decision);
        return 1;
    }
    if (verdict == z.ZIGGY_URL_OPEN_EXTERNALLY) {
        _ = c.gtk_show_uri_on_window(null, uri.ptr, c.GDK_CURRENT_TIME, null);
    }
    c.webkit_policy_decision_ignore(decision);
    return 1;
}

//
// Records the files of a drop on the web view with the core, so the frontend can get their paths. WebKitGTK gives the frontend no
// files and hides the file addresses, so the paths can only be read here. This handler runs before WebKit's own, which is the default
// handler of the signal and runs last, so the paths are recorded before the frontend's drop is handled. Anything dropped that is not a file is ignored.
//
fn onDragDataReceived(widget: *c.GtkWidget, drag_context: *c.GdkDragContext, x: c_int, y: c_int, data: *c.GtkSelectionData, info: c_uint, time: c_uint, user_data: ?*anyopaque) callconv(.c) void {
    _ = widget;
    _ = drag_context;
    _ = x;
    _ = y;
    _ = info;
    _ = time;
    const native_app: *NativeApp = @ptrCast(@alignCast(user_data.?));
    const core = native_app.core orelse {
        return;
    };
    const uris = c.gtk_selection_data_get_uris(data);
    if (uris == null) {
        return;
    }
    defer c.g_strfreev(uris);
    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |path| {
            c.g_free(@ptrCast(@constCast(path.ptr)));
        }
        paths.deinit(std.heap.c_allocator);
    }
    var index: usize = 0;
    while (uris[index] != null) : (index += 1) {
        const path = c.g_filename_from_uri(uris[index], null, null);
        if (path == null) {
            continue;
        }
        paths.append(std.heap.c_allocator, std.mem.span(@as([*:0]const u8, @ptrCast(path)))) catch @panic("out of memory recording a drop");
    }
    const json = std.json.Stringify.valueAlloc(std.heap.c_allocator, paths.items, .{}) catch @panic("out of memory recording a drop");
    defer std.heap.c_allocator.free(json);
    if (!z.ziggy_files_dropped(core, json.ptr, json.len)) {
        std.debug.print("could not record the dropped files: {s}\n", .{json});
    }
}

//
// The window is being closed: destroys the core before the window goes.
//
fn onDeleteEvent(window: *c.GtkWidget, event: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) c.gboolean {
    _ = event;
    _ = window;
    const native_app: *NativeApp = @ptrCast(@alignCast(user_data.?));
    destroyCore(native_app);
    return 0;
}

//
// The application is shutting down: destroys the core if it still exists.
//
fn onShutdown(application: *c.GApplication, user_data: ?*anyopaque) callconv(.c) void {
    _ = application;
    const native_app: *NativeApp = @ptrCast(@alignCast(user_data.?));
    destroyCore(native_app);
}

//
// Destroys the core once. After it nothing more is delivered to the frontend and no result is sent: ziggy_destroy gives every
// call taken and not finished yet its result, so a file dialog that is showing is closed with no result.
//
fn destroyCore(native_app: *NativeApp) void {
    const core = native_app.core orelse {
        return;
    };
    native_app.core = null;
    closePickDialog(native_app);
    z.ziggy_destroy(core);
}

//
// The core's wake. It runs on any thread of the core or the app, and only adds an idle callback, which GLib runs on the main thread
// with the native app's address, the wake data, which this never reads.
//
fn wake(wake_data: ?*anyopaque) callconv(.c) void {
    _ = c.g_idle_add(takeCoreMessages, wake_data);
}

//
// Runs on the main thread: takes every message the core has posted for the native app, passing each message for the frontend to the
// web view and doing each call.
//
fn takeCoreMessages(user_data: ?*anyopaque) callconv(.c) c.gboolean {
    const native_app: *NativeApp = @ptrCast(@alignCast(user_data.?));
    while (true) {
        const core = native_app.core orelse {
            return 0;
        };
        var length: usize = 0;
        var kind: i32 = 0;
        var reply: u64 = 0;
        const text_pointer = z.ziggy_take_native_message(core, &length, &kind, &reply) orelse {
            return 0;
        };
        // The text is valid only until the next take, so the call works on a copy of its own.
        const text = std.heap.c_allocator.dupe(u8, text_pointer[0..length]) catch @panic("out of memory taking a message from the core");
        defer std.heap.c_allocator.free(text);
        if (kind == z.ZIGGY_NATIVE_DELIVER) {
            deliverToWebView(native_app, text);
            continue;
        }
        doCall(native_app, text, reply) catch |err| {
            fatal("could not do the core's call {s}: {s}", .{ text, @errorName(err) });
        };
    }
}

//
// Sends a message from the core to the frontend.
//
fn deliverToWebView(native_app: *NativeApp, text: []const u8) void {
    const web_view = native_app.web_view orelse {
        fatal("a message arrived from the core before the web view existed", .{});
    };
    const script = std.mem.concat(std.heap.c_allocator, u8, &.{ "window.__ziggyReceive(", text, ");" }) catch @panic("out of memory delivering a message");
    defer std.heap.c_allocator.free(script);
    c.webkit_web_view_evaluate_javascript(web_view, script.ptr, @intCast(script.len), null, null, null, null, null);
}

//
// Does one call of the core's, and sends the core its result when it has one: at once, or, for a dialog or a screenshot, once it is done.
//
fn doCall(native_app: *NativeApp, text: []const u8, reply: u64) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const call = try native_message.parse(arena, text);
    switch (call) {
        .quit => quitApplication(native_app),
        .menu_action => |action| try performAction(native_app, action),
        .os_version => {
            var buffer: [512]u8 = undefined;
            const version = osVersion(&buffer) catch |err| {
                sendResult(native_app, reply, false, @errorName(err));
                return;
            };
            sendResult(native_app, reply, true, version);
        },
        .native_call => |native_call| runNativeCall(native_app, reply, native_call.method, native_call.request),
        .pick_paths => |pick| try showPickDialog(native_app, reply, pick),
        .screenshot => |output_path| try startScreenshot(native_app, reply, output_path),
        .keep_alive, .stopped => fatal("the core sent a call the native app does not do: {s}", .{text}),
    }
}

//
// Sends the core the result of its call taken under the number `reply`, unless the core has been destroyed, which gave it its result already.
//
fn sendResult(native_app: *NativeApp, reply: u64, ok: bool, text: []const u8) void {
    const core = native_app.core orelse {
        return;
    };
    z.ziggy_native_result(core, reply, ok, text.ptr, text.len);
}

//
// The operating system's version, as the JSON text of a string written into the buffer.
//
fn osVersion(buffer: []u8) ![]u8 {
    var info: std.c.utsname = undefined;
    if (std.c.uname(&info) != 0) {
        return error.VersionUnavailable;
    }
    var version_buffer: [256]u8 = undefined;
    const version = try std.fmt.bufPrint(&version_buffer, "{s} {s} {s}", .{
        std.mem.sliceTo(&info.sysname, 0),
        std.mem.sliceTo(&info.release, 0),
        std.mem.sliceTo(&info.machine, 0),
    });
    // The version is written as a JSON string, so the JSON writer does the quoting and escaping.
    return try std.fmt.bufPrint(buffer, "{f}", .{std.json.fmt(version, .{})});
}

//
// Does one thing only the platform can do by handing it to the app's handler, and sends the core its result, or the reason it
// failed.
//
fn runNativeCall(native_app: *NativeApp, reply: u64, method: []const u8, request: []const u8) void {
    const handler = native_app.app_config.native_call.?;
    var reason_buffer: [256]u8 = undefined;
    const result = handler(.{ .native_app = native_app }, method, request) catch |err| {
        sendResult(native_app, reply, false, std.fmt.bufPrint(&reason_buffer, "The native call {s} failed: {s}", .{ method, @errorName(err) }) catch "The native call failed.");
        return;
    };
    const text = result orelse {
        sendResult(native_app, reply, false, std.fmt.bufPrint(&reason_buffer, "The {s} Linux app cannot do \"{s}\".", .{ native_app.app_config.title, method }) catch "The native call is not known.");
        return;
    };
    sendResult(native_app, reply, true, text);
}

//
// Takes one hold on the computer staying awake. The first one inhibits suspend.
//
fn holdAwakeOnMainThread(native_app: *NativeApp) void {
    native_app.awake_holds += 1;
    if (native_app.awake_holds == 1) {
        const reason = std.fmt.allocPrintSentinel(std.heap.c_allocator, "{s} is working in the background", .{native_app.app_config.title}, 0) catch @panic("out of memory holding the computer awake");
        defer std.heap.c_allocator.free(reason);
        native_app.inhibit_cookie = c.gtk_application_inhibit(native_app.application, native_app.window, c.GTK_APPLICATION_INHIBIT_SUSPEND, reason.ptr);
    }
}

//
// Lets go of one hold on the computer staying awake. Letting go of the last one allows suspend again.
//
fn releaseAwakeOnMainThread(native_app: *NativeApp) void {
    if (native_app.awake_holds == 0) {
        fatal("a hold on the computer staying awake was let go that was never taken", .{});
    }
    native_app.awake_holds -= 1;
    if (native_app.awake_holds == 0 and native_app.inhibit_cookie != 0) {
        c.gtk_application_uninhibit(native_app.application, native_app.inhibit_cookie);
        native_app.inhibit_cookie = 0;
    }
}

//
// Quits the application.
//
fn quitApplication(native_app: *NativeApp) void {
    c.g_application_quit(@ptrCast(native_app.application));
}


//
// One menu item's action, kept for as long as the menu item lives: it and its action are allocated with the C allocator and freed
// when GTK destroys the item (see freeMenuItemContext).
//
const MenuItemContext = struct {
    // The native app the item belongs to.
    native_app: *NativeApp,
    // The item's action.
    action: [:0]const u8,
};

//
// Frees a menu item's context when GTK destroys the item, as the destroy notify of its "activate" handler.
//
fn freeMenuItemContext(data: ?*anyopaque, closure: ?*anyopaque) callconv(.c) void {
    _ = closure;
    const context: *MenuItemContext = @ptrCast(@alignCast(data.?));
    std.heap.c_allocator.free(context.action);
    std.heap.c_allocator.destroy(context);
}

//
// Builds the menu bar from the app's menu, which the core holds as JSON, and puts it above the web view. An app with no menu
// gets no menu bar. Every item's shortcut is registered with the window, so it works wherever the focus is.
//
fn buildMenu(native_app: *NativeApp, box_widget: *c.GtkWidget, window: *c.GtkWindow) !void {
    var length: usize = 0;
    const text_pointer = z.ziggy_menu_json(native_app.core, &length);
    // The menu's parsed text and labels are needed only while the menu is built: GTK copies a label.
    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const menus = try std.json.parseFromSliceLeaky(std.json.Value, arena, text_pointer[0..length], .{});
    if (menus != .array) {
        return error.MenuIsNotAnArray;
    }
    if (menus.array.items.len == 0) {
        return;
    }
    const accel_group = c.gtk_accel_group_new();
    c.gtk_window_add_accel_group(window, accel_group);
    const menu_bar = c.gtk_menu_bar_new();
    for (menus.array.items) |menu| {
        const menu_item = c.gtk_menu_item_new_with_label(try requireString(arena, menu, "label"));
        const submenu = c.gtk_menu_new();
        try appendItems(native_app, arena, submenu, accel_group, menu);
        c.gtk_menu_item_set_submenu(menu_item, submenu);
        c.gtk_menu_shell_append(menu_bar, menu_item);
    }
    c.gtk_box_pack_start(box_widget, menu_bar, 0, 0, 0);
    c.gtk_box_reorder_child(box_widget, menu_bar, 0);
}

//
// Adds the "items" of a menu or submenu to a GTK menu.
//
fn appendItems(native_app: *NativeApp, arena: std.mem.Allocator, gtk_menu: *c.GtkWidget, accel_group: *c.GtkAccelGroup, menu: std.json.Value) !void {
    const items = menu.object.get("items") orelse {
        return error.MenuHasNoItems;
    };
    for (items.array.items) |item| {
        if (item.object.get("separator") != null) {
            c.gtk_menu_shell_append(gtk_menu, c.gtk_separator_menu_item_new());
            continue;
        }
        const menu_item = c.gtk_menu_item_new_with_label(try requireString(arena, item, "label"));
        if (item.object.get("items") != null) {
            const submenu = c.gtk_menu_new();
            try appendItems(native_app, arena, submenu, accel_group, item);
            c.gtk_menu_item_set_submenu(menu_item, submenu);
        }
        else {
            const context = try std.heap.c_allocator.create(MenuItemContext);
            errdefer std.heap.c_allocator.destroy(context);
            context.* = .{
                .native_app = native_app,
                .action = try requireString(std.heap.c_allocator, item, "action"),
            };
            _ = c.g_signal_connect_data(menu_item, "activate", @ptrCast(&onMenuItemActivate), context, @ptrCast(@constCast(&freeMenuItemContext)), 0);
            if (item.object.get("accelerator")) |accelerator_text| {
                try addAccelerator(arena, menu_item, accel_group, accelerator_text.string);
            }
        }
        c.gtk_menu_shell_append(gtk_menu, menu_item);
    }
}

//
// Registers a menu item's keyboard shortcut with the window.
//
fn addAccelerator(arena: std.mem.Allocator, menu_item: *c.GtkWidget, accel_group: *c.GtkAccelGroup, text: []const u8) !void {
    var parsed: z.ziggy_accelerator = undefined;
    if (!z.ziggy_parse_accelerator(text.ptr, text.len, &parsed)) {
        std.debug.print("ziggy native app: the menu has a shortcut that cannot be read: {s}\n", .{text});
        return error.UnreadableShortcut;
    }
    _ = arena;
    var name_buffer: [32]u8 = undefined;
    const key_name = try menu_keys.gdkKeyName(&name_buffer, std.mem.sliceTo(&parsed.key, 0));
    const key_value = c.gdk_keyval_from_name(key_name.ptr);
    if (key_value == 0) {
        std.debug.print("ziggy native app: GTK has no key named {s}, for the shortcut {s}\n", .{ key_name, text });
        return error.UnknownKey;
    }
    c.gtk_widget_add_accelerator(menu_item, "activate", accel_group, key_value, menu_keys.gdkModifiers(parsed.modifiers), c.GTK_ACCEL_VISIBLE);
}

//
// Reads a string field of a menu entry, as a NUL terminated copy allocated with the allocator.
//
fn requireString(arena: std.mem.Allocator, entry: std.json.Value, name: []const u8) ![:0]const u8 {
    const field = entry.object.get(name) orelse {
        std.debug.print("ziggy native app: a menu entry has no \"{s}\"\n", .{name});
        return error.MenuEntryIncomplete;
    };
    return try arena.dupeZ(u8, field.string);
}

//
// A menu item was chosen: does its action.
//
fn onMenuItemActivate(menu_item: *c.GtkWidget, user_data: ?*anyopaque) callconv(.c) void {
    _ = menu_item;
    const context: *MenuItemContext = @ptrCast(@alignCast(user_data.?));
    performAction(context.native_app, context.action) catch |err| {
        fatal("could not do the menu action {s}: {s}", .{ context.action, @errorName(err) });
    };
}

//
// Does a menu action. The actions every native app does itself are done here. Any other is the app's: it goes to the core, which
// runs the app's item.
//
fn performAction(native_app: *NativeApp, action: []const u8) !void {
    const web_view = native_app.web_view.?;
    if (std.mem.eql(u8, action, "quit")) {
        quitApplication(native_app);
    }
    else if (std.mem.eql(u8, action, "close-window")) {
        c.gtk_window_close(native_app.window.?);
    }
    else if (std.mem.eql(u8, action, "reload")) {
        c.webkit_web_view_reload(web_view);
    }
    else if (std.mem.eql(u8, action, "toggle-devtools")) {
        const inspector = c.webkit_web_view_get_inspector(web_view);
        if (native_app.inspector_open) {
            c.webkit_web_inspector_close(inspector);
        }
        else {
            c.webkit_web_inspector_show(inspector);
            native_app.inspector_open = true;
        }
    }
    else if (std.mem.eql(u8, action, "toggle-fullscreen")) {
        if (native_app.fullscreen) {
            c.gtk_window_unfullscreen(native_app.window.?);
        }
        else {
            c.gtk_window_fullscreen(native_app.window.?);
        }
        native_app.fullscreen = !native_app.fullscreen;
    }
    else if (std.mem.eql(u8, action, "zoom-in")) {
        c.webkit_web_view_set_zoom_level(web_view, @min(5.0, c.webkit_web_view_get_zoom_level(web_view) + 0.1));
    }
    else if (std.mem.eql(u8, action, "zoom-out")) {
        c.webkit_web_view_set_zoom_level(web_view, @max(0.25, c.webkit_web_view_get_zoom_level(web_view) - 0.1));
    }
    else if (std.mem.eql(u8, action, "zoom-reset")) {
        c.webkit_web_view_set_zoom_level(web_view, 1.0);
    }
    else if (std.mem.eql(u8, action, "focus-window")) {
        c.gtk_window_present(native_app.window.?);
    }
    else if (editingCommand(action)) |command| {
        c.webkit_web_view_execute_editing_command(web_view, command);
    }
    else {
        const message = try std.json.Stringify.valueAlloc(std.heap.c_allocator, .{
            .kind = "system",
            .name = "menu-action",
            .data = .{
                .action = action,
            },
        }, .{});
        defer std.heap.c_allocator.free(message);
        z.ziggy_send_message(native_app.core, message.ptr, message.len);
    }
}

//
// The WebKit editing command for a menu action that edits, or null for any other action.
//
fn editingCommand(action: []const u8) ?[*:0]const u8 {
    if (std.mem.eql(u8, action, "undo")) {
        return "Undo";
    }
    if (std.mem.eql(u8, action, "redo")) {
        return "Redo";
    }
    if (std.mem.eql(u8, action, "cut")) {
        return "Cut";
    }
    if (std.mem.eql(u8, action, "copy")) {
        return "Copy";
    }
    if (std.mem.eql(u8, action, "paste")) {
        return "Paste";
    }
    if (std.mem.eql(u8, action, "select-all")) {
        return "SelectAll";
    }
    return null;
}

//
// The developer tools window was closed by the user, so the next toggle opens it again.
//
fn onInspectorClosed(inspector: *c.WebKitWebInspector, user_data: ?*anyopaque) callconv(.c) void {
    _ = inspector;
    const native_app: *NativeApp = @ptrCast(@alignCast(user_data.?));
    native_app.inspector_open = false;
}

//
// A file dialog that is showing for one of the core's calls. Only the main thread touches it.
//
const PickDialog = struct {
    // The native app.
    native_app: *NativeApp,
    // The dialog.
    dialog: *c.GtkFileChooserNative,
    // The number the result of the core's call is sent with.
    reply: u64,
};

//
// Shows a file or folder dialog for the core's call and returns at once: the result is sent when the user closes the dialog. One
// dialog shows at a time, as the core requests one at a time.
//
fn showPickDialog(native_app: *NativeApp, reply: u64, pick: native_message.PickPaths) !void {
    if (native_app.open_pick != null) {
        sendResult(native_app, reply, false, "A file dialog is showing already.");
        return;
    }
    const action: c_int = switch (pick.kind) {
        z.ZIGGY_PICK_OPEN_FILES => c.GTK_FILE_CHOOSER_ACTION_OPEN,
        z.ZIGGY_PICK_SAVE_FILE => c.GTK_FILE_CHOOSER_ACTION_SAVE,
        z.ZIGGY_PICK_FOLDER => c.GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER,
        else => {
            sendResult(native_app, reply, false, "UnknownDialogKind");
            return;
        },
    };
    const default_title: []const u8 = switch (pick.kind) {
        z.ZIGGY_PICK_OPEN_FILES => "Select Files",
        z.ZIGGY_PICK_SAVE_FILE => "Save As",
        else => "Select Folder",
    };
    const title = try std.heap.c_allocator.dupeZ(u8, pick.title orelse default_title);
    defer std.heap.c_allocator.free(title);
    const dialog = c.gtk_file_chooser_native_new(title.ptr, native_app.window, action, null, null);
    if (pick.kind == z.ZIGGY_PICK_OPEN_FILES) {
        c.gtk_file_chooser_set_select_multiple(dialog, 1);
    }
    if (pick.kind == z.ZIGGY_PICK_SAVE_FILE) {
        c.gtk_file_chooser_set_do_overwrite_confirmation(dialog, 1);
        if (pick.initial_name) |name| {
            const name_text = try std.heap.c_allocator.dupeZ(u8, name);
            defer std.heap.c_allocator.free(name_text);
            c.gtk_file_chooser_set_current_name(dialog, name_text.ptr);
        }
    }
    const open = try std.heap.c_allocator.create(PickDialog);
    open.* = .{
        .native_app = native_app,
        .dialog = dialog,
        .reply = reply,
    };
    native_app.open_pick = open;
    _ = c.g_signal_connect_data(dialog, "response", @ptrCast(&onPickResponse), open, null, 0);
    c.gtk_native_dialog_show(dialog);
}

//
// Runs on the main thread when the user closes the dialog: sends the core the paths chosen, as a JSON array, empty when
// they cancelled.
//
fn onPickResponse(dialog: *c.GtkFileChooserNative, response: c_int, user_data: ?*anyopaque) callconv(.c) void {
    const open: *PickDialog = @ptrCast(@alignCast(user_data.?));
    const native_app = open.native_app;
    const reply = open.reply;
    native_app.open_pick = null;
    std.heap.c_allocator.destroy(open);
    defer c.g_object_unref(dialog);
    if (response != c.GTK_RESPONSE_ACCEPT) {
        sendResult(native_app, reply, true, "[]");
        return;
    }
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(std.heap.c_allocator);
    const list = c.gtk_file_chooser_get_filenames(dialog);
    defer c.g_slist_free_full(list, c.g_free);
    var node = list;
    while (node) |entry| : (node = entry.next) {
        paths.append(std.heap.c_allocator, std.mem.span(@as([*:0]const u8, @ptrCast(entry.data.?)))) catch @panic("out of memory reading the paths chosen");
    }
    const json = std.json.Stringify.valueAlloc(std.heap.c_allocator, paths.items, .{}) catch @panic("out of memory reading the paths chosen");
    defer std.heap.c_allocator.free(json);
    sendResult(native_app, reply, true, json);
}

//
// Closes the file dialog that is showing, when there is one, with no result for its call: the core is being destroyed, which gives
// the call its result.
//
fn closePickDialog(native_app: *NativeApp) void {
    const open = native_app.open_pick orelse {
        return;
    };
    native_app.open_pick = null;
    c.gtk_native_dialog_destroy(open.dialog);
    c.g_object_unref(open.dialog);
    std.heap.c_allocator.destroy(open);
}

//
// A screenshot being taken for one of the core's calls. Only the main thread touches it.
//
const Screenshot = struct {
    // The native app.
    native_app: *NativeApp,
    // The number the result of the core's call is sent with.
    reply: u64,
    // The file to write the PNG to.
    output_path: [:0]u8,
};

//
// Starts a snapshot of what the web view's window shows, for the core's call, and returns at once: the result is sent once the file
// is written.
//
fn startScreenshot(native_app: *NativeApp, reply: u64, output_path: []const u8) !void {
    const web_view = native_app.web_view orelse {
        sendResult(native_app, reply, false, "the window has no web view yet");
        return;
    };
    if (native_app.open_screenshot != null) {
        sendResult(native_app, reply, false, "a screenshot is being taken already");
        return;
    }
    const taking = try std.heap.c_allocator.create(Screenshot);
    taking.* = .{
        .native_app = native_app,
        .reply = reply,
        .output_path = try std.heap.c_allocator.dupeZ(u8, output_path),
    };
    native_app.open_screenshot = taking;
    c.webkit_web_view_get_snapshot(web_view, c.WEBKIT_SNAPSHOT_REGION_VISIBLE, c.WEBKIT_SNAPSHOT_OPTIONS_NONE, null, onSnapshot, taking);
}

//
// Runs on the main thread when the web view has made the snapshot: writes it as a PNG and sends the core the result of its call.
//
fn onSnapshot(source: c.gpointer, result: *c.GAsyncResult, user_data: c.gpointer) callconv(.c) void {
    const taking: *Screenshot = @ptrCast(@alignCast(user_data.?));
    const native_app = taking.native_app;
    native_app.open_screenshot = null;
    defer {
        std.heap.c_allocator.free(taking.output_path);
        std.heap.c_allocator.destroy(taking);
    }
    const web_view: *c.WebKitWebView = @ptrCast(@alignCast(source.?));
    var snapshot_error: ?*c.GError = null;
    const surface = c.webkit_web_view_get_snapshot_finish(web_view, result, &snapshot_error) orelse {
        const fields: *const c.GErrorFields = @ptrCast(@alignCast(snapshot_error.?));
        var reason_buffer: [512]u8 = undefined;
        sendResult(native_app, taking.reply, false, std.fmt.bufPrint(&reason_buffer, "the web view could not make a snapshot: {s}", .{std.mem.span(fields.message)}) catch reason_buffer[0..]);
        c.g_error_free(snapshot_error.?);
        return;
    };
    defer c.cairo_surface_destroy(surface);
    const status = c.cairo_surface_write_to_png(surface, taking.output_path.ptr);
    if (status != c.CAIRO_STATUS_SUCCESS) {
        var reason_buffer: [512]u8 = undefined;
        sendResult(native_app, taking.reply, false, std.fmt.bufPrint(&reason_buffer, "could not write the PNG to {s}: {s}", .{ taking.output_path, std.mem.span(c.cairo_status_to_string(status)) }) catch reason_buffer[0..]);
        return;
    }
    sendResult(native_app, taking.reply, true, "");
}
