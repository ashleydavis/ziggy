package dev.ziggy.nativeapp;

// The Intent extra that sets the theme for one run: ziggy.theme, "light", "dark" or "system". It is the Android form of the
// --theme option of the desktop native apps, because an Android app is started with an Intent, not a command line. It is never
// written to the config file.
final class ThemeExtra {
    // The extra's name.
    static final String NAME = "ziggy.theme";

    private ThemeExtra() {
    }

    // The value the extra gives, or null when the extra is absent or empty, which leaves the setting to the config file.
    static String value(String value) {
        if (value == null || value.isEmpty()) {
            return null;
        }
        return value;
    }
}
