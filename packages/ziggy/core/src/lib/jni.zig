//
// The JNI crossing for Ziggy's Android native app, written in Zig against the NDK's own jni.h. The Java class
// dev.ziggy.nativeapp.ZiggyNative declares the native methods and the Java interface dev.ziggy.nativeapp.ZiggyNativeCalls is what the
// native app's main thread is called on. Ziggy's app-root.zig, the root of every app's backend library, calls exportJni with the app
// registered with App, and the Java_dev_ziggy_nativeapp_ZiggyNative_* functions below are exported from that library.
//
// Everything the crossing keeps lives in a Bridge, which is allocated by create and whose address is the jlong handle the Java side
// holds. Only the native app's main thread touches it. The core posts its messages for the native app to the native app's queue and
// wakes the main thread by writing to a pipe the main looper watches (see native-message.zig), and the main thread takes them with
// takeMessages, calling into ZiggyNativeCalls for each one. The frontend's messages come in on a web view thread, which posts them to the
// core's main thread's queue, the only part of the core that thread touches, whose address Java holds as a handle of its own. Every
// function a thread other than the main thread calls allocates with an allocator of its own for the call.
//
// Messages cross as byte arrays holding UTF-8, because the JNI string functions use a modified UTF-8 that is not valid
// UTF-8 for characters outside the basic multilingual plane. Configuration strings (paths) are plain text and
// use the JNI string functions.
//

const std = @import("std");
const c = @import("jni-c");
const types = @import("types.zig");
const core = @import("core.zig");
const ui_files = @import("ui-files.zig");
const origin_check = @import("origin-check.zig");
const inject_script = @import("inject-script.zig");
const native_message = @import("native-message.zig");
const NativeSide = @import("native-side.zig").NativeSide;
const ThreadAllocator = @import("thread-allocator.zig").ThreadAllocator;

const MessageQueue = core.MessageQueue;

//
// The Java interface the native app's main thread is called on.
//
const native_calls_class_name = "dev/ziggy/nativeapp/ZiggyNativeCalls";

//
// The native app's main thread's own allocator and Io, made by createBridge and released by destroy, at the edge of the system for as
// long as the core runs, as the C interface's are (see ziggy-api.zig). A process runs one core at a time.
//
var ui_allocator: ThreadAllocator = .init;
var ui_threaded: std.Io.Threaded = undefined;

//
// Everything one created core needs on the native app's main thread. The address of a Bridge is the handle the Java side holds. It
// lives in pages of its own, and only the main thread touches it.
//
const Bridge = struct {
    // A global reference to the Java object that implements ZiggyNativeCalls.
    native_calls: c.jobject,
    // ZiggyNativeCalls.onCoreMessage(byte[]).
    on_core_message_method: c.jmethodID,
    // ZiggyNativeCalls.osVersionJson().
    os_version_json_method: c.jmethodID,
    // ZiggyNativeCalls.quit().
    quit_method: c.jmethodID,
    // ZiggyNativeCalls.keepAlive(boolean).
    keep_alive_method: c.jmethodID,
    // ZiggyNativeCalls.pickPaths(int, String, String, long).
    pick_paths_method: c.jmethodID,
    // ZiggyNativeCalls.nativeCall(byte[], byte[], long).
    native_call_method: c.jmethodID,
    // The core's main thread's queue, which the web view thread posts the frontend's messages to. It lives in pages of its own, so the
    // web view thread needs nothing of the Bridge to reach it.
    main_queue: *MessageQueue,
    // The native app's queue, which the core's threads post to.
    native_queue: MessageQueue,
    // The native app's side of its queue.
    native: NativeSide,
    // The core's main thread.
    main_thread: std.Thread,
    // The end of the wake pipe the main looper watches.
    wake_read: std.posix.fd_t,
    // The end of the wake pipe the core's wake writes to.
    wake_write: std.posix.fd_t,
};

//
// The table of JNI functions behind an environment.
//
fn envTable(env: *c.JNIEnv) *const c.struct_JNINativeInterface {
    return env.*;
}

//
// The table of Java virtual machine functions behind a virtual machine pointer.
//
fn vmTable(java_vm: *c.JavaVM) *const c.struct_JNIInvokeInterface {
    return java_vm.*;
}

//
// Ends the process with a message in the log. Used for a failure in a callback that has nowhere to report it to.
//
fn fatal(env: *c.JNIEnv, message: [*:0]const u8) noreturn {
    envTable(env).FatalError.?(env, message);
    @panic("Ziggy JNI: FatalError returned");
}

//
// When a Java exception is pending, prints it to the log and ends the process. Used after a call into Java from a callback.
//
fn failOnPendingException(env: *c.JNIEnv, message: [*:0]const u8) void {
    if (envTable(env).ExceptionCheck.?(env) == c.JNI_FALSE) {
        return;
    }
    envTable(env).ExceptionDescribe.?(env);
    envTable(env).ExceptionClear.?(env);
    fatal(env, message);
}

//
// Throws a Java exception of the given class with a message. The exception is delivered when the native method returns.
//
fn throwJava(env: *c.JNIEnv, class_name: [*:0]const u8, message: []const u8) void {
    var buffer: [256]u8 = undefined;
    const text = std.fmt.bufPrintZ(&buffer, "{s}", .{message}) catch blk: {
        buffer[buffer.len - 1] = 0;
        break :blk buffer[0 .. buffer.len - 1 :0];
    };
    const class = envTable(env).FindClass.?(env, class_name);
    if (class == null) {
        // FindClass has already thrown NoClassDefFoundError, which is as loud as this one.
        return;
    }
    _ = envTable(env).ThrowNew.?(env, class, text.ptr);
}

//
// Copies a Java string into memory allocated with the allocator. Returns null when the Java string is null.
//
fn dupeJavaString(env: *c.JNIEnv, allocator: std.mem.Allocator, string: c.jstring) !?[:0]u8 {
    if (string == null) {
        return null;
    }
    const chars = envTable(env).GetStringUTFChars.?(env, string, null);
    if (chars == null) {
        return error.JavaException;
    }
    defer envTable(env).ReleaseStringUTFChars.?(env, string, chars);
    return try allocator.dupeZ(u8, std.mem.span(@as([*:0]const u8, @ptrCast(chars))));
}

//
// Copies the bytes of a Java byte array into memory the caller frees. The bytes are copied rather than pinned, because
// handling a message can call back into Java, which a pinned array does not allow.
//
fn copyJavaBytes(env: *c.JNIEnv, allocator: std.mem.Allocator, array: c.jbyteArray) ![]u8 {
    const length: usize = @intCast(envTable(env).GetArrayLength.?(env, array));
    const copy = try allocator.alloc(u8, length);
    errdefer allocator.free(copy);
    envTable(env).GetByteArrayRegion.?(env, array, 0, @intCast(length), @ptrCast(copy.ptr));
    if (envTable(env).ExceptionCheck.?(env) == c.JNI_TRUE) {
        return error.JavaException;
    }
    return copy;
}

//
// Makes a Java byte array holding a copy of the bytes, or ends the process when it could not be made.
//
fn newJavaBytes(env: *c.JNIEnv, bytes: []const u8, what: [*:0]const u8) c.jbyteArray {
    const array = envTable(env).NewByteArray.?(env, @intCast(bytes.len));
    if (array == null) {
        failOnPendingException(env, what);
        fatal(env, what);
    }
    envTable(env).SetByteArrayRegion.?(env, array, 0, @intCast(bytes.len), @ptrCast(bytes.ptr));
    failOnPendingException(env, what);
    return array;
}

//
// Makes a Java string of the text, or null for null, or ends the process when it could not be made.
//
fn newJavaString(env: *c.JNIEnv, allocator: std.mem.Allocator, text: ?[]const u8, what: [*:0]const u8) c.jstring {
    const value = text orelse {
        return null;
    };
    const terminated = allocator.dupeZ(u8, value) catch @panic("Ziggy JNI: out of memory making a string");
    defer allocator.free(terminated);
    const string = envTable(env).NewStringUTF.?(env, terminated.ptr);
    if (string == null) {
        failOnPendingException(env, what);
        fatal(env, what);
    }
    return string;
}

//
// What a signal that is only there to interrupt a blocked system call does when it arrives: nothing.
//
fn doNothingSignalHandler(signal_number: c_int) callconv(.c) void {
    _ = signal_number;
}

//
// WORKAROUND, with the reason and what it fixed.
//
// The problem: every task the core cancels while it is blocked in a system call (the remote control connection's reads, the retry timer
// that openStorage cancels after a read finishes) is cancelled by sending its thread SIGIO, which returns the call early. That needs
// a do-nothing SIGIO handler, and Zig 0.16.0's threaded Io installs it when it is created with options (the remote control connection's
// is). It builds the sigaction struct in the layout glibc uses, and Android's libc has the flags first, so the install lands as no
// handler at all, the default action is restored, and the first cancel of a blocked task ends the whole app with "I/O possible"
// (signal 29). Every Android scenario died this way: the app log stops mid-load and the harness times out waiting for a log line.
//
// What this does: installs the same do-nothing handler for SIGIO and SIGPIPE through the NDK's own struct sigaction and sigaction. It
// has to run after the core is created, because creating the core is what makes Zig overwrite the handler, and it checks by reading
// the handler back so a lost install is loud.
//
// TODO: investigate and remove. Check whether a later Zig fixes the struct layout for Android, and whether the threaded Io should be
// given a way to skip installing its own handler. The Zig threaded Io's deinit also restores the handler it replaced, which on Android
// is the default, so the handler is gone again once the remote control connection stops.
//
fn installSignalHandlers() void {
    var action = std.mem.zeroes(c.struct_sigaction);
    action.unnamed_0.sa_handler = doNothingSignalHandler;
    if (c.sigaction(c.SIGIO, &action, null) != 0) {
        @panic("Ziggy JNI: could not install the SIGIO handler");
    }
    if (c.sigaction(c.SIGPIPE, &action, null) != 0) {
        @panic("Ziggy JNI: could not install the SIGPIPE handler");
    }
    var installed = std.mem.zeroes(c.struct_sigaction);
    if (c.sigaction(c.SIGIO, null, &installed) != 0) {
        @panic("Ziggy JNI: could not read the SIGIO handler back");
    }
    if (installed.unnamed_0.sa_handler != doNothingSignalHandler) {
        @panic("Ziggy JNI: the SIGIO handler was not the one installed");
    }
}

//
// The core's wake. It runs on any thread of the core or the app, and only writes a byte to the wake pipe, whose end it is given as the
// wake data (the descriptor plus one, so that it is never null). The main looper wakes the main thread for it. A full pipe already has
// a wake waiting in it, so a write that would wait is dropped.
//
fn wake(wake_data: ?*anyopaque) callconv(.c) void {
    const descriptor: std.posix.fd_t = @intCast(@intFromPtr(wake_data) - 1);
    const byte = [1]u8{1};
    const written = std.c.write(descriptor, &byte, byte.len);
    if (written < 0) {
        switch (std.c.errno(written)) {
            .AGAIN => {},
            else => |code| std.debug.panic("Ziggy JNI: could not write to the wake pipe: {s}", .{@tagName(code)}),
        }
    }
}

//
// What createBridge needs from Java.
//
const CreateArguments = struct {
    // The Java object that implements ZiggyNativeCalls.
    native_calls: c.jobject,
    // The number of worker threads.
    worker_threads: u32,
    // The limit on child tasks in flight for any one parent task.
    max_concurrent_child_tasks: u32,
    // The URL prefix of the app's bundled frontend.
    app_url_prefix: c.jstring,
    // The app's private data directory.
    data_dir: c.jstring,
    // The remote control server's address, "host:port", from the ziggy.remoteControl extra, or null when the app was started
    // without it.
    remote_control: c.jstring,
};

//
// Creates the Bridge and the core behind it, on the native app's main thread. On failure it returns an error, and a Java exception is
// already pending when the error is error.JavaException.
//
fn createBridge(env: *c.JNIEnv, arguments: CreateArguments, app: core.RegisteredApp) !*Bridge {
    const bridge = try std.heap.page_allocator.create(Bridge);
    errdefer std.heap.page_allocator.destroy(bridge);
    ui_allocator = .init;
    errdefer ui_allocator.deinit();
    const allocator = ui_allocator.allocator();
    ui_threaded = .init_single_threaded;
    ui_threaded.allocator = allocator;
    errdefer ui_threaded.deinit();

    const native_calls_class = envTable(env).FindClass.?(env, native_calls_class_name);
    if (native_calls_class == null) {
        return error.JavaException;
    }
    defer envTable(env).DeleteLocalRef.?(env, native_calls_class);
    bridge.on_core_message_method = envTable(env).GetMethodID.?(env, native_calls_class, "onCoreMessage", "([B)V") orelse {
        return error.JavaException;
    };
    bridge.os_version_json_method = envTable(env).GetMethodID.?(env, native_calls_class, "osVersionJson", "()Ljava/lang/String;") orelse {
        return error.JavaException;
    };
    bridge.quit_method = envTable(env).GetMethodID.?(env, native_calls_class, "quit", "()V") orelse {
        return error.JavaException;
    };
    bridge.keep_alive_method = envTable(env).GetMethodID.?(env, native_calls_class, "keepAlive", "(Z)V") orelse {
        return error.JavaException;
    };
    bridge.pick_paths_method = envTable(env).GetMethodID.?(env, native_calls_class, "pickPaths", "(ILjava/lang/String;Ljava/lang/String;J)V") orelse {
        return error.JavaException;
    };
    bridge.native_call_method = envTable(env).GetMethodID.?(env, native_calls_class, "nativeCall", "([B[BJ)V") orelse {
        return error.JavaException;
    };

    bridge.native_calls = envTable(env).NewGlobalRef.?(env, arguments.native_calls);
    if (bridge.native_calls == null) {
        return error.JavaException;
    }
    errdefer envTable(env).DeleteGlobalRef.?(env, bridge.native_calls);

    const app_url_prefix = (try dupeJavaString(env, allocator, arguments.app_url_prefix)) orelse {
        return error.AppUrlPrefixMissing;
    };
    defer allocator.free(app_url_prefix);
    const data_dir = (try dupeJavaString(env, allocator, arguments.data_dir)) orelse {
        return error.DataDirMissing;
    };
    defer allocator.free(data_dir);
    const remote_control = try dupeJavaString(env, allocator, arguments.remote_control);
    defer if (remote_control) |address| allocator.free(address);

    var pipe: [2]std.posix.fd_t = undefined;
    if (std.c.pipe2(&pipe, .{
        .NONBLOCK = true,
        .CLOEXEC = true,
    }) != 0) {
        return error.WakePipeFailed;
    }
    bridge.wake_read = pipe[0];
    bridge.wake_write = pipe[1];
    errdefer {
        _ = std.c.close(bridge.wake_read);
        _ = std.c.close(bridge.wake_write);
    }

    const config = types.ZiggyConfig{
        .wake_data = @ptrFromInt(@as(usize, @intCast(bridge.wake_write)) + 1),
        .wake = wake,
        .has_os_version = true,
        .has_quit = true,
        .has_pick_paths = true,
        // A phone has no menu bar, so a test's menu item reaches the core as the frontend's menu-action message instead.
        .has_menu_action = true,
        .has_keep_alive = true,
        .has_native_call = true,
        // A phone's screenshot is taken from the computer with adb, so the app has no way of taking one itself.
        .has_screenshot = false,
        .worker_threads = arguments.worker_threads,
        .max_concurrent_child_tasks = arguments.max_concurrent_child_tasks,
        .app_url_prefix = app_url_prefix.ptr,
        .data_dir = data_dir.ptr,
        .test_mode = remote_control != null,
        .remote_control = if (remote_control) |address| address.ptr else null,
        // A phone app has no command line.
        .arg_count = 0,
        .args = null,
    };
    bridge.main_queue = try std.heap.page_allocator.create(MessageQueue);
    errdefer std.heap.page_allocator.destroy(bridge.main_queue);
    bridge.main_queue.* = MessageQueue.init();
    errdefer bridge.main_queue.deinit();
    bridge.native_queue = MessageQueue.init();
    errdefer bridge.native_queue.deinit();
    bridge.native = .init(&bridge.native_queue);
    errdefer bridge.native.deinit(allocator);
    bridge.main_thread = try core.start(allocator, bridge.main_queue, &bridge.native_queue, config, app);
    installSignalHandlers();
    return bridge;
}

//
// Takes every message the core has posted for the native app, on the main thread, and calls ZiggyNativeCalls for each: onCoreMessage for a
// message for the frontend, and the method of each call. A menu action becomes the frontend's menu-action message, because a phone has
// no menu of the native app's own.
//
fn takeMessages(env: *c.JNIEnv, bridge: *Bridge) void {
    const allocator = ui_allocator.allocator();
    var drained: [64]u8 = undefined;
    while (true) {
        _ = std.posix.read(bridge.wake_read, &drained) catch |err| switch (err) {
            error.WouldBlock => break,
            else => std.debug.panic("Ziggy JNI: could not read the wake pipe: {s}", .{@errorName(err)}),
        };
    }
    while (true) {
        const taken = bridge.native.take(ui_threaded.io(), allocator, .{
            .duration = .{
                .raw = .zero,
                .clock = .awake,
            },
        }) orelse {
            return;
        };
        if (taken.kind == .deliver) {
            const array = newJavaBytes(env, taken.text, "Ziggy JNI: could not copy a message into a byte array");
            defer envTable(env).DeleteLocalRef.?(env, array);
            var arguments = [1]c.jvalue{
                .{
                    .l = array,
                },
            };
            envTable(env).CallVoidMethodA.?(env, bridge.native_calls, bridge.on_core_message_method, &arguments);
            failOnPendingException(env, "Ziggy JNI: ZiggyNativeCalls.onCoreMessage threw");
            continue;
        }
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        // The text is valid only until the next take, which Java may cause, so the call is read from a copy.
        const text = arena.dupe(u8, taken.text) catch @panic("Ziggy JNI: out of memory taking a call");
        const call = native_message.parse(arena, text) catch {
            std.debug.panic("Ziggy JNI: the core sent a call the native app cannot read: {s}", .{text});
        };
        doCall(env, bridge, arena, call, taken.reply);
    }
}

//
// Does one call of the core's, on the main thread. A dialog and a native call are given their results later, by ZiggyNative.nativeResult.
//
fn doCall(env: *c.JNIEnv, bridge: *Bridge, arena: std.mem.Allocator, call: native_message.Call, reply: u64) void {
    switch (call) {
        .quit => {
            envTable(env).CallVoidMethodA.?(env, bridge.native_calls, bridge.quit_method, null);
            failOnPendingException(env, "Ziggy JNI: ZiggyNativeCalls.quit threw");
        },
        .keep_alive => |keep_running| {
            var arguments = [1]c.jvalue{
                .{
                    .z = if (keep_running) c.JNI_TRUE else c.JNI_FALSE,
                },
            };
            envTable(env).CallVoidMethodA.?(env, bridge.native_calls, bridge.keep_alive_method, &arguments);
            failOnPendingException(env, "Ziggy JNI: ZiggyNativeCalls.keepAlive threw");
        },
        .menu_action => |action| {
            const message = std.json.Stringify.valueAlloc(arena, .{
                .kind = "system",
                .name = "menu-action",
                .data = .{
                    .action = action,
                },
            }, .{}) catch @panic("Ziggy JNI: out of memory building a menu-action message");
            core.sendMessage(arena, bridge.main_queue, message);
        },
        .os_version => {
            const string = envTable(env).CallObjectMethodA.?(env, bridge.native_calls, bridge.os_version_json_method, null);
            failOnPendingException(env, "Ziggy JNI: ZiggyNativeCalls.osVersionJson threw");
            if (string == null) {
                giveResult(bridge, reply, false, "NativeCallFailed");
                return;
            }
            defer envTable(env).DeleteLocalRef.?(env, string);
            const version = dupeJavaString(env, arena, @ptrCast(string)) catch {
                failOnPendingException(env, "Ziggy JNI: could not read the operating system version");
                giveResult(bridge, reply, false, "NativeCallFailed");
                return;
            };
            giveResult(bridge, reply, true, version.?);
        },
        .pick_paths => |pick| {
            const title = newJavaString(env, arena, pick.title, "Ziggy JNI: could not make the picker title");
            defer if (title != null) envTable(env).DeleteLocalRef.?(env, title);
            const initial_name = newJavaString(env, arena, pick.initial_name, "Ziggy JNI: could not make the picker file name");
            defer if (initial_name != null) envTable(env).DeleteLocalRef.?(env, initial_name);
            var arguments = [4]c.jvalue{
                .{
                    .i = pick.kind,
                },
                .{
                    .l = title,
                },
                .{
                    .l = initial_name,
                },
                .{
                    .j = @bitCast(reply),
                },
            };
            envTable(env).CallVoidMethodA.?(env, bridge.native_calls, bridge.pick_paths_method, &arguments);
            failOnPendingException(env, "Ziggy JNI: ZiggyNativeCalls.pickPaths threw");
        },
        .native_call => |native_call| {
            const method = newJavaBytes(env, native_call.method, "Ziggy JNI: could not make the native call method");
            defer envTable(env).DeleteLocalRef.?(env, method);
            const request = newJavaBytes(env, native_call.request, "Ziggy JNI: could not make the native call argument");
            defer envTable(env).DeleteLocalRef.?(env, request);
            var arguments = [3]c.jvalue{
                .{
                    .l = method,
                },
                .{
                    .l = request,
                },
                .{
                    .j = @bitCast(reply),
                },
            };
            envTable(env).CallVoidMethodA.?(env, bridge.native_calls, bridge.native_call_method, &arguments);
            failOnPendingException(env, "Ziggy JNI: ZiggyNativeCalls.nativeCall threw");
        },
        .screenshot, .stopped => std.debug.panic("Ziggy JNI: the core sent a call the native app does not do", .{}),
    }
}

//
// Gives the result of the core's call taken under the number `reply`.
//
fn giveResult(bridge: *Bridge, reply: u64, succeeded: bool, text: []const u8) void {
    bridge.native.result(ui_threaded.io(), ui_allocator.allocator(), reply, succeeded, text) catch |err| {
        std.debug.panic("Ziggy JNI: could not give the result of the core's call: {s}", .{@errorName(err)});
    };
}

//
// Exports the JNI entry points of dev.ziggy.nativeapp.ZiggyNative and JNI_OnLoad from the library that calls this, serving the
// app registered with App. It is called once, from app-root.zig, and only for an Android target.
//
pub fn exportJni(comptime app: core.RegisteredApp) void {
    const Exports = struct {
        //
        // Called when the virtual machine loads the library: checks that it supports the JNI version the entry points use.
        //
        fn onLoad(java_vm: *c.JavaVM, reserved: ?*anyopaque) callconv(.c) c.jint {
            _ = reserved;
            var env: ?*c.JNIEnv = null;
            if (vmTable(java_vm).GetEnv.?(java_vm, @ptrCast(&env), c.JNI_VERSION_1_6) != c.JNI_OK) {
                @panic("Ziggy JNI: the virtual machine does not support JNI 1.6");
            }
            return c.JNI_VERSION_1_6;
        }

        //
        // Creates the core for the app's ZiggyNativeCalls object, on the main thread, and returns its handle, or zero with a Java exception pending.
        //
        fn create(
            env: *c.JNIEnv,
            class: c.jclass,
            native_calls: c.jobject,
            worker_threads: c.jint,
            max_concurrent_child_tasks: c.jint,
            app_url_prefix: c.jstring,
            data_dir: c.jstring,
            remote_control: c.jstring,
        ) callconv(.c) c.jlong {
            _ = class;
            const bridge = createBridge(env, .{
                .native_calls = native_calls,
                .worker_threads = @intCast(worker_threads),
                .max_concurrent_child_tasks = @intCast(max_concurrent_child_tasks),
                .app_url_prefix = app_url_prefix,
                .data_dir = data_dir,
                .remote_control = remote_control,
            }, app) catch |err| {
                if (err != error.JavaException) {
                    var buffer: [128]u8 = undefined;
                    const message = std.fmt.bufPrint(&buffer, "Ziggy could not create the core: {s}", .{@errorName(err)}) catch "Ziggy could not create the core";
                    throwJava(env, "java/lang/IllegalStateException", message);
                }
                return 0;
            };
            return @intCast(@intFromPtr(bridge));
        }

        //
        // The handle of the core's main thread's queue, which the frontend's messages are posted to from the web view's thread.
        //
        fn messageQueue(env: *c.JNIEnv, class: c.jclass, handle: c.jlong) callconv(.c) c.jlong {
            _ = env;
            _ = class;
            const bridge: *Bridge = @ptrFromInt(@as(usize, @intCast(handle)));
            return @intCast(@intFromPtr(bridge.main_queue));
        }

        //
        // The end of the wake pipe the main looper watches, readable whenever the core has posted messages for the native app.
        //
        fn wakeDescriptor(env: *c.JNIEnv, class: c.jclass, handle: c.jlong) callconv(.c) c.jint {
            _ = env;
            _ = class;
            const bridge: *Bridge = @ptrFromInt(@as(usize, @intCast(handle)));
            return @intCast(bridge.wake_read);
        }

        //
        // Takes every message the core has posted for the native app, on the main thread.
        //
        fn takeMessagesEntry(env: *c.JNIEnv, class: c.jclass, handle: c.jlong) callconv(.c) void {
            _ = class;
            takeMessages(env, @ptrFromInt(@as(usize, @intCast(handle))));
        }

        //
        // Gives the result of the core's call taken under the number reply, on the main thread.
        //
        fn nativeResult(env: *c.JNIEnv, class: c.jclass, handle: c.jlong, reply: c.jlong, ok: c.jboolean, text: c.jbyteArray) callconv(.c) void {
            _ = class;
            const bridge: *Bridge = @ptrFromInt(@as(usize, @intCast(handle)));
            const allocator = ui_allocator.allocator();
            const copy = copyJavaBytes(env, allocator, text) catch |err| {
                if (err != error.JavaException) {
                    throwJava(env, "java/lang/OutOfMemoryError", "Ziggy could not copy the result of a call");
                }
                return;
            };
            defer allocator.free(copy);
            giveResult(bridge, @bitCast(reply), ok != c.JNI_FALSE, copy);
        }

        //
        // Destroys the core of the handle, on the main thread, failing every call meanwhile with ShuttingDown, and releases
        // everything the bridge held.
        //
        fn destroy(env: *c.JNIEnv, class: c.jclass, handle: c.jlong) callconv(.c) void {
            _ = class;
            const bridge: *Bridge = @ptrFromInt(@as(usize, @intCast(handle)));
            const allocator = ui_allocator.allocator();
            // After this returns nothing runs and nothing is delivered, so the Bridge can be released.
            core.stop(allocator, bridge.main_queue, &bridge.native, null, bridge.main_thread);
            bridge.native.deinit(allocator);
            bridge.native_queue.deinit();
            bridge.main_queue.deinit();
            std.heap.page_allocator.destroy(bridge.main_queue);
            _ = std.c.close(bridge.wake_read);
            _ = std.c.close(bridge.wake_write);
            envTable(env).DeleteGlobalRef.?(env, bridge.native_calls);
            ui_threaded.deinit();
            ui_allocator.deinit();
            std.heap.page_allocator.destroy(bridge);
        }

        //
        // Passes a message from the frontend to the core's main thread, from the web view's thread, which reaches only the queue.
        //
        fn sendMessage(env: *c.JNIEnv, class: c.jclass, queue_handle: c.jlong, message: c.jbyteArray) callconv(.c) void {
            _ = class;
            const queue: *MessageQueue = @ptrFromInt(@as(usize, @intCast(queue_handle)));
            var thread_allocator: ThreadAllocator = .init;
            defer thread_allocator.deinit();
            const allocator = thread_allocator.allocator();
            const copy = copyJavaBytes(env, allocator, message) catch |err| {
                if (err != error.JavaException) {
                    throwJava(env, "java/lang/OutOfMemoryError", "Ziggy could not copy a message from the UI");
                }
                return;
            };
            defer allocator.free(copy);
            core.sendMessage(allocator, queue, copy);
        }

        //
        // Has the core's origin check decide what to do with an address the web view is about to load, against the app's URL prefix,
        // from whichever of the web view's threads calls it.
        //
        fn checkUrl(env: *c.JNIEnv, class: c.jclass, app_url_prefix: c.jbyteArray, url: c.jbyteArray) callconv(.c) c.jint {
            _ = class;
            var thread_allocator: ThreadAllocator = .init;
            defer thread_allocator.deinit();
            const allocator = thread_allocator.allocator();
            const prefix = copyJavaBytes(env, allocator, app_url_prefix) catch |err| {
                if (err != error.JavaException) {
                    throwJava(env, "java/lang/OutOfMemoryError", "Ziggy could not copy the app's URL prefix");
                }
                return @intFromEnum(types.UrlDecision.block);
            };
            defer allocator.free(prefix);
            const copy = copyJavaBytes(env, allocator, url) catch |err| {
                if (err != error.JavaException) {
                    throwJava(env, "java/lang/OutOfMemoryError", "Ziggy could not copy an address to check");
                }
                return @intFromEnum(types.UrlDecision.block);
            };
            defer allocator.free(copy);
            return @intFromEnum(origin_check.checkUrl(prefix, copy));
        }

        //
        // Copies the Java byte array of a request path and finds the bundled frontend's file for it. Null when there is no
        // such file, or when the path could not be copied (in which case a Java exception is pending).
        //
        fn findUiFile(env: *c.JNIEnv, path: c.jbyteArray) ?*const ui_files.UiFile {
            var thread_allocator: ThreadAllocator = .init;
            defer thread_allocator.deinit();
            const allocator = thread_allocator.allocator();
            const copy = copyJavaBytes(env, allocator, path) catch |err| {
                if (err != error.JavaException) {
                    throwJava(env, "java/lang/OutOfMemoryError", "Ziggy could not copy a UI path");
                }
                return null;
            };
            defer allocator.free(copy);
            return ui_files.findFile(app.ui_files, copy);
        }

        //
        // Gives the script to inject into the frontend before it loads, as UTF-8 bytes.
        //
        fn injectScript(env: *c.JNIEnv, class: c.jclass) callconv(.c) c.jbyteArray {
            _ = class;
            return newJavaBytes(env, inject_script.text, "Ziggy JNI: could not copy the inject script into a byte array");
        }

        //
        // The query of the frontend's address as UTF-8 bytes, or null, with a Java exception pending, when the app could not make it.
        // Called on the main thread.
        //
        fn uiQuery(env: *c.JNIEnv, class: c.jclass, handle: c.jlong) callconv(.c) c.jbyteArray {
            _ = class;
            const bridge: *Bridge = @ptrFromInt(@as(usize, @intCast(handle)));
            const allocator = ui_allocator.allocator();
            const text = core.uiQuery(allocator, bridge.main_queue) catch |err| {
                throwJava(env, "java/lang/IllegalStateException", @errorName(err));
                return null;
            };
            defer allocator.free(text);
            return newJavaBytes(env, text, "Ziggy JNI: could not copy the UI query into a byte array");
        }

        //
        // Gives the bytes of a file of the bundled frontend, or null when the frontend has no such file.
        //
        fn uiFileContent(env: *c.JNIEnv, class: c.jclass, path: c.jbyteArray) callconv(.c) c.jbyteArray {
            _ = class;
            const file = findUiFile(env, path) orelse {
                return null;
            };
            return newJavaBytes(env, file.content, "Ziggy JNI: could not copy a UI file into a byte array");
        }

        //
        // Gives the content type of a file of the bundled frontend, or null when the frontend has no such file.
        //
        fn uiFileContentType(env: *c.JNIEnv, class: c.jclass, path: c.jbyteArray) callconv(.c) c.jstring {
            _ = class;
            const file = findUiFile(env, path) orelse {
                return null;
            };
            const text = envTable(env).NewStringUTF.?(env, ui_files.contentType(file.path).ptr);
            if (text == null) {
                failOnPendingException(env, "Ziggy JNI: could not allocate a string for a content type");
                fatal(env, "Ziggy JNI: could not allocate a string for a content type");
            }
            return text;
        }
    };
    @export(&Exports.onLoad, .{
        .name = "JNI_OnLoad",
    });
    @export(&Exports.create, .{
        .name = "Java_dev_ziggy_nativeapp_ZiggyNative_create",
    });
    @export(&Exports.messageQueue, .{
        .name = "Java_dev_ziggy_nativeapp_ZiggyNative_messageQueue",
    });
    @export(&Exports.wakeDescriptor, .{
        .name = "Java_dev_ziggy_nativeapp_ZiggyNative_wakeDescriptor",
    });
    @export(&Exports.takeMessagesEntry, .{
        .name = "Java_dev_ziggy_nativeapp_ZiggyNative_takeMessages",
    });
    @export(&Exports.nativeResult, .{
        .name = "Java_dev_ziggy_nativeapp_ZiggyNative_nativeResult",
    });
    @export(&Exports.destroy, .{
        .name = "Java_dev_ziggy_nativeapp_ZiggyNative_destroy",
    });
    @export(&Exports.sendMessage, .{
        .name = "Java_dev_ziggy_nativeapp_ZiggyNative_sendMessage",
    });
    @export(&Exports.checkUrl, .{
        .name = "Java_dev_ziggy_nativeapp_ZiggyNative_checkUrl",
    });
    @export(&Exports.injectScript, .{
        .name = "Java_dev_ziggy_nativeapp_ZiggyNative_injectScript",
    });
    @export(&Exports.uiQuery, .{
        .name = "Java_dev_ziggy_nativeapp_ZiggyNative_uiQuery",
    });
    @export(&Exports.uiFileContent, .{
        .name = "Java_dev_ziggy_nativeapp_ZiggyNative_uiFileContent",
    });
    @export(&Exports.uiFileContentType, .{
        .name = "Java_dev_ziggy_nativeapp_ZiggyNative_uiFileContentType",
    });
}
