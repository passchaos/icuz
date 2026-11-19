//! CLDR language matching: pick the best supported locale for a list of
//! desired locales.
//!
//! The distance model follows CLDR's `languageInfo.xml`: the most specific
//! matching rule contributes its distance, then any remaining script and
//! region differences add their level defaults (50 and 4). Unmatched
//! languages use the default language distance 80. Earlier desired locales
//! are demoted less, and matches at or above the threshold fall back to the
//! default locale, matching ICU's `LocaleMatcher` defaults.

const std = @import("std");

const likely_subtags = @import("../format/likely_subtags.zig");
const data = @import("matcher_data.zig");

pub const default_threshold: u16 = 50;
pub const default_demotion: u16 = 5;
pub const default_language_distance: u16 = 80;
pub const default_script_distance: u16 = 50;
pub const default_region_distance: u16 = 4;

pub const Options = struct {
    /// Maximum acceptable distance; matches at or above it are rejected.
    threshold: u16 = default_threshold,
    /// Added per earlier desired locale, so later preferences need a
    /// strictly better match.
    demotion: u16 = default_demotion,
};

pub const Parts = struct {
    language: []const u8,
    script: []const u8,
    region: []const u8,
};

/// Split a locale into language, script, and region, ignoring variants and
/// extensions. Case is preserved; comparisons are ASCII case-insensitive.
pub fn parse(locale: []const u8) Parts {
    var iterator = std.mem.splitAny(u8, locale, "-_");
    const language = iterator.next() orelse "";
    var script: []const u8 = "";
    var region: []const u8 = "";
    while (iterator.next()) |part| {
        if (script.len == 0 and region.len == 0 and part.len == 4 and
            isAlpha(part))
        {
            script = part;
            continue;
        }
        if (region.len == 0 and
            ((part.len == 2 and isAlpha(part)) or
                (part.len == 3 and isDigitString(part))))
        {
            region = part;
            continue;
        }
        break;
    }
    return .{ .language = language, .script = script, .region = region };
}

/// Distance between two locales after likely-subtag maximization.
pub fn distanceAlloc(
    allocator: std.mem.Allocator,
    desired: []const u8,
    supported: []const u8,
) !u16 {
    const desired_max = try maximize(allocator, desired);
    defer allocator.free(desired_max);
    const supported_max = try maximize(allocator, supported);
    defer allocator.free(supported_max);
    return distance(parse(desired_max), parse(supported_max));
}

/// True when the pair matches within `threshold`.
pub fn isMatchAlloc(
    allocator: std.mem.Allocator,
    desired: []const u8,
    supported: []const u8,
    threshold: u16,
) !bool {
    return try distanceAlloc(allocator, desired, supported) < threshold;
}

/// Return the supported locale that best matches the desired list, or the
/// default locale when nothing matches within the threshold.
///
/// The returned slice is borrowed from `supported` or `default_locale`.
pub fn bestMatchAlloc(
    allocator: std.mem.Allocator,
    desired: []const []const u8,
    supported: []const []const u8,
    default_locale: ?[]const u8,
    options: Options,
) !?[]const u8 {
    if (supported.len == 0) return default_locale;

    const maximized = try allocator.alloc([]const u8, supported.len);
    defer {
        for (maximized) |value| allocator.free(value);
        allocator.free(maximized);
    }
    const parts = try allocator.alloc(Parts, supported.len);
    defer allocator.free(parts);
    const paradigms = try allocator.alloc(bool, supported.len);
    defer allocator.free(paradigms);
    for (supported, 0..) |locale, index| {
        maximized[index] = try maximize(allocator, locale);
        parts[index] = parse(maximized[index]);
        paradigms[index] = false;
    }

    // ICU prefers the default locale, then paradigm locales, then the rest
    // when distances tie.
    const default_index: ?usize = if (default_locale) |value|
        findSupported(value, supported)
    else
        null;
    var paradigm_parts: [data.paradigm_locales.len]?Parts = .{null} **
        data.paradigm_locales.len;
    for (data.paradigm_locales, 0..) |locale, index| {
        const maximized_paradigm = try maximize(allocator, locale);
        defer allocator.free(maximized_paradigm);
        paradigm_parts[index] = parse(maximized_paradigm);
    }
    for (supported, 0..) |_, index| {
        for (paradigm_parts) |maybe_paradigm| {
            const paradigm = maybe_paradigm orelse continue;
            if (sameParts(parts[index], paradigm)) {
                paradigms[index] = true;
                break;
            }
        }
    }

    const order = try allocator.alloc(usize, supported.len);
    defer allocator.free(order);
    var order_len: usize = 0;
    if (default_index) |index| {
        order[order_len] = index;
        order_len += 1;
    } else {
        order[order_len] = 0;
        order_len += 1;
    }
    for (supported, 0..) |_, index| {
        if ((default_index != null and default_index.? == index) or
            (default_index == null and index == 0) or !paradigms[index])
        {
            continue;
        }
        order[order_len] = index;
        order_len += 1;
    }
    for (supported, 0..) |_, index| {
        if ((default_index != null and default_index.? == index) or
            (default_index == null and index == 0) or paradigms[index])
        {
            continue;
        }
        order[order_len] = index;
        order_len += 1;
    }

    var best_weighted: u32 = options.threshold;
    var best_index: ?usize = null;
    for (desired, 0..) |locale, desired_index| {
        const demotion = @as(u32, @intCast(desired_index)) * options.demotion;
        if (demotion >= best_weighted) break;
        const desired_max = try maximize(allocator, locale);
        const desired_parts = parse(desired_max);
        for (order[0..order_len]) |supported_index| {
            const candidate = distance(desired_parts, parts[supported_index]);
            if (candidate == 0) {
                allocator.free(desired_max);
                return supported[supported_index];
            }
            const weighted = demotion + candidate;
            if (weighted < best_weighted) {
                best_weighted = weighted;
                best_index = supported_index;
            }
        }
        allocator.free(desired_max);
    }
    if (best_index) |index| return supported[index];
    return default_locale orelse supported[0];
}

fn maximize(allocator: std.mem.Allocator, locale: []const u8) ![]u8 {
    const parts = parse(locale);
    if (parts.language.len == 0 or std.mem.eql(u8, parts.language, "und")) {
        return allocator.dupe(u8, locale);
    }
    return likely_subtags.maximizeAlloc(allocator, locale);
}

fn findSupported(value: []const u8, supported: []const []const u8) ?usize {
    for (supported, 0..) |locale, index| {
        if (std.ascii.eqlIgnoreCase(locale, value)) return index;
    }
    return null;
}

fn sameParts(a: Parts, b: Parts) bool {
    return equalField(a.language, b.language) and
        equalField(a.script, b.script) and
        equalField(a.region, b.region);
}

fn equalField(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

const Level = enum { script, region };

fn distance(desired: Parts, supported: Parts) u16 {
    if (sameParts(desired, supported)) return 0;
    var total: u32 = 0;
    var covered: u8 = 1;
    if (bestRule(desired, supported, 0)) |rule| {
        total += rule.distance;
        covered = fieldCount(rule);
    } else if (!equalField(desired.language, supported.language)) {
        total += default_language_distance;
    }
    if (covered < 2 and !equalField(desired.script, supported.script)) {
        total += levelDistance(.script, desired, supported) orelse
            default_script_distance;
    }
    if (covered < 3 and !equalField(desired.region, supported.region)) {
        total += levelDistance(.region, desired, supported) orelse
            default_region_distance;
    }
    return @intCast(@min(total, std.math.maxInt(u16)));
}

fn levelDistance(
    level: Level,
    desired: Parts,
    supported: Parts,
) ?u16 {
    const fields: u8 = if (level == .script) 2 else 3;
    for (data.rules) |rule| {
        if (fieldCount(rule) != fields or isDefaultRule(rule)) continue;
        if (ruleMatches(rule, desired, supported)) return rule.distance;
    }
    return null;
}

/// Return the most specific non-default rule matching the pair.
fn bestRule(
    desired: Parts,
    supported: Parts,
    minimum_fields: u8,
) ?data.Rule {
    var best: ?data.Rule = null;
    var best_fields = minimum_fields;
    for (data.rules) |rule| {
        if (isDefaultRule(rule)) continue;
        const fields = fieldCount(rule);
        if (fields <= best_fields) continue;
        if (!coversDifference(rule, desired, supported)) continue;
        if (!ruleMatches(rule, desired, supported)) continue;
        best = rule;
        best_fields = fields;
    }
    return best;
}

/// A rule only contributes when at least one of its levels actually differs;
/// identical subtags are skipped by the CLDR algorithm.
fn coversDifference(rule: data.Rule, desired: Parts, supported: Parts) bool {
    const fields = fieldCount(rule);
    if (!equalField(desired.language, supported.language)) return true;
    if (fields >= 2 and !equalField(desired.script, supported.script)) return true;
    if (fields >= 3 and !equalField(desired.region, supported.region)) return true;
    return false;
}

fn fieldCount(rule: data.Rule) u8 {
    if (rule.desired_region.len != 0 or rule.supported_region.len != 0) return 3;
    if (rule.desired_script.len != 0 or rule.supported_script.len != 0) return 2;
    return 1;
}

fn isDefaultRule(rule: data.Rule) bool {
    return isWildcard(rule.desired_language) and
        isWildcardOrEmpty(rule.desired_script) and
        isWildcardOrEmpty(rule.desired_region) and
        isWildcard(rule.supported_language) and
        isWildcardOrEmpty(rule.supported_script) and
        isWildcardOrEmpty(rule.supported_region);
}

fn isWildcard(value: []const u8) bool {
    return std.mem.eql(u8, value, "*");
}

fn isWildcardOrEmpty(value: []const u8) bool {
    return value.len == 0 or isWildcard(value);
}

fn ruleMatches(rule: data.Rule, desired: Parts, supported: Parts) bool {
    if (sideMatches(rule, desired, supported)) return true;
    return !rule.one_way and sideMatches(rule, supported, desired);
}

fn sideMatches(
    rule: data.Rule,
    desired: Parts,
    supported: Parts,
) bool {
    if (rule.desired_language.len != 0 and
        !matchPattern(rule.desired_language, desired.language, false))
    {
        return false;
    }
    if (rule.desired_script.len != 0 and
        !matchPattern(rule.desired_script, desired.script, false))
    {
        return false;
    }
    if (rule.desired_region.len != 0 and
        !matchPattern(rule.desired_region, desired.region, true))
    {
        return false;
    }
    if (rule.supported_language.len != 0 and
        !matchPattern(rule.supported_language, supported.language, false))
    {
        return false;
    }
    if (rule.supported_script.len != 0 and
        !matchPattern(rule.supported_script, supported.script, false))
    {
        return false;
    }
    if (rule.supported_region.len != 0 and
        !matchPattern(rule.supported_region, supported.region, true))
    {
        return false;
    }
    return true;
}

fn matchPattern(pattern: []const u8, value: []const u8, is_region: bool) bool {
    if (isWildcard(pattern)) return true;
    if (is_region and pattern.len > 0 and pattern[0] == '$') {
        if (pattern.len > 1 and pattern[1] == '!') {
            return !inVariable(pattern[2..], value);
        }
        return inVariable(pattern[1..], value);
    }
    return std.ascii.eqlIgnoreCase(pattern, value);
}

fn inVariable(name: []const u8, region: []const u8) bool {
    if (region.len == 0) return false;
    var low: usize = 0;
    var high: usize = data.variables.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        switch (std.mem.order(u8, data.variables[middle].name, name)) {
            .lt => low = middle + 1,
            .gt => high = middle,
            .eq => {
                for (data.variables[middle].regions) |candidate| {
                    if (std.ascii.eqlIgnoreCase(candidate, region)) return true;
                }
                return false;
            },
        }
    }
    return false;
}

fn isAlpha(value: []const u8) bool {
    for (value) |byte| {
        if (!std.ascii.isAlphabetic(byte)) return false;
    }
    return true;
}

fn isDigitString(value: []const u8) bool {
    for (value) |byte| {
        if (!std.ascii.isDigit(byte)) return false;
    }
    return true;
}

test "locale matcher picks ICU's expected locales" {
    const allocator = std.testing.allocator;
    const options = Options{};
    const supported1 = [_][]const u8{ "fr", "en-GB", "en" };
    try std.testing.expectEqualStrings(
        "en",
        (try bestMatchAlloc(
            allocator,
            &.{"en-US"},
            &supported1,
            null,
            options,
        )).?,
    );
    const supported2 = [_][]const u8{ "de", "fr", "ja" };
    try std.testing.expectEqualStrings(
        "de",
        (try bestMatchAlloc(
            allocator,
            &.{ "de-AT", "fr" },
            &supported2,
            null,
            options,
        )).?,
    );
    const supported3 = [_][]const u8{ "en-GB", "en-US" };
    try std.testing.expectEqualStrings(
        "en-GB",
        (try bestMatchAlloc(
            allocator,
            &.{"en-AU"},
            &supported3,
            null,
            options,
        )).?,
    );
    const supported4 = [_][]const u8{ "en", "sv" };
    try std.testing.expectEqualStrings(
        "en",
        (try bestMatchAlloc(
            allocator,
            &.{ "en-GB", "sv" },
            &supported4,
            null,
            options,
        )).?,
    );
    const supported5 = [_][]const u8{ "de", "fr" };
    try std.testing.expectEqualStrings(
        "de",
        (try bestMatchAlloc(
            allocator,
            &.{"gsw"},
            &supported5,
            null,
            options,
        )).?,
    );
    const supported6 = [_][]const u8{ "ja-JP", "de", "zh-TW" };
    try std.testing.expectEqualStrings(
        "de",
        (try bestMatchAlloc(
            allocator,
            &.{ "gsw", "de", "fr", "it" },
            &supported6,
            null,
            options,
        )).?,
    );
}

test "locale matcher distances and thresholds" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqual(
        @as(u16, 5),
        try distanceAlloc(allocator, "en-US", "en-GB"),
    );
    try std.testing.expectEqual(
        @as(u16, 0),
        try distanceAlloc(allocator, "en", "en-US"),
    );
    try std.testing.expectEqual(
        @as(u16, 4),
        try distanceAlloc(allocator, "de-DE", "de-AT"),
    );
    try std.testing.expectEqual(
        @as(u16, 3),
        try distanceAlloc(allocator, "en-AU", "en-GB"),
    );
    try std.testing.expectEqual(
        @as(u16, 5),
        try distanceAlloc(allocator, "sr-Latn", "sr-Cyrl"),
    );
    try std.testing.expect(try isMatchAlloc(
        allocator,
        "en-US",
        "en-GB",
        default_threshold,
    ));
    try std.testing.expect(!try isMatchAlloc(
        allocator,
        "en-US",
        "fr",
        default_threshold,
    ));
    try std.testing.expect(!try isMatchAlloc(
        allocator,
        "en-US",
        "fr",
        84,
    ));
    try std.testing.expect(try isMatchAlloc(
        allocator,
        "en-US",
        "fr",
        85,
    ));
}

test "locale matcher defaults and und" {
    const allocator = std.testing.allocator;
    const supported = [_][]const u8{"ja-JP"};
    try std.testing.expectEqualStrings(
        "ja-JP",
        (try bestMatchAlloc(
            allocator,
            &.{"zh"},
            &supported,
            null,
            .{},
        )).?,
    );
    const supported2 = [_][]const u8{ "en", "it" };
    // `und` never matches by likely subtags; a later exact preference still
    // wins because the demotion stays below the threshold, like ICU.
    try std.testing.expectEqualStrings(
        "it",
        (try bestMatchAlloc(
            allocator,
            &.{ "und", "it" },
            &supported2,
            null,
            .{},
        )).?,
    );
    try std.testing.expectEqualStrings(
        "fr-FR",
        (try bestMatchAlloc(
            allocator,
            &.{"zh"},
            &supported2,
            "fr-FR",
            .{},
        )).?,
    );
    try std.testing.expect(
        (try bestMatchAlloc(allocator, &.{"en"}, &.{}, null, .{})) == null,
    );
}
