package dev.ziggy.nativeapp;

// What the core's messages for the native app are handed to. The Zig side (the JNI entry points in Ziggy's core library) holds an
// object of this type and calls these methods on the main thread only, when ZiggyNative.takeMessages takes the messages.
public interface ZiggyNativeCalls {
    // A message from the core to the frontend, as UTF-8 JSON. The array belongs to the callee.
    void onCoreMessage(byte[] message);

    // The operating system's version, as the text of a JSON string, such as "Android 16 (API 36)".
    String osVersionJson();

    // Quits the application.
    void quit();

    // Keeps the application running (true) or reports it need not be (false), because tasks the app must be kept running for are queued
    // or running.
    void keepAlive(boolean keepRunning);

    // Shows a file or folder picker and returns at once. kind is 0 to open files, 1 to save a file (initialName is the suggested name)
    // or 2 to choose a directory. The result goes to ZiggyNative.nativeResult with the number reply, on the main thread: the UTF-8 JSON
    // of an array of path strings, which is [] when the user cancelled, or a failure when the picker could not be shown.
    void pickPaths(int kind, String title, String initialName, long reply);

    // Has the app's own code do one thing only it can do, named by method, and returns at once. Both arguments are UTF-8 text as bytes
    // (the method name and the JSON text of its argument). The result goes to ZiggyNative.nativeResult with the number reply, on the
    // main thread: the JSON text of the result, or a failure with the reason.
    void nativeCall(byte[] method, byte[] requestJson, long reply);
}
