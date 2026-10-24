package dev.ziggy.nativeapp;

// The native methods of Ziggy's core. They are implemented in Zig, in the app's core library (see jni.zig in packages/ziggy/core),
// which must be loaded with System.loadLibrary before any of them is called. A handle is the address of what create made, and only
// the main thread uses it.
final class ZiggyNative {
    private ZiggyNative() {
    }

    // Whether the core library was built with the test hooks.
    static native boolean testHooksEnabled();

    // Creates a core and returns its handle, on the main thread. Throws when the core cannot be created. testPortFile may be null.
    static native long create(
        ZiggyNativeCalls nativeCalls,
        int workerThreads,
        int maxConcurrentChildTasks,
        String appUrlPrefix,
        String dataDir,
        boolean testMode,
        String testPortFile);

    // The handle of the core's main thread's queue, which sendMessage takes. It is the only part of the core a thread other than the
    // main thread reaches.
    static native long messageQueue(long handle);

    // The file descriptor that is readable whenever the core has messages for the native app, which the main looper watches. The core
    // owns it and closes it in destroy.
    static native int wakeDescriptor(long handle);

    // Takes every message the core has for the native app, on the main thread, and calls the ZiggyNativeCalls methods for them.
    static native void takeMessages(long handle);

    // Gives the core the result of the call that ZiggyNativeCalls.pickPaths or ZiggyNativeCalls.nativeCall was given the number reply for, on the main thread:
    // ok and the result as UTF-8, or not ok and the reason as UTF-8.
    static native void nativeResult(long handle, long reply, boolean ok, byte[] text);

    // Cancels every running task, waits for the workers to stop and releases the core, on the main thread. Every call without a result yet
    // gets the result ShuttingDown. Nothing is delivered after it returns, and no result may be given after it.
    static native void destroy(long handle);

    // Passes a message from the frontend, as UTF-8 JSON, to the core's main thread and returns at once, from any thread. The message's
    // handler runs later, on the core's main thread. The handle is messageQueue's.
    static native void sendMessage(long queueHandle, byte[] message);

    // Decides what to do with an address the web view is about to load, against the app's URL prefix, from any thread: 0 to load it,
    // 1 to open it in the system browser, 2 to block it.
    static native int checkUrl(byte[] appUrlPrefix, byte[] url);

    // The script that exposes window.ziggy, as UTF-8, which the native app runs in the frontend before the frontend's own
    // scripts. It is embedded in the core library, so the app supplies nothing.
    static native byte[] injectScript();

    // The query of the frontend's address as UTF-8, which the app supplies: the text after the question mark, empty when the app
    // has none. The native app appends it to the frontend's address unread. Throws when the app could not make it. On the main thread.
    static native byte[] uiQuery(long handle);

    // The bytes of the app's bundled frontend file for a request path as UTF-8 (such as "/index.html"), or null when the
    // frontend has no such file, from any thread.
    static native byte[] uiFileContent(byte[] path);

    // The content type of that file, such as "text/html; charset=utf-8", or null when the frontend has no such file, from any thread.
    static native String uiFileContentType(byte[] path);
}
