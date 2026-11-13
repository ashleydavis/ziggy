package dev.ziggy.nativeapp;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNull;

import org.junit.Test;

// Plain-JVM tests for how the ziggy.theme extra sets the theme for one run.
public final class ThemeExtraTest {
    @Test
    public void theExtraIsNamedAsTheSmokeTestsSendIt() {
        assertEquals("ziggy.theme", ThemeExtra.NAME);
    }

    @Test
    public void theExtraGivesTheSetting() {
        assertEquals("dark", ThemeExtra.value("dark"));
        assertEquals("system", ThemeExtra.value("system"));
    }

    @Test
    public void anAbsentExtraLeavesTheSettingToTheConfigFile() {
        assertNull(ThemeExtra.value(null));
    }

    @Test
    public void anEmptyExtraLeavesTheSettingToTheConfigFile() {
        assertNull(ThemeExtra.value(""));
    }
}
