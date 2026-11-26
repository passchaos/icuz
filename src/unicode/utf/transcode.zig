//! Strict conversion into native-endian UTF-16 and UTF-8 buffers.
const std = @import("std");
const scalar = @import("../scalar/root.zig");
const validation = @import("validate16.zig");
const toUtf16 = @import("convert/to_utf16.zig").convert;
const toUtf8 = @import("convert/to_utf8.zig").convert;
pub const Error = error{ InvalidUtf8, InvalidUtf16, OutOfMemory };

/// Append converted UTF-8. Invalid input and allocation failure leave the
/// existing contents unchanged. Capacity can be reused between calls.
pub fn utf8ToUtf16Into(allocator: std.mem.Allocator, text: []const u8, output: *std.ArrayList(u16)) Error!void {
    var validated = false;
    if (output.capacity - output.items.len < text.len) {
        if (!scalar.validate.isValid(text)) return error.InvalidUtf8;
        validated = true;
        try output.ensureUnusedCapacity(allocator, utf16SizeValid(text));
    }
    const count = if (validated) try toUtf16(false, text, output.unusedCapacitySlice()) else try toUtf16(true, text, output.unusedCapacitySlice());
    output.items.len += count;
}

/// Append converted native-endian UTF-16, preserving contents on error.
pub fn utf16ToUtf8Into(allocator: std.mem.Allocator, units: []const u16, output: *std.ArrayList(u8)) Error!void {
    var validated = false;
    const maximum = std.math.mul(usize, units.len, 3) catch return error.OutOfMemory;
    if (output.capacity - output.items.len < maximum) {
        const size = validation.utf8Size(units) orelse return error.InvalidUtf16;
        validated = true;
        try output.ensureUnusedCapacity(allocator, size);
    }
    const count = if (validated) try toUtf8(false, units, output.unusedCapacitySlice()) else try toUtf8(true, units, output.unusedCapacitySlice());
    output.items.len += count;
}

pub fn utf8ToUtf16Alloc(allocator: std.mem.Allocator, text: []const u8) Error![]u16 {
    if (!scalar.validate.isValid(text)) return error.InvalidUtf8;
    const output = try allocator.alloc(u16, utf16SizeValid(text));
    errdefer allocator.free(output);
    const count = try toUtf16(false, text, output);
    std.debug.assert(count == output.len);
    return output;
}

pub fn utf16ToUtf8Alloc(allocator: std.mem.Allocator, units: []const u16) Error![]u8 {
    const size = validation.utf8Size(units) orelse return error.InvalidUtf16;
    const output = try allocator.alloc(u8, size);
    errdefer allocator.free(output);
    const count = try toUtf8(false, units, output);
    std.debug.assert(count == output.len);
    return output;
}

fn utf16SizeValid(text: []const u8) usize {
    var count = text.len;
    var offset: usize = 0;
    const V = @Vector(32, u8);
    while (offset + 32 <= text.len) : (offset += 32) {
        const v = @as(*align(1) const V, @ptrCast(text.ptr + offset)).*;
        const cont: u32 = @bitCast((v & @as(V, @splat(0xc0))) == @as(V, @splat(0x80)));
        const four: u32 = @bitCast(v >= @as(V, @splat(0xf0)));
        count = count - @popCount(cont) + @popCount(four);
    }
    for (text[offset..]) |byte| {
        if (byte & 0xc0 == 0x80) count -= 1;
        if (byte >= 0xf0) count += 1;
    }
    return count;
}
