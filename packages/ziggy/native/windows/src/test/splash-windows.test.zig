//
// The Windows splash helpers: the app.zon colour and the uncompressed BMP the window is painted with.
//

const std = @import("std");
const splash_windows = @import("../lib/splash-windows.zig");

//
// A BMP file whose 54 byte header is followed by a few bytes of pixels.
//
fn bitmapFile(width: i32, height: i32, bits_per_pixel: u16, compression: u32) [70]u8 {
    var header = [_]u8{0} ** 70;
    header[0] = 'B';
    header[1] = 'M';
    std.mem.writeInt(u32, header[10..14], 54, .little);
    std.mem.writeInt(u32, header[14..18], 40, .little);
    std.mem.writeInt(i32, header[18..22], width, .little);
    std.mem.writeInt(i32, header[22..26], height, .little);
    std.mem.writeInt(u16, header[26..28], 1, .little);
    std.mem.writeInt(u16, header[28..30], bits_per_pixel, .little);
    std.mem.writeInt(u32, header[30..34], compression, .little);
    return header;
}

test "a six digit hex colour is read" {
    try std.testing.expectEqual(splash_windows.Color{ .red = 0x14, .green = 0x0A, .blue = 0x24 }, try splash_windows.parseColor("#140A24"));
}

test "a colour that is not #RRGGBB is rejected" {
    try std.testing.expectError(error.InvalidColor, splash_windows.parseColor("140A24"));
    try std.testing.expectError(error.InvalidColor, splash_windows.parseColor("#140A2"));
    try std.testing.expectError(error.InvalidColor, splash_windows.parseColor("#140A2G"));
    try std.testing.expectError(error.InvalidColor, splash_windows.parseColor(""));
}

test "a BMP's size, pixel offset and bytes are read" {
    const header = bitmapFile(4, 3, 24, 0);
    const parsed = try splash_windows.bitmap(&header);
    try std.testing.expectEqual(@as(i32, 4), parsed.width);
    try std.testing.expectEqual(@as(i32, 3), parsed.height);
    try std.testing.expectEqual(@as(usize, 54), parsed.pixel_offset);
    try std.testing.expectEqual(@as(usize, 70), parsed.bytes.len);
}

test "a 32 bit BMP is read too" {
    const header = bitmapFile(8, 8, 32, 0);
    const parsed = try splash_windows.bitmap(&header);
    try std.testing.expectEqual(@as(i32, 8), parsed.width);
}

test "a truncated BMP is rejected" {
    const header = bitmapFile(4, 3, 24, 0);
    try std.testing.expectError(error.BitmapTooShort, splash_windows.bitmap(header[0..40]));
}

test "a file that is not a BMP is rejected" {
    var header = bitmapFile(4, 3, 24, 0);
    header[0] = 'X';
    try std.testing.expectError(error.BitmapNotBmp, splash_windows.bitmap(&header));
}

test "an unsupported colour depth is rejected" {
    const header = bitmapFile(4, 3, 16, 0);
    try std.testing.expectError(error.BitmapUnsupportedDepth, splash_windows.bitmap(&header));
}

test "a compressed BMP is rejected" {
    const header = bitmapFile(4, 3, 24, 1);
    try std.testing.expectError(error.BitmapCompressed, splash_windows.bitmap(&header));
}

test "an image with no width is rejected" {
    const header = bitmapFile(0, 3, 24, 0);
    try std.testing.expectError(error.BitmapInvalidWidth, splash_windows.bitmap(&header));
}
