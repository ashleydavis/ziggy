package dev.ziggy.nativeapp;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNull;

import org.junit.Test;

// Plain-JVM tests for how the ziggy.remoteControl extra turns remote control on: the address it gives, or nothing when it is absent.
public final class RemoteControlExtraTest {
    @Test
    public void theExtraIsNamedAsTheSmokeTestsSendIt() {
        assertEquals("ziggy.remoteControl", RemoteControlExtra.NAME);
    }

    @Test
    public void theExtraGivesTheServersAddress() {
        assertEquals("127.0.0.1:4001", RemoteControlExtra.address("127.0.0.1:4001"));
    }

    @Test
    public void anAbsentExtraLeavesRemoteControlAndTestModeOff() {
        assertNull(RemoteControlExtra.address(null));
    }

    @Test
    public void anEmptyExtraLeavesRemoteControlAndTestModeOff() {
        assertNull(RemoteControlExtra.address(""));
    }
}
