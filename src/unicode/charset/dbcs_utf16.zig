//! Direct DBCS to UTF-16 and back for valid input. Invalid sequences return
//! false without touching the output, so the generic converter can apply the
//! configured error mode.

const std = @import("std");
const types = @import("types.zig");

const DecodeResult = types.DecodeResult;
const native_endian = @import("builtin").target.cpu.arch.endian();

inline fn writeUnit(
    comptime endian: std.builtin.Endian,
    spare: []u8,
    written: usize,
    unit: u16,
) usize {
    spare[written..][0..2].* = std.mem.toBytes(
        if (endian == native_endian) unit else @byteSwap(unit),
    );
    return written + 2;
}

pub fn dbcsToUtf16Into(
    comptime decode: fn ([]const u8, *usize) DecodeResult,
    comptime endian: std.builtin.Endian,
    allocator: std.mem.Allocator,
    input: []const u8,
    output: *std.ArrayList(u8),
) error{OutOfMemory}!bool {
    // Two UTF-16 bytes per input byte covers a one-byte DBCS value and a
    // four-byte GB18030 sequence mapping to a surrogate pair.
    try output.ensureUnusedCapacity(allocator, input.len * 2 + 8);
    const spare = output.unusedCapacitySlice();
    var index: usize = 0;
    var written: usize = 0;
    while (index < input.len) {
        switch (@call(.always_inline, decode, .{ input, &index })) {
            .end => break,
            .codepoint => |codepoint| {
                if (codepoint >= 0xD800 and codepoint <= 0xDFFF) return false;
                if (codepoint < 0x10000) {
                    written = writeUnit(
                        endian,
                        spare,
                        written,
                        @intCast(codepoint),
                    );
                    continue;
                }
                const value = codepoint - 0x10000;
                written = writeUnit(
                    endian,
                    spare,
                    written,
                    @intCast(0xD800 + (value >> 10)),
                );
                written = writeUnit(
                    endian,
                    spare,
                    written,
                    @intCast(0xDC00 + (value & 0x3FF)),
                );
            },
            .malformed, .incomplete => return false,
        }
    }
    output.items.len += written;
    return true;
}

pub fn utf16ToDbcsInto(
    comptime encode: fn (u21, *[4]u8) u8,
    comptime endian: std.builtin.Endian,
    allocator: std.mem.Allocator,
    input: []const u8,
    output: *std.ArrayList(u8),
) error{OutOfMemory}!bool {
    // A BMP unit becomes at most two DBCS bytes; a surrogate pair becomes
    // four, so the input length bounds the output.
    try output.ensureUnusedCapacity(allocator, input.len + 8);
    const spare = output.unusedCapacitySlice();
    var index: usize = 0;
    var written: usize = 0;
    while (index + 2 <= input.len) {
        const unit = std.mem.readInt(u16, input[index..][0..2], endian);
        index += 2;
        var codepoint: u21 = unit;
        if (unit >= 0xD800 and unit <= 0xDBFF) {
            if (index + 2 > input.len) return false;
            const low = std.mem.readInt(u16, input[index..][0..2], endian);
            if (low < 0xDC00 or low > 0xDFFF) return false;
            index += 2;
            codepoint = 0x10000 +
                (@as(u21, unit - 0xD800) << 10) + (low - 0xDC00);
        } else if (unit >= 0xDC00 and unit <= 0xDFFF) {
            return false;
        }
        var buffer: [4]u8 = undefined;
        const length = @call(.always_inline, encode, .{ codepoint, &buffer });
        if (length == 0) return false;
        switch (length) {
            1 => spare[written] = buffer[0],
            2 => {
                spare[written] = buffer[0];
                spare[written + 1] = buffer[1];
            },
            3 => {
                spare[written] = buffer[0];
                spare[written + 1] = buffer[1];
                spare[written + 2] = buffer[2];
            },
            4 => {
                spare[written] = buffer[0];
                spare[written + 1] = buffer[1];
                spare[written + 2] = buffer[2];
                spare[written + 3] = buffer[3];
            },
            else => return false,
        }
        written += length;
    }
    if (index < input.len) return false;
    output.items.len += written;
    return true;
}
