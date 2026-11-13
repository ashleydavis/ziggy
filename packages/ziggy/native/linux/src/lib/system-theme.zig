//
// The system's theme, read from the desktop portal's colour scheme.
//

const std = @import("std");

//
// The system's theme, matching ZIGGY_THEME_LIGHT and ZIGGY_THEME_DARK in ziggy.h.
//
pub const SystemTheme = enum(c_int) {
    light = 0,
    dark = 1,
};

//
// The theme the portal's color-scheme value names: 1 is dark, anything else light.
//
pub fn fromColorScheme(value: u32) SystemTheme {
    return if (value == 1) .dark else .light;
}
