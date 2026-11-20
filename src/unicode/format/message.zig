//! ICU-style plural/select message formatting built on the CLDR number,
//! plural, and date modules.

const std = @import("std");
const number = @import("number.zig");
const plural = @import("plurals.zig");
const dates = @import("dates.zig");
const choice = @import("choice.zig");

pub const Error = error{
    InvalidMessage,
    MissingArgument,
    InvalidArgument,
    OutOfMemory,
};

pub const Argument = union(enum) {
    string: []const u8,
    integer: i64,
    float: f64,
    date_time: dates.DateTime,
};

pub const NamedArgument = struct {
    name: []const u8,
    value: Argument,
};

pub const Arguments = struct {
    positional: []const Argument = &.{},
    named: []const NamedArgument = &.{},
};

/// Format a message using `{0}`, `{name}`, `{0, number, percent}`,
/// `{0, date, medium}`, `{0, plural, ...}`, `{0, select, ...}`, and
/// `{0, choice, ...}` syntax.
pub fn formatAlloc(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    locale: []const u8,
    arguments: Arguments,
) Error![]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try formatMessage(
        allocator,
        pattern,
        locale,
        arguments,
        null,
        &output,
    );
    return output.toOwnedSlice(allocator);
}

fn formatMessage(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    locale: []const u8,
    arguments: Arguments,
    hash_text: ?[]const u8,
    output: *std.ArrayList(u8),
) Error!void {
    var index: usize = 0;
    while (index < pattern.len) {
        const byte = pattern[index];

        if (byte == '\'') {
            if (index + 1 < pattern.len and pattern[index + 1] == '\'') {
                try output.append(allocator, '\'');
                index += 2;
                continue;
            }
            if (index + 1 < pattern.len and
                (pattern[index + 1] == '{' or
                    pattern[index + 1] == '}' or
                    pattern[index + 1] == '#'))
            {
                index += 1;
                while (index < pattern.len) {
                    if (pattern[index] == '\'') {
                        if (index + 1 < pattern.len and
                            pattern[index + 1] == '\'')
                        {
                            try output.append(allocator, '\'');
                            index += 2;
                            continue;
                        }
                        index += 1;
                        break;
                    }
                    try output.append(allocator, pattern[index]);
                    index += 1;
                }
                continue;
            }
            try output.append(allocator, '\'');
            index += 1;
            continue;
        }

        if (byte == '#' and hash_text != null) {
            try output.appendSlice(allocator, hash_text.?);
            index += 1;
            continue;
        }

        if (byte == '{') {
            const close = findClosingBrace(pattern, index + 1) orelse
                return error.InvalidMessage;
            try formatArgumentBlock(
                allocator,
                pattern[index + 1 .. close],
                locale,
                arguments,
                hash_text,
                output,
            );
            index = close + 1;
            continue;
        }

        try output.append(allocator, byte);
        index += 1;
    }
}

fn formatArgumentBlock(
    allocator: std.mem.Allocator,
    content: []const u8,
    locale: []const u8,
    arguments: Arguments,
    hash_text: ?[]const u8,
    output: *std.ArrayList(u8),
) Error!void {
    const fields = splitFields(content) orelse return error.InvalidMessage;
    if (fields.name.len == 0) return error.InvalidMessage;
    const argument = resolveArgument(arguments, fields.name) orelse
        return error.MissingArgument;

    if (fields.kind.len == 0) {
        try appendSimpleArgument(allocator, argument, locale, output);
        return;
    }

    if (std.mem.eql(u8, fields.kind, "number")) {
        try appendNumberArgument(
            allocator,
            argument,
            locale,
            fields.rest,
            output,
        );
        return;
    }

    if (std.mem.eql(u8, fields.kind, "date") or
        std.mem.eql(u8, fields.kind, "time"))
    {
        try appendDateArgument(
            allocator,
            argument,
            locale,
            fields.kind,
            fields.rest,
            output,
        );
        return;
    }

    if (std.mem.eql(u8, fields.kind, "plural") or
        std.mem.eql(u8, fields.kind, "selectordinal"))
    {
        try appendPluralArgument(
            allocator,
            argument,
            locale,
            fields.rest,
            std.mem.eql(u8, fields.kind, "selectordinal"),
            arguments,
            hash_text,
            output,
        );
        return;
    }

    if (std.mem.eql(u8, fields.kind, "select")) {
        try appendSelectArgument(
            allocator,
            argument,
            locale,
            fields.rest,
            arguments,
            hash_text,
            output,
        );
        return;
    }

    if (std.mem.eql(u8, fields.kind, "choice")) {
        try appendChoiceArgument(
            allocator,
            argument,
            locale,
            fields.rest,
            arguments,
            hash_text,
            output,
        );
        return;
    }

    return error.InvalidMessage;
}

const Fields = struct {
    name: []const u8,
    kind: []const u8,
    rest: []const u8,
};

fn splitFields(content: []const u8) ?Fields {
    var commas: [2]usize = undefined;
    var comma_count: usize = 0;
    var depth: usize = 0;
    var in_quote = false;
    var index: usize = 0;
    while (index < content.len) : (index += 1) {
        const byte = content[index];
        if (byte == '\'') {
            if (index + 1 < content.len and content[index + 1] == '\'') {
                index += 1;
                continue;
            }
            in_quote = !in_quote;
            continue;
        }
        if (in_quote) continue;
        if (byte == '{') {
            depth += 1;
        } else if (byte == '}') {
            if (depth > 0) depth -= 1;
        } else if (byte == ',' and depth == 0) {
            if (comma_count == commas.len) return null;
            commas[comma_count] = index;
            comma_count += 1;
        }
    }

    if (comma_count == 0) {
        return .{
            .name = std.mem.trim(u8, content, " \t\r\n"),
            .kind = "",
            .rest = "",
        };
    }
    if (comma_count == 1) {
        return .{
            .name = std.mem.trim(u8, content[0..commas[0]], " \t\r\n"),
            .kind = std.mem.trim(
                u8,
                content[commas[0] + 1 ..],
                " \t\r\n",
            ),
            .rest = "",
        };
    }
    return .{
        .name = std.mem.trim(u8, content[0..commas[0]], " \t\r\n"),
        .kind = std.mem.trim(
            u8,
            content[commas[0] + 1 .. commas[1]],
            " \t\r\n",
        ),
        .rest = std.mem.trim(u8, content[commas[1] + 1 ..], " \t\r\n"),
    };
}

fn resolveArgument(
    arguments: Arguments,
    name: []const u8,
) ?Argument {
    if (name.len > 0 and isDigit(name[0])) {
        const index = std.fmt.parseInt(usize, name, 10) catch return null;
        if (index >= arguments.positional.len) return null;
        return arguments.positional[index];
    }
    for (arguments.named) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.value;
    }
    return null;
}

fn appendSimpleArgument(
    allocator: std.mem.Allocator,
    argument: Argument,
    locale: []const u8,
    output: *std.ArrayList(u8),
) Error!void {
    switch (argument) {
        .string => |value| try output.appendSlice(allocator, value),
        .integer => |value| {
            const text = number.formatIntegerAlloc(
                allocator,
                value,
                locale,
                .{},
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidArgument,
            };
            defer allocator.free(text);
            try output.appendSlice(allocator, text);
        },
        .float => |value| {
            const text = number.formatAlloc(
                allocator,
                value,
                locale,
                .{},
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidArgument,
            };
            defer allocator.free(text);
            try output.appendSlice(allocator, text);
        },
        .date_time => |value| {
            const text = dates.formatDateAlloc(
                allocator,
                value,
                locale,
                .medium,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidArgument,
            };
            defer allocator.free(text);
            try output.appendSlice(allocator, text);
        },
    }
}

fn appendNumberArgument(
    allocator: std.mem.Allocator,
    argument: Argument,
    locale: []const u8,
    style: []const u8,
    output: *std.ArrayList(u8),
) Error!void {
    const value: f64 = switch (argument) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float| float,
        else => return error.InvalidArgument,
    };

    var options = number.Options{};
    if (std.mem.eql(u8, style, "percent")) {
        options.style = .percent;
    } else if (std.mem.eql(u8, style, "currency")) {
        options.style = .currency;
        options.currency = "USD";
    } else if (std.mem.eql(u8, style, "integer")) {
        options.max_fraction_digits = 0;
    }

    const text = number.formatAlloc(allocator, value, locale, options) catch |err|
        switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidArgument,
        };
    defer allocator.free(text);
    try output.appendSlice(allocator, text);
}

fn appendDateArgument(
    allocator: std.mem.Allocator,
    argument: Argument,
    locale: []const u8,
    kind: []const u8,
    style: []const u8,
    output: *std.ArrayList(u8),
) Error!void {
    const value = switch (argument) {
        .date_time => |date_time| date_time,
        else => return error.InvalidArgument,
    };
    const date_style = parseDateStyle(style) orelse .medium;
    const text = if (std.mem.eql(u8, kind, "time"))
        dates.formatTimeAlloc(allocator, value, locale, date_style) catch |err|
            switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidArgument,
            }
    else
        dates.formatDateAlloc(allocator, value, locale, date_style) catch |err|
            switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidArgument,
            };
    defer allocator.free(text);
    try output.appendSlice(allocator, text);
}

fn parseDateStyle(style: []const u8) ?dates.Style {
    if (std.mem.eql(u8, style, "full")) return .full;
    if (std.mem.eql(u8, style, "long")) return .long;
    if (std.mem.eql(u8, style, "medium")) return .medium;
    if (std.mem.eql(u8, style, "short")) return .short;
    return null;
}

fn appendPluralArgument(
    allocator: std.mem.Allocator,
    argument: Argument,
    locale: []const u8,
    style_input: []const u8,
    ordinal: bool,
    arguments: Arguments,
    hash_text: ?[]const u8,
    output: *std.ArrayList(u8),
) Error!void {
    var style = style_input;
    var offset: i64 = 0;
    if (std.mem.startsWith(u8, style, "offset:")) {
        var index: usize = "offset:".len;
        const start = index;
        while (index < style.len and isDigit(style[index])) index += 1;
        offset = std.fmt.parseInt(i64, style[start..index], 10) catch
            return error.InvalidMessage;
        style = std.mem.trimStart(u8, style[index..], " \t\r\n");
    }

    const original: f64 = switch (argument) {
        .integer => |value| @floatFromInt(value),
        .float => |value| value,
        else => return error.InvalidArgument,
    };
    const adjusted = original - @as(f64, @floatFromInt(offset));

    const category = switch (argument) {
        .integer => |value| if (ordinal)
            plural.ordinalCategoryForInteger(locale, value - offset)
        else
            plural.categoryForInteger(locale, value - offset),
        .float => blk: {
            var buffer: [64]u8 = undefined;
            const text = std.fmt.bufPrint(&buffer, "{d:.3}", .{adjusted}) catch
                return error.InvalidArgument;
            break :blk if (ordinal)
                plural.ordinalCategoryForDecimalString(locale, text) catch
                    return error.InvalidArgument
            else
                plural.categoryForDecimalString(locale, text) catch
                    return error.InvalidArgument;
        },
        else => return error.InvalidArgument,
    };

    const branch = findPluralBranch(style, category, original) orelse
        return error.InvalidMessage;

    const hash = number.formatAlloc(allocator, adjusted, locale, .{}) catch |err|
        switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidArgument,
        };
    defer allocator.free(hash);
    _ = hash_text;
    try formatMessage(
        allocator,
        branch,
        locale,
        arguments,
        hash,
        output,
    );
}

fn findPluralBranch(
    style: []const u8,
    category: plural.Category,
    exact_value: f64,
) ?[]const u8 {
    var category_branch: ?[]const u8 = null;
    var other_branch: ?[]const u8 = null;
    var index: usize = 0;
    while (index < style.len) {
        while (index < style.len and isSpace(style[index])) index += 1;
        if (index >= style.len) break;

        const key_start = index;
        while (index < style.len and style[index] != '{' and
            !isSpace(style[index])) index += 1;
        const key = style[key_start..index];
        while (index < style.len and isSpace(style[index])) index += 1;
        if (index >= style.len or style[index] != '{') return null;
        const open = index;
        const close = findClosingBrace(style, open + 1) orelse return null;
        const branch = style[open + 1 .. close];
        index = close + 1;

        if (key.len > 1 and key[0] == '=') {
            const exact = std.fmt.parseInt(i64, key[1..], 10) catch continue;
            if (@as(f64, @floatFromInt(exact)) == exact_value) return branch;
            continue;
        }
        if (std.mem.eql(u8, key, @tagName(category))) {
            category_branch = branch;
            continue;
        }
        if (std.mem.eql(u8, key, "other")) {
            other_branch = branch;
        }
    }
    return category_branch orelse other_branch;
}

fn appendSelectArgument(
    allocator: std.mem.Allocator,
    argument: Argument,
    locale: []const u8,
    style: []const u8,
    arguments: Arguments,
    hash_text: ?[]const u8,
    output: *std.ArrayList(u8),
) Error!void {
    const key = switch (argument) {
        .string => |value| value,
        else => return error.InvalidArgument,
    };
    const branch = findSelectBranch(style, key) orelse
        return error.InvalidMessage;
    try formatMessage(
        allocator,
        branch,
        locale,
        arguments,
        hash_text,
        output,
    );
}

fn findSelectBranch(style: []const u8, wanted: []const u8) ?[]const u8 {
    var other_branch: ?[]const u8 = null;
    var index: usize = 0;
    while (index < style.len) {
        while (index < style.len and isSpace(style[index])) index += 1;
        if (index >= style.len) break;

        const key_start = index;
        while (index < style.len and style[index] != '{' and
            !isSpace(style[index])) index += 1;
        const key = style[key_start..index];
        while (index < style.len and isSpace(style[index])) index += 1;
        if (index >= style.len or style[index] != '{') return null;
        const open = index;
        const close = findClosingBrace(style, open + 1) orelse return null;
        const branch = style[open + 1 .. close];
        index = close + 1;

        if (std.mem.eql(u8, key, wanted)) return branch;
        if (std.mem.eql(u8, key, "other")) other_branch = branch;
    }
    return other_branch;
}

fn appendChoiceArgument(
    allocator: std.mem.Allocator,
    argument: Argument,
    locale: []const u8,
    style: []const u8,
    arguments: Arguments,
    hash_text: ?[]const u8,
    output: *std.ArrayList(u8),
) Error!void {
    const value: f64 = switch (argument) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float| float,
        else => return error.InvalidArgument,
    };
    const branch = choice.selectMessage(style, value) orelse
        return error.InvalidMessage;
    try formatMessage(
        allocator,
        branch,
        locale,
        arguments,
        hash_text,
        output,
    );
}

fn findClosingBrace(text: []const u8, start: usize) ?usize {
    var depth: usize = 1;
    var in_quote = false;
    var index = start;
    while (index < text.len) : (index += 1) {
        const byte = text[index];
        if (byte == '\'') {
            if (index + 1 < text.len and text[index + 1] == '\'') {
                index += 1;
                continue;
            }
            in_quote = !in_quote;
            continue;
        }
        if (in_quote) continue;
        if (byte == '{') {
            depth += 1;
        } else if (byte == '}') {
            depth -= 1;
            if (depth == 0) return index;
        }
    }
    return null;
}

fn isDigit(byte: u8) bool {
    return byte >= '0' and byte <= '9';
}

fn isSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n';
}

test "simple arguments and quoting" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const args = Arguments{
        .positional = &.{Argument{ .string = "world" }},
    };
    const result = try formatAlloc(allocator, "Hello, {0}!", "en", args);
    defer allocator.free(result);
    try testing.expectEqualStrings("Hello, world!", result);

    const literal = try formatAlloc(allocator, "'{0}'", "en", .{});
    defer allocator.free(literal);
    try testing.expectEqualStrings("{0}", literal);

    try testing.expectError(
        error.MissingArgument,
        formatAlloc(allocator, "{0}", "en", .{}),
    );
}

test "plural messages" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const pattern = "{0, plural, one {# item} other {# items}}";
    const one = try formatAlloc(
        allocator,
        pattern,
        "en",
        .{ .positional = &.{Argument{ .integer = 1 }} },
    );
    defer allocator.free(one);
    try testing.expectEqualStrings("1 item", one);

    const many = try formatAlloc(
        allocator,
        pattern,
        "en",
        .{ .positional = &.{Argument{ .integer = 5 }} },
    );
    defer allocator.free(many);
    try testing.expectEqualStrings("5 items", many);

    const russian = "{0, plural, one {# файл} few {# файла} many {# файлов} other {# файла}}";
    const few = try formatAlloc(
        allocator,
        russian,
        "ru",
        .{ .positional = &.{Argument{ .integer = 2 }} },
    );
    defer allocator.free(few);
    try testing.expectEqualStrings("2 файла", few);

    const offset_pattern = "{0, plural, offset:1 =0 {nobody} one {# person} other {# people}}";
    const nobody = try formatAlloc(
        allocator,
        offset_pattern,
        "en",
        .{ .positional = &.{Argument{ .integer = 0 }} },
    );
    defer allocator.free(nobody);
    try testing.expectEqualStrings("nobody", nobody);

    const person = try formatAlloc(
        allocator,
        offset_pattern,
        "en",
        .{ .positional = &.{Argument{ .integer = 2 }} },
    );
    defer allocator.free(person);
    try testing.expectEqualStrings("1 person", person);

    const ordinal_pattern = "{0, selectordinal, one {#st} two {#nd} few {#rd} other {#th}}";
    const ordinal_cases = [_]struct { value: i64, expected: []const u8 }{
        .{ .value = 1, .expected = "1st" },
        .{ .value = 2, .expected = "2nd" },
        .{ .value = 3, .expected = "3rd" },
        .{ .value = 4, .expected = "4th" },
        .{ .value = 11, .expected = "11th" },
        .{ .value = 22, .expected = "22nd" },
    };
    for (ordinal_cases) |case| {
        const formatted = try formatAlloc(
            allocator,
            ordinal_pattern,
            "en",
            .{ .positional = &.{Argument{ .integer = case.value }} },
        );
        defer allocator.free(formatted);
        try testing.expectEqualStrings(case.expected, formatted);
    }
}

test "select, number, and date arguments" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const select = try formatAlloc(
        allocator,
        "{0, select, female {She} male {He} other {They}} likes tea",
        "en",
        .{ .positional = &.{Argument{ .string = "female" }} },
    );
    defer allocator.free(select);
    try testing.expectEqualStrings("She likes tea", select);

    const percent = try formatAlloc(
        allocator,
        "{0, number, percent}",
        "en",
        .{ .positional = &.{Argument{ .float = 0.25 }} },
    );
    defer allocator.free(percent);
    try testing.expectEqualStrings("25%", percent);

    const date = try formatAlloc(
        allocator,
        "{0, date, medium}",
        "en",
        .{ .positional = &.{Argument{
            .date_time = .{
                .year = 2026,
                .month = 11,
                .day = 18,
                .hour = 15,
                .minute = 4,
                .second = 5,
            },
        }} },
    );
    defer allocator.free(date);
    try testing.expectEqualStrings("Nov 18, 2026", date);

    const nested = try formatAlloc(
        allocator,
        "{0, select, female {{1, plural, one {She has # item} other {She has # items}}} other {They have items}}",
        "en",
        .{
            .positional = &.{
                Argument{ .string = "female" },
                Argument{ .integer = 2 },
            },
        },
    );
    defer allocator.free(nested);
    try testing.expectEqualStrings("She has 2 items", nested);
}

test "choice arguments" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const pattern = "{0, choice, 0#no files|1#one file|1<many files}";
    const cases = [_]struct { value: f64, expected: []const u8 }{
        .{ .value = 0, .expected = "no files" },
        .{ .value = 0.5, .expected = "no files" },
        .{ .value = 1, .expected = "one file" },
        .{ .value = 1.5, .expected = "many files" },
        .{ .value = 2, .expected = "many files" },
    };
    for (cases) |case| {
        const formatted = try formatAlloc(
            allocator,
            pattern,
            "en",
            .{ .positional = &.{Argument{ .float = case.value }} },
        );
        defer allocator.free(formatted);
        try testing.expectEqualStrings(case.expected, formatted);
    }

    const integer = try formatAlloc(
        allocator,
        pattern,
        "en",
        .{ .positional = &.{Argument{ .integer = 1 }} },
    );
    defer allocator.free(integer);
    try testing.expectEqualStrings("one file", integer);

    const escaped = try formatAlloc(
        allocator,
        "{0, choice, 0#a''b|1#c}",
        "en",
        .{ .positional = &.{Argument{ .float = 0.5 }} },
    );
    defer allocator.free(escaped);
    try testing.expectEqualStrings("a'b", escaped);

    const literal_hash = try formatAlloc(
        allocator,
        "{0, choice, 0#a#b|1#c}",
        "en",
        .{ .positional = &.{Argument{ .float = 0.5 }} },
    );
    defer allocator.free(literal_hash);
    try testing.expectEqualStrings("a#b", literal_hash);

    try testing.expectError(
        error.InvalidArgument,
        formatAlloc(
            allocator,
            pattern,
            "en",
            .{ .positional = &.{Argument{ .string = "one" }} },
        ),
    );
}
