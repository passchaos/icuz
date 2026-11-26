//! Generated bounded UTF-8 width layouts; adaptive windows follow simdutf's design.
//! See licenses/simdutf-MIT.txt for the reference implementation's license.
pub const B = @Vector(16, u8);
pub const Entry = struct { control: u16, consumed: u8, units: u8 };
pub const Control = struct { shuffle: B align(64), bits: B, units_shuffle: B };
pub const index = makeIndex();
pub const controls = makeControls();

fn makeIndex() [4096]Entry {
    @setEvalBranchQuota(100000);
    var result = [_]Entry{.{ .control = 511, .consumed = 0, .units = 0 }} ** 4096;
    for (0..4096) |key| {
        var remaining: u16 = @intCast(key);
        var widths = [_]usize{0} ** 6;
        var ends = [_]usize{0} ** 6;
        var count: usize = 0;
        var position: usize = 0;
        while (remaining != 0 and count < 6) {
            const end = @as(usize, @ctz(remaining)) + 1;
            const width = end - position;
            if (width > 4) break;
            widths[count] = width;
            ends[count] = end;
            count += 1;
            position = end;
            remaining &= remaining - 1;
        }
        if (count == 6) {
            var latin = true;
            for (widths) |width| latin = latin and width <= 2;
            if (latin) {
                var code: usize = 320;
                for (0..6) |lane| code += (widths[lane] - 1) << @intCast(lane);
                result[key] = .{ .control = @intCast(code), .consumed = @intCast(ends[5]), .units = 6 };
                continue;
            }
        }
        const lanes: usize = if (count >= 4) 4 else if (count == 3) 3 else continue;
        var code: usize = if (lanes == 4) 0 else 256;
        var units = lanes;
        for (0..lanes) |lane| code += (widths[lane] - 1) << @intCast(lane * 2);
        for (widths[0..lanes]) |width| units += @intFromBool(width == 4);
        result[key] = .{ .control = @intCast(code), .consumed = @intCast(ends[lanes - 1]), .units = @intCast(units) };
    }
    return result;
}

fn makeControls() [384]Control {
    @setEvalBranchQuota(20000);
    var result: [384]Control = undefined;
    for (0..384) |code| {
        if (code >= 320) {
            var shuffle = [_]u8{0x80} ** 16;
            var bits = [_]u8{0} ** 16;
            var position: usize = 0;
            for (0..6) |lane| {
                const wide = ((code - 320) >> @intCast(lane)) & 1 != 0;
                shuffle[lane * 2] = @intCast(position + @intFromBool(wide));
                shuffle[lane * 2 + 1] = if (wide) @intCast(position) else 0x80;
                bits[lane * 2] = 0x7f;
                bits[lane * 2 + 1] = 0x1f;
                position += if (wide) @as(usize, 2) else 1;
            }
            result[code] = .{ .shuffle = shuffle, .bits = bits, .units_shuffle = @splat(0x80) };
            continue;
        }
        const lanes: usize = if (code < 256) 4 else 3;
        const widths = if (code < 256) code else code - 256;
        var shuffle = [_]u8{0x80} ** 16;
        var bits = [_]u8{0} ** 16;
        var output = [_]u8{0x80} ** 16;
        var position: usize = 0;
        var written: usize = 0;
        for (0..lanes) |lane| {
            const width = 1 + ((widths >> @intCast(lane * 2)) & 3);
            for (0..width) |byte| {
                shuffle[lane * 4 + byte] = @intCast(position + width - byte - 1);
                bits[lane * 4 + byte] = if (byte + 1 < width) 0x3f else switch (width) {
                    1 => 0x7f,
                    2 => 0x1f,
                    3 => 0x0f,
                    4 => 0x07,
                    else => unreachable,
                };
            }
            const bytes: usize = if (width == 4) 4 else 2;
            for (0..bytes) |byte| output[written + byte] = @intCast(lane * 4 + byte);
            written += bytes;
            position += width;
        }
        result[code] = .{ .shuffle = shuffle, .bits = bits, .units_shuffle = output };
    }
    return result;
}
