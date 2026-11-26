//! Native UTF-16 to UTF-8 conversion kernels.
const blocks = @import("../blocks.zig");
const bmp = @import("../bmp_pack.zig");
const ascii = @import("ascii_encode.zig");
const mixed_runs = @import("bmp_encode.zig");
const Error = error{InvalidUtf16};

pub inline fn convert(comptime checked: bool, units: []const u16, output: []u8) Error!usize {
    const index = if (units.len != 0 and units[0] < 0x80)
        if (units.len < 256) @call(.always_inline, ascii.prefix, .{ units, output }) else @call(.never_inline, ascii.prefix, .{ units, output })
    else
        0;
    if (index == units.len) return index;
    if (checked and units.len < 256) return index + try @call(.always_inline, general, .{ checked, units[index..], output[index..] });
    return index + try @call(.never_inline, general, .{ checked, units[index..], output[index..] });
}

/// The size pass already validated the input and handled the all-ASCII case.
pub inline fn convertValid(units: []const u16, output: []u8) Error!usize {
    return @call(.never_inline, general, .{ false, units, output });
}

fn general(comptime checked: bool, units: []const u16, output: []u8) Error!usize {
    var index: usize = 0;
    var written: usize = 0;
    input_loop: while (index < units.len) {
        const unit = units[index];
        if (unit < 0x80) {
            while (index + 32 <= units.len) {
                const v = @as(*align(2) const @Vector(32, u16), @ptrCast(units.ptr + index)).*;
                if (!@reduce(.And, v < @as(@Vector(32, u16), @splat(0x80)))) break;
                const bytes: @Vector(32, u8) = @truncate(v);
                output[written..][0..32].* = bytes;
                index += 32;
                written += 32;
            }
            while (index + 16 <= units.len) {
                const v = @as(*align(2) const @Vector(16, u16), @ptrCast(units.ptr + index)).*;
                if (!@reduce(.And, v < @as(@Vector(16, u16), @splat(0x80)))) break;
                const bytes: @Vector(16, u8) = @truncate(v);
                output[written..][0..16].* = bytes;
                index += 16;
                written += 16;
            }
            if (comptime bmp.wide_supported) {
                if (index + 16 <= units.len) {
                    const v = @as(*align(2) const @Vector(16, u16), @ptrCast(units.ptr + index)).*;
                    if (@reduce(.And, v < @as(@Vector(16, u16), @splat(0x100)))) {
                        const run = bmp.latinRun(units[index..], output, written);
                        index += run.consumed;
                        written = run.written;
                        continue;
                    }
                }
            }
            while (index < units.len and units[index] < 0x80) {
                if (comptime bmp.wide_supported) {
                    if (index + 8 <= units.len) {
                        const run = try mixed_runs.run(checked, units[index..], output, written);
                        written = run.written;
                        index += run.consumed;
                        continue :input_loop;
                    }
                }
                if (comptime bmp.supported) {
                    if (index + 4 <= units.len) {
                        const v = @as(*align(2) const @Vector(4, u16), @ptrCast(units.ptr + index)).*;
                        if (bmp.encode(output, written, v)) |next| {
                            written = next;
                            index += 4;
                            continue :input_loop;
                        }
                    }
                }
                output[written] = @intCast(units[index]);
                index += 1;
                written += 1;
            }
            continue;
        }
        if (comptime bmp.wide_supported) {
            if (unit < 0x100 and index + 16 <= units.len) {
                const v = @as(*align(2) const @Vector(16, u16), @ptrCast(units.ptr + index)).*;
                if (@reduce(.And, v < @as(@Vector(16, u16), @splat(0x100)))) {
                    const run = bmp.latinRun(units[index..], output, written);
                    index += run.consumed;
                    written = run.written;
                    continue;
                }
            }
        }
        if (unit < 0x800) {
            inline for (.{ 16, 4 }) |n| {
                if (index + n <= units.len) {
                    const v: @Vector(n, u16) = if (@import("builtin").zig_backend == .stage2_llvm)
                        @as(*align(2) const @Vector(n, u16), @ptrCast(units.ptr + index)).*
                    else
                        units[index..][0..n].*;
                    if (@reduce(.And, (v >= @as(@Vector(n, u16), @splat(0x80))) & (v < @as(@Vector(n, u16), @splat(0x800))))) {
                        written = blocks.encode2(n, output, written, v);
                        index += n;
                        continue :input_loop;
                    }
                }
            }
        } else if (unit & 0xf800 != 0xd800) {
            inline for (.{ 16, 4 }) |n| {
                if (index + n <= units.len) {
                    const v: @Vector(n, u16) = if (@import("builtin").zig_backend == .stage2_llvm)
                        @as(*align(2) const @Vector(n, u16), @ptrCast(units.ptr + index)).*
                    else
                        units[index..][0..n].*;
                    if (@reduce(.And, (v >= @as(@Vector(n, u16), @splat(0x800))) & ((v & @as(@Vector(n, u16), @splat(0xf800))) != @as(@Vector(n, u16), @splat(0xd800))))) {
                        written = blocks.encode3(u16, n, output, written, v);
                        index += n;
                        continue :input_loop;
                    }
                }
            }
        } else {
            inline for (.{ 8, 2 }) |n| {
                if (index + n * 2 <= units.len) {
                    const v: @Vector(n * 2, u16) = if (@import("builtin").zig_backend == .stage2_llvm)
                        @as(*align(2) const @Vector(n * 2, u16), @ptrCast(units.ptr + index)).*
                    else
                        units[index..][0 .. n * 2].*;
                    if (blocks.encode4(checked, n, output, written, v)) |next| {
                        written = next;
                        index += n * 2;
                        continue :input_loop;
                    }
                }
            }
        }
        if (comptime bmp.wide_supported) {
            if (index + 8 <= units.len) {
                if (unit & 0xf800 != 0xd800) {
                    const run = try mixed_runs.run(checked, units[index..], output, written);
                    written = run.written;
                    index += run.consumed;
                    continue :input_loop;
                }
            }
        }
        if (comptime bmp.supported) {
            if (index + 4 <= units.len) {
                const v = @as(*align(2) const @Vector(4, u16), @ptrCast(units.ptr + index)).*;
                if (bmp.encode(output, written, v)) |next| {
                    written = next;
                    index += 4;
                    continue :input_loop;
                }
            }
        }
        index += 1;
        if (unit & 0xf800 == 0xd800) {
            if (checked and (unit >= 0xdc00 or index == units.len or units[index] & 0xfc00 != 0xdc00)) return error.InvalidUtf16;
            const low = units[index];
            index += 1;
            written = blocks.writeSurrogatePair(output, written, unit, low);
            continue;
        }
        written = blocks.writeScalar(output, written, unit);
    }
    return written;
}
