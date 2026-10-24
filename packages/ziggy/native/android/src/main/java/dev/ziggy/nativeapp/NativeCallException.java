package dev.ziggy.nativeapp;

// What a NativeCallHandler throws when it cannot do what a native call's method names. The message is the reason, in words the user can act on, and
// it is passed to the core as the failure text of the call.
public final class NativeCallException extends Exception {
    public NativeCallException(String reason) {
        super(reason);
    }

    public NativeCallException(String reason, Throwable cause) {
        super(reason, cause);
    }
}
