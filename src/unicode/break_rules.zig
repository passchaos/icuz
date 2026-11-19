//! Runtime ICU break-rule engine (RuleBasedBreakIterator subset).
//!
//! Rules describe the character sequences that end at a boundary. Each rule
//! is a sequence of elements (literals, UnicodeSets, `.`, `$set` variables,
//! and groups with `|` alternation) with `?`/`*`/`+` quantifiers and an
//! optional `{status}` tag. At each boundary the engine takes the longest
//! matching rule; unmatched code points advance one at a time, matching ICU.

const std = @import("std");
const set = @import("set.zig");
const scalar = @import("scalar/root.zig");

pub const Error = error{
    InvalidRule,
    UnsupportedRule,
    InvalidUtf8,
    OutOfMemory,
};

const Quantifier = enum { one, optional, zero_or_more, one_or_more };

const Piece = struct {
    element: Element,
    quantifier: Quantifier = .one,
};

const Element = union(enum) {
    literal: []const u21,
    any: void,
    set: *const set.Set,
    group: []const []const Piece,
};

const Rule = struct {
    pieces: []const Piece,
    lookahead: []const Piece = &.{},
    status: u32 = 0,
};

/// Compiled break rules. Release with `deinit`.
pub const Rules = struct {
    arena: std.heap.ArenaAllocator,
    rules: []const Rule = &.{},

    pub fn deinit(self: *Rules) void {
        self.arena.deinit();
    }

    /// Iterate boundaries over UTF-8 text. Release with `deinit`.
    pub fn iterateAlloc(
        self: *const Rules,
        allocator: std.mem.Allocator,
        text: []const u8,
    ) Error!Iterator {
        var codepoints = std.ArrayList(u21).empty;
        errdefer codepoints.deinit(allocator);
        var index: usize = 0;
        while (index < text.len) {
            const length = std.unicode.utf8ByteSequenceLength(text[index]) catch
                return error.InvalidUtf8;
            if (index + length > text.len) return error.InvalidUtf8;
            const codepoint = std.unicode.utf8Decode(
                text[index..][0..length],
            ) catch return error.InvalidUtf8;
            try codepoints.append(allocator, codepoint);
            index += length;
        }
        return .{
            .allocator = allocator,
            .rules = self,
            .codepoints = try codepoints.toOwnedSlice(allocator),
        };
    }
};

/// Boundary iterator over decoded text.
pub const Iterator = struct {
    allocator: std.mem.Allocator,
    rules: *const Rules,
    codepoints: []const u21,
    position: usize = 0,
    last_status: u32 = 0,

    pub fn deinit(self: *Iterator) void {
        self.allocator.free(self.codepoints);
    }

    /// Advance to the next boundary and return its code-point offset, or
    /// null at the end of the text. Like ICU's `nextBoundary`, the start of
    /// the text is not reported; the end is.
    pub fn next(self: *Iterator) ?usize {
        if (self.position >= self.codepoints.len) return null;
        var best_end: ?usize = null;
        var best_status: u32 = 0;
        for (self.rules.rules) |rule| {
            if (matchSequence(rule.pieces, self.codepoints, self.position)) |end| {
                if (end > self.position and
                    lookaheadMatches(rule.lookahead, self.codepoints, end) and
                    (best_end == null or end > best_end.?))
                {
                    best_end = end;
                    best_status = rule.status;
                }
            }
        }
        const next_position = best_end orelse self.position + 1;
        self.last_status = if (best_end != null) best_status else 0;
        self.position = next_position;
        return self.position;
    }

    /// Rule status of the boundary most recently returned by `next`.
    pub fn status(self: Iterator) u32 {
        return self.last_status;
    }
};

fn lookaheadMatches(
    pieces: []const Piece,
    codepoints: []const u21,
    position: usize,
) bool {
    if (pieces.len == 0) return true;
    return matchSequence(pieces, codepoints, position) != null;
}

fn matchSequence(
    pieces: []const Piece,
    codepoints: []const u21,
    position: usize,
) ?usize {
    return matchSequenceFrom(pieces, 0, codepoints, position);
}

fn matchSequenceFrom(
    pieces: []const Piece,
    index: usize,
    codepoints: []const u21,
    position: usize,
) ?usize {
    if (index == pieces.len) return position;
    const piece = pieces[index];
    if (piece.element == .group) {
        const alternatives = piece.element.group;
        var ends: [64]usize = undefined;
        var count: usize = 0;
        var current = position;
        while (count < ends.len) {
            var best_group_end: ?usize = null;
            for (alternatives) |alternative| {
                if (matchSequence(alternative, codepoints, current)) |end| {
                    if (end > current and
                        (best_group_end == null or end > best_group_end.?))
                    {
                        best_group_end = end;
                    }
                }
            }
            const group_end = best_group_end orelse break;
            ends[count] = group_end;
            count += 1;
            current = group_end;
        }
        const minimum: usize = switch (piece.quantifier) {
            .one, .one_or_more => 1,
            .optional, .zero_or_more => 0,
        };
        const maximum: usize = switch (piece.quantifier) {
            .one, .optional => @min(count, 1),
            .zero_or_more, .one_or_more => count,
        };
        if (maximum < minimum) return null;
        var best: ?usize = null;
        var repetitions = maximum + 1;
        while (repetitions > minimum) {
            repetitions -= 1;
            const next_position = if (repetitions == 0)
                position
            else
                ends[repetitions - 1];
            if (matchSequenceFrom(
                pieces,
                index + 1,
                codepoints,
                next_position,
            )) |end| {
                if (best == null or end > best.?) best = end;
            }
        }
        return best;
    }

    const unit = unitLength(piece.element);
    if (unit == 0) return matchSequenceFrom(pieces, index + 1, codepoints, position);
    const available = (codepoints.len - position) / unit;
    const minimum: usize = switch (piece.quantifier) {
        .one, .one_or_more => 1,
        .optional, .zero_or_more => 0,
    };
    const maximum = switch (piece.quantifier) {
        .one, .optional => @min(available, 1),
        .zero_or_more, .one_or_more => available,
    };
    if (maximum < minimum) return null;
    var best: ?usize = null;
    var repetitions = maximum + 1;
    while (repetitions > minimum) {
        repetitions -= 1;
        if (!repetitionsMatch(piece.element, codepoints, position, repetitions)) {
            continue;
        }
        const next_position = position + repetitions * unit;
        if (matchSequenceFrom(pieces, index + 1, codepoints, next_position)) |end| {
            if (best == null or end > best.?) best = end;
        }
    }
    return best;
}

fn unitLength(element: Element) usize {
    return switch (element) {
        .literal => |sequence| sequence.len,
        .any, .set => 1,
        .group => 0,
    };
}

fn repetitionsMatch(
    element: Element,
    codepoints: []const u21,
    start: usize,
    repetitions: usize,
) bool {
    switch (element) {
        .literal => |sequence| {
            for (0..repetitions) |index| {
                const offset = start + index * sequence.len;
                if (!std.mem.eql(
                    u21,
                    codepoints[offset..][0..sequence.len],
                    sequence,
                )) return false;
            }
            return true;
        },
        .any => return true,
        .set => |unicode_set| {
            for (0..repetitions) |index| {
                if (!unicode_set.contains(codepoints[start + index])) {
                    return false;
                }
            }
            return true;
        },
        .group => return false,
    }
}

/// Compile ICU break rules.
pub fn compileAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
) Error!Rules {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();
    var parser = Parser{
        .arena = arena_allocator,
        .text = text,
        .index = 0,
        .variables = std.StringHashMap(*const set.Set).init(arena_allocator),
        .rules = std.ArrayList(Rule).empty,
    };
    try parser.parseAll();
    return .{
        .arena = arena,
        .rules = try parser.rules.toOwnedSlice(arena_allocator),
    };
}

const Parser = struct {
    arena: std.mem.Allocator,
    text: []const u8,
    index: usize,
    variables: std.StringHashMap(*const set.Set),
    rules: std.ArrayList(Rule),

    fn parseAll(self: *Parser) Error!void {
        while (self.nextStatement()) |statement| {
            if (statement.len == 0) continue;
            if (statement[0] == '$' and isVariableDefinition(statement)) {
                try self.parseVariable(statement);
            } else {
                try self.parseRule(statement);
            }
        }
    }

    fn nextStatement(self: *Parser) ?[]const u8 {
        while (true) {
            while (self.index < self.text.len and
                std.ascii.isWhitespace(self.text[self.index]))
            {
                self.index += 1;
            }
            if (self.index >= self.text.len) return null;
            if (self.text[self.index] != '#') break;
            while (self.index < self.text.len and self.text[self.index] != '\n') {
                self.index += 1;
            }
        }
        const start = self.index;
        var quoted = false;
        while (self.index < self.text.len) {
            const byte = self.text[self.index];
            if (byte == '\\' and !quoted) {
                self.index += @min(@as(usize, 2), self.text.len - self.index);
                continue;
            }
            if (byte == '\'') {
                quoted = !quoted;
                self.index += 1;
                continue;
            }
            if (byte == '#' and !quoted) {
                while (self.index < self.text.len and
                    self.text[self.index] != '\n')
                {
                    self.index += 1;
                }
                continue;
            }
            if (byte == ';' and !quoted) {
                const statement = std.mem.trim(
                    u8,
                    self.text[start..self.index],
                    " \t\r\n",
                );
                self.index += 1;
                return statement;
            }
            self.index += 1;
        }
        const statement = std.mem.trim(u8, self.text[start..], " \t\r\n");
        return if (statement.len == 0) null else statement;
    }

    fn parseVariable(self: *Parser, statement: []const u8) Error!void {
        var index: usize = 1;
        while (index < statement.len and isNameByte(statement[index])) index += 1;
        if (index == 1) return error.InvalidRule;
        const name = statement[1..index];
        while (index < statement.len and std.ascii.isWhitespace(statement[index])) {
            index += 1;
        }
        if (index >= statement.len or statement[index] != '=') {
            return error.InvalidRule;
        }
        index += 1;
        const value = std.mem.trim(u8, statement[index..], " \t\r\n");
        if (value.len == 0) return error.InvalidRule;
        const parsed = set.parse(self.arena, value) catch |err| switch (err) {
            error.InvalidPattern => return error.InvalidRule,
            error.OutOfMemory => return error.OutOfMemory,
        };
        const stored = try self.arena.create(set.Set);
        stored.* = parsed;
        try self.variables.put(try self.arena.dupe(u8, name), stored);
    }

    fn parseRule(self: *Parser, statement: []const u8) Error!void {
        var pattern_text = std.mem.trim(u8, statement, " \t\r\n");
        var reverse_only = false;
        if (pattern_text.len > 0 and pattern_text[0] == '!') {
            reverse_only = true;
            pattern_text = std.mem.trimStart(u8, pattern_text[1..], " \t\r\n");
        }
        var status: u32 = 0;
        if (pattern_text.len > 0 and pattern_text[pattern_text.len - 1] == '}') {
            if (std.mem.lastIndexOfScalar(u8, pattern_text, '{')) |open| {
                status = std.fmt.parseInt(
                    u32,
                    pattern_text[open + 1 .. pattern_text.len - 1],
                    10,
                ) catch return error.InvalidRule;
                pattern_text = std.mem.trim(
                    u8,
                    pattern_text[0..open],
                    " \t\r\n",
                );
            }
        }
        var segment_text = pattern_text;
        var lookahead_text: []const u8 = "";
        if (findUnquoted(pattern_text, '/')) |slash| {
            segment_text = pattern_text[0..slash];
            lookahead_text = pattern_text[slash + 1 ..];
        }
        const pieces = try self.parsePieces(segment_text);
        if (pieces.len == 0) return error.InvalidRule;
        if (reverse_only) return;
        const lookahead = try self.parsePieces(lookahead_text);
        try self.rules.append(self.arena, .{
            .pieces = pieces,
            .lookahead = lookahead,
            .status = status,
        });
    }

    fn parseRuleBody(self: *Parser, statement: []const u8) Error!void {
        var pieces = std.ArrayList(Piece).empty;
        errdefer pieces.deinit(self.arena);
        var index: usize = 0;
        while (index < statement.len) {
            const byte = statement[index];
            if (std.ascii.isWhitespace(byte)) {
                index += 1;
                continue;
            }
            switch (byte) {
                '\'' => {
                    const sequence = try parseQuoted(self.arena, statement, &index);
                    try pieces.append(self.arena, .{
                        .element = .{ .literal = sequence },
                    });
                },
                '\\' => {
                    const codepoint = try decodeEscape(statement, &index);
                    try pieces.append(self.arena, .{
                        .element = .{ .literal = try single(self.arena, codepoint) },
                    });
                },
                '[' => {
                    const pattern = try extractSetPattern(statement, &index);
                    const parsed = set.parse(self.arena, pattern) catch |err| switch (err) {
                        error.InvalidPattern => return error.InvalidRule,
                        error.OutOfMemory => return error.OutOfMemory,
                    };
                    const stored = try self.arena.create(set.Set);
                    stored.* = parsed;
                    try pieces.append(self.arena, .{
                        .element = .{ .set = stored },
                    });
                },
                '.' => {
                    index += 1;
                    try pieces.append(self.arena, .{ .element = .any });
                },
                '$' => {
                    const name = try readVariableName(statement, &index);
                    const variable = self.variables.get(name) orelse
                        return error.InvalidRule;
                    try pieces.append(self.arena, .{
                        .element = .{ .set = variable },
                    });
                },
                '(' => {
                    const close = findMatchingParen(statement, index) orelse
                        return error.InvalidRule;
                    const alternatives = try self.parseAlternatives(
                        statement[index + 1 .. close],
                    );
                    index = close + 1;
                    try pieces.append(self.arena, .{
                        .element = .{ .group = alternatives },
                    });
                },
                '?', '*', '+' => {
                    if (pieces.items.len == 0) return error.InvalidRule;
                    pieces.items[pieces.items.len - 1].quantifier = switch (byte) {
                        '?' => .optional,
                        '*' => .zero_or_more,
                        else => .one_or_more,
                    };
                    index += 1;
                },
                '!', '/' => return error.UnsupportedRule,
                else => {
                    const length = std.unicode.utf8ByteSequenceLength(byte) catch
                        return error.InvalidUtf8;
                    if (index + length > statement.len) return error.InvalidUtf8;
                    const codepoint = std.unicode.utf8Decode(
                        statement[index..][0..length],
                    ) catch return error.InvalidUtf8;
                    index += length;
                    try pieces.append(self.arena, .{
                        .element = .{ .literal = try single(self.arena, codepoint) },
                    });
                },
            }
        }
        if (pieces.items.len == 0) return error.InvalidRule;
        try self.rules.append(self.arena, .{
            .pieces = try pieces.toOwnedSlice(self.arena),
        });
    }

    fn parseAlternatives(
        self: *Parser,
        text: []const u8,
    ) Error![]const []const Piece {
        var alternatives = std.ArrayList([]const Piece).empty;
        errdefer alternatives.deinit(self.arena);
        var start: usize = 0;
        var index: usize = 0;
        var quoted = false;
        while (index <= text.len) : (index += 1) {
            if (index == text.len or (!quoted and text[index] == '|')) {
                const part = try self.parsePieces(text[start..index]);
                try alternatives.append(self.arena, part);
                start = index + 1;
                continue;
            }
            const byte = text[index];
            if (byte == '\\' and !quoted) {
                index += 1;
            } else if (byte == '\'') {
                quoted = !quoted;
            }
        }
        return alternatives.toOwnedSlice(self.arena);
    }

    fn parsePieces(self: *Parser, text: []const u8) Error![]const Piece {
        var pieces = std.ArrayList(Piece).empty;
        errdefer pieces.deinit(self.arena);
        var index: usize = 0;
        while (index < text.len) {
            const byte = text[index];
            if (std.ascii.isWhitespace(byte)) {
                index += 1;
                continue;
            }
            switch (byte) {
                '\'' => {
                    const sequence = try parseQuoted(self.arena, text, &index);
                    try pieces.append(self.arena, .{
                        .element = .{ .literal = sequence },
                    });
                },
                '\\' => {
                    const codepoint = try decodeEscape(text, &index);
                    try pieces.append(self.arena, .{
                        .element = .{ .literal = try single(self.arena, codepoint) },
                    });
                },
                '[' => {
                    const pattern = try extractSetPattern(text, &index);
                    const parsed = set.parse(self.arena, pattern) catch |err| switch (err) {
                        error.InvalidPattern => return error.InvalidRule,
                        error.OutOfMemory => return error.OutOfMemory,
                    };
                    const stored = try self.arena.create(set.Set);
                    stored.* = parsed;
                    try pieces.append(self.arena, .{
                        .element = .{ .set = stored },
                    });
                },
                '.' => {
                    index += 1;
                    try pieces.append(self.arena, .{ .element = .any });
                },
                '$' => {
                    const name = try readVariableName(text, &index);
                    const variable = self.variables.get(name) orelse
                        return error.InvalidRule;
                    try pieces.append(self.arena, .{
                        .element = .{ .set = variable },
                    });
                },
                '(' => {
                    const close = findMatchingParen(text, index) orelse
                        return error.InvalidRule;
                    const alternatives = try self.parseAlternatives(
                        text[index + 1 .. close],
                    );
                    index = close + 1;
                    try pieces.append(self.arena, .{
                        .element = .{ .group = alternatives },
                    });
                },
                '?', '*', '+' => {
                    if (pieces.items.len == 0) return error.InvalidRule;
                    pieces.items[pieces.items.len - 1].quantifier = switch (byte) {
                        '?' => .optional,
                        '*' => .zero_or_more,
                        else => .one_or_more,
                    };
                    index += 1;
                },
                '!', '/', '|', '{', '}' => return error.UnsupportedRule,
                else => {
                    const length = std.unicode.utf8ByteSequenceLength(byte) catch
                        return error.InvalidUtf8;
                    if (index + length > text.len) return error.InvalidUtf8;
                    const codepoint = std.unicode.utf8Decode(
                        text[index..][0..length],
                    ) catch return error.InvalidUtf8;
                    index += length;
                    try pieces.append(self.arena, .{
                        .element = .{ .literal = try single(self.arena, codepoint) },
                    });
                },
            }
        }
        return pieces.toOwnedSlice(self.arena);
    }
};

fn isNameByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn isVariableDefinition(statement: []const u8) bool {
    var index: usize = 1;
    while (index < statement.len and isNameByte(statement[index])) index += 1;
    if (index == 1) return false;
    while (index < statement.len and std.ascii.isWhitespace(statement[index])) {
        index += 1;
    }
    return index < statement.len and statement[index] == '=';
}

fn readVariableName(text: []const u8, index: *usize) Error![]const u8 {
    const start = index.*;
    if (start >= text.len or text[start] != '$') return error.InvalidRule;
    var cursor = start + 1;
    while (cursor < text.len and isNameByte(text[cursor])) cursor += 1;
    if (cursor == start + 1) return error.InvalidRule;
    index.* = cursor;
    return text[start + 1 .. cursor];
}

fn single(allocator: std.mem.Allocator, codepoint: u21) Error![]const u21 {
    const sequence = try allocator.alloc(u21, 1);
    sequence[0] = codepoint;
    return sequence;
}

fn parseQuoted(
    allocator: std.mem.Allocator,
    text: []const u8,
    index: *usize,
) Error![]const u21 {
    var codepoints = std.ArrayList(u21).empty;
    errdefer codepoints.deinit(allocator);
    if (index.* >= text.len or text[index.*] != '\'') return error.InvalidRule;
    index.* += 1;
    while (index.* < text.len) {
        const byte = text[index.*];
        if (byte == '\'') {
            if (index.* + 1 < text.len and text[index.* + 1] == '\'') {
                try codepoints.append(allocator, '\'');
                index.* += 2;
                continue;
            }
            index.* += 1;
            return codepoints.toOwnedSlice(allocator);
        }
        if (byte == '\\') {
            try codepoints.append(allocator, try decodeEscape(text, index));
            continue;
        }
        const length = std.unicode.utf8ByteSequenceLength(byte) catch
            return error.InvalidUtf8;
        if (index.* + length > text.len) return error.InvalidUtf8;
        const codepoint = std.unicode.utf8Decode(
            text[index.*..][0..length],
        ) catch return error.InvalidUtf8;
        try codepoints.append(allocator, codepoint);
        index.* += length;
    }
    return error.InvalidRule;
}

fn decodeEscape(text: []const u8, index: *usize) Error!u21 {
    if (index.* >= text.len or text[index.*] != '\\') return error.InvalidRule;
    index.* += 1;
    if (index.* >= text.len) return error.InvalidRule;
    const byte = text[index.*];
    index.* += 1;
    switch (byte) {
        'u' => {
            if (index.* + 4 > text.len) return error.InvalidRule;
            const value = std.fmt.parseInt(u21, text[index.*..][0..4], 16) catch
                return error.InvalidRule;
            index.* += 4;
            return value;
        },
        'U' => {
            if (index.* + 8 > text.len) return error.InvalidRule;
            const value = std.fmt.parseInt(u32, text[index.*..][0..8], 16) catch
                return error.InvalidRule;
            index.* += 8;
            if (value > 0x10ffff) return error.InvalidRule;
            return @intCast(value);
        },
        'x' => {
            if (index.* >= text.len or text[index.*] != '{') {
                return error.InvalidRule;
            }
            index.* += 1;
            const start = index.*;
            while (index.* < text.len and text[index.*] != '}') index.* += 1;
            if (index.* >= text.len) return error.InvalidRule;
            const value = std.fmt.parseInt(u32, text[start..index.*], 16) catch
                return error.InvalidRule;
            index.* += 1;
            if (value > 0x10ffff) return error.InvalidRule;
            return @intCast(value);
        },
        'n' => return '\n',
        't' => return '\t',
        'r' => return '\r',
        else => {
            const length = std.unicode.utf8ByteSequenceLength(byte) catch
                return error.InvalidUtf8;
            if (index.* - 1 + length > text.len) return error.InvalidUtf8;
            const codepoint = std.unicode.utf8Decode(
                text[index.* - 1 ..][0..length],
            ) catch return error.InvalidUtf8;
            index.* += length - 1;
            return codepoint;
        },
    }
}

fn extractSetPattern(text: []const u8, index: *usize) Error![]const u8 {
    if (index.* >= text.len or text[index.*] != '[') return error.InvalidRule;
    const start = index.*;
    var depth: usize = 0;
    var quoted = false;
    while (index.* < text.len) {
        const byte = text[index.*];
        if (byte == '\\' and !quoted) {
            index.* += @min(@as(usize, 2), text.len - index.*);
            continue;
        }
        if (byte == '\'') {
            quoted = !quoted;
            index.* += 1;
            continue;
        }
        if (!quoted) {
            if (byte == '[') depth += 1;
            if (byte == ']') {
                depth -= 1;
                if (depth == 0) {
                    index.* += 1;
                    return text[start..index.*];
                }
            }
        }
        index.* += 1;
    }
    return error.InvalidRule;
}

fn findUnquoted(text: []const u8, needle: u8) ?usize {
    var index: usize = 0;
    var quoted = false;
    var bracket_depth: usize = 0;
    var paren_depth: usize = 0;
    while (index < text.len) {
        const byte = text[index];
        if (byte == '\\' and !quoted) {
            index += @min(@as(usize, 2), text.len - index);
            continue;
        }
        if (byte == '\'') {
            quoted = !quoted;
            index += 1;
            continue;
        }
        if (!quoted) {
            if (byte == '[') bracket_depth += 1;
            if (byte == ']' and bracket_depth > 0) bracket_depth -= 1;
            if (bracket_depth == 0) {
                if (byte == '(') paren_depth += 1;
                if (byte == ')' and paren_depth > 0) paren_depth -= 1;
                if (paren_depth == 0 and byte == needle) return index;
            }
        }
        index += 1;
    }
    return null;
}

fn findMatchingParen(text: []const u8, open_index: usize) ?usize {
    var depth: usize = 0;
    var bracket_depth: usize = 0;
    var quoted = false;
    var index = open_index;
    while (index < text.len) {
        const byte = text[index];
        if (byte == '\\' and !quoted) {
            index += @min(@as(usize, 2), text.len - index);
            continue;
        }
        if (byte == '\'') {
            quoted = !quoted;
            index += 1;
            continue;
        }
        if (!quoted) {
            if (byte == '[') {
                bracket_depth += 1;
            } else if (byte == ']' and bracket_depth > 0) {
                bracket_depth -= 1;
            } else if (bracket_depth == 0) {
                if (byte == '(') {
                    depth += 1;
                } else if (byte == ')') {
                    depth -= 1;
                    if (depth == 0) return index;
                }
            }
        }
        index += 1;
    }
    return null;
}

test "break rules boundaries and statuses" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    var rules = try compileAlloc(
        allocator,
        "$l = [A-Za-z]; $l+ {100}; [\\u0020]+ {200};",
    );
    defer rules.deinit();

    var iterator = try rules.iterateAlloc(allocator, "abc def");
    defer iterator.deinit();
    try testing.expectEqual(@as(?usize, 3), iterator.next());
    try testing.expectEqual(@as(u32, 100), iterator.status());
    try testing.expectEqual(@as(?usize, 4), iterator.next());
    try testing.expectEqual(@as(u32, 200), iterator.status());
    try testing.expectEqual(@as(?usize, 7), iterator.next());
    try testing.expectEqual(@as(u32, 100), iterator.status());
    try testing.expect(iterator.next() == null);
}

test "break rules fall back to single code points" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    var rules = try compileAlloc(allocator, "$l = [A-Za-z]; $l+;");
    defer rules.deinit();
    var iterator = try rules.iterateAlloc(allocator, "ab1cd");
    defer iterator.deinit();
    try testing.expectEqual(@as(?usize, 2), iterator.next());
    try testing.expectEqual(@as(?usize, 3), iterator.next());
    try testing.expectEqual(@as(?usize, 5), iterator.next());
    try testing.expect(iterator.next() == null);
}

test "break rules alternation and longest match" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    var rules = try compileAlloc(
        allocator,
        "$l = [A-Za-z]; ($l | [0-9])+;",
    );
    defer rules.deinit();
    var iterator = try rules.iterateAlloc(allocator, "ab12cd");
    defer iterator.deinit();
    try testing.expectEqual(@as(?usize, 6), iterator.next());
    try testing.expect(iterator.next() == null);
}

test "break rule conformance" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const fixture = @embedFile("break/conformance.bin");
    try testing.expect(fixture.len >= 12);
    try testing.expectEqualStrings("CJGF", fixture[0..4]);
    const case_count = std.mem.readInt(u32, fixture[8..12], .little);
    var cursor: usize = 12;
    var failures: usize = 0;
    for (0..case_count) |_| {
        const rules_length = std.mem.readInt(u16, fixture[cursor..][0..2], .little);
        const text_length = std.mem.readInt(
            u16,
            fixture[cursor + 2 ..][0..2],
            .little,
        );
        const boundary_count = std.mem.readInt(
            u16,
            fixture[cursor + 4 ..][0..2],
            .little,
        );
        cursor += 8;
        const rules_text = fixture[cursor .. cursor + rules_length];
        cursor += rules_length;
        const text = fixture[cursor .. cursor + text_length];
        cursor += text_length;

        var rules = compileAlloc(allocator, rules_text) catch {
            failures += 1;
            cursor += @as(usize, boundary_count) * 8;
            continue;
        };
        defer rules.deinit();
        var iterator = rules.iterateAlloc(allocator, text) catch {
            failures += 1;
            cursor += @as(usize, boundary_count) * 8;
            continue;
        };
        defer iterator.deinit();

        var produced: usize = 0;
        while (iterator.next()) |position| {
            if (produced >= boundary_count) {
                failures += 1;
                break;
            }
            const expected_position = std.mem.readInt(
                u32,
                fixture[cursor + produced * 8 ..][0..4],
                .little,
            );
            const expected_status = std.mem.readInt(
                u32,
                fixture[cursor + produced * 8 + 4 ..][0..4],
                .little,
            );
            if (position != expected_position or
                iterator.status() != expected_status)
            {
                failures += 1;
            }
            produced += 1;
        }
        if (produced != boundary_count) failures += 1;
        cursor += @as(usize, boundary_count) * 8;
    }
    std.debug.print("break rule conformance: {d}/{d} cases passed\n", .{
        @as(usize, case_count) - failures,
        case_count,
    });
    try testing.expect(failures == 0);
}
