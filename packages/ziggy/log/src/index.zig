//
// Ziggy's log: the log interface (ILog) and its logs (the console log, the file log, the memory log and the mute log), and the console
// and standard streams they write to. It depends on Ziggy's utils and on nothing else in Ziggy.
//

pub const console = @import("lib/console.zig");
pub const file_log = @import("lib/file-log.zig");
pub const log = @import("lib/log.zig");
pub const memory_log = @import("lib/memory-log.zig");
pub const mute_log = @import("lib/mute-log.zig");
pub const standard_streams = @import("lib/standard-streams.zig");
