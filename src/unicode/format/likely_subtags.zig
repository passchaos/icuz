//! CLDR likely-subtags resolution.

const std = @import("std");

const blob = @embedFile("likely_subtags_data.bin");

const header_len = 16;
const entry_count = readU32(8);
const string_length = readU32(12);
const entry_offset = header_len;
const strings_offset = entry_offset + @as(usize, entry_count) * 8;

comptime {
    if (blob.len < header_len or !std.mem.eql(u8, blob[0..4], "CJL1") or
        blob[4] != 1)
    {
        @compileError("invalid likely subtags data");
    }
    if (strings_offset + @as(usize, string_length) != blob.len) {
        @compileError("invalid likely subtags data lengths");
    }
}

fn readU32(offset: usize) u32 {
    return std.mem.readInt(u32, blob[offset..][0..4], .little);
}

fn strAt(offset: u32) []const u8 {
    if (offset == 0) return "";
    return std.mem.sliceTo(blob[strings_offset + @as(usize, offset) ..], 0);
}

fn lookup(key: []const u8) ?[]const u8 {
    var low: usize = 0;
    var high: usize = entry_count;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const base = entry_offset + middle * 8;
        const source = strAt(readU32(base));
        switch (std.mem.order(u8, source, key)) {
            .lt => low = middle + 1,
            .gt => high = middle,
            .eq => return strAt(readU32(base + 4)),
        }
    }
    return null;
}

const Parsed = struct {
    language: []const u8 = "",
    script: []const u8 = "",
    region: []const u8 = "",
    variants: []const u8 = "",
};

fn parse(locale: []const u8) Parsed {
    var result = Parsed{};
    var iterator = std.mem.tokenizeAny(u8, locale, "-_");
    var first = true;
    var variant_start: ?usize = null;
    while (iterator.next()) |subtag| {
        if (first) {
            first = false;
            result.language = subtag;
            continue;
        }
        if (result.script.len == 0 and subtag.len == 4 and
            std.ascii.isAlphabetic(subtag[0]))
        {
            result.script = subtag;
            continue;
        }
        if (result.region.len == 0 and
            ((subtag.len == 2 and std.ascii.isAlphabetic(subtag[0])) or
                (subtag.len == 3 and std.ascii.isDigit(subtag[0]))))
        {
            result.region = subtag;
            continue;
        }
        if (variant_start == null) {
            variant_start = @intFromPtr(subtag.ptr) - @intFromPtr(locale.ptr);
        }
    }
    if (variant_start) |start| {
        result.variants = locale[start..];
    }
    return result;
}

fn buildKey(
    buffer: []u8,
    language: []const u8,
    script: []const u8,
    region: []const u8,
) []const u8 {
    var length: usize = 0;
    const parts = [_][]const u8{ language, script, region };
    for (parts) |part| {
        if (part.len == 0) continue;
        if (length != 0) {
            if (length == buffer.len) return buffer[0..length];
            buffer[length] = '_';
            length += 1;
        }
        const take = @min(part.len, buffer.len - length);
        @memcpy(buffer[length..][0..take], part[0..take]);
        length += take;
    }
    return buffer[0..length];
}

const Match = struct {
    language: []const u8,
    script: []const u8,
    region: []const u8,
};

fn splitTarget(target: []const u8, match: *Match) void {
    var iterator = std.mem.tokenizeScalar(u8, target, '_');
    if (iterator.next()) |language| match.language = language;
    if (iterator.next()) |script| match.script = script;
    if (iterator.next()) |region| match.region = region;
}

fn findMatch(parsed: Parsed) ?Match {
    var buffer: [32]u8 = undefined;
    var match = Match{ .language = "", .script = "", .region = "" };
    // Language-first candidates.
    if (parsed.language.len != 0 and
        !std.mem.eql(u8, parsed.language, "und"))
    {
        const candidates = [_][]const u8{
            buildKey(&buffer, parsed.language, parsed.script, parsed.region),
        };
        if (lookup(candidates[0])) |target| {
            splitTarget(target, &match);
            return match;
        }
        var key = buildKey(&buffer, parsed.language, parsed.script, "");
        if (lookup(key)) |target| {
            splitTarget(target, &match);
            return match;
        }
        key = buildKey(&buffer, parsed.language, "", parsed.region);
        if (lookup(key)) |target| {
            splitTarget(target, &match);
            return match;
        }
        key = buildKey(&buffer, parsed.language, "", "");
        if (lookup(key)) |target| {
            splitTarget(target, &match);
            return match;
        }
    }
    // Script/region candidates.
    if (parsed.script.len != 0) {
        const key = buildKey(&buffer, "und", parsed.script, parsed.region);
        if (lookup(key)) |target| {
            splitTarget(target, &match);
            return match;
        }
        const script_key = buildKey(&buffer, "und", parsed.script, "");
        if (lookup(script_key)) |target| {
            splitTarget(target, &match);
            return match;
        }
    }
    if (parsed.region.len != 0) {
        const key = buildKey(&buffer, "und", "", parsed.region);
        if (lookup(key)) |target| {
            splitTarget(target, &match);
            return match;
        }
    }
    if (parsed.language.len == 0 or std.mem.eql(u8, parsed.language, "und")) {
        if (lookup("und")) |target| {
            splitTarget(target, &match);
            return match;
        }
    }
    return null;
}

const Parts = struct {
    language: []const u8,
    script: []const u8,
    region: []const u8,
};

fn maximizeParts(parsed: Parsed) ?Parts {
    const match = findMatch(parsed) orelse return null;
    const language = if (parsed.language.len != 0 and
        !std.mem.eql(u8, parsed.language, "und"))
        parsed.language
    else
        match.language;
    const script = if (parsed.script.len != 0) parsed.script else match.script;
    // "ZZ" is CLDR's unknown region; ICU drops it and uses the match.
    const has_region = parsed.region.len != 0 and
        !std.mem.eql(u8, parsed.region, "ZZ");
    const region = if (has_region) parsed.region else match.region;
    return .{ .language = language, .script = script, .region = region };
}

/// Maximize a locale by filling in likely script and region subtags.
pub fn maximizeAlloc(
    allocator: std.mem.Allocator,
    locale: []const u8,
) ![]u8 {
    const parsed = parse(locale);
    const maximal = maximizeParts(parsed) orelse
        return allocator.dupe(u8, locale);
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, maximal.language);
    if (maximal.script.len != 0) {
        try output.append(allocator, '_');
        try output.appendSlice(allocator, maximal.script);
    }
    if (maximal.region.len != 0) {
        try output.append(allocator, '_');
        try output.appendSlice(allocator, maximal.region);
    }
    if (parsed.variants.len != 0) {
        try output.append(allocator, '_');
        try output.appendSlice(allocator, parsed.variants);
    }
    return output.toOwnedSlice(allocator);
}

fn matchesMaximal(candidate: Parsed, maximal: Parts) bool {
    const parts = maximizeParts(candidate) orelse return false;
    return std.mem.eql(u8, parts.script, maximal.script) and
        std.mem.eql(u8, parts.region, maximal.region);
}

pub const MinimizeOptions = struct {
    /// Keep the script subtag when minimizing, matching ICU's
    /// `ULOC_MINIMIZE_FAVOR_SCRIPT`.
    favor_script: bool = false,
};

/// Minimize a locale by removing script and region subtags that likely
/// subtags imply, matching ICU's `uloc_minimizeSubtags`.
pub fn minimizeAlloc(
    allocator: std.mem.Allocator,
    locale: []const u8,
) ![]u8 {
    return minimizeWithOptionsAlloc(allocator, locale, .{});
}

/// Minimize a locale with explicit options.
pub fn minimizeWithOptionsAlloc(
    allocator: std.mem.Allocator,
    locale: []const u8,
    options: MinimizeOptions,
) ![]u8 {
    const parsed = parse(locale);
    const maximal = maximizeParts(parsed) orelse
        return allocator.dupe(u8, locale);

    var script: []const u8 = maximal.script;
    var region: []const u8 = maximal.region;
    if (matchesMaximal(.{ .language = maximal.language }, maximal)) {
        script = "";
        region = "";
    } else {
        const order = if (options.favor_script)
            [2]u8{ 1, 0 }
        else
            [2]u8{ 0, 1 };
        for (order) |kind| {
            if (kind == 1) {
                if (parsed.script.len == 0) continue;
                const candidate = Parsed{
                    .language = maximal.language,
                    .script = parsed.script,
                };
                if (!matchesMaximal(candidate, maximal)) continue;
                script = parsed.script;
                region = "";
                break;
            }
            if (parsed.region.len == 0) continue;
            const candidate = Parsed{
                .language = maximal.language,
                .region = parsed.region,
            };
            if (!matchesMaximal(candidate, maximal)) continue;
            script = "";
            region = parsed.region;
            break;
        }
    }

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, maximal.language);
    if (script.len != 0) {
        try output.append(allocator, '_');
        try output.appendSlice(allocator, script);
    } else if (parsed.variants.len != 0) {
        // ICU keeps the empty script slot so variants stay in position.
        try output.append(allocator, '_');
    }
    if (region.len != 0) {
        try output.append(allocator, '_');
        try output.appendSlice(allocator, region);
    }
    if (parsed.variants.len != 0) {
        try output.append(allocator, '_');
        try output.appendSlice(allocator, parsed.variants);
    }
    return output.toOwnedSlice(allocator);
}

test "minimize favors script" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const default = try minimizeAlloc(allocator, "zh-Hant-TW");
    defer allocator.free(default);
    try testing.expectEqualStrings("zh_TW", default);

    const favor = try minimizeWithOptionsAlloc(
        allocator,
        "zh-Hant-TW",
        .{ .favor_script = true },
    );
    defer allocator.free(favor);
    try testing.expectEqualStrings("zh_Hant", favor);
}

test "likely subtags" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const cases = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "en", .expected = "en_Latn_US" },
        .{ .input = "zh", .expected = "zh_Hans_CN" },
        .{ .input = "sr", .expected = "sr_Cyrl_RS" },
        .{ .input = "und", .expected = "en_Latn_US" },
        .{ .input = "de_AT", .expected = "de_Latn_AT" },
        .{ .input = "zh_Hant", .expected = "zh_Hant_TW" },
        .{ .input = "ja", .expected = "ja_Jpan_JP" },
        .{ .input = "ko", .expected = "ko_Kore_KR" },
        .{ .input = "ar", .expected = "ar_Arab_EG" },
        .{ .input = "ru", .expected = "ru_Cyrl_RU" },
        .{ .input = "hi", .expected = "hi_Deva_IN" },
        .{ .input = "fr_CA", .expected = "fr_Latn_CA" },
        .{ .input = "en_US", .expected = "en_Latn_US" },
        .{ .input = "sr_Latn", .expected = "sr_Latn_RS" },
        .{ .input = "und_US", .expected = "en_Latn_US" },
        .{ .input = "und_Latn", .expected = "en_Latn_US" },
        .{ .input = "zh_Hans", .expected = "zh_Hans_CN" },
        .{ .input = "en_US_POSIX", .expected = "en_Latn_US_POSIX" },
        .{ .input = "de", .expected = "de_Latn_DE" },
        .{ .input = "und_ZZ", .expected = "en_Latn_US" },
        .{ .input = "sh", .expected = "sh" },
    };
    for (cases) |case| {
        const value = try maximizeAlloc(allocator, case.input);
        defer allocator.free(value);
        try testing.expectEqualStrings(case.expected, value);
    }
}

test "likely subtags minimization" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const cases = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "en_Latn_US", .expected = "en" },
        .{ .input = "en_Latn_GB", .expected = "en_GB" },
        .{ .input = "zh_Hant_TW", .expected = "zh_TW" },
        .{ .input = "zh_Hans_CN", .expected = "zh" },
        .{ .input = "sr_Latn_RS", .expected = "sr_Latn" },
        .{ .input = "und_Latn_US", .expected = "en" },
        .{ .input = "de_Latn_AT", .expected = "de_AT" },
        .{ .input = "en", .expected = "en" },
        .{ .input = "zh_TW", .expected = "zh_TW" },
        .{ .input = "und", .expected = "en" },
        .{ .input = "en_US_POSIX", .expected = "en__POSIX" },
    };
    for (cases) |case| {
        const value = try minimizeAlloc(allocator, case.input);
        defer allocator.free(value);
        try testing.expectEqualStrings(case.expected, value);
    }
}

test "likely subtags conformance" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const fixture = @embedFile("likely_subtags_conformance.bin");
    try testing.expect(fixture.len >= 12);
    try testing.expectEqualStrings("CJLV", fixture[0..4]);
    const case_count = std.mem.readInt(u32, fixture[8..12], .little);
    var cursor: usize = 12;
    var failures: usize = 0;
    var total: usize = 0;
    var printed: usize = 0;
    for (0..case_count) |_| {
        const input_length = fixture[cursor];
        const expected_length = fixture[cursor + 1];
        cursor += 4;
        const input = fixture[cursor .. cursor + input_length];
        cursor += input_length;
        const expected = fixture[cursor .. cursor + expected_length];
        cursor += expected_length;
        total += 1;
        const actual = try maximizeAlloc(allocator, input);
        defer allocator.free(actual);
        if (!std.mem.eql(u8, actual, expected)) {
            failures += 1;
            if (printed < 30) {
                printed += 1;
                std.debug.print(
                    "likely subtags mismatch {s}: got '{s}' expected '{s}'\n",
                    .{ input, actual, expected },
                );
            }
        }
    }
    std.debug.print("likely subtags conformance: {d}/{d} passed\n", .{ total - failures, total });
    try testing.expect(failures == 0);
}
