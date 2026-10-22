//
// Ziggy's dev host, for dev mode: an app's core run as a program of its own, which the frontend in an ordinary browser talks
// to, and the supervisor that rebuilds and restarts it when the app's Zig files change.
//

pub const dev_host = @import("lib/dev-host.zig");
pub const run = dev_host.run;
pub const AppInfo = dev_host.AppInfo;
