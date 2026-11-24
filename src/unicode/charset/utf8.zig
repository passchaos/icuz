//! Vector helpers shared by the UTF-8 conversion paths: deinterleaving
//! three-byte sequences and packing BMP scalars back into UTF-8.

const std = @import("std");
const types = @import("types.zig");

const Options = types.Options;

/// Lane masks for deinterleaving a 48-byte block of sixteen three-byte
/// sequences into its lead and continuation byte vectors.
pub fn threeByteLane(comptime offset: usize) @Vector(16, i32) {
    var mask: [16]i32 = undefined;
    for (&mask, 0..) |*lane, index| lane.* = @intCast(index * 3 + offset);
    return mask;
}

/// Decode sixteen consecutive three-byte BMP sequences at `index`. Returns
/// null when the block holds anything else, so the scalar path can take over.
pub inline fn decodeThreeByteBlock(
    input: []const u8,
    index: usize,
) ?@Vector(16, u16) {
    const Lane = @Vector(16, u8);
    const chunk: @Vector(48, u8) = input[index..][0..48].*;
    const lead = @shuffle(u8, chunk, undefined, threeByteLane(0));
    const second = @shuffle(u8, chunk, undefined, threeByteLane(1));
    const third = @shuffle(u8, chunk, undefined, threeByteLane(2));
    if (!@reduce(.And, (lead >= @as(Lane, @splat(0xe0))) &
        (lead <= @as(Lane, @splat(0xef)))))
    {
        return null;
    }
    if (!@reduce(.And, (second >= @as(Lane, @splat(0x80))) &
        (second <= @as(Lane, @splat(0xbf)))))
    {
        return null;
    }
    if (!@reduce(.And, (third >= @as(Lane, @splat(0x80))) &
        (third <= @as(Lane, @splat(0xbf)))))
    {
        return null;
    }
    const Wide = @Vector(16, u16);
    const lead_wide: Wide = @intCast(lead & @as(Lane, @splat(0x0f)));
    const second_wide: Wide = @intCast(second & @as(Lane, @splat(0x3f)));
    const third_wide: Wide = @intCast(third & @as(Lane, @splat(0x3f)));
    // Multiplying by powers of two keeps the shift counts out of vector
    // operands, whose element type would be Log2Int(u16).
    const value: Wide = (lead_wide * @as(Wide, @splat(1 << 12))) |
        (second_wide * @as(Wide, @splat(1 << 6))) |
        third_wide;
    // Overlong forms and U+D800..U+DFFF must not reach the output.
    if (@reduce(.Or, value < @as(Wide, @splat(0x800)))) return null;
    if (@reduce(.Or, (value >= @as(Wide, @splat(0xd800))) &
        (value <= @as(Wide, @splat(0xdfff)))))
    {
        return null;
    }
    return value;
}

/// Interleave masks for packing sixteen BMP scalars into their UTF-8 bytes.
/// Negative lanes select from the second operand, as `@shuffle` defines.
pub fn pairLanes() @Vector(32, i32) {
    var mask: [32]i32 = undefined;
    for (0..16) |index| {
        mask[index * 2] = @intCast(index);
        mask[index * 2 + 1] = -@as(i32, @intCast(index)) - 1;
    }
    return mask;
}

pub fn tripleLanes() @Vector(48, i32) {
    var mask: [48]i32 = undefined;
    for (0..16) |index| {
        mask[index * 3] = @intCast(index * 2);
        mask[index * 3 + 1] = @intCast(index * 2 + 1);
        mask[index * 3 + 2] = -@as(i32, @intCast(index)) - 1;
    }
    return mask;
}

/// True when every lane is a BMP scalar that encodes to three UTF-8 bytes.
pub inline fn bmpThreeByteLanes(
    comptime Lane: type,
    units: @Vector(16, Lane),
) bool {
    const Wide = @Vector(16, Lane);
    return @reduce(.And, (units >= @as(Wide, @splat(0x800))) &
        (units <= @as(Wide, @splat(0xFFFF))) &
        ((units < @as(Wide, @splat(0xD800))) |
            (units > @as(Wide, @splat(0xDFFF)))));
}

/// Store sixteen three-byte sequences at `written` and return the new length.
pub inline fn storeThreeByteScalars(
    comptime Lane: type,
    spare: []u8,
    written: usize,
    units: @Vector(16, Lane),
) usize {
    const Wide = @Vector(16, Lane);
    const Shift = @Vector(16, std.math.Log2Int(Lane));
    const first: @Vector(16, u8) = @intCast(
        (units >> @as(Shift, @splat(12))) | @as(Wide, @splat(0xE0)),
    );
    const second: @Vector(16, u8) = @intCast(
        ((units >> @as(Shift, @splat(6))) & @as(Wide, @splat(0x3F))) |
            @as(Wide, @splat(0x80)),
    );
    const third: @Vector(16, u8) = @intCast(
        (units & @as(Wide, @splat(0x3F))) | @as(Wide, @splat(0x80)),
    );
    const pairs: @Vector(32, u8) = @shuffle(u8, first, second, pairLanes());
    const triples: @Vector(48, u8) = @shuffle(u8, pairs, third, tripleLanes());
    spare[written..][0..48].* = @bitCast(triples);
    return written + 48;
}

/// Write one valid scalar as UTF-8 at `written` and return the new length.
pub inline fn writeScalar(spare: []u8, written: usize, codepoint: u21) usize {
    if (codepoint < 0x80) {
        spare[written] = @intCast(codepoint);
        return written + 1;
    }
    if (codepoint < 0x800) {
        spare[written] = @intCast(0xC0 | (codepoint >> 6));
        spare[written + 1] = @intCast(0x80 | (codepoint & 0x3F));
        return written + 2;
    }
    if (codepoint < 0x10000) {
        spare[written] = @intCast(0xE0 | (codepoint >> 12));
        spare[written + 1] = @intCast(0x80 | ((codepoint >> 6) & 0x3F));
        spare[written + 2] = @intCast(0x80 | (codepoint & 0x3F));
        return written + 3;
    }
    spare[written] = @intCast(0xF0 | (codepoint >> 18));
    spare[written + 1] = @intCast(0x80 | ((codepoint >> 12) & 0x3F));
    spare[written + 2] = @intCast(0x80 | ((codepoint >> 6) & 0x3F));
    spare[written + 3] = @intCast(0x80 | (codepoint & 0x3F));
    return written + 4;
}

/// Apply the configured error mode for one malformed or incomplete unit.
/// Returns true when the caller must fail with `error.InvalidSequence`.
pub inline fn writeError(
    options: Options,
    spare: []u8,
    written: *usize,
    replacement: []const u8,
) bool {
    switch (options.on_error) {
        .strict => return true,
        .ignore => {},
        .replace => {
            @memcpy(spare[written.*..][0..replacement.len], replacement);
            written.* += replacement.len;
        },
    }
    return false;
}
