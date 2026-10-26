const std = @import("std");
const builtin = @import("builtin");
const process_env = @import("process-env.zig");

//
// The operating system's temporary directory, read from the calling thread's environment (see process-env.zig), without a trailing
// separator. On Windows: TEMP or TMP, else %SystemRoot%\temp (or %windir%\temp), keeping the separator of a drive root. Elsewhere:
// TMPDIR, TMP or TEMP, else /tmp. The text is allocated with the allocator.
//
pub fn osTmpDir(allocator: std.mem.Allocator) ![]const u8 {
    if (builtin.os.tag == .windows) {
        const windows_path = firstSet(&.{ "TEMP", "TMP" }) orelse {
            const system_root = firstSet(&.{ "SystemRoot", "windir" }) orelse {
                return error.NoTemporaryDirectory;
            };
            return std.mem.concat(allocator, u8, &.{ system_root, "\\temp" });
        };
        if (windows_path.len > 1 and std.mem.endsWith(u8, windows_path, "\\") and !std.mem.endsWith(u8, windows_path, ":\\")) {
            return allocator.dupe(u8, windows_path[0 .. windows_path.len - 1]);
        }
        return allocator.dupe(u8, windows_path);
    }
    const posix_path = firstSet(&.{ "TMPDIR", "TMP", "TEMP" }) orelse {
        return allocator.dupe(u8, "/tmp");
    };
    if (posix_path.len > 1 and posix_path[posix_path.len - 1] == '/') {
        return allocator.dupe(u8, posix_path[0 .. posix_path.len - 1]);
    }
    return allocator.dupe(u8, posix_path);
}

//
// The value of the first of the environment variables that is set and not empty, or null.
//
fn firstSet(names: []const []const u8) ?[]const u8 {
    for (names) |name| {
        if (process_env.getEnv(name)) |value| {
            if (value.len > 0) {
                return value;
            }
        }
    }
    return null;
}
