//
// The Windows parts of the splash: reading the app.zon background colour and reading the uncompressed BMP the window
// is painted with before the splash web view has loaded.
//

const std = @import("std");

//
// The red, green and blue of a splash background.
//
pub const Color = struct {
    // The red channel.
    red: u8,
    // The green channel.
    green: u8,
    // The blue channel.
    blue: u8,
};

//
// Reads a "#RRGGBB" colour. Any other text fails, so a malformed app.zon stops the app naming the value.
//
pub fn parseColor(text: []const u8) !Color {
    if (text.len != 7 or text[0] != '#') {
        return error.InvalidColor;
    }
    const value = std.fmt.parseInt(u24, text[1..], 16) catch {
        return error.InvalidColor;
    };
    return .{
        .red = @intCast((value >> 16) & 0xff),
        .green = @intCast((value >> 8) & 0xff),
        .blue = @intCast(value & 0xff),
    };
}

//
// An uncompressed BMP's size and where its pixels are in the file, which the window procedure paints from.
//
pub const Bitmap = struct {
    // The image width in pixels.
    width: i32,
    // The image height in pixels. A positive height stores the rows bottom-up, as BMP files usually do.
    height: i32,
    // Where the pixels start in the file.
    pixel_offset: usize,
    // The whole file's bytes, which the pixels and the info header are read from.
    bytes: []const u8,
};

//
// The size of a BMP file header, before the info header.
pub const file_header_size: usize = 14;

//
// The size of the info header every BMP this app writes has.
const info_header_size: usize = 40;

//
// Reads an uncompressed 24 or 32 bit BMP. Any other file fails, naming what is wrong with it.
//
pub fn bitmap(bytes: []const u8) !Bitmap {
    if (bytes.len < file_header_size + info_header_size) {
        return error.BitmapTooShort;
    }
    if (bytes[0] != 'B' or bytes[1] != 'M') {
        return error.BitmapNotBmp;
    }
    const pixel_offset = readU32(bytes, 10);
    if (readU32(bytes, file_header_size) < info_header_size) {
        return error.BitmapInfoHeaderTooShort;
    }
    const width = readI32(bytes, 18);
    if (width <= 0) {
        return error.BitmapInvalidWidth;
    }
    const height = readI32(bytes, 22);
    if (height == 0) {
        return error.BitmapInvalidHeight;
    }
    const bits_per_pixel = readU16(bytes, 28);
    if (bits_per_pixel != 24 and bits_per_pixel != 32) {
        return error.BitmapUnsupportedDepth;
    }
    if (readU32(bytes, 30) != 0) {
        return error.BitmapCompressed;
    }
    if (pixel_offset < file_header_size + info_header_size or pixel_offset >= bytes.len) {
        return error.BitmapPixelsOutsideFile;
    }
    return .{
        .width = width,
        .height = height,
        .pixel_offset = pixel_offset,
        .bytes = bytes,
    };
}

fn readU16(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .little);
}

fn readU32(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

fn readI32(bytes: []const u8, offset: usize) i32 {
    return @bitCast(readU32(bytes, offset));
}
