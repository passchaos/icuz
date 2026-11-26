//! Differential and boundary tests for the public UTF-8 validator.

const std = @import("std");
const isValid = @import("../validate.zig").isValid;
const portable = @import("vector.zig").isValid;
const scalarValid = @import("scalar.zig").scalarValid;

fn expectSame(text: []const u8) !void {
    const expected = std.unicode.utf8ValidateSlice(text);
    const actual = isValid(text);
    if (expected != actual or expected != portable(text) or expected != scalarValid(text)) {
        std.debug.print("validation mismatch for {any}\n", .{text});
        return error.TestUnexpectedResult;
    }
}

test "vector validation matches the scalar validator" {
    // Every one- and two-byte string.
    var two: [2]u8 = undefined;
    for (0..256) |first| {
        two[0] = @intCast(first);
        try expectSame(two[0..1]);
        for (0..256) |second| {
            two[1] = @intCast(second);
            try expectSame(two[0..2]);
        }
    }

    // Every three-byte string.
    var three: [3]u8 = undefined;
    for (0..256) |first| {
        three[0] = @intCast(first);
        for (0..256) |second| {
            three[1] = @intCast(second);
            for (0..256) |third| {
                three[2] = @intCast(third);
                try expectSame(three[0..3]);
            }
        }
    }

    // Every four-byte string with the lead and second byte varying and the
    // continuation bytes sampled around the range edges.
    var four: [4]u8 = undefined;
    const third_values = [_]u8{ 0x00, 0x7f, 0x80, 0x9f, 0xbf, 0xc0, 0xff };
    for (0..256) |first| {
        four[0] = @intCast(first);
        for (0..256) |second| {
            four[1] = @intCast(second);
            for (third_values) |third| {
                four[2] = third;
                for (third_values) |fourth| {
                    four[3] = fourth;
                    try expectSame(four[0..4]);
                }
            }
        }
    }
}

test "vector validation accepts long two-byte text" {
    const testing = std.testing;
    var buffer: [512]u8 = undefined;
    // A mix of ASCII and two-byte sequences drives the window scan's
    // two-byte-only branch.
    const unit = "a\u{00e9}\u{00f6}\u{00fc} b\u{00e5}";
    var length: usize = 0;
    while (length + unit.len <= buffer.len) {
        @memcpy(buffer[length..][0..unit.len], unit);
        length += unit.len;
    }
    try testing.expect(isValid(buffer[0..length]));
    try testing.expect(std.unicode.utf8ValidateSlice(buffer[0..length]));

    // A truncated sequence at the end must fail.
    buffer[length] = 0xc3;
    try testing.expect(!isValid(buffer[0 .. length + 1]));

    // Overlong two-byte leads and non-lead high bytes must fail inside the
    // window scan as well.
    buffer[length] = 'a';
    for ([_]u8{ 0xc0, 0xc1, 0xf8, 0xff }) |bad| {
        buffer[100] = bad;
        try testing.expect(!isValid(buffer[0 .. length + 1]));
    }
}

test "vector validation accepts long three-byte text" {
    const testing = std.testing;
    var buffer: [320]u8 = undefined;
    const cjk = "\u{4e16}";
    var length: usize = 0;
    while (length + 3 <= 300) : (length += 3) {
        @memcpy(buffer[length..][0..3], cjk);
    }
    try testing.expect(isValid(buffer[0..length]));
    try testing.expect(std.unicode.utf8ValidateSlice(buffer[0..length]));

    // A surrogate and an overlong three-byte sequence must fail even though
    // the window has no four-byte lead.
    const at = 99;
    buffer[at] = 0xed;
    buffer[at + 1] = 0xa0;
    buffer[at + 2] = 0x80;
    try testing.expect(!isValid(buffer[0..length]));
    try testing.expect(!std.unicode.utf8ValidateSlice(buffer[0..length]));

    buffer[at] = 0xe0;
    buffer[at + 1] = 0x80;
    buffer[at + 2] = 0x80;
    try testing.expect(!isValid(buffer[0..length]));
    try testing.expect(!std.unicode.utf8ValidateSlice(buffer[0..length]));

    // The lowest valid three-byte scalar must pass.
    buffer[at] = 0xe0;
    buffer[at + 1] = 0xa0;
    buffer[at + 2] = 0x80;
    try testing.expect(isValid(buffer[0..length]));
    try testing.expect(std.unicode.utf8ValidateSlice(buffer[0..length]));

    // A trailing four-byte scalar keeps the general path working alongside
    // the three-byte windows.
    buffer[length] = 0xf0;
    buffer[length + 1] = 0x9f;
    buffer[length + 2] = 0x98;
    buffer[length + 3] = 0x80;
    try testing.expect(isValid(buffer[0 .. length + 4]));
    try testing.expect(std.unicode.utf8ValidateSlice(buffer[0 .. length + 4]));
}

test "vector validation checks the overlapping tail window" {
    const testing = std.testing;
    // The tail path re-validates the final window, so exercise valid and
    // invalid endings at lengths where only one window fits.
    var buffer: [64]u8 = undefined;
    const prefix = "abcdefghijklmnopqrstuvwxyz0123456789abcdefgh";
    @memcpy(buffer[0..prefix.len], prefix);
    const good_endings = [_][]const u8{
        "\u{4e16}\u{754c}",
        "a\u{4e16}",
        "\u{1f600}",
        "\u{00e9}\u{4e16}",
        "\u{00e9}",
    };
    for (good_endings) |ending| {
        const len = prefix.len + ending.len;
        @memcpy(buffer[prefix.len..][0..ending.len], ending);
        try testing.expect(isValid(buffer[0..len]));
        try testing.expect(std.unicode.utf8ValidateSlice(buffer[0..len]));
    }
    const bad_endings = [_][]const u8{
        "\xe4",
        "\xe4\xb8",
        "\x80",
        "\xf0\x9f\x98",
        "\xc3",
        "\xed\xa0\x80",
        "\xe0\x80\x80",
    };
    for (bad_endings) |ending| {
        const len = prefix.len + ending.len;
        @memcpy(buffer[prefix.len..][0..ending.len], ending);
        try testing.expect(!isValid(buffer[0..len]));
        try testing.expect(!std.unicode.utf8ValidateSlice(buffer[0..len]));
    }
}

test "vector validation rejects leads crossing the tail boundary" {
    const testing = std.testing;
    // 229 bytes make the last window start at 227, so a lead at 226 reaches
    // into the scalar tail. The tail scan must back up far enough to recheck
    // it.
    var buffer = [_]u8{'a'} ** 229;
    buffer[226] = 0xeb;
    buffer[227] = 'x';
    try testing.expect(!isValid(&buffer));
    try testing.expect(!std.unicode.utf8ValidateSlice(&buffer));

    buffer[226] = 0xc3;
    try testing.expect(!isValid(&buffer));

    buffer[227] = 0xa9;
    try testing.expect(isValid(&buffer));
    try testing.expect(std.unicode.utf8ValidateSlice(&buffer));

    // A three-byte scalar ending exactly at the last byte is valid.
    buffer[226] = 0xe4;
    buffer[227] = 0x96;
    buffer[228] = 0x87;
    try testing.expect(isValid(&buffer));
    try testing.expect(std.unicode.utf8ValidateSlice(&buffer));

    // Truncating it must fail.
    try testing.expect(!isValid(buffer[0..228]));
    try testing.expect(!std.unicode.utf8ValidateSlice(buffer[0..228]));
}

test "vector validation matches on window boundaries" {
    var buffer: [160]u8 = undefined;

    // Build valid text of every length in the window range, then mutate each
    // byte to a set of interesting values.
    const piece = "a\u{00e9}\u{4e16}\u{1f600}\u{0301}";
    var prng = std.Random.DefaultPrng.init(0x9e3779b97f4a7c15);
    const random = prng.random();

    var round: usize = 0;
    while (round < 4000) : (round += 1) {
        const length = 60 + random.uintLessThan(usize, 100);
        var filled: usize = 0;
        while (filled < length) {
            const scalar = piece[random.uintLessThan(usize, piece.len)];
            buffer[filled] = scalar;
            filled += 1;
        }
        // The random fill is not necessarily valid; compare either way.
        try expectSame(buffer[0..length]);

        const position = random.uintLessThan(usize, length);
        const original = buffer[position];
        const replacements = [_]u8{
            0x00, 0x41, 0x7f, 0x80, 0x8f, 0x90, 0x9f, 0xa0,
            0xbf, 0xc0, 0xc1, 0xc2, 0xdf, 0xe0, 0xed, 0xef,
            0xf0, 0xf4, 0xf5, 0xff,
        };
        for (replacements) |replacement| {
            buffer[position] = replacement;
            try expectSame(buffer[0..length]);
        }
        buffer[position] = original;
    }
}

test "vector validation matches on valid text and mutations" {
    const testing = std.testing;
    var buffer: [256]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0x243f6a8885a308d3);
    const random = prng.random();

    var round: usize = 0;
    while (round < 3000) : (round += 1) {
        // Generate valid text: random scalars, including ASCII runs.
        var filled: usize = 0;
        while (filled + 4 <= buffer.len) {
            const choice = random.uintLessThan(u8, 9);
            const codepoint: u21 = if (choice < 4)
                random.uintLessThan(u8, 0x80)
            else if (choice < 6)
                0x80 + random.uintLessThan(u21, 0x780)
            else if (choice < 7)
                0x800 + random.uintLessThan(u21, 0xd000)
            else if (choice == 7)
                0xe000 + random.uintLessThan(u21, 0x2000)
            else
                0x10000 + random.uintLessThan(u21, 0x100000);
            const length = std.unicode.utf8Encode(codepoint, buffer[filled..][0..4]) catch unreachable;
            filled += length;
        }
        try testing.expect(isValid(buffer[0..filled]));
        try expectSame(buffer[0..filled]);

        // Single-byte mutations at random positions.
        for (0..8) |_| {
            const position = random.uintLessThan(usize, filled);
            const original = buffer[position];
            buffer[position] = random.int(u8);
            try expectSame(buffer[0..filled]);
            buffer[position] = original;
        }
    }
}

test "vector validation carries valid and invalid sequences at every lane" {
    // Exercise each lane around the first two vector boundaries, including
    // the overlapping tail window. The scalar reference is independent of
    // the vector masks and covers all four exceptional second-byte ranges.
    const samples = [_][]const u8{
        "\x7f",             "\xc2\x80",     "\xdf\xbf",         "\xe0\xa0\x80",
        "\xed\x9f\xbf",     "\xee\x80\x80", "\xef\xbf\xbf",     "\xf0\x90\x80\x80",
        "\xf4\x8f\xbf\xbf", "\x80",         "\xc0\x80",         "\xc1\xbf",
        "\xe0\x9f\xbf",     "\xed\xa0\x80", "\xf0\x8f\xbf\xbf", "\xf4\x90\x80\x80",
        "\xf5\x80\x80\x80", "\xff",         "\xc2a",            "\xe1\x80a",
        "\xf1\x80\x80a",    "\xc2",         "\xe1\x80",         "\xf1\x80\x80",
    };
    var buffer: [192]u8 = undefined;
    for (samples) |sample| {
        for (0..96) |offset| {
            @memset(&buffer, 'a');
            @memcpy(buffer[offset..][0..sample.len], sample);
            for ([_]usize{ 48, 64, 96, 128, 160, 192 }) |length| {
                if (offset + sample.len > length) continue;
                try expectSame(buffer[0..length]);
            }
            // A sequence truncated at the exact slice end must be checked
            // even if its lead sits at the end of a vector window.
            for (1..sample.len + 1) |take| {
                try expectSame(buffer[0 .. offset + take]);
            }
        }
    }
}

test "vector validation agrees on all scalar encodings across a window" {
    var buffer = [_]u8{'a'} ** 128;
    var short_buffer = [_]u8{'a'} ** 32;
    var short_boundary = [_]u8{'a'} ** 32;
    @memcpy(short_boundary[0..3], "\xe4\xb8\x96");
    @memcpy(buffer[0..3], "\xe4\xb8\x96");
    // The portable first window ends at 32; the lookup first window starts
    // after the initial three-byte scalar and ends at 35. Exercise both
    // boundaries, and every legal four-byte continuation combination.
    for (0..0x110000) |value| {
        if (value >= 0xd800 and value <= 0xdfff) continue;
        const initial_length = try std.unicode.utf8Encode(@intCast(value), short_buffer[0..4]);
        try expectSame(&short_buffer);
        @memset(short_buffer[0..initial_length], 'a');
        // The register shifts cross a 128-bit lane at byte 16. Each lead
        // distance needs a valid scalar crossing that lane boundary.
        for ([_]usize{ 13, 14, 15 }) |offset| {
            const length = try std.unicode.utf8Encode(@intCast(value), short_boundary[offset..][0..4]);
            try expectSame(&short_boundary);
            @memset(short_boundary[offset..][0..length], 'a');
        }
        for ([_]usize{ 31, 34 }) |offset| {
            const length = try std.unicode.utf8Encode(@intCast(value), buffer[offset..][0..4]);
            try expectSame(&buffer);
            @memset(buffer[offset..][0..length], 'a');
        }
    }
}

test "short register windows reject malformed scalars across lane boundaries" {
    const bad = [_][]const u8{
        "\x80",         "\xc0\x80",         "\xc1\xbf",         "\xe0\x9f\xbf",
        "\xed\xa0\x80", "\xf0\x8f\xbf\xbf", "\xf4\x90\x80\x80", "\xf5\x80\x80\x80",
        "\xe2\x28\xa1", "\xf1\x80\x80",
    };
    for (bad) |sequence| {
        for ([_]usize{ 13, 14, 15 }) |offset| {
            var buffer = [_]u8{'a'} ** 32;
            @memcpy(buffer[0..3], "\xe4\xb8\x96");
            @memcpy(buffer[offset..][0..sequence.len], sequence);
            try expectSame(&buffer);
        }
    }
}

test "vector validation stays between unreadable guard pages" {
    if (comptime @import("builtin").os.tag != .linux) return error.SkipZigTest;
    const page = std.heap.pageSize();
    const memory = try std.posix.mmap(null, 3 * page, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
    defer std.posix.munmap(memory);
    try std.testing.expectEqual(std.posix.E.SUCCESS, std.posix.errno(std.os.linux.mprotect(memory.ptr, page, .{})));
    try std.testing.expectEqual(std.posix.E.SUCCESS, std.posix.errno(std.os.linux.mprotect(memory.ptr + 2 * page, page, .{})));

    const endings = [_][]const u8{
        "a",            "\xc2\x80",      "\xe0\xa0\x80",      "\xf4\x8f\xbf\xbf",
        "a\xc2\xa9",    "a\xe4\xb8\x96", "a\xf0\x9f\x98\x80", "\xff",
        "\xe0\x9f\x80", "\xed\xa0\x80",  "\xf0\x8f\xbf\xbf",  "\xf4\x90\x80\x80",
        "\xc2",         "\xe1\x80",      "\xf1\x80\x80",
    };
    for (0..513) |length| {
        // An end exactly at the unreadable page catches even one-byte
        // lookahead overreads, at every alignment and dispatch threshold.
        const text = memory[2 * page - length .. 2 * page];
        @memset(text, 'a');
        try expectSame(text);
        for (endings) |ending| {
            if (ending.len > length) continue;
            @memset(text, 'a');
            // Force non-ASCII dispatch beside the end guard as well, so
            // padded 16-32-byte lookup windows see valid and truncated tails.
            if (length >= 8) @memcpy(text[0..3], "\xe4\xb8\x96");
            @memcpy(text[length - ending.len ..], ending);
            try expectSame(text);
        }
        // A start immediately after the first guard catches lookbehind
        // underreads. Vary the first scalar as well as the slice length.
        const start = memory[page .. page + length];
        for (endings) |beginning| {
            if (beginning.len > length) continue;
            @memset(start, 'a');
            @memcpy(start[0..beginning.len], beginning);
            try expectSame(start);
        }
    }
}
