package dev.ziggy.nativeapp;

import static org.junit.Assert.assertEquals;

import java.nio.charset.StandardCharsets;
import org.junit.Test;

// Plain-JVM tests for how the result of a native call crosses to the core: a status byte, then the result or the reason as UTF-8.
public final class NativeCallResultTest {
    @Test
    public void aSuccessIsMarkedAndCarriesTheResult() {
        byte[] result = NativeCallResult.succeeded("{\"granted\":true}");
        assertEquals(NativeCallResult.SUCCEEDED, result[0]);
        assertEquals("{\"granted\":true}", new String(result, 1, result.length - 1, StandardCharsets.UTF_8));
    }

    @Test
    public void aFailureIsMarkedAndCarriesTheReason() {
        byte[] result = NativeCallResult.failed("Photo access was refused.");
        assertEquals(NativeCallResult.FAILED, result[0]);
        assertEquals("Photo access was refused.", new String(result, 1, result.length - 1, StandardCharsets.UTF_8));
    }

    @Test
    public void textOutsideTheBasicPlaneSurvives() {
        String text = "\"photo-📷\"";
        byte[] result = NativeCallResult.succeeded(text);
        assertEquals(text, new String(result, 1, result.length - 1, StandardCharsets.UTF_8));
    }

    @Test
    public void anEmptyResultIsJustTheStatusByte() {
        assertEquals(1, NativeCallResult.succeeded("").length);
    }
}
