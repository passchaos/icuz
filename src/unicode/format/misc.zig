//! Shared helpers for CLDR list, relative-time, and unit formatting.

const std = @import("std");
const plural = @import("plurals.zig");

pub fn findLocale(locales: anytype, name: []const u8) ?*const @TypeOf(locales[0]) {
    if (lookup(locales, name)) |entry| return entry;

    var buffer: [64]u8 = undefined;
    var length: usize = 0;
    for (name) |byte| {
        if (length == buffer.len) break;
        buffer[length] = if (byte == '-') '_' else byte;
        length += 1;
    }
    if (lookup(locales, buffer[0..length])) |entry| return entry;

    if (std.mem.indexOfAny(u8, name, "-_")) |position| {
        if (lookup(locales, name[0..position])) |entry| return entry;
    }
    return null;
}

fn lookup(locales: anytype, name: []const u8) ?*const @TypeOf(locales[0]) {
    var low: usize = 0;
    var high = locales.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const entry = locales[middle];
        switch (std.mem.order(u8, entry.id, name)) {
            .lt => low = middle + 1,
            .gt => high = middle,
            .eq => return &locales[middle],
        }
    }
    return null;
}

pub const LocaleSplit = struct {
    locale: []const u8,
    system: ?[]const u8,
};

/// Split a locale name with a numbering-system keyword such as
/// `en@numbers=arab` or `en-u-nu-arab`.
pub fn splitNumberingSystem(name: []const u8) LocaleSplit {
    // Plain language and region tags have none of the three separators; one
    // scan avoids three substring searches on the common formatting path.
    var plain = true;
    for (name) |byte| {
        if (byte == '@' or byte == ';' or byte == '-') {
            plain = false;
            break;
        }
    }
    if (plain) return .{ .locale = name, .system = null };
    if (std.mem.indexOfScalar(u8, name, '@')) |at| {
        return .{
            .locale = name[0..at],
            .system = findKeyword(name[at + 1 ..], "numbers"),
        };
    }
    if (std.mem.indexOfScalar(u8, name, ';')) |semi| {
        return .{
            .locale = name[0..semi],
            .system = findKeyword(name[semi + 1 ..], "numbers"),
        };
    }
    if (std.mem.indexOf(u8, name, "-u-")) |position| {
        var iterator = std.mem.splitScalar(u8, name[position + 3 ..], '-');
        while (iterator.next()) |key| {
            if (std.mem.eql(u8, key, "nu")) {
                if (iterator.next()) |value| {
                    return .{ .locale = name[0..position], .system = value };
                }
                break;
            }
        }
    }
    return .{ .locale = name, .system = null };
}

fn findKeyword(params: []const u8, keyword: []const u8) ?[]const u8 {
    var iterator = std.mem.splitScalar(u8, params, ';');
    while (iterator.next()) |part| {
        if (std.mem.indexOfScalar(u8, part, '=')) |equals| {
            if (std.mem.eql(u8, part[0..equals], keyword)) {
                return part[equals + 1 ..];
            }
        }
    }
    return null;
}

pub fn pluralCategory(locale: []const u8, value: f64) plural.Category {
    const magnitude = @abs(value);
    if (magnitude == @floor(magnitude) and
        magnitude <= @as(f64, @floatFromInt(std.math.maxInt(i64))))
    {
        return plural.categoryForInteger(locale, @intFromFloat(magnitude));
    }
    var buffer: [64]u8 = undefined;
    // Values whose shortest decimal expansion has at most nine fraction
    // digits skip Zig's general float formatter, which dominates the plural
    // path for formatted measurements and currency names.
    if (formatShortDecimal(&buffer, magnitude)) |text| {
        return plural.categoryForDecimalString(locale, text) catch .other;
    }
    const text = std.fmt.bufPrint(&buffer, "{d}", .{magnitude}) catch
        return .other;
    return plural.categoryForDecimalString(locale, text) catch .other;
}

const decimal_scales = [_]f64{
    1,
    10,
    100,
    1_000,
    10_000,
    100_000,
    1_000_000,
    10_000_000,
    100_000_000,
    1_000_000_000,
};

/// Write a non-negative integer in decimal.
fn writeUnsigned(buffer: []u8, value: u64) usize {
    var temp: [20]u8 = undefined;
    var index: usize = temp.len;
    var remaining = value;
    while (remaining >= 10) {
        index -= 1;
        temp[index] = '0' + @as(u8, @intCast(remaining % 10));
        remaining /= 10;
    }
    index -= 1;
    temp[index] = '0' + @as(u8, @intCast(remaining));
    const length = temp.len - index;
    @memcpy(buffer[0..length], temp[index..]);
    return length;
}

const decimal_pow10_int = [_]u64{
    1,
    10,
    100,
    1_000,
    10_000,
    100_000,
    1_000_000,
    10_000_000,
    100_000_000,
    1_000_000_000,
};

/// Format `magnitude` as its shortest exact decimal expansion when that
/// expansion has at most nine fraction digits, matching `{d}` output.
/// Returns null when the general float formatter is required.
fn formatShortDecimal(buffer: []u8, magnitude: f64) ?[]const u8 {
    for (1..decimal_scales.len) |digits| {
        const scaled = magnitude * decimal_scales[digits];
        // Above 2^53 consecutive integers are no longer exactly
        // representable, so the rounded value could not be trusted.
        if (scaled >= 9_007_199_254_740_992.0) return null;
        const total: u64 = @intFromFloat(@round(scaled));
        // A candidate is the shortest expansion only when the decimal string
        // parses back to the same double; otherwise more digits are needed.
        const back = @as(f64, @floatFromInt(total)) / decimal_scales[digits];
        if (back != magnitude) continue;
        const scale = decimal_pow10_int[digits];
        var length = writeUnsigned(buffer, total / scale);
        buffer[length] = '.';
        length += 1;
        var fraction_buffer: [10]u8 = undefined;
        const fraction_length = writeUnsigned(
            &fraction_buffer,
            total % scale,
        );
        const pad = digits - fraction_length;
        @memset(buffer[length..][0..pad], '0');
        length += pad;
        @memcpy(
            buffer[length..][0..fraction_length],
            fraction_buffer[0..fraction_length],
        );
        length += fraction_length;
        return buffer[0..length];
    }
    return null;
}

pub fn replacePlaceholderAlloc(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    value: []const u8,
) error{OutOfMemory}![]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    // The pattern with "{0}" replaced by the value never exceeds the two
    // lengths combined, so one exact reservation avoids growing the list.
    try output.ensureTotalCapacity(allocator, pattern.len + value.len);
    var index: usize = 0;
    while (index < pattern.len) {
        if (pattern[index] == '{' and index + 2 < pattern.len and
            pattern[index + 2] == '}' and pattern[index + 1] == '0')
        {
            try output.appendSlice(allocator, value);
            index += 3;
            continue;
        }
        try output.append(allocator, pattern[index]);
        index += 1;
    }
    return output.toOwnedSlice(allocator);
}
