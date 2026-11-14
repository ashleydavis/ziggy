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
const remote_control_arguments = @import("remote-control-arguments");
const system_theme = @import("system-theme.zig");
const web_view_theme = @import("web-view-theme.zig");
const splash = @import("splash");

// The URL scheme the bundled frontend is served under. WebKitGTK calls the native app's scheme handler for each file instead of reading a directory.
const app_scheme = "ziggy-app";

// The URL prefix of the bundled frontend, with a trailing slash. It is what the core allows the web view to navigate to.
const app_url_prefix = app_scheme ++ "://app/";

// The address of the splash page in the core's UI files.
const splash_url = app_url_prefix ++ "ziggy-splash.html";

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
    // The app's private data directory, owned: freed with g_free when run returns.
    data_directory: [*:0]u8,
    // The GTK application.
    application: *c.GtkApplication,
    // The command line without --remote-control and its address, for the geometry option and the app.
    args: []const [:0]const u8,
    // The web view, once the window exists.
    web_view: ?*c.WebKitWebView,
    // The overlay the splash picture is added to, once it exists.
    overlay: ?*c.GtkWidget,
    // The drawing area that paints the splash image, or null when it is gone.
    splash_picture: ?*c.GtkWidget,
    // The pixbuf the splash picture draws. Owned while the picture exists.
    splash_pixbuf: ?*c.GdkPixbuf,
    // Whether the app's own frontend has loaded.
    main_loaded: bool,
    // The core's handle, until it is destroyed.
    core: ?*anyopaque,
    // The file dialog that is showing, or null.
    open_pick: ?*PickDialog,
    // The screenshot whose snapshot is being made, or null.
    open_screenshot: ?*Screenshot,
    // The remote control server's address from --remote-control, or null when the app was started without it. Test mode is on
    // exactly when it is set.
    remote_control: ?[:0]const u8,
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
    // The desktop portal's settings proxy, or null when it could not be made.
    portal: ?*c.GDBusProxy,
    // The desktop's GTK theme name before Ziggy changed it, which the light theme restores.
    gtk_theme_name: ?[*:0]u8,
};

//
// Runs the app and returns the process's exit code.
//
pub fn run(app_config: AppConfig, args: []const [:0]const u8) !u8 {
    // The option is taken out first, so nothing that reads the command line after this sees it. GApplication is given no
    // arguments at all, because it refuses options it does not know.
    const taken = try remote_control_arguments.take(std.heap.c_allocator, args);
    defer std.heap.c_allocator.free(taken.arguments);
    // Before GTK starts any thread, because choosing the card forks.
    try render_device.chooseRenderDevice();
    const data_directory = c.g_build_filename(c.g_get_user_data_dir(), app_config.app_id.ptr, @as([*c]const u8, null));
    defer c.g_free(data_directory);
    if (c.g_mkdir_with_parents(data_directory, 0o755) != 0) {
        return error.DataDirectoryFailed;
    }
    const application = c.gtk_application_new(app_config.app_id.ptr, c.G_APPLICATION_NON_UNIQUE) orelse {
        return error.GtkApplicationFailed;
    };
    defer c.g_object_unref(application);
    var native_app = NativeApp{
        .app_config = app_config,
        .data_directory = data_directory,
        .application = application,
        .args = taken.arguments,
        .web_view = null,
        .overlay = null,
        .splash_picture = null,
        .splash_pixbuf = null,
        .main_loaded = false,
        .core = null,
        .open_pick = null,
        .open_screenshot = null,
        .remote_control = taken.remote_control,
        .window = null,
        .inspector_open = false,
        .fullscreen = false,
        .awake_holds = 0,
        .inhibit_cookie = 0,
        .portal = null,
        .gtk_theme_name = null,
    };
    defer if (native_app.portal) |proxy| c.g_object_unref(proxy);
    defer if (native_app.gtk_theme_name) |name| c.g_free(@ptrCast(name));
    _ = c.g_signal_connect_data(application, "activate", @ptrCast(&onActivate), &native_app, null, 0);
    _ = c.g_signal_connect_data(application, "shutdown", @ptrCast(&onShutdown), &native_app, null, 0);
    // Another window's Quit, or anything else that sends SIGTERM, ends this window, and only this window, as its own Quit would.
    _ = c.g_unix_signal_add(c.SIGTERM, on_terminate_signal, &native_app);
    if (!z.ziggy_window_opened(native_app.data_directory, std.mem.len(native_app.data_directory))) {
        fatal("could not record the window in the app's data directory", .{});
    }
    defer {
        if (!z.ziggy_window_closed(native_app.data_directory, std.mem.len(native_app.data_directory))) {
            std.debug.print("ziggy native app: could not remove the window's record\n", .{});
        }
    }
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
    const pixbuf = pixbufFromPng(icon_png) orelse {
        fatal("could not read the window icon", .{});
    };
    defer c.g_object_unref(pixbuf);
    c.gtk_window_set_icon(window, pixbuf);
}

//
// Decodes a PNG into a pixbuf the caller releases with g_object_unref, or null when the loader made no pixbuf. A PNG that
// cannot be read ends the program, naming what failed.
//
fn pixbufFromPng(png: []const u8) ?*c.GdkPixbuf {
    const loader = c.gdk_pixbuf_loader_new_with_type("png", null) orelse {
        fatal("could not create the PNG loader", .{});
    };
    defer c.g_object_unref(loader);
    if (c.gdk_pixbuf_loader_write(loader, png.ptr, png.len, null) == 0) {
        fatal("could not read the PNG", .{});
    }
    if (c.gdk_pixbuf_loader_close(loader, null) == 0) {
        fatal("could not finish reading the PNG", .{});
    }
    const pixbuf = c.gdk_pixbuf_loader_get_pixbuf(loader) orelse {
        return null;
    };
    return @ptrCast(@alignCast(c.g_object_ref(pixbuf).?));
}

//
// Reports why the native app cannot go on and ends the program with a failure code.
//
fn fatal(comptime format: []const u8, arguments: anytype) noreturn {
    std.debug.print("ziggy native app: " ++ format ++ "\n", arguments);
    std.process.exit(1);
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
// Prints a splash event with its wall-clock time, so a recording can be annotated.
//
fn splashEvent(name: []const u8) void {
    std.debug.print("SPLASH-EVENT {s} {d}\n", .{ name, @divTrunc(c.g_get_real_time(), 1000) });
}

//
// Creates the window and the web view, creates the core and loads the frontend.
//
fn start(native_app: *NativeApp, application: *c.GtkApplication) !void {
    splashEvent("started");
    native_app.portal = c.g_dbus_proxy_new_for_bus_sync(c.G_BUS_TYPE_SESSION, c.G_DBUS_PROXY_FLAGS_NONE, null, "org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop", "org.freedesktop.portal.Settings", null, null);
    if (c.gtk_settings_get_default()) |settings| {
        var theme_name: [*c]u8 = null;
        c.g_object_get(settings, "gtk-theme-name", &theme_name, @as(?*anyopaque, null));
        if (theme_name != null) {
            native_app.gtk_theme_name = @ptrCast(theme_name);
        }
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
    // The window opens in the centre of the screen that has the focus, which GTK takes to be the one the mouse pointer is on.
    c.gtk_window_set_position(window, c.GTK_WIN_POS_CENTER);
    if (native_app.app_config.icon_png) |icon_png| {
        setWindowIcon(window, icon_png);
    }

    // The window shows the splash picture before the core is created, so the first frame the user sees is the art. The image
    // is the window's X background too, so X paints it before GTK or the compositor draws any child: no solid colour comes
    // before the image.
    const box_widget = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
    const overlay_widget = c.gtk_overlay_new();
    c.gtk_container_add(overlay_widget, box_widget);
    c.gtk_container_add(window_widget, overlay_widget);
    native_app.overlay = overlay_widget;
    addSplashPicture(native_app, overlay_widget, width, height);
    applySplashBackground(window_widget);
    if (splash.configured) {
        configureSplashWindow(window_widget, width, height);
        c.gtk_widget_show_all(window_widget);
        c.gtk_window_present(window);
        splashEvent("app-started");
    }

    var config = std.mem.zeroes(z.ziggy_config);
    // GLib hands the native app's address back to the main thread with the idle callback, unread.
    config.wake_data = native_app;
    config.wake = wake;
    config.has_os_version = true;
    config.has_quit = true;
    config.has_pick_paths = true;
    config.has_menu_action = true;
    config.has_screenshot = true;
    config.has_key_press = true;
    config.has_new_window = true;
    config.has_native_call = native_app.app_config.native_call != null;
    config.worker_threads = c.g_get_num_processors();
    config.max_concurrent_child_tasks = 10;
    config.app_url_prefix = app_url_prefix;
    config.data_dir = native_app.data_directory;
    if (native_app.remote_control) |address| {
        config.test_mode = true;
        config.remote_control = address.ptr;
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
    config.system_theme = @intFromEnum(readSystemTheme(native_app));
    native_app.core = z.ziggy_create(&config) orelse {
        return error.CoreCreateFailed;
    };

    var theme_arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer theme_arena_state.deinit();
    var theme_length: usize = 0;
    const theme_pointer = z.ziggy_theme(native_app.core, &theme_length) orelse {
        return error.ThemeFailed;
    };
    const theme_call = try native_message.parse(theme_arena_state.allocator(), theme_pointer[0..theme_length]);
    watchSystemTheme(native_app);

    // The web context is made after the core, so the theme it gives is applied to the web view as it is created.
    // The frontend's own scripts are classic scripts, but a frontend may also fetch its files, which needs the scheme to
    // be allowed to make cross-origin style requests and to count as a secure context like https does.
    const web_context = c.webkit_web_context_get_default();
    c.webkit_web_context_register_uri_scheme(web_context, app_scheme, onUriSchemeRequest, native_app, null);
    const security_manager = c.webkit_web_context_get_security_manager(web_context);
    c.webkit_security_manager_register_uri_scheme_as_secure(security_manager, app_scheme);
    c.webkit_security_manager_register_uri_scheme_as_cors_enabled(security_manager, app_scheme);

    const web_view_widget = c.webkit_web_view_new();
    const web_view: *c.WebKitWebView = @ptrCast(@alignCast(web_view_widget));
    native_app.web_view = web_view;
    splashEvent("app-web-view-created");
    c.webkit_settings_set_enable_developer_extras(c.webkit_web_view_get_settings(web_view), 1);
    // The popup blocker drops a window.open or a target="_blank" that no click of the user's ran. onCreate and onDecidePolicy open
    // each new window with the system's opener or drop it.
    c.webkit_settings_set_javascript_can_open_windows_automatically(c.webkit_web_view_get_settings(web_view), 1);
    _ = c.g_signal_connect_data(c.webkit_web_view_get_inspector(web_view), "closed", @ptrCast(&onInspectorClosed), native_app, null, 0);
    c.gtk_box_pack_start(box_widget, web_view_widget, 1, 1, 0);
    _ = c.g_signal_connect_data(web_view, "load-changed", @ptrCast(&onMainLoadChanged), native_app, null, 0);
    switch (theme_call) {
        .theme => |theme| applyTheme(native_app, theme),
        else => return error.ThemeFailed,
    }
    try buildMenu(native_app, box_widget);
    if (splash.configured) {
        // The app's web view stays out of the window until the frontend says it is ready.
        c.gtk_widget_hide(web_view_widget);
    }

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
    _ = c.g_signal_connect_data(web_view, "create", @ptrCast(&onCreate), native_app, null, 0);
    _ = c.g_signal_connect_data(window, "delete-event", @ptrCast(&onDeleteEvent), native_app, null, 0);
    _ = c.g_signal_connect_data(web_view, "drag-data-received", @ptrCast(&onDragDataReceived), native_app, null, 0);

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
}

//
// Adds the splash picture over the app's own web view when the app declares a splash. The picture is the only thing on
// screen until it has drawn its first frame; the splash web view is not made until then, so nothing the web view does can
// hold up the picture.
//
fn addSplashPicture(native_app: *NativeApp, overlay_widget: *c.GtkWidget, width: c_int, height: c_int) void {
    if (!splash.configured) {
        return;
    }
    const png = if (width < height) splash.portrait_png else splash.landscape_png;
    const pixbuf = pixbufFromPng(png) orelse {
        fatal("could not read the splash image", .{});
    };
    const picture = c.gtk_drawing_area_new();
    applySplashBackground(picture);
    c.gtk_widget_set_hexpand(picture, 1);
    c.gtk_widget_set_vexpand(picture, 1);
    c.gtk_widget_set_halign(picture, c.GTK_ALIGN_FILL);
    c.gtk_widget_set_valign(picture, c.GTK_ALIGN_FILL);
    native_app.splash_pixbuf = pixbuf;
    native_app.splash_picture = picture;
    _ = c.g_signal_connect_data(picture, "draw", @ptrCast(&onSplashPictureDraw), native_app, null, 0);
    c.gtk_overlay_add_overlay(overlay_widget, picture);
}

//
// Sets the splash image as the window's X background pixmap, scaled to cover it, so the first frame the window maps is the
// art. X paints the pixmap itself, before GTK or the compositor has drawn any child, so no solid colour comes first.
//
fn configureSplashWindow(window_widget: *c.GtkWidget, width: c_int, height: c_int) void {
    if (width <= 0 or height <= 0) {
        return;
    }
    const png = if (width < height) splash.portrait_png else splash.landscape_png;
    const pixbuf = pixbufFromPng(png) orelse {
        return;
    };
    defer c.g_object_unref(pixbuf);
    c.gtk_widget_realize(window_widget);
    const gdk_window = c.gtk_widget_get_window(window_widget) orelse {
        return;
    };
    const display = c.gdk_x11_get_default_xdisplay() orelse {
        return;
    };
    const visual = c.gdk_window_get_visual(gdk_window) orelse {
        return;
    };
    const xvisual = c.gdk_x11_visual_get_xvisual(visual) orelse {
        return;
    };
    const depth = c.gdk_visual_get_depth(visual);
    const xid = c.gdk_x11_window_get_xid(gdk_window);
    const pixmap = c.XCreatePixmap(display, xid, @intCast(width), @intCast(height), @intCast(depth));
    if (pixmap == 0) {
        return;
    }
    const surface = c.cairo_xlib_surface_create(display, pixmap, xvisual, width, height);
    const cairo = c.cairo_create(surface);
    const image_width = c.gdk_pixbuf_get_width(pixbuf);
    const image_height = c.gdk_pixbuf_get_height(pixbuf);
    if (image_width > 0 and image_height > 0) {
        const scale = @max(
            @as(f64, @floatFromInt(width)) / @as(f64, @floatFromInt(image_width)),
            @as(f64, @floatFromInt(height)) / @as(f64, @floatFromInt(image_height)),
        );
        c.cairo_scale(cairo, scale, scale);
        c.cairo_translate(cairo, (@as(f64, @floatFromInt(width)) / scale - @as(f64, @floatFromInt(image_width))) / 2.0, (@as(f64, @floatFromInt(height)) / scale - @as(f64, @floatFromInt(image_height))) / 2.0);
        c.gdk_cairo_set_source_pixbuf(cairo, pixbuf, 0.0, 0.0);
        c.cairo_paint(cairo);
    }
    c.cairo_destroy(cairo);
    c.cairo_surface_destroy(surface);
    _ = c.XSetWindowBackgroundPixmap(display, xid, pixmap);
    _ = c.XFreePixmap(display, pixmap);
}

//
// Draws the splash image into its drawing area, scaled to cover it and centred, as the CSS object-fit: cover does.
//
fn onSplashPictureDraw(widget: *c.GtkWidget, cairo: *c.Cairo, user_data: ?*anyopaque) callconv(.c) c.gboolean {
    const native_app: *NativeApp = @ptrCast(@alignCast(user_data.?));
    const pixbuf = native_app.splash_pixbuf orelse {
        return 0;
    };
    const width = c.gtk_widget_get_allocated_width(widget);
    const height = c.gtk_widget_get_allocated_height(widget);
    const image_width = c.gdk_pixbuf_get_width(pixbuf);
    const image_height = c.gdk_pixbuf_get_height(pixbuf);
    if (width <= 0 or height <= 0 or image_width <= 0 or image_height <= 0) {
        return 0;
    }
    const scale = @max(
        @as(f64, @floatFromInt(width)) / @as(f64, @floatFromInt(image_width)),
        @as(f64, @floatFromInt(height)) / @as(f64, @floatFromInt(image_height)),
    );
    const drawn_width = @as(f64, @floatFromInt(image_width)) * scale;
    const drawn_height = @as(f64, @floatFromInt(image_height)) * scale;
    c.cairo_translate(cairo, (@as(f64, @floatFromInt(width)) - drawn_width) / 2.0, (@as(f64, @floatFromInt(height)) - drawn_height) / 2.0);
    c.cairo_scale(cairo, scale, scale);
    c.gdk_cairo_set_source_pixbuf(cairo, pixbuf, 0.0, 0.0);
    c.cairo_paint(cairo);
    return 1;
}

//
// The app's own frontend has loaded. With no splash it is shown at once. With one it stays hidden behind the native picture
// until the frontend sends frontend-ready, which is the frontend saying its own splash overlay has painted over the real UI.
//
fn onMainLoadChanged(web_view: *c.WebKitWebView, load_event: c.WebKitLoadEvent, user_data: ?*anyopaque) callconv(.c) void {
    _ = web_view;
    if (load_event != c.WEBKIT_LOAD_FINISHED) {
        return;
    }
    const native_app: *NativeApp = @ptrCast(@alignCast(user_data.?));
    native_app.main_loaded = true;
    if (!splash.configured) {
        // With no splash to cover it, the window waits for the app's own page, so the blank web view is never shown.
        if (native_app.window) |window| {
            c.gtk_widget_show_all(@ptrCast(window));
            c.gtk_window_present(window);
        }
    }
}

//
// The frontend's frontend-ready message: the app's web view, with the frontend's own splash overlay painted in it, is shown,
// the native picture goes, and the frontend is told the app is showing so it can fade its overlay.
//
fn revealAppView(native_app: *NativeApp) void {
    if (!splash.configured) {
        return;
    }
    if (native_app.web_view) |web_view| {
        c.gtk_widget_show(@ptrCast(web_view));
        splashEvent("app-web-view-visible");
    }
    destroySplashPicture(native_app);
    deliverToWebView(native_app, "{\"kind\":\"app\",\"data\":{\"type\":\"frontend-visible\"}}");
}

//
// Destroys the picture and releases the pixbuf it draws.
//
fn destroySplashPicture(native_app: *NativeApp) void {
    if (native_app.splash_picture) |picture| {
        native_app.splash_picture = null;
        c.gtk_widget_destroy(picture);
    }
    if (native_app.splash_pixbuf) |pixbuf| {
        native_app.splash_pixbuf = null;
        c.g_object_unref(pixbuf);
    }
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
// Opens the address of a window the frontend asked to open in the system's browser, and never creates a new web view: WebKitGTK
// sends a window.open here instead of the decide-policy signal, and the core's origin check decides the address as it does every
// other navigation.
//
fn onCreate(web_view: *c.WebKitWebView, navigation_action: *c.WebKitNavigationAction, user_data: ?*anyopaque) callconv(.c) ?*c.GtkWidget {
    _ = web_view;
    const native_app: *NativeApp = @ptrCast(@alignCast(user_data.?));
    const request = c.webkit_navigation_action_get_request(navigation_action);
    const uri = std.mem.span(@as([*:0]const u8, @ptrCast(c.webkit_uri_request_get_uri(request))));
    const verdict = z.ziggy_check_url(native_app.core, uri.ptr, uri.len);
    if (verdict == z.ZIGGY_URL_OPEN_EXTERNALLY) {
        openExternally(uri);
    }
    return null;
}

//
// Opens an address the core decided belongs outside the app with the system's browser, and reports a failure on standard error.
//
fn openExternally(uri: [:0]const u8) void {
    var open_error: ?*c.GError = null;
    if (c.gtk_show_uri_on_window(null, uri.ptr, c.GDK_CURRENT_TIME, &open_error) == 0) {
        std.debug.print("ziggy native app: could not open {s} in the system browser\n", .{uri});
        if (open_error) |error_value| {
            c.g_error_free(error_value);
        }
    }
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
        openExternally(uri);
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
        .key_press => |key| press_key(native_app, reply, key),
        .new_window => |arguments| start_new_window(native_app, reply, arguments),
        .theme => |theme_call| applyTheme(native_app, theme_call),
        .frontend_ready => {
            splashEvent("frontend-ready-received");
            revealAppView(native_app);
        },
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
// Starts the app again as a process of its own with the arguments, which is another window of the app, and sends the core its
// process id. GLib reaps the process when it ends.
//
fn start_new_window(native_app: *NativeApp, reply: u64, arguments: []const []const u8) void {
    const allocator = std.heap.c_allocator;
    const pointers = allocator.alloc([*:0]const u8, arguments.len) catch @panic("out of memory starting a new window");
    defer allocator.free(pointers);
    var copied: usize = 0;
    defer {
        for (pointers[0..copied]) |pointer| {
            allocator.free(std.mem.span(pointer));
        }
    }
    for (arguments, pointers) |argument, *pointer| {
        const argument_z = allocator.dupeZ(u8, argument) catch @panic("out of memory starting a new window");
        pointer.* = argument_z.ptr;
        copied += 1;
    }
    var process_id: i64 = 0;
    if (!z.ziggy_start_instance(@ptrCast(pointers.ptr), pointers.len, &process_id)) {
        sendResult(native_app, reply, false, "StartFailed");
        return;
    }
    _ = c.g_child_watch_add(@intCast(process_id), on_child_exited, null);
    var text_buffer: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&text_buffer, "{d}", .{process_id}) catch unreachable;
    sendResult(native_app, reply, true, text);
}

//
// Called once GLib has reaped a window's process that this one started. The process's record is its own to remove.
//
fn on_child_exited(pid: c.GPid, wait_status: c_int, user_data: c.gpointer) callconv(.c) void {
    _ = pid;
    _ = wait_status;
    _ = user_data;
}

//
// Called when this process receives SIGTERM: another window's Quit, or anything else that sends SIGTERM, ends this window, and only
// this window, as its own Quit would. The core is then destroyed by onShutdown, which writes the log's footer.
//
fn on_terminate_signal(user_data: c.gpointer) callconv(.c) c.gboolean {
    const native_app: *NativeApp = @ptrCast(@alignCast(user_data.?));
    c.g_application_quit(@ptrCast(native_app.application));
    return 0;
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
// Quit ends every window of the app, whichever route asked for it: the File menu's Quit and Ctrl+Q, the app's own code's
// HandlerServices.quit, and the remote control quit command all reach this. Every other recorded window of the app is sent SIGTERM,
// which it handles as its own Quit.
//
fn quitApplication(native_app: *NativeApp) void {
    if (!z.ziggy_end_other_windows(native_app.data_directory, std.mem.len(native_app.data_directory))) {
        std.debug.print("ziggy native app: could not end the app's other windows\n", .{});
    }
    c.g_application_quit(@ptrCast(native_app.application));
}


//
// One menu item's action, or one shortcut-only action's, kept for as long as the menu item or the shortcut lives: it and its action are
// allocated with the C allocator and freed when GTK destroys the item or the shortcut's closure (see freeMenuItemContext).
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
//
// The deepest a menu entry may be: menus of the menu bar are at 0, and each submenu is one deeper. Ziggy's own menus go two deep, so
// eight leaves room for any menu a user can still find their way around.
//
const menu_depth_max = 8;

//
// Builds the menu bar from the app's menu entries, which the core holds, and puts it above the web view. An app with no menu gets no
// menu bar. Each item shows its shortcut in its label; the frontend runs the shortcut, so the window binds none.
//
fn buildMenu(native_app: *NativeApp, box_widget: *c.GtkWidget) !void {
    var count: usize = 0;
    const entries = z.ziggy_menu(native_app.core, &count);
    if (count == 0) {
        return;
    }
    const menu_bar = c.gtk_menu_bar_new();
    // The GTK menu each depth's entries go into: the menu bar at depth 0, and below it the menu or submenu opened last at the depth
    // above.
    var containers: [menu_depth_max + 1]*c.GtkWidget = undefined;
    containers[0] = menu_bar;
    for (entries[0..count]) |entry| {
        if (entry.depth > menu_depth_max) {
            std.debug.print("ziggy native app: the menu goes deeper than {d}\n", .{menu_depth_max});
            return error.MenuTooDeep;
        }
        const container = containers[entry.depth];
        if (entry.kind == z.ZIGGY_MENU_ENTRY_SEPARATOR) {
            c.gtk_menu_shell_append(container, c.gtk_separator_menu_item_new());
            continue;
        }
        if (entry.label == null) {
            return error.MenuEntryHasNoLabel;
        }
        const menu_item = if (entry.shortcut) |shortcut| shortcutLabel(entry.label.?, shortcut) else c.gtk_menu_item_new_with_label(entry.label.?);
        if (entry.kind == z.ZIGGY_MENU_ENTRY_MENU or entry.kind == z.ZIGGY_MENU_ENTRY_SUBMENU) {
            const submenu = c.gtk_menu_new();
            c.gtk_menu_item_set_submenu(menu_item, submenu);
            containers[entry.depth + 1] = submenu;
        }
        else {
            if (entry.action == null) {
                return error.MenuItemHasNoAction;
            }
            try attachMenuItemAction(native_app, menu_item, std.mem.span(entry.action));
        }
        c.gtk_menu_shell_append(container, menu_item);
    }
    c.gtk_box_pack_start(box_widget, menu_bar, 0, 0, 0);
    c.gtk_box_reorder_child(box_widget, menu_bar, 0);
    // The box was shown before the menu existed, so the menu bar is shown here.
    c.gtk_widget_show(menu_bar);
}

//
// A menu item with its shortcut shown after its label, which GTK copies, so the buffer is freed at once.
//
fn shortcutLabel(label: [*:0]const u8, shortcut: [*:0]const u8) *c.GtkWidget {
    var buffer: [512]u8 = undefined;
    const text = menu_keys.menuLabel(&buffer, std.mem.span(label), std.mem.span(shortcut)) catch @panic("the menu label and its shortcut are too long");
    return c.gtk_menu_item_new_with_label(text.ptr);
}

//
// Attaches an action to a menu item, so choosing the item, or pressing its shortcut, does the action (see performAction).
//
fn attachMenuItemAction(native_app: *NativeApp, menu_item: *c.GtkWidget, action_name: []const u8) !void {
    const action = try std.heap.c_allocator.dupeZ(u8, action_name);
    errdefer std.heap.c_allocator.free(action);
    const context = try std.heap.c_allocator.create(MenuItemContext);
    context.* = .{
        .native_app = native_app,
        .action = action,
    };
    _ = c.g_signal_connect_data(menu_item, "activate", @ptrCast(&onMenuItemActivate), context, @ptrCast(@constCast(&freeMenuItemContext)), 0);
}

//
// The event one step of a key press sends: the GDK event type, the keyval the event carries, the key on the keyboard that sends it,
// the modifier mask held and whether the key is a modifier key.
//
const PressKeyEvent = struct {
    // The GDK event type: GDK_KEY_PRESS or GDK_KEY_RELEASE.
    event_type: c_int,
    // The keyval the event carries, which for a key with Shift is the character Shift gives.
    keyval: c_uint,
    // The key on the keyboard that sends the keyval.
    key: c.GdkKeymapKey,
    // The modifier mask the event carries.
    state: c_uint,
    // Whether the key is one of the modifier keys the press holds down.
    is_modifier: bool,
};

//
// The key on the keyboard that types the keyval, as the layout gives it, or null when the layout has none. More than sixteen keys
// for one keyval is TooManyKeys, which the key press reports.
//
fn press_key_find_key(keymap: *c.GdkKeymap, keyval: c_uint) error{TooManyKeys}!?c.GdkKeymapKey {
    std.debug.assert(@intFromPtr(keymap) != 0);
    std.debug.assert(keyval != 0);
    var keys: ?[*]c.GdkKeymapKey = null;
    var count: c_int = 0;
    if (c.gdk_keymap_get_entries_for_keyval(keymap, keyval, &keys, &count) == 0) {
        return null;
    }
    const entries_pointer = keys orelse return null;
    defer c.g_free(@ptrCast(entries_pointer));
    const entry_count: usize = @intCast(count);
    if (entry_count > 16) {
        return error.TooManyKeys;
    }
    var entries: [16]menu_keys.KeyEntry = undefined;
    for (entries_pointer[0..entry_count], 0..) |entry, index| {
        entries[index] = .{
            .keycode = entry.keycode,
            .group = entry.group,
            .level = entry.level,
        };
    }
    const lowest = menu_keys.lowest_level_key(entries[0..entry_count]) orelse return null;
    std.debug.assert(lowest.level >= 0);
    return .{
        .keycode = lowest.keycode,
        .group = lowest.group,
        .level = lowest.level,
    };
}

//
// Sends one key event to GTK, as the keyboard sends it. The event is read back through GTK's getters before GTK is given it, so a
// wrong hand-written GdkEventKey layout stops the app on the first press rather than pressing the wrong key.
//
fn press_key_send_event(gdk_window: *c.GdkWindow, keyboard: *c.GdkDevice, event_options: PressKeyEvent) void {
    std.debug.assert(@intFromPtr(gdk_window) != 0);
    std.debug.assert(@intFromPtr(keyboard) != 0);
    const event = c.gdk_event_new(event_options.event_type);
    defer c.gdk_event_free(event);
    const key_event: *c.GdkEventKey = @ptrCast(@alignCast(event));
    key_event.window = @ptrCast(c.g_object_ref(gdk_window));
    key_event.send_event = 0;
    key_event.time = c.GDK_CURRENT_TIME;
    key_event.state = event_options.state;
    key_event.keyval = event_options.keyval;
    key_event.length = 0;
    key_event.string = c.g_strdup("");
    key_event.hardware_keycode = @intCast(event_options.key.keycode);
    key_event.group = @intCast(event_options.key.group);
    key_event.is_modifier = if (event_options.is_modifier) 1 else 0;
    var read_keyval: c_uint = 0;
    var read_keycode: u16 = 0;
    var read_state: c_uint = 0;
    if (c.gdk_event_get_event_type(event) != event_options.event_type) {
        std.debug.panic("GdkEventKey does not match GTK's layout: the type was written as {d} and GTK reads {d}", .{ event_options.event_type, c.gdk_event_get_event_type(event) });
    }
    if (c.gdk_event_get_window(event) != key_event.window) {
        std.debug.panic("GdkEventKey does not match GTK's layout: the window was written as {?} and GTK reads {?}", .{ key_event.window, c.gdk_event_get_window(event) });
    }
    if (c.gdk_event_get_keyval(event, &read_keyval) == 0 or read_keyval != event_options.keyval) {
        std.debug.panic("GdkEventKey does not match GTK's layout: the keyval was written as {d} and GTK reads {d}", .{ event_options.keyval, read_keyval });
    }
    if (c.gdk_event_get_keycode(event, &read_keycode) == 0 or read_keycode != key_event.hardware_keycode) {
        std.debug.panic("GdkEventKey does not match GTK's layout: the keycode was written as {d} and GTK reads {d}", .{ key_event.hardware_keycode, read_keycode });
    }
    if (c.gdk_event_get_state(event, &read_state) == 0 or read_state != event_options.state) {
        std.debug.panic("GdkEventKey does not match GTK's layout: the state was written as {d} and GTK reads {d}", .{ event_options.state, read_state });
    }
    c.gdk_event_set_device(event, keyboard);
    c.gtk_main_do_event(event);
}

//
// Sends the core the result of a key press that failed, with the reason built from the format and its arguments.
//
fn press_key_result(native_app: *NativeApp, reply: u64, comptime format: []const u8, arguments: anytype) void {
    var buffer: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, format, arguments) catch "the key press failed";
    sendResult(native_app, reply, false, text);
}

//
// Presses and releases a key as a user does, through GTK's own key handling, so a shortcut that is broken for a user fails. The key
// is written as a shortcut, such as CmdOrCtrl+Plus.
//
fn press_key(native_app: *NativeApp, reply: u64, key: []const u8) void {
    std.debug.assert(key.len != 0);
    var parsed: z.ziggy_accelerator = undefined;
    if (!z.ziggy_parse_accelerator(key.ptr, key.len, &parsed)) {
        return press_key_result(native_app, reply, "the native app cannot press {s}", .{key});
    }
    var name_buffer: [32]u8 = undefined;
    const key_name = menu_keys.gdkKeyName(&name_buffer, std.mem.sliceTo(&parsed.key, 0)) catch {
        return press_key_result(native_app, reply, "GTK has no key for {s}", .{key});
    };
    const keyval = c.gdk_keyval_from_name(key_name.ptr);
    if (keyval == 0) {
        return press_key_result(native_app, reply, "GTK has no key for {s}", .{key});
    }
    const window = native_app.window orelse {
        return press_key_result(native_app, reply, "the native app has no window", .{});
    };
    const gdk_window = c.gtk_widget_get_window(@ptrCast(window)) orelse {
        return press_key_result(native_app, reply, "the window is not shown", .{});
    };
    const display = c.gdk_display_get_default() orelse {
        return press_key_result(native_app, reply, "there is no display", .{});
    };
    const seat = c.gdk_display_get_default_seat(display);
    const keyboard = c.gdk_seat_get_keyboard(seat) orelse {
        return press_key_result(native_app, reply, "the display has no keyboard", .{});
    };
    const keymap = c.gdk_keymap_get_for_display(display);
    const key_entry = press_key_find_key(keymap, keyval) catch {
        return press_key_result(native_app, reply, "the keyboard has too many keys for {s}", .{key});
    } orelse {
        return press_key_result(native_app, reply, "the keyboard has no key for {s}", .{key});
    };
    var core_modifiers: u32 = parsed.modifiers;
    if (key_entry.level == 1) {
        core_modifiers |= z.ZIGGY_MOD_SHIFT;
    }
    const modifier_names = menu_keys.gdk_modifier_key_names(core_modifiers);
    const modifier_count: usize = modifier_names.count;
    var modifier_masks: [4]c_uint = undefined;
    var modifier_keys: [4]c.GdkKeymapKey = undefined;
    var index: usize = 0;
    while (index < modifier_count) : (index += 1) {
        const modifier_name = modifier_names.names[index];
        const modifier_keyval = c.gdk_keyval_from_name(modifier_name.ptr);
        modifier_keys[index] = press_key_find_key(keymap, modifier_keyval) catch {
            return press_key_result(native_app, reply, "the keyboard has too many keys for {s}", .{modifier_name});
        } orelse {
            return press_key_result(native_app, reply, "the keyboard has no key for {s}", .{modifier_name});
        };
        modifier_masks[index] = menu_keys.gdk_modifier_mask(modifier_name) catch {
            return press_key_result(native_app, reply, "the native app cannot press the modifier {s}", .{modifier_name});
        };
    }
    var full_state: c_uint = 0;
    for (modifier_masks[0..modifier_count]) |mask| {
        full_state |= mask;
    }
    var event_keyval: c_uint = 0;
    if (c.gdk_keymap_translate_keyboard_state(keymap, key_entry.keycode, full_state, key_entry.group, &event_keyval, null, null, null) == 0) {
        return press_key_result(native_app, reply, "the keyboard has no key for {s}", .{key});
    }
    if (c.gtk_window_is_active(window) == 0) {
        const focus_event = c.gdk_event_new(c.GDK_FOCUS_CHANGE);
        defer c.gdk_event_free(focus_event);
        const focus: *c.GdkEventFocus = @ptrCast(@alignCast(focus_event));
        focus.window = @ptrCast(c.g_object_ref(gdk_window));
        focus.send_event = 0;
        focus.in = 1;
        if (c.gdk_event_get_event_type(focus_event) != c.GDK_FOCUS_CHANGE) {
            std.debug.panic("GdkEventFocus does not match GTK's layout", .{});
        }
        if (c.gdk_event_get_window(focus_event) != focus.window) {
            std.debug.panic("GdkEventFocus does not match GTK's layout", .{});
        }
        c.gdk_event_set_device(focus_event, keyboard);
        c.gtk_main_do_event(focus_event);
    }
    var steps_buffer: [10]menu_keys.KeyPressStep = undefined;
    const steps = menu_keys.key_press_steps(&steps_buffer, modifier_masks[0..modifier_count]);
    for (steps) |step| {
        const event_type = if (step.is_release) c.GDK_KEY_RELEASE else c.GDK_KEY_PRESS;
        if (step.modifier_index) |modifier_index| {
            const modifier_position: usize = @intCast(modifier_index);
            press_key_send_event(gdk_window, keyboard, .{
                .event_type = event_type,
                .keyval = c.gdk_keyval_from_name(modifier_names.names[modifier_position].ptr),
                .key = modifier_keys[modifier_position],
                .state = step.state,
                .is_modifier = true,
            });
        }
        else {
            press_key_send_event(gdk_window, keyboard, .{
                .event_type = event_type,
                .keyval = event_keyval,
                .key = key_entry,
                .state = step.state,
                .is_modifier = false,
            });
        }
    }
    sendResult(native_app, reply, true, "");
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

//
// The system's theme, read from the desktop portal. A portal that does not answer prints why and gives light.
//
fn readSystemTheme(native_app: *NativeApp) system_theme.SystemTheme {
    const proxy = native_app.portal orelse {
        std.debug.print("ziggy native app: could not read the system theme from the desktop portal (the settings proxy could not be made), so it is light\n", .{});
        return .light;
    };
    var error_pointer: ?*c.GError = null;
    const parameters = c.g_variant_new("(ss)", @as([*:0]const u8, "org.freedesktop.appearance"), @as([*:0]const u8, "color-scheme"));
    const result = c.g_dbus_proxy_call_sync(proxy, "org.freedesktop.portal.Settings.ReadOne", parameters, c.G_DBUS_CALL_FLAGS_NONE, -1, null, &error_pointer) orelse {
        reportPortalError(error_pointer);
        return .light;
    };
    defer c.g_variant_unref(result);
    const child = c.g_variant_get_child_value(result, 0);
    defer c.g_variant_unref(child);
    const value = c.g_variant_get_variant(child);
    defer c.g_variant_unref(value);
    return system_theme.fromColorScheme(c.g_variant_get_uint32(value));
}

//
// Prints why the portal call failed and frees the error.
//
fn reportPortalError(error_pointer: ?*c.GError) void {
    const given = error_pointer orelse return;
    const fields: *const c.GErrorFields = @ptrCast(@alignCast(given));
    std.debug.print("ziggy native app: could not read the system theme from the desktop portal ({s}), so it is light\n", .{std.mem.span(fields.message)});
    c.g_error_free(given);
}

//
// Follows the desktop portal's colour scheme for the rest of the run.
//
fn watchSystemTheme(native_app: *NativeApp) void {
    const proxy = native_app.portal orelse return;
    _ = c.g_signal_connect_data(proxy, "g-signal", @ptrCast(&onPortalSettingChanged), native_app, null, 0);
}

//
// The portal's SettingChanged signal: posts the new system theme when the appearance's colour scheme changes.
//
fn onPortalSettingChanged(proxy: *c.GDBusProxy, sender_name: ?[*:0]const u8, signal_name: [*:0]const u8, parameters: *c.GVariant, user_data: ?*anyopaque) callconv(.c) void {
    _ = proxy;
    _ = sender_name;
    if (!std.mem.eql(u8, std.mem.span(signal_name), "SettingChanged")) {
        return;
    }
    const namespace = c.g_variant_get_child_value(parameters, 0);
    defer c.g_variant_unref(namespace);
    const key = c.g_variant_get_child_value(parameters, 1);
    defer c.g_variant_unref(key);
    if (!std.mem.eql(u8, std.mem.span(c.g_variant_get_string(namespace, null)), "org.freedesktop.appearance")) {
        return;
    }
    if (!std.mem.eql(u8, std.mem.span(c.g_variant_get_string(key, null)), "color-scheme")) {
        return;
    }
    const value = c.g_variant_get_child_value(parameters, 2);
    defer c.g_variant_unref(value);
    const inner = c.g_variant_get_variant(value);
    defer c.g_variant_unref(inner);
    const theme = system_theme.fromColorScheme(c.g_variant_get_uint32(inner));
    const native_app: *NativeApp = @ptrCast(@alignCast(user_data.?));
    const core = native_app.core orelse {
        return;
    };
    var buffer: [128]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{{\"kind\":\"system\",\"name\":\"system-theme\",\"data\":\"{s}\"}}", .{if (theme == .dark) "dark" else "light"}) catch return;
    z.ziggy_send_message(core, text.ptr, text.len);
}

//
// Applies a theme call: the web view's background and the GTK theme WebKitGTK reads for prefers-color-scheme.
//
fn applyTheme(native_app: *NativeApp, theme_call: native_message.ThemeCall) void {
    const web_view = native_app.web_view orelse return;
    const background = parseBackground(theme_call.background);
    c.webkit_web_view_set_background_color(web_view, &background);
    applyGtkTheme(native_app, theme_call);
}

//
// Applies a theme call to the GTK settings WebKitGTK reads for prefers-color-scheme.
//
fn applyGtkTheme(native_app: *NativeApp, theme_call: native_message.ThemeCall) void {
    const dark = std.mem.eql(u8, theme_call.theme, "dark");
    const settings = c.gtk_settings_get_default() orelse return;
    if (dark) {
        c.g_object_set(settings, "gtk-application-prefer-dark-theme", @as(c.gboolean, 1), @as(?*anyopaque, null));
        // WebKitGTK reads a theme name ending in -dark as well as the prefer-dark setting, and a light desktop's theme has no dark
        // name to put back, so a dark theme is named here.
        if (native_app.gtk_theme_name) |name| {
            const name_slice = std.mem.span(name);
            if (std.mem.endsWith(u8, name_slice, "-dark") or std.mem.endsWith(u8, name_slice, "-Dark")) {
                c.g_object_set(settings, "gtk-theme-name", name, @as(?*anyopaque, null));
            } else {
                c.g_object_set(settings, "gtk-theme-name", @as([*:0]const u8, "Adwaita-dark"), @as(?*anyopaque, null));
            }
        } else {
            c.g_object_set(settings, "gtk-theme-name", @as([*:0]const u8, "Adwaita-dark"), @as(?*anyopaque, null));
        }
        return;
    }
    c.g_object_set(settings, "gtk-application-prefer-dark-theme", @as(c.gboolean, 0), @as(?*anyopaque, null));
    if (native_app.gtk_theme_name) |name| {
        const name_slice = std.mem.span(name);
        if (web_view_theme.lightThemeName(name_slice)) |light_name| {
            var buffer: [256]u8 = undefined;
            if (light_name.len < buffer.len) {
                @memcpy(buffer[0..light_name.len], light_name);
                buffer[light_name.len] = 0;
                c.g_object_set(settings, "gtk-theme-name", @as([*:0]const u8, @ptrCast(&buffer)), @as(?*anyopaque, null));
            }
        }
    }
    if (c.g_getenv("GTK_THEME")) |gtk_theme_env| {
        if (web_view_theme.forcesDark(std.mem.span(gtk_theme_env))) {
            std.debug.print("ziggy native app: GTK_THEME={s} names a dark theme, so the page's prefers-color-scheme stays dark\n", .{std.mem.span(gtk_theme_env)});
        }
    }
}

//
// Gives the widget the splash background as its own, so no frame shows the GTK theme's colour before the splash paints.
//
fn applySplashBackground(widget: *c.GtkWidget) void {
    if (!splash.configured) {
        return;
    }
    const background = parseBackground(splash.background);
    c.gtk_widget_override_background_color(widget, c.GTK_STATE_FLAG_NORMAL, &background);
}

//
// The colour of a "#rrggbb" background.
//
fn parseBackground(text: []const u8) c.GdkRGBA {
    const value = std.fmt.parseInt(u24, text[1..], 16) catch 0;
    return .{
        .red = @as(f64, @floatFromInt((value >> 16) & 0xff)) / 255.0,
        .green = @as(f64, @floatFromInt((value >> 8) & 0xff)) / 255.0,
        .blue = @as(f64, @floatFromInt(value & 0xff)) / 255.0,
        .alpha = 1.0,
    };
}
