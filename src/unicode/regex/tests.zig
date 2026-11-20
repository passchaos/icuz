const std = @import("std");
const regex = @import("root.zig");

const Regex = regex.Regex;
const Matcher = regex.Matcher;
const Flags = regex.Flags;

fn compile(pattern: []const u8) !Regex {
    return Regex.compileAlloc(std.testing.allocator, pattern, .{});
}

fn compileFlags(pattern: []const u8, flags: Flags) !Regex {
    return Regex.compileAlloc(std.testing.allocator, pattern, flags);
}

fn expectFull(pattern: []const u8, text: []const u8) !void {
    var re = try compile(pattern);
    defer re.deinit();
    var m = try re.matcher(text);
    defer m.deinit();
    try std.testing.expect(try m.matches());
}

fn expectNoFull(pattern: []const u8, text: []const u8) !void {
    var re = try compile(pattern);
    defer re.deinit();
    var m = try re.matcher(text);
    defer m.deinit();
    try std.testing.expect(!(try m.matches()));
}

fn expectFind(pattern: []const u8, text: []const u8, start: usize, end: usize) !void {
    var re = try compile(pattern);
    defer re.deinit();
    var m = try re.matcher(text);
    defer m.deinit();
    try std.testing.expect(try m.find());
    try std.testing.expectEqual(@as(?usize, start), m.start(0));
    try std.testing.expectEqual(@as(?usize, end), m.end(0));
}

fn expectNoFind(pattern: []const u8, text: []const u8) !void {
    var re = try compile(pattern);
    defer re.deinit();
    var m = try re.matcher(text);
    defer m.deinit();
    try std.testing.expect(!(try m.find()));
}

test "regex literals, alternation, and quantifiers" {
    try expectFull("abc", "abc");
    try expectNoFull("abc", "abd");
    try expectFull("a|b", "b");
    try expectFull("(?:ab)+", "ababab");
    try expectFull("a{2,3}", "aaa");
    try expectNoFull("a{2,3}", "a");
    try expectNoFull("a{2,3}", "aaaa");
    try expectFind("b+", "aabbbcc", 2, 5);
    try expectFind("a*?a", "aaa", 0, 1);
    try expectNoFull("a*+a", "aaa");
    try expectNoFull("(?>a*)a", "aaa");
}

test "regex captures and named groups" {
    var re = try compile("(?<word>[a-z]+)-(\\d+)");
    defer re.deinit();
    var m = try re.matcher("abc-123");
    defer m.deinit();
    try std.testing.expect(try m.matches());
    try std.testing.expectEqualStrings("abc", m.group(1).?);
    try std.testing.expectEqualStrings("123", m.group(2).?);
    try std.testing.expectEqualStrings("abc", m.group(re.groupIndexFromName("word").?).?);
    try std.testing.expectEqual(@as(u16, 2), m.groupCount());
}

test "regex full case folding" {
    try expectFull("(?i)abc", "ABC");
    try expectFull("(?i)ß", "ss");
    try expectFull("(?i)ss", "ß");
    try expectNoFull("(?i)s", "ß");
    try expectFull("(?i)σ", "Σ");
    try expectFull("(?i)[a-z]+", "\u{212a}");
    try expectNoFull("(?i)[ß]", "ss");
    try expectNoFull("(?i)[^a]", "A");
    try expectFull("(?i)\\P{L}", "1");
    try expectNoFull("(?i)\\P{L}", "A");
    try expectFull("(?i)(a)\\1", "aA");
}

test "regex lookaround and back references" {
    try expectFind("(?<=ab)c", "abc", 2, 3);
    try expectFind("(?<=a|bc)d", "bcd", 2, 3);
    try expectFind("(?=(a))a", "a", 0, 1);
    try expectFind("a(?!b)", "ac", 0, 1);
    try expectFull("(a)\\1", "aa");
    try expectFull("(?<x>a)\\k<x>", "aa");
    try expectFind("\\G\\w", "ab cd", 0, 1);
}

test "regex anchors and line terminators" {
    try expectFind("abc$", "abc\n", 0, 3);
    try expectFind("abc$", "abc\r\n", 0, 3);
    try expectFind("abc\\Z", "abc\n", 0, 3);
    try expectNoFind("abc\\z", "abc\n");
    try expectFind("(?m)^b", "a\nb", 2, 3);
    try expectFind("(?m)^b", "a\r\nb", 3, 4);
    try expectFind("(?m)a$", "a\r\nb", 0, 1);
    try expectFind("(?d)a$", "a\n", 0, 1);
    try expectNoFind("(?d)a$", "a\r");
    try expectFull("(?d).", "\r");
    try expectNoFull(".", "\u{2028}");
    try expectNoFull(".", "\r");
}

test "regex word boundaries" {
    try expectFind("\\bé", "x é", 2, 4);
    try expectNoFind("\\bé", "aé");
    try expectFull("\\w", "é");
    try expectFull("\\d", "\u{0660}");
    try expectFull("\\s", "\u{2028}");
}

test "regex classes and properties" {
    try expectFull("[a-z&&[^aeiou]]+", "bcdf");
    try expectFull("[a-z--[aeiou]]+", "bcdf");
    try expectFull("[[:alpha:]]+", "abc");
    try expectFull("[[:digit:]]", "\u{0660}");
    try expectFull("\\p{Script=Greek}+", "αβγ");
    try expectFull("\\p{Block=Basic_Latin}", "a");
    try expectFull("\\p{Age=6.0}", "€");
    try expectFull("\\p{Word_Break=ALetter}", "a");
    try expectFull("\\N{LATIN SMALL LETTER A}", "a");
    try expectFull("\\0101", "A");
    try expectFull("\\x{1F600}", "\u{1f600}");
    try expectFull("\\u0041", "A");
    try expectFull("\\cA", "\x01");
    try expectFull("\\Qa+b\\E", "a+b");
    try expectFull("(?x) a b # comment\n c", "abc");
}

test "regex grapheme and linebreak atoms" {
    try expectFull("\\X", "e\u{0301}");
    try expectFull("\\R", "\r\n");
    try expectFull("\\R", "\u{0085}");
    try expectFull("\\R", "\u{000b}");
}

test "regex empty loop captures" {
    var re = try compile("(a*)*");
    defer re.deinit();
    var m = try re.matcher("aa");
    defer m.deinit();
    try std.testing.expect(try m.matches());
    try std.testing.expectEqual(@as(?usize, 2), m.start(1));
    try std.testing.expectEqual(@as(?usize, 2), m.end(1));

    var empty = try compile("(a?)+");
    defer empty.deinit();
    var em = try empty.matcher("");
    defer em.deinit();
    try std.testing.expect(try em.matches());
    try std.testing.expectEqual(@as(?usize, 0), em.start(1));
}

test "regex find iteration handles empty matches" {
    var re = try compile("a*");
    defer re.deinit();
    var m = try re.matcher("ba");
    defer m.deinit();
    try std.testing.expect(try m.find());
    try std.testing.expectEqual(@as(?usize, 0), m.start(0));
    try std.testing.expectEqual(@as(?usize, 0), m.end(0));
    try std.testing.expect(try m.find());
    try std.testing.expectEqual(@as(?usize, 1), m.start(0));
    try std.testing.expectEqual(@as(?usize, 2), m.end(0));
    try std.testing.expect(try m.find());
    try std.testing.expectEqual(@as(?usize, 2), m.start(0));
    try std.testing.expect(!(try m.find()));
}

test "regex region and bounds" {
    var re = try compile("\\babc\\b");
    defer re.deinit();
    var m = try re.matcher("xabcx");
    defer m.deinit();
    m.setRegion(1, 4);
    try std.testing.expect(try m.find());
    try std.testing.expectEqual(@as(?usize, 1), m.start(0));

    m.setRegion(1, 4);
    try std.testing.expect(try m.matches());
}

test "regex replace and split" {
    var re = try compile("(\\w+)@(\\w+)");
    defer re.deinit();
    const replaced = try re.replaceAllAlloc(
        std.testing.allocator,
        "a@b c@d",
        "$2:$1",
    );
    defer std.testing.allocator.free(replaced);
    try std.testing.expectEqualStrings("b:a d:c", replaced);

    const first = try re.replaceFirstAlloc(
        std.testing.allocator,
        "a@b c@d",
        "$2-$1",
    );
    defer std.testing.allocator.free(first);
    try std.testing.expectEqualStrings("b-a c@d", first);

    var comma = try compile(",");
    defer comma.deinit();
    const fields = try comma.splitAlloc(std.testing.allocator, "a,b,c", null);
    defer {
        for (fields) |field| std.testing.allocator.free(field);
        std.testing.allocator.free(fields);
    }
    try std.testing.expectEqual(@as(usize, 3), fields.len);
    try std.testing.expectEqualStrings("a", fields[0]);
    try std.testing.expectEqualStrings("b", fields[1]);
    try std.testing.expectEqualStrings("c", fields[2]);
}

test "regex utf16 offsets" {
    var re = try compile("b");
    defer re.deinit();
    var m = try re.matcher("\u{1f600}b");
    defer m.deinit();
    try std.testing.expect(try m.find());
    try std.testing.expectEqual(@as(?usize, 4), m.start(0));
    try std.testing.expectEqual(@as(?usize, 2), m.start16(0));
    try std.testing.expectEqual(@as(?usize, 3), m.end16(0));
}

test "regex invalid patterns" {
    const invalid = [_][]const u8{
        "",
        "*a",
        "a**",
        "(a)\\2",
        "(?<1x>a)",
        "(?<x>a)(?<x>b)",
        "[a-",
        "\\p{Bogus}",
        "(?<=a*)b",
        "a{b}",
    };
    for (invalid) |pattern| {
        const result = Regex.compileAlloc(std.testing.allocator, pattern, .{});
        try std.testing.expectError(error.InvalidPattern, result);
    }
}

const FixtureReader = struct {
    data: []const u8,
    index: usize = 0,

    fn readU8(self: *FixtureReader) !u8 {
        if (self.index >= self.data.len) return error.Truncated;
        const value = self.data[self.index];
        self.index += 1;
        return value;
    }

    fn readU16(self: *FixtureReader) !u16 {
        if (self.index + 2 > self.data.len) return error.Truncated;
        const value = std.mem.readInt(u16, self.data[self.index..][0..2], .little);
        self.index += 2;
        return value;
    }

    fn readU32(self: *FixtureReader) !u32 {
        if (self.index + 4 > self.data.len) return error.Truncated;
        const value = std.mem.readInt(u32, self.data[self.index..][0..4], .little);
        self.index += 4;
        return value;
    }

    fn readI32(self: *FixtureReader) !i32 {
        return @bitCast(try self.readU32());
    }

    fn readBytes(self: *FixtureReader, length: usize) ![]const u8 {
        if (self.index + length > self.data.len) return error.Truncated;
        const slice = self.data[self.index..][0..length];
        self.index += length;
        return slice;
    }
};

fn flagsFromBits(bits: u8) Flags {
    return .{
        .case_insensitive = bits & 1 != 0,
        .comments = bits & 2 != 0,
        .dotall = bits & 4 != 0,
        .literal = bits & 8 != 0,
        .multiline = bits & 16 != 0,
        .unix_lines = bits & 32 != 0,
        .uword = bits & 64 != 0,
        .error_on_unknown_escapes = bits & 128 != 0,
    };
}

fn byteOffsetFromUtf16(text: []const u8, units: usize) usize {
    var seen: usize = 0;
    var index: usize = 0;
    while (index < text.len and seen < units) {
        const length = std.unicode.utf8ByteSequenceLength(text[index]) catch break;
        if (index + length > text.len) break;
        const codepoint = std.unicode.utf8Decode(text[index..][0..length]) catch break;
        seen += if (codepoint > 0xffff) 2 else 1;
        index += length;
    }
    return index;
}

fn expectSpans(
    matcher: *const Matcher,
    expected: []const [2]i32,
    group_count: u16,
) !void {
    try std.testing.expectEqual(@as(usize, group_count) + 1, expected.len);
    var group: u16 = 0;
    while (group <= group_count) : (group += 1) {
        const start = matcher.start16(group);
        const end = matcher.end16(group);
        if (expected[group][0] < 0) {
            try std.testing.expect(start == null);
            try std.testing.expect(end == null);
        } else {
            try std.testing.expectEqual(
                @as(?usize, @intCast(expected[group][0])),
                start,
            );
            try std.testing.expectEqual(
                @as(?usize, @intCast(expected[group][1])),
                end,
            );
        }
    }
}

test "regex ICU conformance fixture" {
    const data = @embedFile("conformance.bin");
    try std.testing.expectEqualSlices(u8, "CJRX", data[0..4]);
    var reader = FixtureReader{ .data = data, .index = 8 };
    const case_count = try reader.readU32();
    try std.testing.expectEqual(@as(u32, 97), case_count);

    var passed: usize = 0;
    var case_index: usize = 0;
    while (case_index < case_count) : (case_index += 1) {
        const flags_bits = try reader.readU8();
        const kind = try reader.readU8();
        const transparent = (try reader.readU8()) != 0;
        const anchoring = (try reader.readU8()) != 0;
        const region_start_units = try reader.readU16();
        const region_end_units = try reader.readU16();

        const pattern_length = try reader.readU16();
        const pattern = try reader.readBytes(pattern_length);
        const text_length = try reader.readU16();
        const text = try reader.readBytes(text_length);
        const replacement_length = try reader.readU16();
        const replacement = try reader.readBytes(replacement_length);
        const compile_ok = (try reader.readU8()) != 0;

        const flags = flagsFromBits(flags_bits);
        if (!compile_ok) {
            try std.testing.expectError(
                error.InvalidPattern,
                Regex.compileAlloc(std.testing.allocator, pattern, flags),
            );
            passed += 1;
            continue;
        }

        var re = try Regex.compileAlloc(std.testing.allocator, pattern, flags);
        defer re.deinit();
        var matcher = try re.matcher(text);
        defer matcher.deinit();
        if (region_start_units != 0xffff) {
            matcher.setRegion(
                byteOffsetFromUtf16(text, region_start_units),
                byteOffsetFromUtf16(text, region_end_units),
            );
        }
        matcher.setTransparentBounds(transparent);
        matcher.setAnchoringBounds(anchoring);

        switch (kind) {
            0, 1, 2 => {
                const matched = (try reader.readU8()) != 0;
                const actual = switch (kind) {
                    0 => try matcher.matches(),
                    1 => try matcher.find(),
                    else => try matcher.lookingAt(),
                };
                if (matched != actual) {
                    std.debug.print("case {d} kind {d} pattern {s} text {s} region {d}..{d} expected {}\n", .{
                        case_index, kind, pattern, text, region_start_units, region_end_units, matched,
                    });
                }
                try std.testing.expectEqual(matched, actual);
                if (matched) {
                    const group_count = try reader.readU16();
                    const expected = try std.testing.allocator.alloc([2]i32, @as(usize, group_count) + 1);
                    defer std.testing.allocator.free(expected);
                    for (expected) |*span| {
                        span[0] = try reader.readI32();
                        span[1] = try reader.readI32();
                    }
                    try expectSpans(&matcher, expected, group_count);
                }
            },
            3, 5 => {
                const output_length = try reader.readU32();
                const expected = try reader.readBytes(output_length);
                const actual = if (kind == 3)
                    try re.replaceAllAlloc(std.testing.allocator, text, replacement)
                else
                    try re.replaceFirstAlloc(std.testing.allocator, text, replacement);
                defer std.testing.allocator.free(actual);
                try std.testing.expectEqualStrings(expected, actual);
            },
            4 => {
                const field_count = try reader.readU16();
                const expected = try std.testing.allocator.alloc([]const u8, field_count);
                defer std.testing.allocator.free(expected);
                for (expected) |*field| {
                    const length = try reader.readU16();
                    field.* = try reader.readBytes(length);
                }
                const actual = try re.splitAlloc(std.testing.allocator, text, null);
                defer {
                    for (actual) |field| std.testing.allocator.free(field);
                    std.testing.allocator.free(actual);
                }
                try std.testing.expectEqual(@as(usize, field_count), actual.len);
                for (expected, actual) |expected_field, actual_field| {
                    try std.testing.expectEqualStrings(expected_field, actual_field);
                }
            },
            6 => {
                const matched = (try reader.readU8()) != 0;
                const match_count = try reader.readU16();
                try std.testing.expectEqual(@as(usize, match_count) != 0, matched);
                var found: usize = 0;
                while (found < match_count) : (found += 1) {
                    const group_count = try reader.readU16();
                    const expected = try std.testing.allocator.alloc([2]i32, @as(usize, group_count) + 1);
                    defer std.testing.allocator.free(expected);
                    for (expected) |*span| {
                        span[0] = try reader.readI32();
                        span[1] = try reader.readI32();
                    }
                    try std.testing.expect(try matcher.find());
                    try expectSpans(&matcher, expected, group_count);
                }
                try std.testing.expect(!(try matcher.find()));
            },
            else => return error.UnknownCaseKind,
        }
        passed += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), data.len - reader.index);
    std.debug.print("regex conformance: {}/{} passed\n", .{ passed, case_count });
}

test "regex literal flag" {
    var re = try compileFlags("a+b", .{ .literal = true });
    defer re.deinit();
    var m = try re.matcher("a+b");
    defer m.deinit();
    try std.testing.expect(try m.matches());
}

test "regex find prefilters" {
    try expectFind("abc", "xxabcxx", 2, 5);
    try expectFind("[0-9]+", "ab123cd", 2, 5);
    try expectFind("abc|def", "xxdef", 2, 5);
    try expectFind("^abc", "abc", 0, 3);
    try expectNoFind("^abc", "xabc");
    try expectFind("abc", "abcabc", 0, 3);
    try expectFind("a*", "ba", 0, 0);

    var re = try compile("abc");
    defer re.deinit();
    var m = try re.matcher("abcabc");
    defer m.deinit();
    try std.testing.expect(try m.find());
    try std.testing.expectEqual(@as(?usize, 0), m.start(0));
    try std.testing.expect(try m.find());
    try std.testing.expectEqual(@as(?usize, 3), m.start(0));
}

test "regex required-literal prefilter" {
    try expectFind(".*needle", "xxneedlexx", 0, 8);
    try expectNoFind(".*needle", "no match here");
    try expectFind("(?:ab)+cd", "ababcd", 0, 6);
    try expectNoFind("(?:ab)+cd", "abab");
    try expectFind("(?=foo)foo", "foo", 0, 3);
    try expectNoFind("(?=foo)foo", "bar");
    try expectFind("a(bc)?d", "ad", 0, 2);
    try expectFind("(?i)needle", "NEEDLE", 0, 6);
}

test "regex whole-literal fast path" {
    var re = try compile("needle");
    defer re.deinit();

    var m = try re.matcher("a needle b");
    defer m.deinit();
    try std.testing.expect(try m.find());
    try std.testing.expectEqual(@as(?usize, 2), m.start(0));
    try std.testing.expectEqual(@as(?usize, 8), m.end(0));
    try std.testing.expect(!(try m.matches()));
    try std.testing.expect(!(try m.lookingAt()));

    var exact = try re.matcher("needle");
    defer exact.deinit();
    try std.testing.expect(try exact.matches());
    try std.testing.expectEqualStrings("needle", exact.group(0).?);

    var prefix = try re.matcher("needlex");
    defer prefix.deinit();
    try std.testing.expect(try prefix.lookingAt());
    try std.testing.expectEqual(@as(?usize, 6), prefix.end(0));

    const replaced = try re.replaceAllAlloc(std.testing.allocator, "needle needle", "x");
    defer std.testing.allocator.free(replaced);
    try std.testing.expectEqualStrings("x x", replaced);
}

test "regex literal alternation fast path" {
    var re = try compile("foo|bar");
    defer re.deinit();

    var m = try re.matcher("xx bar foo");
    defer m.deinit();
    try std.testing.expect(try m.find());
    try std.testing.expectEqual(@as(?usize, 3), m.start(0));
    try std.testing.expectEqual(@as(?usize, 6), m.end(0));
    try std.testing.expect(try m.find());
    try std.testing.expectEqual(@as(?usize, 7), m.start(0));

    var exact = try re.matcher("foo");
    defer exact.deinit();
    try std.testing.expect(try exact.matches());

    var prefix = try re.matcher("foobar");
    defer prefix.deinit();
    try std.testing.expect(try prefix.lookingAt());
    try std.testing.expectEqual(@as(?usize, 3), prefix.end(0));

    var short = try compile("a|ab");
    defer short.deinit();
    var sm = try short.matcher("ab");
    defer sm.deinit();
    try std.testing.expect(try sm.find());
    try std.testing.expectEqual(@as(?usize, 1), sm.end(0));

    var long = try compile("ab|a");
    defer long.deinit();
    var lm = try long.matcher("ab");
    defer lm.deinit();
    try std.testing.expect(try lm.find());
    try std.testing.expectEqual(@as(?usize, 2), lm.end(0));

    const replaced = try re.replaceAllAlloc(std.testing.allocator, "foo bar", "x");
    defer std.testing.allocator.free(replaced);
    try std.testing.expectEqualStrings("x x", replaced);
}

test "regex match prechecks" {
    var prefix = try compile("abc.*");
    defer prefix.deinit();
    var pm = try prefix.matcher("abcdef");
    defer pm.deinit();
    try std.testing.expect(try pm.matches());
    try pm.reset("xabc");
    try std.testing.expect(!(try pm.matches()));
    try std.testing.expect(!(try pm.lookingAt()));

    var required = try compile(".*needle");
    defer required.deinit();
    var rm = try required.matcher("xxneedle");
    defer rm.deinit();
    try std.testing.expect(try rm.matches());
    try rm.reset("none");
    try std.testing.expect(!(try rm.matches()));

    var digits = try compile("[0-9]+");
    defer digits.deinit();
    var dm = try digits.matcher("123");
    defer dm.deinit();
    try std.testing.expect(try dm.matches());
    try dm.reset("abc");
    try std.testing.expect(!(try dm.matches()));
    try dm.reset("");
    try std.testing.expect(!(try dm.matches()));

    var anchored = try compile("^abc");
    defer anchored.deinit();
    var am = try anchored.matcher("abc");
    defer am.deinit();
    try std.testing.expect(try am.matches());
    try am.reset("xabc");
    try std.testing.expect(!(try am.matches()));
}
