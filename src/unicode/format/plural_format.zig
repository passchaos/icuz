//! ICU `PluralFormat`-compatible plural branch selection.

const std = @import("std");
const branch_pattern = @import("branch_pattern.zig");
const number = @import("number.zig");
const plural = @import("plurals.zig");

pub const Error = error{
    InvalidPattern,
    OutOfMemory,
};

pub const PluralFormat = struct {
    allocator: std.mem.Allocator,
    locale: []u8,
    pattern: []u8 = &.{},
    branches: []branch_pattern.Branch = &.{},
    offset: i64 = 0,

    pub fn init(allocator: std.mem.Allocator, locale: []const u8) !PluralFormat {
        return .{
            .allocator = allocator,
            .locale = try allocator.dupe(u8, locale),
        };
    }

    pub fn deinit(self: *PluralFormat) void {
        if (self.pattern.len != 0) self.allocator.free(self.pattern);
        if (self.branches.len != 0) self.allocator.free(self.branches);
        self.allocator.free(self.locale);
        self.* = undefined;
    }

    pub fn applyPattern(self: *PluralFormat, pattern: []const u8) Error!void {
        const owned = try self.allocator.dupe(u8, pattern);
        errdefer self.allocator.free(owned);
        var rest = owned;
        var offset: i64 = 0;
        if (std.mem.startsWith(u8, rest, "offset:")) {
            var index: usize = "offset:".len;
            const start = index;
            while (index < rest.len and rest[index] >= '0' and
                rest[index] <= '9')
            {
                index += 1;
            }
            if (index == start) return error.InvalidPattern;
            offset = std.fmt.parseInt(i64, rest[start..index], 10) catch
                return error.InvalidPattern;
            while (index < rest.len and
                (rest[index] == ' ' or rest[index] == '\t' or
                    rest[index] == '\r' or rest[index] == '\n'))
            {
                index += 1;
            }
            rest = rest[index..];
        }
        const branches = try branch_pattern.parseBranches(self.allocator, rest);
        errdefer self.allocator.free(branches);
        var has_other = false;
        for (branches) |branch| {
            if (std.mem.eql(u8, branch.key, "other")) has_other = true;
        }
        if (!has_other) return error.InvalidPattern;

        if (self.pattern.len != 0) self.allocator.free(self.pattern);
        if (self.branches.len != 0) self.allocator.free(self.branches);
        self.pattern = owned;
        self.branches = branches;
        self.offset = offset;
    }

    pub fn toPattern(self: *const PluralFormat) []const u8 {
        return self.pattern;
    }

    pub fn formatAlloc(
        self: *const PluralFormat,
        allocator: std.mem.Allocator,
        value: f64,
    ) Error![]u8 {
        const adjusted = value - @as(f64, @floatFromInt(self.offset));
        for (self.branches) |branch| {
            if (branch.key.len > 1 and branch.key[0] == '=') {
                const exact = std.fmt.parseInt(i64, branch.key[1..], 10) catch
                    continue;
                if (@as(f64, @floatFromInt(exact)) == value) {
                    return self.render(allocator, branch.message, adjusted);
                }
            }
        }

        const category = self.categoryFor(adjusted);
        var other: ?[]const u8 = null;
        for (self.branches) |branch| {
            if (std.mem.eql(u8, branch.key, @tagName(category))) {
                return self.render(allocator, branch.message, adjusted);
            }
            if (std.mem.eql(u8, branch.key, "other")) {
                other = branch.message;
            }
        }
        return self.render(
            allocator,
            other orelse return error.InvalidPattern,
            adjusted,
        );
    }

    fn categoryFor(self: *const PluralFormat, value: f64) plural.Category {
        const truncated = @trunc(value);
        if (truncated == value and value >= -9.2e18 and value <= 9.2e18) {
            return plural.categoryForInteger(
                self.locale,
                @intFromFloat(value),
            );
        }
        var buffer: [64]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch
            return .other;
        return plural.categoryForDecimalString(self.locale, text) catch
            .other;
    }

    fn render(
        self: *const PluralFormat,
        allocator: std.mem.Allocator,
        message: []const u8,
        number_value: f64,
    ) Error![]u8 {
        const text = number.formatAlloc(
            allocator,
            number_value,
            self.locale,
            .{},
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidPattern,
        };
        defer allocator.free(text);
        var output = std.ArrayList(u8).empty;
        errdefer output.deinit(allocator);
        for (message) |byte| {
            if (byte == '#') {
                try output.appendSlice(allocator, text);
            } else {
                try output.append(allocator, byte);
            }
        }
        return output.toOwnedSlice(allocator);
    }
};

test "PluralFormat selection" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    var format = try PluralFormat.init(allocator, "en");
    defer format.deinit();
    try format.applyPattern("one {# item} other {# items}");
    const one = try format.formatAlloc(allocator, 1);
    defer allocator.free(one);
    try testing.expectEqualStrings("1 item", one);
    const many = try format.formatAlloc(allocator, 2);
    defer allocator.free(many);
    try testing.expectEqualStrings("2 items", many);

    try format.applyPattern("offset:1 one {# person} other {# people}");
    const person = try format.formatAlloc(allocator, 2);
    defer allocator.free(person);
    try testing.expectEqualStrings("1 person", person);

    try format.applyPattern("=0 {nobody} one {# person} other {# people}");
    const nobody = try format.formatAlloc(allocator, 0);
    defer allocator.free(nobody);
    try testing.expectEqualStrings("nobody", nobody);

    var russian = try PluralFormat.init(allocator, "ru");
    defer russian.deinit();
    try russian.applyPattern(
        "one {# файл} few {# файла} many {# файлов} other {# файла}",
    );
    const few = try russian.formatAlloc(allocator, 2);
    defer allocator.free(few);
    try testing.expectEqualStrings("2 файла", few);
    const many_ru = try russian.formatAlloc(allocator, 5);
    defer allocator.free(many_ru);
    try testing.expectEqualStrings("5 файлов", many_ru);
}
