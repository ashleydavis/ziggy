// The root of this package's unit tests: the parts of the Linux native app that do not need GTK.
test {
    _ = @import("test/menu-keys.test.zig");
    _ = @import("test/geometry.test.zig");
}
