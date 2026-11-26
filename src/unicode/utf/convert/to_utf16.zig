//! UTF-8 to native UTF-16 conversion kernels.
const scalar = @import("../../scalar/root.zig");
const blocks = @import("../blocks.zig");
const ascii = @import("../../scalar/validation/scalar.zig");
const Error = error{InvalidUtf8};

pub fn convert(comptime checked: bool, text: []const u8, output: []u16) Error!usize {
    var index: usize = 0;
    var written: usize = 0;
    input_loop: while (index < text.len) {
        if (text[index] < 0x80) {
            while (index + 32 <= text.len) {
                const bytes = @as(*align(1) const @Vector(32, u8), @ptrCast(text.ptr + index)).*;
                if (!@reduce(.And, bytes < @as(@Vector(32, u8), @splat(0x80)))) break;
                const wide: @Vector(32, u16) = @intCast(bytes);
                output[written..][0..32].* = wide;
                index += 32;
                written += 32;
            }
            while (index + 16 <= text.len) {
                const bytes = @as(*align(1) const @Vector(16, u8), @ptrCast(text.ptr + index)).*;
                if (!@reduce(.And, bytes < @as(@Vector(16, u8), @splat(0x80)))) break;
                const wide: @Vector(16, u16) = @intCast(bytes);
                output[written..][0..16].* = wide;
                index += 16;
                written += 16;
            }
            const end = index + ascii.asciiSpanWords(text[index..]);
            inline for (.{ 8, 4 }) |n| {
                while (index + n <= end) {
                    const bytes: @Vector(n, u8) = if (@import("builtin").zig_backend == .stage2_llvm)
                        @as(*align(1) const @Vector(n, u8), @ptrCast(text.ptr + index)).*
                    else
                        text[index..][0..n].*;
                    const wide: @Vector(n, u16) = @intCast(bytes);
                    output[written..][0..n].* = wide;
                    index += n;
                    written += n;
                }
            }
            while (index < end) {
                output[written] = text[index];
                index += 1;
                written += 1;
            }
            continue;
        }
        if (text[index] >= 0xc2 and text[index] < 0xe0 and
            index + 2 < text.len and text[index + 2] >= 0xc2 and text[index + 2] < 0xe0)
        {
            inline for (.{ 16, 4, 2 }) |n| {
                if (index + n * 2 <= text.len and text[index + (n - 1) * 2] >= 0xc2 and text[index + (n - 1) * 2] < 0xe0) {
                    if (blocks.decode2(checked, n, text, index)) |wide| {
                        output[written..][0..n].* = wide;
                        index += n * 2;
                        written += n;
                        continue :input_loop;
                    }
                }
            }
        } else if (text[index] >= 0xe0 and text[index] < 0xf0 and
            index + 3 < text.len and text[index + 3] >= 0xe0 and text[index + 3] < 0xf0)
        {
            inline for (.{ 16, 4, 2 }) |n| {
                if (index + n * 3 <= text.len and text[index + (n - 1) * 3] >= 0xe0 and text[index + (n - 1) * 3] < 0xf0) {
                    if (blocks.decode3(checked, n, text, index)) |wide| {
                        output[written..][0..n].* = wide;
                        index += n * 3;
                        written += n;
                        continue :input_loop;
                    }
                }
            }
        } else if (text[index] >= 0xf0 and text[index] <= 0xf4) {
            inline for (.{ 8, 2 }) |n| {
                if (index + n * 4 <= text.len) {
                    if (blocks.decode4(checked, n, text, index)) |wide| {
                        output[written..][0 .. n * 2].* = wide;
                        index += n * 4;
                        written += n * 2;
                        continue :input_loop;
                    }
                }
            }
        }
        const first = text[index];
        if (first >= 0xc2 and first < 0xe0) {
            if (index + 2 > text.len) return error.InvalidUtf8;
            const second = text[index + 1];
            if (checked and second & 0xc0 != 0x80) return error.InvalidUtf8;
            output[written] = (@as(u16, first & 0x1f) << 6) | (second & 0x3f);
            index += 2;
            written += 1;
            continue;
        }
        if (first >= 0xe0 and first < 0xf0) {
            if (index + 3 > text.len) return error.InvalidUtf8;
            const second = text[index + 1];
            const third = text[index + 2];
            if (checked and (second & 0xc0 != 0x80 or third & 0xc0 != 0x80 or
                (first == 0xe0 and second < 0xa0) or (first == 0xed and second >= 0xa0))) return error.InvalidUtf8;
            output[written] = (@as(u16, first & 0x0f) << 12) | (@as(u16, second & 0x3f) << 6) | (third & 0x3f);
            index += 3;
            written += 1;
            continue;
        }
        const value = if (checked) scalar.decodeValidatingPacked(text, index) else scalar.decodeValidPacked(text, index);
        if (value == scalar.packed_invalid) return error.InvalidUtf8;
        const cp = scalar.packedCodepoint(value);
        index += scalar.packedLength(value);
        if (cp <= 0xffff) {
            output[written] = @intCast(cp);
            written += 1;
        } else {
            const n = cp - 0x10000;
            output[written] = @intCast(0xd800 | (n >> 10));
            output[written + 1] = @intCast(0xdc00 | (n & 0x3ff));
            written += 2;
        }
    }
    return written;
}
