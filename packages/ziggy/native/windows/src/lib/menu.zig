//
// Writing the labels of the menu the core describes, for Win32.
//

const std = @import("std");

//
// Writes a menu label for Win32, where & starts a keyboard mnemonic, so a literal & is doubled. The caller owns the result.
//
pub fn escapeLabel(allocator: std.mem.Allocator, label: []const u8) ![]u8 {
    var escaped: std.ArrayList(u8) = .empty;
    errdefer escaped.deinit(allocator);
    for (label) |byte| {
        if (byte == '&') {
            try escaped.append(allocator, '&');
        }
        try escaped.append(allocator, byte);
    }
    return escaped.toOwnedSlice(allocator);
}
