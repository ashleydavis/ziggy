package dev.ziggy.nativeapp;

// How an app's own Android code handles the core's native calls: the things only the platform can do (a permission prompt, a keychain,
// a share sheet), each named by a method. The core knows no method names, they are the app's and its handler's. The app gives its handler
// to ZiggyNativeApp.setNativeCallHandler before ZiggyNativeApp.start.
public interface NativeCallHandler {
    // Does what the method names with the JSON text of its argument and returns the JSON text of the result. It is called on the native
    // app's own thread for the app's calls, never the main thread, one call at a time, and may block for as long as it takes, for
    // instance until a permission dialog closes.
    // It throws NativeCallException, with the reason in words the user can act on, for a method it does not know or cannot do.
    String handle(String method, String requestJson) throws NativeCallException;
}
