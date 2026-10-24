package dev.ziggy.nativeapp;

import java.nio.charset.StandardCharsets;

// How a native call's result crosses to the core: UTF-8 bytes whose first byte records whether the call succeeded (1) or failed (0),
// followed by the JSON text of the result or the text of the reason. The core's JNI code reads the first byte and passes the rest on.
public final class NativeCallResult {
    // The first byte of the result of a call that succeeded.
    public static final byte SUCCEEDED = 1;

    // The first byte of the result of a call that failed.
    public static final byte FAILED = 0;

    private NativeCallResult() {
    }

    // The result of a call that succeeded, with the JSON text of what it gave.
    public static byte[] succeeded(String resultJson) {
        return encode(SUCCEEDED, resultJson);
    }

    // The result of a call that failed, with the reason.
    public static byte[] failed(String reason) {
        return encode(FAILED, reason);
    }

    private static byte[] encode(byte status, String text) {
        byte[] bytes = text.getBytes(StandardCharsets.UTF_8);
        byte[] result = new byte[bytes.length + 1];
        result[0] = status;
        System.arraycopy(bytes, 0, result, 1, bytes.length);
        return result;
    }
}
