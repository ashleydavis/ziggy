//
// An app's dev host: Ziggy's dev host linked with the app's core, which an app's <name>-dev-host build step builds. The app's
// name comes from the build. See lib/dev-host.zig.
//

const std = @import("std");
const dev_host = @import("ziggy-dev");
const dev_app = @import("dev_app");

pub fn main(init: std.process.Init) !u8 {
    return dev_host.run(init, .{
        .title = dev_app.title,
    });
}
