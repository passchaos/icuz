//! In-place compaction of Arabic shaping's generated-space markers.
const std = @import("std");

pub const LAMALEF_SPACE_SUB: u21 = 0xffff;
pub const TASHKEEL_SPACE_SUB: u21 = 0xfffe;

pub fn markers(buffer: []u21, lam: bool, tashkeel: bool) usize {
    var write: usize = 0;
    var read: usize = 0;
    // Markers are rare, so most blocks are copied whole: one vector load,
    // one marker test, and one vector store per eight scalars.
    const lanes = 8;
    const V = @Vector(lanes, u32);
    const slots: []u32 = std.mem.bytesAsSlice(
        u32,
        std.mem.sliceAsBytes(buffer),
    );
    const lam_marker: V = @splat(LAMALEF_SPACE_SUB);
    const tashkeel_marker: V = @splat(TASHKEEL_SPACE_SUB);
    while (read + lanes <= buffer.len) {
        // u21 occupies four bytes, but its upper eleven representation bits
        // are padding. Mask them before comparing the storage as u32 lanes.
        const block: V = @as(V, slots[read..][0..lanes].*) & @as(V, @splat(0x1f_ffff));
        var hit = lam and @reduce(.Or, block == lam_marker);
        if (!hit and tashkeel) {
            hit = @reduce(.Or, block == tashkeel_marker);
        }
        if (!hit) {
            slots[write..][0..lanes].* = block;
            write += lanes;
            read += lanes;
            continue;
        }
        for (slots[read..][0..lanes]) |slot| {
            // Scalar reads also see the storage padding bits, so mask them
            // before comparing or publishing a value.
            const codepoint: u21 = @truncate(slot & 0x1f_ffff);
            if ((lam and codepoint == LAMALEF_SPACE_SUB) or
                (tashkeel and codepoint == TASHKEEL_SPACE_SUB))
            {
                continue;
            }
            buffer[write] = codepoint;
            write += 1;
        }
        read += lanes;
    }
    while (read < buffer.len) : (read += 1) {
        const codepoint: u21 = @truncate(slots[read] & 0x1f_ffff);
        if ((lam and codepoint == LAMALEF_SPACE_SUB) or
            (tashkeel and codepoint == TASHKEEL_SPACE_SUB))
        {
            continue;
        }
        buffer[write] = codepoint;
        write += 1;
    }
    return write;
}

test "shaping compaction ignores u21 representation padding" {
    const testing = std.testing;
    const modes = [_]struct { lam: bool, tashkeel: bool }{
        .{ .lam = true, .tashkeel = false },
        .{ .lam = false, .tashkeel = true },
        .{ .lam = true, .tashkeel = true },
    };
    for (modes) |mode| {
        for (0..24) |position| {
            var buffer = [_]u21{0x0633} ** 24;
            const expected = [_]u21{0x0633} ** 23;
            buffer[position] = if (mode.lam and (!mode.tashkeel or position % 2 == 0))
                LAMALEF_SPACE_SUB
            else
                TASHKEEL_SPACE_SUB;

            const storage = std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(&buffer));
            for (storage) |*slot| slot.* |= 0xffe0_0000;
            try testing.expectEqual(@as(usize, 23), markers(&buffer, mode.lam, mode.tashkeel));
            try testing.expectEqualSlices(u21, &expected, buffer[0..23]);
        }
    }
}
