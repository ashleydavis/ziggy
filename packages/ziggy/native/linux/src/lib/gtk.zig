//
// The declarations of the GLib, GTK 3 and WebKitGTK 4.1 functions the native app calls, and the types and constants they use.
//
// These are declarations of the real libraries' functions, which the build links. They are written out here because
// Zig's C header translator cannot read GLib's headers: they use compiler pragma macros it does not understand. Only what
// the native app uses is declared, and each is checked against the library's own header documentation.
//

pub const gboolean = c_int;
pub const gpointer = ?*anyopaque;

pub const GApplication = opaque {};
pub const GtkApplication = opaque {};
pub const GtkWidget = opaque {};
pub const GtkWindow = opaque {};
pub const GError = opaque {};
pub const GdkPixbuf = opaque {};
pub const GdkPixbufLoader = opaque {};
pub const GtkSelectionData = opaque {};
pub const GtkOverlay = opaque {};
pub const GtkDrawingArea = opaque {};
pub const Cairo = opaque {};
pub const GdkWindow = opaque {};
pub const GdkVisual = opaque {};
pub const Display = opaque {};
pub const Visual = opaque {};
pub const GdkDragContext = opaque {};
pub const WebKitWebView = opaque {};
pub const WebKitUserContentManager = opaque {};
pub const WebKitUserScript = opaque {};
pub const WebKitPolicyDecision = opaque {};
pub const WebKitNavigationPolicyDecision = opaque {};
pub const WebKitNavigationAction = opaque {};
pub const WebKitURIRequest = opaque {};
pub const JSCValue = opaque {};
pub const WebKitJavascriptResult = opaque {};
pub const GDBusProxy = opaque {};
pub const GVariant = opaque {};
pub const GtkSettings = opaque {};

// GBusType: G_BUS_TYPE_SESSION is the user's session bus.
pub const GBusType = c_int;
pub const G_BUS_TYPE_SESSION: GBusType = 2;

// GDBusProxyFlags: G_DBUS_PROXY_FLAGS_NONE.
pub const G_DBUS_PROXY_FLAGS_NONE: c_uint = 0;

// GDBusCallFlags: G_DBUS_CALL_FLAGS_NONE.
pub const G_DBUS_CALL_FLAGS_NONE: c_uint = 0;

// GdkRGBA: a colour as four doubles.
pub const GdkRGBA = extern struct {
    red: f64,
    green: f64,
    blue: f64,
    alpha: f64,
};

// A GCallback: the signal handler's real type is cast to this when connecting.
// A WebKitPolicyDecisionType.
pub const WebKitPolicyDecisionType = c_uint;

// A GCallback: the signal handler's real type is cast to this when connecting.
pub const GCallback = ?*const fn () callconv(.c) void;
pub const GSourceFunc = *const fn (user_data: gpointer) callconv(.c) gboolean;

// GApplicationFlags: G_APPLICATION_NON_UNIQUE lets several copies run at once.
pub const G_APPLICATION_NON_UNIQUE: c_uint = 1 << 5;

// WebKitUserContentInjectedFrames: WEBKIT_USER_CONTENT_INJECT_TOP_FRAME.
pub const WEBKIT_USER_CONTENT_INJECT_TOP_FRAME: c_uint = 1;

// WebKitUserScriptInjectionTime: WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START.
pub const WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START: c_uint = 0;

// WebKitPolicyDecisionType.
pub const WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION: c_uint = 0;
pub const WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION: c_uint = 1;

// WebKitLoadEvent: WEBKIT_LOAD_FINISHED is the event after the page and its resources have loaded.
pub const WebKitLoadEvent = c_uint;
pub const WEBKIT_LOAD_FINISHED: WebKitLoadEvent = 3;

// GtkAlign: GTK_ALIGN_FILL makes a widget take the whole space it is given.
pub const GTK_ALIGN_FILL: c_int = 0;

// GtkStateFlags: GTK_STATE_FLAG_NORMAL is a widget's normal state.
pub const GTK_STATE_FLAG_NORMAL: c_uint = 0;

// GDK_CURRENT_TIME.
pub const GDK_CURRENT_TIME: u32 = 0;

// Opaque types the key press uses, declared only as pointers. GdkWindow, gtk_widget_get_window and g_object_ref are declared
// once with the other types and functions: a second copy here failed CI's app-build-linux with "duplicate struct member name".
pub const GdkDisplay = opaque {};
pub const GdkSeat = opaque {};
pub const GdkDevice = opaque {};
pub const GdkKeymap = opaque {};
pub const GdkEvent = opaque {};

// struct _GdkEventKey from gdk/gdkevents.h. C declares is_modifier as a one-bit field, which on the little-endian targets Ziggy
// builds sits in the byte after group.
pub const GdkEventKey = extern struct {
    type: c_int,
    window: ?*GdkWindow,
    send_event: i8,
    time: u32,
    state: c_uint,
    keyval: c_uint,
    length: c_int,
    string: ?[*:0]u8,
    hardware_keycode: u16,
    group: u8,
    is_modifier: u8,
};

comptime {
    // The layout read from gdk/gdkevents.h on GTK's gtk-3-24 branch. A mismatch stops the build rather than a key press.
    if (@offsetOf(GdkEventKey, "string") != 40) {
        @compileError("GdkEventKey.string is not at the offset gdk/gdkevents.h gives it");
    }
    if (@offsetOf(GdkEventKey, "hardware_keycode") != 48) {
        @compileError("GdkEventKey.hardware_keycode is not at the offset gdk/gdkevents.h gives it");
    }
    if (@offsetOf(GdkEventKey, "is_modifier") != 51) {
        @compileError("GdkEventKey.is_modifier is not at the offset gdk/gdkevents.h gives it");
    }
    if (@sizeOf(GdkEventKey) != 56) {
        @compileError("GdkEventKey is not the size gdk/gdkevents.h gives it");
    }
}

// struct _GdkEventFocus from gdk/gdkevents.h.
pub const GdkEventFocus = extern struct {
    type: c_int,
    window: ?*GdkWindow,
    send_event: i8,
    in: i16,
};

// GdkEventType: a key press, a key release and the window gaining or losing the keyboard.
pub const GDK_KEY_PRESS: c_int = 8;
pub const GDK_KEY_RELEASE: c_int = 9;
pub const GDK_FOCUS_CHANGE: c_int = 12;

pub extern fn gdk_event_new(event_type: c_int) *GdkEvent;
pub extern fn gdk_event_free(event: *GdkEvent) void;
pub extern fn gdk_event_set_device(event: *GdkEvent, device: *GdkDevice) void;

// The getters gdk/gdkevents.h gives the fields of a key event, used to read an event back before GTK is given it.
pub extern fn gdk_event_get_event_type(event: *const GdkEvent) c_int;
pub extern fn gdk_event_get_window(event: *const GdkEvent) ?*GdkWindow;
pub extern fn gdk_event_get_keyval(event: *const GdkEvent, keyval: *c_uint) gboolean;
pub extern fn gdk_event_get_keycode(event: *const GdkEvent, keycode: *u16) gboolean;
pub extern fn gdk_event_get_state(event: *const GdkEvent, state: *c_uint) gboolean;

// GdkKeymapKey from gdk/gdkkeys.h: one key of the layout that types a keyval.
pub const GdkKeymapKey = extern struct {
    keycode: c_uint,
    group: c_int,
    level: c_int,
};

pub extern fn gdk_keymap_get_for_display(display: *GdkDisplay) *GdkKeymap;
pub extern fn gdk_keymap_get_entries_for_keyval(keymap: *GdkKeymap, keyval: c_uint, keys: *?[*]GdkKeymapKey, n_keys: *c_int) gboolean;
pub extern fn gdk_keymap_translate_keyboard_state(keymap: *GdkKeymap, hardware_keycode: c_uint, state: c_uint, group: c_int, keyval: ?*c_uint, effective_group: ?*c_int, level: ?*c_int, consumed_modifiers: ?*c_uint) gboolean;

pub extern fn gdk_display_get_default() ?*GdkDisplay;
pub extern fn gdk_display_get_default_seat(display: *GdkDisplay) *GdkSeat;
pub extern fn gdk_seat_get_keyboard(seat: *GdkSeat) ?*GdkDevice;

pub extern fn gtk_main_do_event(event: *GdkEvent) void;
pub extern fn gtk_window_is_active(window: *GtkWindow) gboolean;

pub extern fn g_strdup(text: [*:0]const u8) [*:0]u8;

pub extern fn g_object_unref(object: gpointer) void;
pub extern fn g_object_ref(object: gpointer) gpointer;
pub extern fn g_signal_connect_data(instance: gpointer, detailed_signal: [*:0]const u8, handler: GCallback, data: gpointer, destroy_data: gpointer, connect_flags: c_uint) c_ulong;
pub extern fn g_application_run(application: *GApplication, argc: c_int, argv: ?[*]?[*:0]u8) c_int;
pub extern fn g_application_quit(application: *GApplication) void;
pub extern fn g_idle_add(function: GSourceFunc, data: gpointer) c_uint;
pub extern fn g_get_real_time() i64;
pub extern fn g_timeout_add(interval: c_uint, function: GSourceFunc, data: gpointer) c_uint;
pub extern fn g_getenv(variable: [*:0]const u8) ?[*:0]const u8;
pub extern fn g_file_read_link(filename: [*:0]const u8, err: ?*?*GError) ?[*:0]u8;
pub extern fn g_path_get_dirname(file_name: [*:0]const u8) [*:0]u8;
pub extern fn g_build_filename(first_element: [*:0]const u8, ...) [*:0]u8;
pub extern fn g_filename_to_uri(filename: [*:0]const u8, hostname: ?[*:0]const u8, err: ?*?*GError) ?[*:0]u8;
pub extern fn g_free(memory: gpointer) void;
pub extern fn g_strfreev(strings: [*c][*c]u8) void;
pub extern fn g_filename_from_uri(uri: [*:0]const u8, hostname: ?*[*c]u8, err: ?*?*GError) [*c]u8;
pub extern fn gtk_selection_data_get_uris(selection_data: *GtkSelectionData) [*c][*c]u8;
pub extern fn g_get_user_data_dir() [*:0]const u8;
pub extern fn g_mkdir_with_parents(pathname: [*:0]const u8, mode: c_int) c_int;
pub extern fn g_get_num_processors() c_uint;
pub const GDir = opaque {};
pub extern fn g_dir_open(path: [*:0]const u8, flags: c_uint, err: ?*?*GError) ?*GDir;
pub extern fn g_dir_read_name(dir: *GDir) ?[*:0]const u8;
pub extern fn g_dir_close(dir: *GDir) void;
pub extern fn g_file_get_contents(filename: [*:0]const u8, contents: *[*c]u8, length: ?*usize, err: ?*?*GError) gboolean;

pub extern fn gtk_application_new(application_id: [*:0]const u8, flags: c_uint) ?*GtkApplication;
pub extern fn gtk_application_inhibit(application: *GtkApplication, window: ?*GtkWindow, flags: c_uint, reason: [*:0]const u8) c_uint;
pub extern fn gtk_application_uninhibit(application: *GtkApplication, cookie: c_uint) void;

// GtkApplicationInhibitFlags: GTK_APPLICATION_INHIBIT_SUSPEND.
pub const GTK_APPLICATION_INHIBIT_SUSPEND: c_uint = 4;
pub extern fn gtk_application_window_new(application: *GtkApplication) *GtkWidget;
pub extern fn gtk_window_set_title(window: *GtkWindow, title: [*:0]const u8) void;
pub extern fn gtk_window_set_icon(window: *GtkWindow, icon: ?*GdkPixbuf) void;
pub extern fn gdk_pixbuf_loader_new_with_type(image_type: [*:0]const u8, err: ?*?*GError) ?*GdkPixbufLoader;
pub extern fn gdk_pixbuf_loader_write(loader: *GdkPixbufLoader, buffer: [*]const u8, count: usize, err: ?*?*GError) gboolean;
pub extern fn gdk_pixbuf_loader_close(loader: *GdkPixbufLoader, err: ?*?*GError) gboolean;
pub extern fn gdk_pixbuf_loader_get_pixbuf(loader: *GdkPixbufLoader) ?*GdkPixbuf;
pub extern fn gtk_window_set_default_size(window: *GtkWindow, width: c_int, height: c_int) void;

// GtkWindowPosition: GTK_WIN_POS_CENTER centres the window on the screen containing the mouse pointer.
pub const GTK_WIN_POS_CENTER: c_int = 1;

// Sets where the window is placed when it is shown.
pub extern fn gtk_window_set_position(window: *GtkWindow, position: c_int) void;
pub extern fn gtk_container_add(container: *GtkWidget, widget: *GtkWidget) void;
pub extern fn gtk_widget_show_all(widget: *GtkWidget) void;
pub extern fn gtk_window_present(window: *GtkWindow) void;
pub extern fn gtk_window_close(window: *GtkWindow) void;
pub extern fn gtk_show_uri_on_window(parent: ?*GtkWindow, uri: [*:0]const u8, timestamp: u32, err: ?*?*GError) gboolean;

pub extern fn webkit_web_view_new() *GtkWidget;
pub extern fn webkit_web_view_get_user_content_manager(web_view: *WebKitWebView) *WebKitUserContentManager;
pub extern fn webkit_web_view_load_uri(web_view: *WebKitWebView, uri: [*:0]const u8) void;
pub extern fn webkit_web_view_evaluate_javascript(web_view: *WebKitWebView, script: [*]const u8, length: isize, world_name: ?[*:0]const u8, source_uri: ?[*:0]const u8, cancellable: gpointer, callback: gpointer, user_data: gpointer) void;
pub extern fn webkit_user_content_manager_register_script_message_handler(manager: *WebKitUserContentManager, name: [*:0]const u8) gboolean;
pub extern fn webkit_javascript_result_get_js_value(js_result: *WebKitJavascriptResult) *JSCValue;
pub extern fn webkit_user_content_manager_add_script(manager: *WebKitUserContentManager, script: *WebKitUserScript) void;
pub extern fn webkit_user_script_new(source: [*:0]const u8, injected_frames: c_uint, injection_time: c_uint, allow_list: ?[*]const ?[*:0]const u8, block_list: ?[*]const ?[*:0]const u8) *WebKitUserScript;
pub extern fn webkit_user_script_unref(script: *WebKitUserScript) void;
pub extern fn webkit_navigation_policy_decision_get_navigation_action(decision: *WebKitNavigationPolicyDecision) *WebKitNavigationAction;
pub extern fn webkit_navigation_action_get_request(navigation: *WebKitNavigationAction) *WebKitURIRequest;
pub extern fn webkit_uri_request_get_uri(request: *WebKitURIRequest) [*:0]const u8;
pub extern fn webkit_policy_decision_use(decision: *WebKitPolicyDecision) void;
pub extern fn webkit_policy_decision_ignore(decision: *WebKitPolicyDecision) void;
pub extern fn jsc_value_to_string(value: *JSCValue) ?[*:0]u8;

pub extern fn system(command: [*:0]const u8) c_int;
pub extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

// GPid: a process id, a C int.
pub const GPid = c_int;

// A GChildWatchFunc: called once GLib has reaped a child process.
pub const GChildWatchFunc = *const fn (pid: GPid, wait_status: c_int, user_data: gpointer) callconv(.c) void;

// Watches a child process, calling the function once GLib has reaped it (glib/gmain.h). GLib here is 2.80, whose child watch uses a
// pidfd and installs no SIGCHLD handler.
pub extern fn g_child_watch_add(pid: GPid, function: GChildWatchFunc, data: gpointer) c_uint;

// Calls the function when the process receives the signal (glib-unix.h). The handler is reset to the default by execve, so the
// windows and tools this process starts end on SIGTERM as usual.
pub extern fn g_unix_signal_add(signum: c_int, function: GSourceFunc, data: gpointer) c_uint;

// The SIGTERM signal's number.
pub const SIGTERM: c_int = 15;


pub const GtkAccelGroup = opaque {};
pub const GClosure = opaque {};

// The handler of a shortcut connected with gtk_accel_group_connect, as g_cclosure_new calls it: the group, the window it is added to,
// the key, its modifiers and the closure's data.
pub const GtkAccelGroupActivate = *const fn (accel_group: *GtkAccelGroup, acceleratable: gpointer, keyval: c_uint, modifier: c_uint, user_data: gpointer) callconv(.c) gboolean;
// A GClosureNotify: frees a closure's data when the closure is finalized.
pub const GClosureNotify = *const fn (data: gpointer, closure: ?*GClosure) callconv(.c) void;
pub const WebKitWebInspector = opaque {};
pub const WebKitSettings = opaque {};

// GtkOrientation: GTK_ORIENTATION_VERTICAL.
pub const GTK_ORIENTATION_VERTICAL: c_int = 1;

// GtkAccelFlags: GTK_ACCEL_VISIBLE shows the shortcut beside the menu item.
pub const GTK_ACCEL_VISIBLE: c_uint = 1;

pub extern fn gtk_box_new(orientation: c_int, spacing: c_int) *GtkWidget;
pub extern fn gtk_box_pack_start(box: *GtkWidget, child: *GtkWidget, expand: gboolean, fill: gboolean, padding: c_uint) void;
pub extern fn gtk_menu_bar_new() *GtkWidget;
pub extern fn gtk_menu_new() *GtkWidget;
pub extern fn gtk_menu_item_new_with_label(label: [*:0]const u8) *GtkWidget;
pub extern fn gtk_menu_item_set_submenu(menu_item: *GtkWidget, submenu: *GtkWidget) void;
pub extern fn gtk_menu_shell_append(menu_shell: *GtkWidget, child: *GtkWidget) void;
pub extern fn gtk_separator_menu_item_new() *GtkWidget;
pub extern fn gtk_accel_group_new() *GtkAccelGroup;
pub extern fn gtk_window_add_accel_group(window: *GtkWindow, accel_group: *GtkAccelGroup) void;
pub extern fn gtk_accel_group_connect(accel_group: *GtkAccelGroup, accel_key: c_uint, accel_mods: c_uint, accel_flags: c_uint, closure: *GClosure) void;
pub extern fn g_cclosure_new(callback_func: GCallback, user_data: gpointer, destroy_data: GClosureNotify) *GClosure;
pub extern fn gtk_widget_add_accelerator(widget: *GtkWidget, accel_signal: [*:0]const u8, accel_group: *GtkAccelGroup, accel_key: c_uint, accel_mods: c_uint, accel_flags: c_uint) void;
pub extern fn gtk_window_fullscreen(window: *GtkWindow) void;
pub extern fn gtk_window_unfullscreen(window: *GtkWindow) void;
pub extern fn gdk_keyval_from_name(keyval_name: [*:0]const u8) c_uint;
pub extern fn webkit_web_view_reload(web_view: *WebKitWebView) void;
pub extern fn webkit_web_view_get_zoom_level(web_view: *WebKitWebView) f64;
pub extern fn webkit_web_view_set_zoom_level(web_view: *WebKitWebView, zoom_level: f64) void;
pub extern fn webkit_web_view_execute_editing_command(web_view: *WebKitWebView, command: [*:0]const u8) void;
pub extern fn webkit_web_view_get_settings(web_view: *WebKitWebView) *WebKitSettings;
pub extern fn webkit_web_view_get_inspector(web_view: *WebKitWebView) *WebKitWebInspector;
pub extern fn webkit_settings_set_enable_developer_extras(settings: *WebKitSettings, enabled: gboolean) void;
pub extern fn webkit_settings_set_javascript_can_open_windows_automatically(settings: *WebKitSettings, enabled: gboolean) void;
pub extern fn webkit_web_inspector_show(inspector: *WebKitWebInspector) void;
pub extern fn webkit_web_inspector_close(inspector: *WebKitWebInspector) void;
pub extern fn gtk_box_reorder_child(box: *GtkWidget, child: *GtkWidget, position: c_int) void;

pub const GtkFileChooserNative = opaque {};

// A GSList: a singly linked list node, as GTK returns the file names of a dialog.
pub const GSList = extern struct {
    data: gpointer,
    next: ?*GSList,
};

// GtkFileChooserAction.
pub const GTK_FILE_CHOOSER_ACTION_OPEN: c_int = 0;
pub const GTK_FILE_CHOOSER_ACTION_SAVE: c_int = 1;
pub const GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER: c_int = 2;

// GtkResponseType: GTK_RESPONSE_ACCEPT, what a dialog returns when the user chose something.
pub const GTK_RESPONSE_ACCEPT: c_int = -3;

pub extern fn gtk_file_chooser_native_new(title: [*:0]const u8, parent: ?*GtkWindow, action: c_int, accept_label: ?[*:0]const u8, cancel_label: ?[*:0]const u8) *GtkFileChooserNative;
pub extern fn gtk_native_dialog_show(dialog: *GtkFileChooserNative) void;
pub extern fn gtk_native_dialog_destroy(dialog: *GtkFileChooserNative) void;
pub extern fn gtk_file_chooser_set_select_multiple(chooser: *GtkFileChooserNative, select_multiple: gboolean) void;
pub extern fn gtk_file_chooser_set_current_name(chooser: *GtkFileChooserNative, name: [*:0]const u8) void;
pub extern fn gtk_file_chooser_set_do_overwrite_confirmation(chooser: *GtkFileChooserNative, do_overwrite_confirmation: gboolean) void;
pub extern fn gtk_file_chooser_get_filenames(chooser: *GtkFileChooserNative) ?*GSList;
pub extern fn g_slist_free_full(list: ?*GSList, free_func: *const fn (data: gpointer) callconv(.c) void) void;

pub const WebKitWebContext = opaque {};
pub const WebKitSecurityManager = opaque {};
pub const WebKitURISchemeRequest = opaque {};
pub const GInputStream = opaque {};

// A WebKitURISchemeRequestCallback: called for every request to a URL of a scheme the app registered.
pub const WebKitURISchemeRequestCallback = *const fn (request: *WebKitURISchemeRequest, user_data: gpointer) callconv(.c) void;

// G_IO_ERROR_NOT_FOUND.
pub const G_IO_ERROR_NOT_FOUND: c_int = 1;

pub extern fn webkit_web_context_get_default() *WebKitWebContext;
pub extern fn webkit_web_context_register_uri_scheme(context: *WebKitWebContext, scheme: [*:0]const u8, callback: WebKitURISchemeRequestCallback, user_data: gpointer, user_data_destroy_func: gpointer) void;
pub extern fn webkit_web_context_get_security_manager(context: *WebKitWebContext) *WebKitSecurityManager;
pub extern fn webkit_security_manager_register_uri_scheme_as_secure(security_manager: *WebKitSecurityManager, scheme: [*:0]const u8) void;
pub extern fn webkit_security_manager_register_uri_scheme_as_cors_enabled(security_manager: *WebKitSecurityManager, scheme: [*:0]const u8) void;
pub extern fn webkit_uri_scheme_request_get_path(request: *WebKitURISchemeRequest) [*:0]const u8;
pub extern fn webkit_uri_scheme_request_finish(request: *WebKitURISchemeRequest, stream: *GInputStream, stream_length: i64, content_type: ?[*:0]const u8) void;
pub extern fn webkit_uri_scheme_request_finish_error(request: *WebKitURISchemeRequest, err: *GError) void;
pub extern fn g_memory_input_stream_new_from_data(data: ?*const anyopaque, len: isize, destroy: gpointer) *GInputStream;
pub extern fn g_io_error_quark() u32;
pub extern fn g_error_new_literal(domain: u32, code: c_int, message: [*:0]const u8) *GError;
pub extern fn g_error_free(err: *GError) void;

pub const GAsyncResult = opaque {};
pub const CairoSurface = opaque {};

// A GAsyncReadyCallback: called on the thread that started the operation when it finishes.
pub const GAsyncReadyCallback = *const fn (source_object: gpointer, result: *GAsyncResult, user_data: gpointer) callconv(.c) void;

// What a GError holds, in the order glib declares it: GError is declared as an opaque type above, so this is how its message is read.
pub const GErrorFields = extern struct {
    // The error domain.
    domain: u32,
    // The error code.
    code: c_int,
    // The text of the error, NUL terminated.
    message: [*:0]const u8,
};

// WebKitSnapshotRegion: WEBKIT_SNAPSHOT_REGION_VISIBLE is the part of the frontend the window shows.
pub const WEBKIT_SNAPSHOT_REGION_VISIBLE: c_uint = 0;

// WebKitSnapshotOptions: WEBKIT_SNAPSHOT_OPTIONS_NONE.
pub const WEBKIT_SNAPSHOT_OPTIONS_NONE: c_uint = 0;

// cairo_status_t: CAIRO_STATUS_SUCCESS.
pub const CAIRO_STATUS_SUCCESS: c_int = 0;

pub extern fn webkit_web_view_get_snapshot(web_view: *WebKitWebView, region: c_uint, options: c_uint, cancellable: gpointer, callback: GAsyncReadyCallback, user_data: gpointer) void;
pub extern fn webkit_web_view_get_snapshot_finish(web_view: *WebKitWebView, result: *GAsyncResult, err: ?*?*GError) ?*CairoSurface;
pub extern fn cairo_surface_write_to_png(surface: *CairoSurface, filename: [*:0]const u8) c_int;
pub extern fn cairo_surface_destroy(surface: *CairoSurface) void;
pub extern fn cairo_status_to_string(status: c_int) [*:0]const u8;

pub extern fn g_dbus_proxy_new_for_bus_sync(bus_type: GBusType, flags: c_uint, info: ?*anyopaque, name: [*:0]const u8, object_path: [*:0]const u8, interface_name: [*:0]const u8, cancellable: ?*anyopaque, err: ?*?*GError) ?*GDBusProxy;
pub extern fn g_dbus_proxy_call_sync(proxy: *GDBusProxy, method_name: [*:0]const u8, parameters: ?*GVariant, flags: c_uint, timeout_msec: c_int, cancellable: ?*anyopaque, err: ?*?*GError) ?*GVariant;
pub extern fn g_variant_new(format_string: [*:0]const u8, ...) ?*GVariant;
pub extern fn g_variant_get_child_value(value: *GVariant, index: usize) *GVariant;
pub extern fn g_variant_get_variant(value: *GVariant) *GVariant;
pub extern fn g_variant_get_uint32(value: *GVariant) u32;
pub extern fn g_variant_get_string(value: *GVariant, length: ?*usize) [*:0]const u8;
pub extern fn g_variant_unref(value: *GVariant) void;
pub extern fn gtk_settings_get_default() ?*GtkSettings;
pub extern fn g_object_set(object: ?*anyopaque, first_property_name: [*:0]const u8, ...) void;
pub extern fn g_object_get(object: ?*anyopaque, first_property_name: [*:0]const u8, ...) void;
pub extern fn webkit_web_view_set_background_color(web_view: *WebKitWebView, rgba: *const GdkRGBA) void;

pub extern fn gtk_overlay_new() *GtkWidget;
pub extern fn gtk_overlay_add_overlay(overlay: *GtkWidget, widget: *GtkWidget) void;
pub extern fn gtk_widget_set_hexpand(widget: *GtkWidget, expand: gboolean) void;
pub extern fn gtk_widget_set_vexpand(widget: *GtkWidget, expand: gboolean) void;
pub extern fn gtk_widget_set_halign(widget: *GtkWidget, alignment: c_int) void;
pub extern fn gtk_widget_set_valign(widget: *GtkWidget, alignment: c_int) void;
pub extern fn gtk_widget_set_no_show_all(widget: *GtkWidget, no_show_all: gboolean) void;
pub extern fn gtk_widget_show(widget: *GtkWidget) void;
pub extern fn gtk_widget_hide(widget: *GtkWidget) void;
pub extern fn gtk_widget_destroy(widget: *GtkWidget) void;
pub extern fn gtk_widget_override_background_color(widget: *GtkWidget, state: c_uint, color: *const GdkRGBA) void;

// The part of cairo the splash picture draws with, and the drawing area it draws into. GTK 3 has no GtkPicture, so the
// image is scaled to cover the window here.
pub extern fn gtk_drawing_area_new() *GtkWidget;
pub extern fn gtk_widget_get_allocated_width(widget: *GtkWidget) c_int;
pub extern fn gtk_widget_get_allocated_height(widget: *GtkWidget) c_int;
pub extern fn gdk_pixbuf_get_width(pixbuf: *GdkPixbuf) c_int;
pub extern fn gdk_pixbuf_get_height(pixbuf: *GdkPixbuf) c_int;
pub extern fn gdk_cairo_set_source_pixbuf(cr: *Cairo, pixbuf: *GdkPixbuf, pixbuf_x: f64, pixbuf_y: f64) void;
pub extern fn cairo_paint(cr: *Cairo) void;
pub extern fn cairo_scale(cr: *Cairo, sx: f64, sy: f64) void;
pub extern fn cairo_translate(cr: *Cairo, dx: f64, dy: f64) void;
pub extern fn cairo_create(surface: *CairoSurface) *Cairo;
pub extern fn cairo_destroy(cr: *Cairo) void;
pub extern fn cairo_xlib_surface_create(display: *Display, drawable: c_ulong, visual: *Visual, width: c_int, height: c_int) *CairoSurface;
pub extern fn gtk_widget_realize(widget: *GtkWidget) void;
pub extern fn gtk_widget_get_window(widget: *GtkWidget) ?*GdkWindow;
pub extern fn gdk_x11_get_default_xdisplay() ?*Display;
pub extern fn gdk_x11_window_get_xid(window: *GdkWindow) c_ulong;
pub extern fn gdk_window_get_visual(window: *GdkWindow) ?*GdkVisual;
pub extern fn gdk_x11_visual_get_xvisual(visual: *GdkVisual) ?*Visual;
pub extern fn gdk_visual_get_depth(visual: *GdkVisual) c_int;
pub extern fn XCreatePixmap(display: *Display, drawable: c_ulong, width: c_uint, height: c_uint, depth: c_uint) c_ulong;
pub extern fn XSetWindowBackgroundPixmap(display: *Display, window: c_ulong, pixmap: c_ulong) c_int;
pub extern fn XFreePixmap(display: *Display, pixmap: c_ulong) c_int;
