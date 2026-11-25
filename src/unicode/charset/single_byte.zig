//! Direct single-byte to UTF-8 and back. The generic converter dispatches
//! through decoder and encoder structs and appends one scalar at a time; a
//! resolved table view plus a reserved output region avoids both.

const std = @import("std");
const types = @import("types.zig");
const tables = @import("tables.zig");
const utf8_vec = @import("utf8.zig");
const scalar = @import("../scalar/root.zig");

const Error = types.Error;
const Options = types.Options;

pub const Kind = union(enum) {
    /// ASCII: bytes above 0x7F are malformed.
    ascii_identity,
    /// Latin-1: every byte is its own scalar.
    latin1_identity,
    /// x-user-defined: 0x80..0xFF map to U+F780..U+F7FF.
    user_defined,
    /// A 128-entry table covering 0x80..0xFF; lower bytes are identity.
    table: usize,
    /// An IBM page covering all 256 bytes.
    ibm_page: usize,
};

/// UTF-8 bytes for every non-ASCII byte of each 128-entry table, with the
/// encoded length in the fourth lane (zero marks an unmapped byte). Decoding a
/// byte then costs one four-byte load and one store instead of a codepoint
/// lookup plus a length ladder.
const expanded_tables = blk: {
    @setEvalBranchQuota(200_000);
    var list: [28][128][4]u8 = undefined;
    for (0..28) |table_index| {
        for (0..128) |offset| {
            const byte: u8 = @intCast(0x80 + offset);
            const codepoint = tables.singleByteForward(table_index, byte) orelse {
                list[table_index][offset] = .{ 0, 0, 0, 0 };
                continue;
            };
            var buffer: [4]u8 = undefined;
            const length = std.unicode.utf8Encode(codepoint, &buffer) catch 0;
            list[table_index][offset] = .{
                buffer[0],
                buffer[1],
                buffer[2],
                @intCast(length),
            };
        }
    }
    break :blk list;
};

inline fn decodeByte(
    kind: Kind,
    forward: ?tables.SingleByteForwardTable,
    byte: u8,
) ?u21 {
    return switch (kind) {
        .ascii_identity => if (byte < 0x80) byte else null,
        .latin1_identity => byte,
        .user_defined => if (byte < 0x80)
            byte
        else
            @as(u21, 0xF780) + byte - 0x80,
        .table => |table_index| if (byte < 0x80)
            byte
        else if (forward) |view|
            view.get(byte)
        else
            tables.singleByteForward(table_index, byte),
        .ibm_page => |page| tables.ibmForward(page, byte),
    };
}

pub fn decodeInto(
    allocator: std.mem.Allocator,
    input: []const u8,
    kind: Kind,
    options: Options,
    output: *std.ArrayList(u8),
) Error!void {
    // U+F780..U+F7FF are the widest results, at three UTF-8 bytes.
    try output.ensureUnusedCapacity(allocator, input.len * 3 + 8);
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
    // Every kind except IBM pages keeps ASCII bytes unchanged.
    const ascii_runs = switch (kind) {
        .ibm_page => false,
        else => true,
    };
    const forward: ?tables.SingleByteForwardTable = switch (kind) {
        .table => |table_index| tables.singleByteForwardView(table_index),
        else => null,
    };
    const expanded: ?*const [128][4]u8 = switch (kind) {
        .table => |table_index| if (table_index < expanded_tables.len)
            &expanded_tables[table_index]
        else
            null,
        else => null,
    };
    var index: usize = 0;
    while (index < input.len) {
        if (ascii_runs and input[index] < 0x80) {
            var end = index;
            // Real prose interleaves short ASCII runs with accented scalars,
            // so eight-byte words keep the scan cheap for both short and long
            // runs.
            while (end + 8 <= input.len) {
                const word = std.mem.readInt(u64, input[end..][0..8], .little);
                if (word & 0x8080_8080_8080_8080 != 0) break;
                end += 8;
            }
            while (end < input.len and input[end] < 0x80) end += 1;
            const count = end - index;
            @memcpy(spare[written..][0..count], input[index..][0..count]);
            written += count;
            index = end;
            continue;
        }
        const byte = input[index];
        index += 1;
        if (expanded) |table| {
            const entry = table[byte - 0x80];
            const length = entry[3];
            if (length != 0) {
                spare[written..][0..4].* = entry;
                written += length;
                continue;
            }
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
        const codepoint = decodeByte(kind, forward, byte) orelse {
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
        };
        written = utf8_vec.writeScalar(spare, written, codepoint);
    }
    output.items.len += written;
}

pub fn decodeAlloc(
    allocator: std.mem.Allocator,
    input: []const u8,
    kind: Kind,
    options: Options,
) Error![]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try decodeInto(allocator, input, kind, options, &output);
    return output.toOwnedSlice(allocator);
}

const EncodeKind = union(enum) {
    ascii_identity,
    latin1_identity,
    user_defined,
    table: tables.SingleByteTable,
};

fn resolveEncodeKind(kind: Kind) ?EncodeKind {
    return switch (kind) {
        .ascii_identity => .ascii_identity,
        .latin1_identity => .latin1_identity,
        .user_defined => .user_defined,
        .table => |table_index| .{
            .table = tables.singleByteTableView(table_index) orelse return null,
        },
        // IBM pages would need a linear reverse scan per scalar.
        .ibm_page => null,
    };
}

inline fn encodeScalar(kind: EncodeKind, codepoint: u21) ?u8 {
    return switch (kind) {
        .ascii_identity => if (codepoint < 0x80) @intCast(codepoint) else null,
        .latin1_identity => if (codepoint <= 0xFF) @intCast(codepoint) else null,
        .user_defined => if (codepoint < 0x80)
            @intCast(codepoint)
        else if (codepoint >= 0xF780 and codepoint <= 0xF7FF)
            @intCast(0x80 + codepoint - 0xF780)
        else
            null,
        .table => |view| if (codepoint < 0x80)
            @intCast(codepoint)
        else
            view.reverse(codepoint),
    };
}

pub fn encodeInto(
    allocator: std.mem.Allocator,
    input: []const u8,
    kind: Kind,
    options: Options,
    output: *std.ArrayList(u8),
) Error!void {
    const resolved = resolveEncodeKind(kind) orelse {
        return error.UnmappableCharacter;
    };
    // Every scalar becomes one byte, replacements included.
    try output.ensureUnusedCapacity(allocator, input.len + 8);
    const spare = output.unusedCapacitySlice();
    var written: usize = 0;
    var replacement: u8 = 0x1A;
    if (options.on_error == .replace) {
        for ([_]u21{ options.replacement, '?', 0x1A }) |candidate| {
            if (encodeScalar(resolved, candidate)) |byte| {
                replacement = byte;
                break;
            }
        }
    }
    // Real text repeats scalars, so a tiny direct-mapped cache turns most
    // reverse lookups into two loads.
    const cached = switch (resolved) {
        .table => true,
        else => false,
    };
    var cache_keys: [64]u32 = @splat(0xFFFF_FFFF);
    var cache_values: [64]u8 = undefined;
    var index: usize = 0;
    while (index < input.len) {
        if (input[index] < 0x80) {
            var end = index;
            while (end + 32 <= input.len) {
                const chunk: @Vector(32, u8) = input[end..][0..32].*;
                if (@reduce(.Or, chunk >= @as(@Vector(32, u8), @splat(0x80)))) {
                    break;
                }
                end += 32;
            }
            // Locate the first high-bit byte directly: short accented-prose
            // runs would otherwise pay the byte-at-a-time tail after the
            // vector test already found the boundary in the same word.
            while (end + 8 <= input.len) {
                const word = std.mem.readInt(u64, input[end..][0..8], .little);
                const high = word & 0x8080_8080_8080_8080;
                if (high != 0) {
                    end += @ctz(high) / 8;
                    break;
                }
                end += 8;
            }
            while (end < input.len and input[end] < 0x80) end += 1;
            const count = end - index;
            @memcpy(spare[written..][0..count], input[index..][0..count]);
            written += count;
            index = end;
            continue;
        }
        const decoded = scalar.decodeValidatingPacked(input, index);
        if (decoded == scalar.packed_invalid) {
            if (options.on_error == .strict) {
                output.items.len += written;
                return error.InvalidSequence;
            }
            if (options.on_error == .replace) {
                spare[written] = replacement;
                written += 1;
            }
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
        const byte = blk: {
            if (cached) {
                const slot = codepoint & 63;
                if (cache_keys[slot] == codepoint) break :blk cache_values[slot];
            }
            const value = encodeScalar(resolved, codepoint) orelse break :blk null;
            if (cached) {
                cache_keys[codepoint & 63] = codepoint;
                cache_values[codepoint & 63] = value;
            }
            break :blk value;
        } orelse {
            switch (options.on_error) {
                .strict => {
                    output.items.len += written;
                    return error.UnmappableCharacter;
                },
                .ignore => {},
                .replace => {
                    spare[written] = replacement;
                    written += 1;
                },
            }
            continue;
        };
        spare[written] = byte;
        written += 1;
    }
    output.items.len += written;
}

pub fn encodeAlloc(
    allocator: std.mem.Allocator,
    input: []const u8,
    kind: Kind,
    options: Options,
) Error![]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try encodeInto(allocator, input, kind, options, &output);
    return output.toOwnedSlice(allocator);
}
