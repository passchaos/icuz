//! ICU SelectFormat/PluralFormat differential conformance test.

const std = @import("std");
const select_format = @import("select_format.zig");
const plural_format = @import("plural_format.zig");

fn fixtureUtf16ToUtf8(
    allocator: std.mem.Allocator,
    fixture: []const u8,
    offset: usize,
    length: u16,
) ![]u8 {
    const units = try allocator.alloc(u16, length);
    defer allocator.free(units);
    for (units, 0..) |*unit, index| {
        unit.* = std.mem.readInt(
            u16,
            fixture[offset + index * 2 ..][0..2],
            .little,
        );
    }
    return std.unicode.utf16LeToUtf8Alloc(allocator, units);
}

test "ICU SelectFormat and PluralFormat conformance" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const fixture = @embedFile("plural_select_conformance.bin");

    try testing.expect(fixture.len >= 12);
    try testing.expectEqualStrings("CJGW", fixture[0..4]);
    try testing.expectEqual(@as(u8, 1), fixture[4]);
    const record_count = std.mem.readInt(u32, fixture[8..12], .little);

    const select_patterns = [_][]const u8{
        "female {She} male {He} other {They}",
        "a {X} b {Y} other {Z}",
        "0 {zero} 1 {one} other {many}",
    };
    const plural_locales = [_][]const u8{ "en", "ru", "fr" };
    const plural_patterns = [_][]const u8{
        "one {# item} other {# items}",
        "offset:1 one {# person} other {# people}",
        "=0 {nobody} one {# person} other {# people}",
        "one {# jour} other {# jours}",
        "one {# файл} few {# файла} many {# файлов} other {# файла}",
    };

    var cursor: usize = 12;
    var failures: usize = 0;
    var record_index: usize = 0;
    while (record_index < record_count) : (record_index += 1) {
        const kind = fixture[cursor];
        cursor += 1;
        if (kind == 0) {
            const pattern_index = fixture[cursor];
            cursor += 1;
            const key_length = std.mem.readInt(
                u16,
                fixture[cursor..][0..2],
                .little,
            );
            cursor += 2;
            const key = try fixtureUtf16ToUtf8(
                allocator,
                fixture,
                cursor,
                key_length,
            );
            defer allocator.free(key);
            cursor += @as(usize, key_length) * 2;
            const message_length = std.mem.readInt(
                u16,
                fixture[cursor..][0..2],
                .little,
            );
            cursor += 2;
            const expected = try fixtureUtf16ToUtf8(
                allocator,
                fixture,
                cursor,
                message_length,
            );
            defer allocator.free(expected);
            cursor += @as(usize, message_length) * 2;
            if (pattern_index >= select_patterns.len) {
                return error.InvalidFixture;
            }
            var format = select_format.SelectFormat.init(allocator);
            defer format.deinit();
            format.applyPattern(select_patterns[pattern_index]) catch {
                failures += 1;
                continue;
            };
            const actual = format.formatAlloc(allocator, key) catch {
                failures += 1;
                continue;
            };
            defer allocator.free(actual);
            if (!std.mem.eql(u8, actual, expected)) {
                failures += 1;
                if (failures <= 10) {
                    std.debug.print(
                        "SelectFormat mismatch: pattern {d} key [{s}] got [{s}] want [{s}]\n",
                        .{ pattern_index, key, actual, expected },
                    );
                }
            }
        } else if (kind == 1) {
            const locale_index = fixture[cursor];
            const pattern_index = fixture[cursor + 1];
            cursor += 2;
            const value_bits = std.mem.readInt(
                u64,
                fixture[cursor..][0..8],
                .little,
            );
            cursor += 8;
            const value: f64 = @bitCast(value_bits);
            const message_length = std.mem.readInt(
                u16,
                fixture[cursor..][0..2],
                .little,
            );
            cursor += 2;
            const expected = try fixtureUtf16ToUtf8(
                allocator,
                fixture,
                cursor,
                message_length,
            );
            defer allocator.free(expected);
            cursor += @as(usize, message_length) * 2;
            if (locale_index >= plural_locales.len or
                pattern_index >= plural_patterns.len)
            {
                return error.InvalidFixture;
            }
            var format = plural_format.PluralFormat.init(
                allocator,
                plural_locales[locale_index],
            ) catch {
                failures += 1;
                continue;
            };
            defer format.deinit();
            format.applyPattern(plural_patterns[pattern_index]) catch {
                failures += 1;
                continue;
            };
            const actual = format.formatAlloc(allocator, value) catch {
                failures += 1;
                continue;
            };
            defer allocator.free(actual);
            if (!std.mem.eql(u8, actual, expected)) {
                failures += 1;
                if (failures <= 10) {
                    std.debug.print(
                        "PluralFormat mismatch: locale {d} pattern {d} value {d} got [{s}] want [{s}]\n",
                        .{
                            locale_index,
                            pattern_index,
                            value,
                            actual,
                            expected,
                        },
                    );
                }
            }
        } else {
            return error.InvalidFixture;
        }
    }
    try testing.expectEqual(fixture.len, cursor);
    try testing.expectEqual(@as(usize, 0), failures);
    std.debug.print(
        "SelectFormat/PluralFormat conformance: {d} records passed\n",
        .{record_count},
    );
}
