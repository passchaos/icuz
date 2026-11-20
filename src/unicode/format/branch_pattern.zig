//! Shared parser for ICU SelectFormat and PluralFormat branch patterns.

const std = @import("std");

pub const Error = error{
    InvalidPattern,
    OutOfMemory,
};

pub const Branch = struct {
    key: []const u8,
    message: []const u8,
};

pub fn findClosingBrace(text: []const u8, open: usize) ?usize {
    var depth: usize = 1;
    var in_quote = false;
    var index = open + 1;
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

fn isSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n';
}

pub fn parseBranches(
    allocator: std.mem.Allocator,
    pattern: []const u8,
) Error![]Branch {
    var branches = std.ArrayList(Branch).empty;
    errdefer branches.deinit(allocator);
    var index: usize = 0;
    while (true) {
        while (index < pattern.len and isSpace(pattern[index])) index += 1;
        if (index >= pattern.len) break;
        const key_start = index;
        while (index < pattern.len and pattern[index] != '{' and
            !isSpace(pattern[index]))
        {
            index += 1;
        }
        const key = pattern[key_start..index];
        if (key.len == 0) return error.InvalidPattern;
        while (index < pattern.len and isSpace(pattern[index])) index += 1;
        if (index >= pattern.len or pattern[index] != '{') {
            return error.InvalidPattern;
        }
        const open = index;
        const close = findClosingBrace(pattern, open) orelse
            return error.InvalidPattern;
        try branches.append(allocator, .{
            .key = key,
            .message = pattern[open + 1 .. close],
        });
        index = close + 1;
    }
    if (branches.items.len == 0) return error.InvalidPattern;
    return branches.toOwnedSlice(allocator);
}
