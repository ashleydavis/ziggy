// The root of the dev host's unit tests: the parts that need no core.
test {
    _ = @import("test/request-paths.test.zig");
    _ = @import("test/args.test.zig");
    _ = @import("test/watch.test.zig");
    _ = @import("test/web-socket.test.zig");
    _ = @import("test/proxy.test.zig");
    _ = @import("test/pickers.test.zig");
}
