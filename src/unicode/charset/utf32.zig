//! UTF-8 and UTF-32 conversion. ASCII runs widen or narrow sixteen scalars
//! at a time, BMP runs pack three-byte UTF-8 sequences, and the scalar path
//! handles four-byte sequences and malformed input.

const std = @import("std");
const types = @import("types.zig");
const utf8_vec = @import("utf8.zig");
const scalar = @import("../scalar/root.zig");

const Error = types.Error;
const Options = types.Options;
const native_endian = @import("builtin").target.cpu.arch.endian();

inline fn writeUtf32Scalar(
    comptime endian: std.builtin.Endian,
    spare: []u8,
    written: usize,
    codepoint: u32,
) usize {
    const value = if (endian == native_endian) codepoint else @byteSwap(codepoint);
    spare[written..][0..4].* = std.mem.toBytes(value);
    return written + 4;
}

fn utf32Replacement(options: Options) u32 {
    for ([_]u21{ options.replacement, '?', 0x1A }) |candidate| {
        if (candidate <= 0x10FFFF and
            (candidate < 0xD800 or candidate > 0xDFFF))
        {
            return candidate;
        }
    }
    return '?';
}

pub fn utf8ToUtf32Into(
    allocator: std.mem.Allocator,
    input: []const u8,
    endian: std.builtin.Endian,
    options: Options,
    output: *std.ArrayList(u8),
) Error!void {
    return switch (endian) {
        .little => utf8ToUtf32IntoEndian(.little, allocator, input, options, output),
        .big => utf8ToUtf32IntoEndian(.big, allocator, input, options, output),
    };
}

fn utf8ToUtf32IntoEndian(
    comptime endian: std.builtin.Endian,
    allocator: std.mem.Allocator,
    input: []const u8,
    options: Options,
    output: *std.ArrayList(u8),
) Error!void {
    // One input byte can become at most one four-byte scalar.
    try output.ensureUnusedCapacity(allocator, input.len * 4 + 8);
    const spare = output.unusedCapacitySlice();
    var written: usize = 0;
    const replacement_value = utf32Replacement(options);
    const encoded_replacement = if (endian == native_endian)
        replacement_value
    else
        @byteSwap(replacement_value);
    const replacement = std.mem.toBytes(encoded_replacement);
    var index: usize = 0;
    while (index < input.len) {
        if (input[index] < 0x80) {
            // Widen an ASCII run into u32 lanes.
            var end = index;
            while (end + 16 <= input.len) {
                const bytes: @Vector(16, u8) = input[end..][0..16].*;
                if (!@reduce(.And, bytes < @as(@Vector(16, u8), @splat(0x80)))) {
                    break;
                }
                var wide: @Vector(16, u32) = @intCast(bytes);
                if (endian != native_endian) wide = @byteSwap(wide);
                spare[written..][0..64].* = @bitCast(wide);
                written += 64;
                end += 16;
            }
            while (end < input.len and input[end] < 0x80) : (end += 1) {
                written = writeUtf32Scalar(endian, spare, written, input[end]);
            }
            index = end;
            continue;
        }
        // Three-byte BMP sequences decode sixteen at a time.
        if (input[index] >= 0xe0 and input[index] < 0xf0 and
            index + 48 <= input.len)
        {
            var consumed = false;
            while (index + 48 <= input.len) {
                const block = utf8_vec.decodeThreeByteBlock(input, index) orelse
                    break;
                var wide: @Vector(16, u32) = @intCast(block);
                if (endian != native_endian) wide = @byteSwap(wide);
                spare[written..][0..64].* = @bitCast(wide);
                written += 64;
                index += 48;
                consumed = true;
            }
            if (consumed) continue;
        }
        const decoded = scalar.decodeValidatingPacked(input, index);
        if (decoded == scalar.packed_invalid) {
            if (utf8_vec.writeError(options, spare, &written, &replacement)) {
                output.items.len += written;
                return error.InvalidSequence;
            }
            // A truncated tail consumes the rest; any other invalid scalar
            // consumes one byte.
            const length: usize = std.unicode.utf8ByteSequenceLength(
                input[index],
            ) catch 1;
            if (index + length > input.len) {
                index = input.len;
            } else {
                index += 1;
            }
            continue;
        }
        const codepoint = scalar.packedCodepoint(decoded);
        index += scalar.packedLength(decoded);
        written = writeUtf32Scalar(endian, spare, written, codepoint);
    }
    output.items.len += written;
}

pub fn utf8ToUtf32Alloc(
    allocator: std.mem.Allocator,
    input: []const u8,
    endian: std.builtin.Endian,
    options: Options,
) Error![]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try utf8ToUtf32Into(allocator, input, endian, options, &output);
    return output.toOwnedSlice(allocator);
}

pub fn utf32ToUtf8Into(
    allocator: std.mem.Allocator,
    input: []const u8,
    endian: std.builtin.Endian,
    options: Options,
    output: *std.ArrayList(u8),
) Error!void {
    return switch (endian) {
        .little => utf32ToUtf8IntoEndian(.little, allocator, input, options, output),
        .big => utf32ToUtf8IntoEndian(.big, allocator, input, options, output),
    };
}

fn utf32ToUtf8IntoEndian(
    comptime endian: std.builtin.Endian,
    allocator: std.mem.Allocator,
    input: []const u8,
    options: Options,
    output: *std.ArrayList(u8),
) Error!void {
    // A four-byte unit becomes at most four UTF-8 bytes; a partial unit at
    // the end becomes one replacement, which the constant slack covers.
    try output.ensureUnusedCapacity(allocator, input.len + 8);
    const spare = output.unusedCapacitySlice();
    var written: usize = 0;
    var replacement: [4]u8 = undefined;
    var replacement_len: usize = 0;
    if (options.on_error == .replace) {
        for ([_]u21{ options.replacement, '?', 0x1A }) |candidate| {
            if (std.unicode.utf8Encode(candidate, replacement[0..4])) |length| {
                replacement_len = length;
                break;
            } else |_| {}
        }
    }
    var index: usize = 0;
    while (index + 4 <= input.len) {
        const value = std.mem.readInt(u32, input[index..][0..4], endian);
        if (value < 0x80) {
            // Narrow an ASCII run from u32 lanes.
            var end = index;
            while (end + 64 <= input.len) {
                var units: @Vector(16, u32) = @bitCast(input[end..][0..64].*);
                if (endian != native_endian) units = @byteSwap(units);
                if (!@reduce(.And, units < @as(@Vector(16, u32), @splat(0x80)))) {
                    break;
                }
                const bytes: @Vector(16, u8) = @intCast(units);
                spare[written..][0..16].* = @bitCast(bytes);
                written += 16;
                end += 64;
            }
            while (end + 4 <= input.len) {
                const next = std.mem.readInt(u32, input[end..][0..4], endian);
                if (next >= 0x80) break;
                spare[written] = @intCast(next);
                written += 1;
                end += 4;
            }
            index = end;
            continue;
        }
        // BMP scalars at or above U+0800 encode to three bytes; pack sixteen
        // at a time when none is a surrogate.
        if (value >= 0x800 and value <= 0xFFFF and
            (value < 0xD800 or value > 0xDFFF))
        {
            var consumed = false;
            while (index + 64 <= input.len) {
                var units: @Vector(16, u32) = @bitCast(input[index..][0..64].*);
                if (endian != native_endian) units = @byteSwap(units);
                if (!utf8_vec.bmpThreeByteLanes(u32, units)) break;
                written = utf8_vec.storeThreeByteScalars(
                    u32,
                    spare,
                    written,
                    units,
                );
                index += 64;
                consumed = true;
            }
            if (consumed) continue;
        }
        index += 4;
        if (value > 0x10FFFF or (value >= 0xD800 and value <= 0xDFFF)) {
            if (utf8_vec.writeError(
                options,
                spare,
                &written,
                replacement[0..replacement_len],
            )) {
                output.items.len += written;
                return error.InvalidSequence;
            }
            continue;
        }
        written = utf8_vec.writeScalar(spare, written, @intCast(value));
    }
    if (index < input.len) {
        // A partial unit at the end of the input.
        if (utf8_vec.writeError(
            options,
            spare,
            &written,
            replacement[0..replacement_len],
        )) {
            output.items.len += written;
            return error.InvalidSequence;
        }
    }
    output.items.len += written;
}

pub fn utf32ToUtf8Alloc(
    allocator: std.mem.Allocator,
    input: []const u8,
    endian: std.builtin.Endian,
    options: Options,
) Error![]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try utf32ToUtf8Into(allocator, input, endian, options, &output);
    return output.toOwnedSlice(allocator);
}

/// UTF-16 to UTF-32. Every non-surrogate unit maps one-to-one, so sixteen
/// widen per step; surrogate pairs and malformed units use the scalar path.
pub fn utf16ToUtf32Into(
    allocator: std.mem.Allocator,
    input: []const u8,
    in_endian: std.builtin.Endian,
    out_endian: std.builtin.Endian,
    options: Options,
    output: *std.ArrayList(u8),
) Error!void {
    return switch (in_endian) {
        .little => switch (out_endian) {
            .little => utf16ToUtf32IntoEndian(.little, .little, allocator, input, options, output),
            .big => utf16ToUtf32IntoEndian(.little, .big, allocator, input, options, output),
        },
        .big => switch (out_endian) {
            .little => utf16ToUtf32IntoEndian(.big, .little, allocator, input, options, output),
            .big => utf16ToUtf32IntoEndian(.big, .big, allocator, input, options, output),
        },
    };
}

fn utf16ToUtf32IntoEndian(
    comptime in_endian: std.builtin.Endian,
    comptime out_endian: std.builtin.Endian,
    allocator: std.mem.Allocator,
    input: []const u8,
    options: Options,
    output: *std.ArrayList(u8),
) Error!void {
    // A unit becomes at most one four-byte scalar.
    try output.ensureUnusedCapacity(allocator, input.len * 2 + 8);
    const spare = output.unusedCapacitySlice();
    var written: usize = 0;
    const replacement_value = utf32Replacement(options);
    const encoded_replacement = if (out_endian == native_endian)
        replacement_value
    else
        @byteSwap(replacement_value);
    const replacement = std.mem.toBytes(encoded_replacement);
    var index: usize = 0;
    while (index + 2 <= input.len) {
        // Any run without surrogates widens one-to-one.
        if (index + 32 <= input.len) {
            var units: @Vector(16, u16) = @bitCast(input[index..][0..32].*);
            if (in_endian != native_endian) units = @byteSwap(units);
            const Wide = @Vector(16, u16);
            const surrogates = (units >= @as(Wide, @splat(0xD800))) &
                (units <= @as(Wide, @splat(0xDFFF)));
            if (!@reduce(.Or, surrogates)) {
                var wide: @Vector(16, u32) = @intCast(units);
                if (out_endian != native_endian) wide = @byteSwap(wide);
                spare[written..][0..64].* = @bitCast(wide);
                written += 64;
                index += 32;
                continue;
            }
        }
        const unit = std.mem.readInt(u16, input[index..][0..2], in_endian);
        index += 2;
        var codepoint: u21 = 0;
        var status: enum { ok, malformed, incomplete } = .ok;
        if (unit >= 0xD800 and unit <= 0xDBFF) {
            if (index + 2 > input.len) {
                status = .incomplete;
            } else {
                const low = std.mem.readInt(u16, input[index..][0..2], in_endian);
                if (low < 0xDC00 or low > 0xDFFF) {
                    status = .malformed;
                } else {
                    index += 2;
                    codepoint = 0x10000 +
                        (@as(u21, unit - 0xD800) << 10) + (low - 0xDC00);
                }
            }
        } else if (unit >= 0xDC00 and unit <= 0xDFFF) {
            status = .malformed;
        } else {
            codepoint = unit;
        }
        switch (status) {
            .ok => written = writeUtf32Scalar(out_endian, spare, written, codepoint),
            .malformed => if (utf8_vec.writeError(
                options,
                spare,
                &written,
                &replacement,
            )) {
                output.items.len += written;
                return error.InvalidSequence;
            },
            .incomplete => {
                if (utf8_vec.writeError(
                    options,
                    spare,
                    &written,
                    &replacement,
                )) {
                    output.items.len += written;
                    return error.InvalidSequence;
                }
                index = input.len;
                break;
            },
        }
    }
    if (index < input.len) {
        if (utf8_vec.writeError(options, spare, &written, &replacement)) {
            output.items.len += written;
            return error.InvalidSequence;
        }
    }
    output.items.len += written;
}

pub fn utf16ToUtf32Alloc(
    allocator: std.mem.Allocator,
    input: []const u8,
    in_endian: std.builtin.Endian,
    out_endian: std.builtin.Endian,
    options: Options,
) Error![]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try utf16ToUtf32Into(
        allocator,
        input,
        in_endian,
        out_endian,
        options,
        &output,
    );
    return output.toOwnedSlice(allocator);
}

/// UTF-32 to UTF-16. BMP scalars narrow sixteen per step; supplementary
/// scalars become surrogate pairs on the scalar path.
pub fn utf32ToUtf16Into(
    allocator: std.mem.Allocator,
    input: []const u8,
    in_endian: std.builtin.Endian,
    out_endian: std.builtin.Endian,
    options: Options,
    output: *std.ArrayList(u8),
) Error!void {
    return switch (in_endian) {
        .little => switch (out_endian) {
            .little => utf32ToUtf16IntoEndian(.little, .little, allocator, input, options, output),
            .big => utf32ToUtf16IntoEndian(.little, .big, allocator, input, options, output),
        },
        .big => switch (out_endian) {
            .little => utf32ToUtf16IntoEndian(.big, .little, allocator, input, options, output),
            .big => utf32ToUtf16IntoEndian(.big, .big, allocator, input, options, output),
        },
    };
}

/// Encode one replacement scalar as UTF-16 bytes for `endian`.
fn utf16ReplacementBytes(
    comptime endian: std.builtin.Endian,
    options: Options,
) struct { bytes: [4]u8, len: usize } {
    var bytes: [4]u8 = undefined;
    for ([_]u21{ options.replacement, '?', 0x1A }) |candidate| {
        if (candidate <= 0xFFFF and
            (candidate < 0xD800 or candidate > 0xDFFF))
        {
            const value: u16 = @intCast(candidate);
            bytes[0..2].* = std.mem.toBytes(
                if (endian == native_endian) value else @byteSwap(value),
            );
            return .{ .bytes = bytes, .len = 2 };
        }
        if (candidate <= 0x10FFFF) {
            const value = candidate - 0x10000;
            const high: u16 = @intCast(0xD800 + (value >> 10));
            const low: u16 = @intCast(0xDC00 + (value & 0x3FF));
            bytes[0..2].* = std.mem.toBytes(
                if (endian == native_endian) high else @byteSwap(high),
            );
            bytes[2..4].* = std.mem.toBytes(
                if (endian == native_endian) low else @byteSwap(low),
            );
            return .{ .bytes = bytes, .len = 4 };
        }
    }
    return .{ .bytes = bytes, .len = 0 };
}

fn utf32ToUtf16IntoEndian(
    comptime in_endian: std.builtin.Endian,
    comptime out_endian: std.builtin.Endian,
    allocator: std.mem.Allocator,
    input: []const u8,
    options: Options,
    output: *std.ArrayList(u8),
) Error!void {
    // A four-byte scalar becomes at most a four-byte surrogate pair.
    try output.ensureUnusedCapacity(allocator, input.len + 8);
    const spare = output.unusedCapacitySlice();
    var written: usize = 0;
    const replacement = utf16ReplacementBytes(out_endian, options);
    const replacement_len: usize = if (options.on_error == .replace)
        replacement.len
    else
        0;
    var index: usize = 0;
    while (index + 4 <= input.len) {
        if (index + 64 <= input.len) {
            var units: @Vector(16, u32) = @bitCast(input[index..][0..64].*);
            if (in_endian != native_endian) units = @byteSwap(units);
            const Wide = @Vector(16, u32);
            const bmp = (units <= @as(Wide, @splat(0xFFFF))) &
                ((units < @as(Wide, @splat(0xD800))) |
                    (units > @as(Wide, @splat(0xDFFF))));
            if (@reduce(.And, bmp)) {
                var narrow: @Vector(16, u16) = @intCast(units);
                if (out_endian != native_endian) narrow = @byteSwap(narrow);
                spare[written..][0..32].* = @bitCast(narrow);
                written += 32;
                index += 64;
                continue;
            }
        }
        const value = std.mem.readInt(u32, input[index..][0..4], in_endian);
        index += 4;
        if (value > 0x10FFFF or (value >= 0xD800 and value <= 0xDFFF)) {
            if (utf8_vec.writeError(options, spare, &written, replacement.bytes[0..replacement_len])) {
                output.items.len += written;
                return error.InvalidSequence;
            }
            continue;
        }
        if (value <= 0xFFFF) {
            const unit: u16 = @intCast(value);
            spare[written..][0..2].* = std.mem.toBytes(
                if (out_endian == native_endian) unit else @byteSwap(unit),
            );
            written += 2;
            continue;
        }
        const pair = value - 0x10000;
        const high: u16 = @intCast(0xD800 + (pair >> 10));
        const low: u16 = @intCast(0xDC00 + (pair & 0x3FF));
        spare[written..][0..2].* = std.mem.toBytes(
            if (out_endian == native_endian) high else @byteSwap(high),
        );
        spare[written + 2 ..][0..2].* = std.mem.toBytes(
            if (out_endian == native_endian) low else @byteSwap(low),
        );
        written += 4;
    }
    if (index < input.len) {
        if (utf8_vec.writeError(options, spare, &written, replacement.bytes[0..replacement_len])) {
            output.items.len += written;
            return error.InvalidSequence;
        }
    }
    output.items.len += written;
}

pub fn utf32ToUtf16Alloc(
    allocator: std.mem.Allocator,
    input: []const u8,
    in_endian: std.builtin.Endian,
    out_endian: std.builtin.Endian,
    options: Options,
) Error![]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try utf32ToUtf16Into(
        allocator,
        input,
        in_endian,
        out_endian,
        options,
        &output,
    );
    return output.toOwnedSlice(allocator);
}
