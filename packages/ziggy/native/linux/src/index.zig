//
// Ziggy's Linux native app.
//

pub const native_app = @import("lib/native-app.zig");
pub const run = native_app.run;
pub const AppConfig = native_app.AppConfig;
pub const NativeCallContext = native_app.NativeCallContext;
