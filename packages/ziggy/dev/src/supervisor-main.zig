//
// The supervisor of Ziggy's dev mode, which an app's <name>-dev build step builds and runs. See lib/supervisor.zig.
//

const std = @import("std");
const supervisor = @import("lib/supervisor.zig");

pub fn main(init: std.process.Init) !u8 {
    return supervisor.run(init);
}
