//! ICU `DateTimePatternGenerator` skeleton helpers.
//!
//! Converts localized date/time patterns to skeletons, reduces skeletons to
//! their base form, and replaces pattern field widths from a skeleton. The
//! field table and ordering mirror ICU's `dtptngen` so results match
//! `getSkeleton`, `getBaseSkeleton`, and `replaceFieldTypes`.

const std = @import("std");

pub const Error = error{ OutOfMemory };

const Field = enum(u4) {
    era,
    year,
    quarter,
    month,
    week_of_year,
    week_of_month,
    weekday,
    day_of_year,
    day_of_week_in_month,
    day,
    day_period,
    hour,
    minute,
    second,
    fraction,
    zone,
};

const field_count = @typeInfo(Field).@"enum".fields.len;

const Entry = struct {
    char: u8 = 0,
    count: u8 = 0,
};

const FieldSet = [field_count]Entry;

fn fieldForChar(char: u8) ?Field {
    return switch (char) {
        'G' => .era,
        'y', 'Y', 'u', 'U', 'r' => .year,
        'Q', 'q' => .quarter,
        'M', 'L', 'l' => .month,
        'w' => .week_of_year,
        'W' => .week_of_month,
        'E', 'e', 'c' => .weekday,
        'D' => .day_of_year,
        'F' => .day_of_week_in_month,
        'd', 'g' => .day,
        'a', 'b', 'B' => .day_period,
        'H', 'h', 'K', 'k', 'J', 'j', 'C' => .hour,
        'm' => .minute,
        's', 'A' => .second,
        'S' => .fraction,
        'z', 'Z', 'O', 'v', 'V', 'X', 'x' => .zone,
        else => null,
    };
}

fn baseLength(char: u8, count: u8) u8 {
    const index: usize = @min(count, 6) - 1;
    return switch (char) {
        'G', 'U', 'a', 'b', 'B', 'Z' => ([6]u8{ 1, 1, 1, 4, 5, 5 })[index],
        'E' => ([6]u8{ 1, 1, 1, 4, 5, 6 })[index],
        'e', 'c' => ([6]u8{ 1, 1, 3, 4, 5, 6 })[index],
        'M', 'L', 'Q', 'q' => ([6]u8{ 1, 1, 3, 4, 5, 5 })[index],
        'z', 'O', 'v' => ([6]u8{ 1, 1, 1, 4, 4, 4 })[index],
        'V' => ([6]u8{ 1, 2, 3, 4, 4, 4 })[index],
        'X', 'x' => ([6]u8{ 1, 2, 2, 4, 4, 4 })[index],
        else => 1,
    };
}

/// Convert a date/time pattern such as `EEEE, MMMM d, y` to its canonical
/// skeleton (`yMMMMEEEEd`).
pub fn skeletonForPatternAlloc(
    allocator: std.mem.Allocator,
    pattern: []const u8,
) Error![]u8 {
    var fields = [_]Entry{.{}} ** field_count;
    parsePattern(&fields, pattern);
    const added_default = applySkeletonRules(&fields);
    if (added_default) fields[@intFromEnum(Field.day_period)] = .{};
    return emitFields(allocator, &fields, false);
}

/// Reduce a skeleton to its base form (`yyyyMMdd` becomes `yMd`).
pub fn baseSkeletonAlloc(
    allocator: std.mem.Allocator,
    skeleton: []const u8,
) Error![]u8 {
    var fields = [_]Entry{.{}} ** field_count;
    parsePattern(&fields, skeleton);
    const added_default = applySkeletonRules(&fields);
    if (added_default) fields[@intFromEnum(Field.day_period)] = .{};
    return emitFields(allocator, &fields, true);
}

/// Replace the field characters and widths of `pattern` with those present in
/// `skeleton`, leaving fields absent from the skeleton and all literals as-is.
/// Uses `h` as the default hour character (ICU's `en` hour cycle).
pub fn replaceFieldTypesAlloc(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    skeleton: []const u8,
) Error![]u8 {
    return replaceFieldTypesWithHourAlloc(
        allocator,
        pattern,
        skeleton,
        'h',
    );
}

/// Like `replaceFieldTypesAlloc`, but with an explicit locale default hour
/// character (`h`, `H`, `K`, or `k`).
pub fn replaceFieldTypesWithHourAlloc(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    skeleton: []const u8,
    default_hour: u8,
) Error![]u8 {
    var fields = [_]Entry{.{}} ** field_count;
    parsePattern(&fields, skeleton);
    _ = applySkeletonRules(&fields);

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    var index: usize = 0;
    while (index < pattern.len) {
        const char = pattern[index];
        if (char == '\'') {
            const start = index;
            index += 1;
            while (index < pattern.len) {
                if (pattern[index] == '\'') {
                    if (index + 1 < pattern.len and pattern[index + 1] == '\'') {
                        index += 2;
                        continue;
                    }
                    index += 1;
                    break;
                }
                index += 1;
            }
            try output.appendSlice(allocator, pattern[start..index]);
            continue;
        }
        if (fieldForChar(char)) |field| {
            var count: usize = 1;
            while (index + count < pattern.len and
                pattern[index + count] == char)
            {
                count += 1;
            }
            const entry = fields[@intFromEnum(field)];
            if (entry.count == 0) {
                try output.appendSlice(allocator, pattern[index .. index + count]);
                index += count;
                continue;
            }
            var output_char = entry.char;
            var output_count = entry.count;
            switch (field) {
                .hour => {
                    output_count = @intCast(count);
                    output_char = char;
                    if (entry.char == default_hour) output_char = default_hour;
                },
                .minute, .second => {
                    output_count = @intCast(count);
                },
                .month => output_char = char,
                .weekday => {
                    output_char = char;
                    if (entry.char == 'E' and entry.count < 3) {
                        output_count = 3;
                    }
                },
                .year => {
                    if (entry.char != 'Y') output_char = char;
                },
                else => {},
            }
            try output.appendNTimes(allocator, output_char, output_count);
            index += count;
            continue;
        }
        try output.append(allocator, char);
        index += 1;
    }
    return output.toOwnedSlice(allocator);
}

fn parsePattern(fields: *FieldSet, text: []const u8) void {
    var index: usize = 0;
    while (index < text.len) {
        const char = text[index];
        if (char == '\'') {
            index += 1;
            while (index < text.len) {
                if (text[index] == '\'') {
                    if (index + 1 < text.len and text[index + 1] == '\'') {
                        index += 2;
                        continue;
                    }
                    index += 1;
                    break;
                }
                index += 1;
            }
            continue;
        }
        if (fieldForChar(char)) |field| {
            var count: u8 = 1;
            while (index + count < text.len and
                text[index + count] == char and count < 255)
            {
                count += 1;
            }
            fields[@intFromEnum(field)] = .{ .char = char, .count = count };
            index += count;
            continue;
        }
        index += 1;
    }
}

fn applySkeletonRules(fields: *FieldSet) bool {
    if (fields[@intFromEnum(Field.minute)].count != 0 and
        fields[@intFromEnum(Field.fraction)].count != 0 and
        fields[@intFromEnum(Field.second)].count == 0)
    {
        fields[@intFromEnum(Field.second)] = .{ .char = 's', .count = 1 };
    }
    var added_default = false;
    const hour = fields[@intFromEnum(Field.hour)];
    if (hour.count != 0) {
        switch (hour.char) {
            'H', 'k', 'j', 'J', 'C' => fields[@intFromEnum(Field.day_period)] = .{},
            'h', 'K' => {
                if (fields[@intFromEnum(Field.day_period)].count == 0) {
                    fields[@intFromEnum(Field.day_period)] = .{
                        .char = 'a',
                        .count = 1,
                    };
                    added_default = true;
                }
            },
            else => {},
        }
    }
    return added_default;
}

fn emitFields(
    allocator: std.mem.Allocator,
    fields: *const FieldSet,
    base: bool,
) Error![]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    for (fields) |entry| {
        if (entry.count == 0) continue;
        const length = if (base) baseLength(entry.char, entry.count) else entry.count;
        try output.appendNTimes(allocator, entry.char, length);
    }
    return output.toOwnedSlice(allocator);
}

test "date pattern skeletons and field replacement" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const skeleton = try skeletonForPatternAlloc(
        allocator,
        "EEEE, MMMM d, y",
    );
    defer allocator.free(skeleton);
    try testing.expectEqualStrings("yMMMMEEEEd", skeleton);

    const time = try skeletonForPatternAlloc(allocator, "h:mm a");
    defer allocator.free(time);
    try testing.expectEqualStrings("ahmm", time);

    const base = try baseSkeletonAlloc(allocator, "yyyyMMdd");
    defer allocator.free(base);
    try testing.expectEqualStrings("yMd", base);

    const replaced = try replaceFieldTypesAlloc(
        allocator,
        "y-MM-dd",
        "yMMMMd",
    );
    defer allocator.free(replaced);
    try testing.expectEqualStrings("y-MMMM-d", replaced);

    const hour = try replaceFieldTypesAlloc(allocator, "H:mm", "hm");
    defer allocator.free(hour);
    try testing.expectEqualStrings("h:mm", hour);
}

const conformance = @embedFile("pattern_generator_conformance.bin");

test "DateTimePatternGenerator conformance" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    try testing.expect(conformance.len >= 12);
    try testing.expectEqualSlices(u8, "CJPG", conformance[0..4]);
    try testing.expectEqual(@as(u8, 1), conformance[4]);
    const case_count = std.mem.readInt(u32, conformance[8..12], .little);
    var offset: usize = 12;
    var index: usize = 0;
    while (index < case_count) : (index += 1) {
        const kind = conformance[offset];
        const first_len = std.mem.readInt(
            u16,
            conformance[offset + 1 ..][0..2],
            .little,
        );
        const second_len = std.mem.readInt(
            u16,
            conformance[offset + 3 ..][0..2],
            .little,
        );
        const expected_len = std.mem.readInt(
            u16,
            conformance[offset + 5 ..][0..2],
            .little,
        );
        offset += 7;
        const first = conformance[offset..][0..first_len];
        offset += first_len;
        const second = conformance[offset..][0..second_len];
        offset += second_len;
        const expected = conformance[offset..][0..expected_len];
        offset += expected_len;

        const actual = switch (kind) {
            0 => try skeletonForPatternAlloc(allocator, first),
            1 => try baseSkeletonAlloc(allocator, first),
            2 => try replaceFieldTypesAlloc(allocator, first, second),
            else => return error.InvalidPattern,
        };
        defer allocator.free(actual);
        testing.expectEqualStrings(expected, actual) catch |err| {
            std.debug.print(
                "pattern generator case {d} kind={d} first={s} second={s}\n",
                .{ index, kind, first, second },
            );
            return err;
        };
    }
    try testing.expectEqual(conformance.len, offset);
}
