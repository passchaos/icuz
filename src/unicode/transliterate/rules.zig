//! Runtime ICU transliteration rule engine.
//!
//! Implements the forward subset of ICU's `Transliterator.createFromRules`
//! syntax: comments, `$variable` definitions (string or UnicodeSet), global
//! `::[set];` filters, and `ante { input } post > output;` conversion rules
//! with UnicodeSets, `.` (any), grouping, and `?`/`*`/`+` quantifiers.
//! Output supports literals, string variables, and the `|` cursor marker.
//! Reverse rules (`<`) are ignored when compiling in the forward direction;
//! captures, alternation, and `::` transform calls report
//! `error.UnsupportedRule`.

const std = @import("std");
const set = @import("../set.zig");

pub const Error = error{
    InvalidRule,
    UnsupportedRule,
    InvalidUtf8,
    OutOfMemory,
    RuleLoop,
};

const Quantifier = enum { one, optional, zero_or_more, one_or_more };

const max_capture_groups = 32;

const Span = struct {
    start: usize,
    end: usize,
};

const Captures = [max_capture_groups]?Span;

const InputElement = struct {
    element: Element,
    quantifier: Quantifier = .one,
};

const Group = struct {
    capture: u16,
    elements: []const InputElement,
};

const Element = union(enum) {
    literal: []const u21,
    any: void,
    set: *const set.Set,
    variable_string: []const u21,
    variable_set: *const set.Set,
    group: Group,
};

const OutputElement = union(enum) {
    literal: []const u21,
    variable_string: []const u21,
    capture: u16,
    cursor: void,
};

const Rule = struct {
    ante: []const InputElement,
    input: []const InputElement,
    post: []const InputElement,
    output: []const OutputElement,
    capture_count: u16 = 0,
};

const Variable = union(enum) {
    string: []const u21,
    set: *const set.Set,
};

/// A compiled rule set. Release with `deinit`.
pub const Rules = struct {
    arena: std.heap.ArenaAllocator,
    rules: []const Rule = &.{},

    pub fn deinit(self: *Rules) void {
        self.arena.deinit();
    }
};

/// Compile ICU transliteration rules in the forward direction.
pub fn compileRulesAlloc(
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
        .variables = std.StringHashMap(Variable).init(arena_allocator),
        .rules = std.ArrayList(Rule).empty,
    };
    try parser.parseAll();
    return .{
        .arena = arena,
        .rules = try parser.rules.toOwnedSlice(arena_allocator),
    };
}

/// Apply a compiled rule set to UTF-8 text.
pub fn applyRulesAlloc(
    allocator: std.mem.Allocator,
    rules: *const Rules,
    text: []const u8,
) Error![]u8 {
    const decoded = try decodeUtf8Alloc(allocator, text);
    defer allocator.free(decoded);
    var buffer = std.ArrayList(u21).empty;
    defer buffer.deinit(allocator);
    try buffer.appendSlice(allocator, decoded);

    var replacement = std.ArrayList(u21).empty;
    defer replacement.deinit(allocator);

    var cursor: usize = 0;
    var steps: usize = 0;
    const step_budget = text.len * 16 + 4096;
    while (cursor < buffer.items.len) {
        steps += 1;
        if (steps > step_budget) return error.RuleLoop;
        var matched = false;
        for (rules.rules) |rule| {
            var captures: Captures = undefined;
            for (&captures) |*slot| slot.* = null;
            const input_end = matchRule(
                rule,
                buffer.items,
                cursor,
                &captures,
            ) orelse continue;
            replacement.clearRetainingCapacity();
            var new_cursor = cursor;
            var saw_cursor = false;
            for (rule.output) |element| {
                switch (element) {
                    .literal => |sequence| try replacement.appendSlice(
                        allocator,
                        sequence,
                    ),
                    .variable_string => |sequence| try replacement.appendSlice(
                        allocator,
                        sequence,
                    ),
                    .capture => |capture| {
                        if (captures[capture - 1]) |span| {
                            try replacement.appendSlice(
                                allocator,
                                buffer.items[span.start..span.end],
                            );
                        }
                    },
                    .cursor => {
                        new_cursor = cursor + replacement.items.len;
                        saw_cursor = true;
                    },
                }
            }
            var next = std.ArrayList(u21).empty;
            errdefer next.deinit(allocator);
            try next.appendSlice(allocator, buffer.items[0..cursor]);
            try next.appendSlice(allocator, replacement.items);
            try next.appendSlice(allocator, buffer.items[input_end..]);
            buffer.deinit(allocator);
            buffer = next;
            cursor = if (saw_cursor)
                new_cursor
            else
                cursor + replacement.items.len;
            matched = true;
            break;
        }
        if (!matched) cursor += 1;
    }
    return encodeUtf8Alloc(allocator, buffer.items);
}

fn matchRule(
    rule: Rule,
    buffer: []const u21,
    cursor: usize,
    captures: *Captures,
) ?usize {
    if (!matchAnte(rule.ante, buffer, cursor, captures)) return null;
    var input_end: usize = undefined;
    if (!matchSequence(rule.input, buffer, cursor, &input_end, captures)) {
        return null;
    }
    var post_end: usize = undefined;
    if (!matchSequence(rule.post, buffer, input_end, &post_end, captures)) {
        return null;
    }
    return input_end;
}

fn matchSequence(
    elements: []const InputElement,
    buffer: []const u21,
    start: usize,
    end: *usize,
    captures: *Captures,
) bool {
    return matchSequenceFrom(elements, 0, buffer, start, end, captures);
}

fn matchSequenceFrom(
    elements: []const InputElement,
    index: usize,
    buffer: []const u21,
    position: usize,
    end: *usize,
    captures: *Captures,
) bool {
    if (index == elements.len) {
        end.* = position;
        return true;
    }
    const element = elements[index];
    if (element.element == .group) {
        const group = element.element.group;
        const saved = captures.*;
        var starts: [64]usize = undefined;
        var ends: [64]usize = undefined;
        var count: usize = 0;
        var current = position;
        while (count < ends.len) {
            var group_end: usize = undefined;
            if (!matchSequence(
                group.elements,
                buffer,
                current,
                &group_end,
                captures,
            ) or group_end == current) {
                break;
            }
            starts[count] = current;
            ends[count] = group_end;
            count += 1;
            current = group_end;
        }
        const minimum: usize = switch (element.quantifier) {
            .one, .one_or_more => 1,
            .optional, .zero_or_more => 0,
        };
        const maximum: usize = switch (element.quantifier) {
            .one, .optional => @min(count, 1),
            .zero_or_more, .one_or_more => count,
        };
        if (maximum < minimum) {
            captures.* = saved;
            return false;
        }
        var repetitions = maximum + 1;
        while (repetitions > minimum) {
            repetitions -= 1;
            captures.* = saved;
            var next_position = position;
            if (repetitions > 0) {
                next_position = ends[repetitions - 1];
                // Replay the accepted repetitions so nested captures and the
                // group's own capture reflect the last repetition.
                var replay_position = position;
                for (0..repetitions) |_| {
                    var group_end: usize = undefined;
                    _ = matchSequence(
                        group.elements,
                        buffer,
                        replay_position,
                        &group_end,
                        captures,
                    );
                    replay_position = group_end;
                }
                captures[group.capture - 1] = .{
                    .start = starts[repetitions - 1],
                    .end = ends[repetitions - 1],
                };
            }
            if (matchSequenceFrom(
                elements,
                index + 1,
                buffer,
                next_position,
                end,
                captures,
            )) {
                return true;
            }
        }
        captures.* = saved;
        return false;
    }

    const unit = unitLength(element.element);
    if (unit == 0) {
        return matchSequenceFrom(
            elements,
            index + 1,
            buffer,
            position,
            end,
            captures,
        );
    }
    const available = (buffer.len - position) / unit;
    const minimum: usize = switch (element.quantifier) {
        .one, .one_or_more => 1,
        .optional, .zero_or_more => 0,
    };
    const maximum = switch (element.quantifier) {
        .one, .optional => @min(available, 1),
        .zero_or_more, .one_or_more => available,
    };
    if (maximum < minimum) return false;
    var repetitions = maximum + 1;
    while (repetitions > minimum) {
        repetitions -= 1;
        const start = position;
        if (!repetitionsMatch(element.element, buffer, start, repetitions)) {
            continue;
        }
        const next_position = start + repetitions * unit;
        if (matchSequenceFrom(
            elements,
            index + 1,
            buffer,
            next_position,
            end,
            captures,
        )) {
            return true;
        }
    }
    return false;
}

fn matchAnte(
    elements: []const InputElement,
    buffer: []const u21,
    cursor: usize,
    captures: *Captures,
) bool {
    return matchAnteFrom(elements, elements.len, buffer, cursor, captures);
}

fn matchAnteFrom(
    elements: []const InputElement,
    index: usize,
    buffer: []const u21,
    position: usize,
    captures: *Captures,
) bool {
    if (index == 0) return true;
    const element = elements[index - 1];
    if (element.element == .group) {
        const group = element.element.group;
        const saved = captures.*;
        const minimum: usize = switch (element.quantifier) {
            .one, .one_or_more => 1,
            .optional, .zero_or_more => 0,
        };
        if (minimum == 0 and
            matchAnteFrom(elements, index - 1, buffer, position, captures))
        {
            return true;
        }
        // Greedy: try the longest group match that ends at the cursor.
        var start = position;
        while (start > 0) {
            start -= 1;
            captures.* = saved;
            var group_end: usize = undefined;
            if (!matchSequence(
                group.elements,
                buffer,
                start,
                &group_end,
                captures,
            )) continue;
            if (group_end != position) continue;
            captures[group.capture - 1] = .{
                .start = start,
                .end = position,
            };
            if (matchAnteFrom(
                elements,
                index - 1,
                buffer,
                start,
                captures,
            )) return true;
        }
        captures.* = saved;
        return false;
    }
    const unit = unitLength(element.element);
    if (unit == 0) {
        return matchAnteFrom(elements, index - 1, buffer, position, captures);
    }
    const available = position / unit;
    const minimum: usize = switch (element.quantifier) {
        .one, .one_or_more => 1,
        .optional, .zero_or_more => 0,
    };
    const maximum = switch (element.quantifier) {
        .one, .optional => @min(available, 1),
        .zero_or_more, .one_or_more => available,
    };
    if (maximum < minimum) return false;
    var repetitions = maximum + 1;
    while (repetitions > minimum) {
        repetitions -= 1;
        const start = position - repetitions * unit;
        if (!repetitionsMatch(element.element, buffer, start, repetitions)) {
            continue;
        }
        if (matchAnteFrom(elements, index - 1, buffer, start, captures)) {
            return true;
        }
    }
    return false;
}

fn unitLength(element: Element) usize {
    return switch (element) {
        .literal => |sequence| sequence.len,
        .variable_string => |sequence| sequence.len,
        .any, .set, .variable_set => 1,
        .group => 0,
    };
}

fn repetitionsMatch(
    element: Element,
    buffer: []const u21,
    start: usize,
    repetitions: usize,
) bool {
    switch (element) {
        .literal => |sequence| {
            for (0..repetitions) |index| {
                const offset = start + index * sequence.len;
                if (!std.mem.eql(u21, buffer[offset..][0..sequence.len], sequence)) {
                    return false;
                }
            }
            return true;
        },
        .variable_string => |sequence| {
            for (0..repetitions) |index| {
                const offset = start + index * sequence.len;
                if (!std.mem.eql(u21, buffer[offset..][0..sequence.len], sequence)) {
                    return false;
                }
            }
            return true;
        },
        .any => return true,
        .set => |unicode_set| {
            for (0..repetitions) |index| {
                if (!unicode_set.contains(buffer[start + index])) return false;
            }
            return true;
        },
        .variable_set => |unicode_set| {
            for (0..repetitions) |index| {
                if (!unicode_set.contains(buffer[start + index])) return false;
            }
            return true;
        },
        .group => return false,
    }
}

fn decodeUtf8Alloc(allocator: std.mem.Allocator, text: []const u8) Error![]u21 {
    var result = std.ArrayList(u21).empty;
    errdefer result.deinit(allocator);
    var index: usize = 0;
    while (index < text.len) {
        const length = std.unicode.utf8ByteSequenceLength(text[index]) catch
            return error.InvalidUtf8;
        if (index + length > text.len) return error.InvalidUtf8;
        const codepoint = std.unicode.utf8Decode(text[index..][0..length]) catch
            return error.InvalidUtf8;
        try result.append(allocator, codepoint);
        index += length;
    }
    return result.toOwnedSlice(allocator);
}

fn encodeUtf8Alloc(allocator: std.mem.Allocator, codepoints: []const u21) Error![]u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);
    var buffer: [4]u8 = undefined;
    for (codepoints) |codepoint| {
        const length = std.unicode.utf8Encode(codepoint, &buffer) catch
            return error.InvalidUtf8;
        try result.appendSlice(allocator, buffer[0..length]);
    }
    return result.toOwnedSlice(allocator);
}

const Arrow = struct {
    index: usize,
    length: usize,
    reverse_only: bool,
};

const Parser = struct {
    arena: std.mem.Allocator,
    text: []const u8,
    index: usize,
    variables: std.StringHashMap(Variable),
    rules: std.ArrayList(Rule),
    group_count: u16 = 0,

    fn parseAll(self: *Parser) Error!void {
        while (self.nextStatement()) |statement| {
            if (statement.len == 0) continue;
            if (statement[0] == '$' and isVariableDefinition(statement)) {
                try self.parseVariable(statement);
            } else if (std.mem.startsWith(u8, statement, "::")) {
                try self.parseDirective(statement[2..]);
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

    fn parseDirective(self: *Parser, directive: []const u8) Error!void {
        const trimmed = std.mem.trim(u8, directive, " \t\r\n");
        if (trimmed.len == 0) return;
        if (std.ascii.eqlIgnoreCase(trimmed, "Null")) return;
        if (trimmed[0] == '[') {
            // ICU parses `::[set];` as the global filter rule but does not
            // apply it during batch transliteration; accept and ignore it.
            _ = set.parse(self.arena, trimmed) catch |err| switch (err) {
                error.InvalidPattern => return error.InvalidRule,
                error.OutOfMemory => return error.OutOfMemory,
            };
            return;
        }
        return error.UnsupportedRule;
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
        if (value[0] == '[' or value[0] == '\\') {
            const parsed = set.parse(self.arena, value) catch |err| switch (err) {
                error.InvalidPattern => return error.InvalidRule,
                error.OutOfMemory => return error.OutOfMemory,
            };
            const stored = try self.arena.create(set.Set);
            stored.* = parsed;
            try self.variables.put(try self.arena.dupe(u8, name), .{ .set = stored });
        } else {
            const sequence = try parseLiteralCodepoints(self.arena, value);
            try self.variables.put(
                try self.arena.dupe(u8, name),
                .{ .string = sequence },
            );
        }
    }

    fn parseRule(self: *Parser, statement: []const u8) Error!void {
        const arrow = findArrow(statement) orelse return error.InvalidRule;
        if (arrow.reverse_only) return;
        const left = statement[0..arrow.index];
        const right = statement[arrow.index + arrow.length ..];

        var ante_text: []const u8 = "";
        var input_text: []const u8 = left;
        var post_text: []const u8 = "";
        if (findUnquoted(left, '{')) |open| {
            const close_relative = findUnquoted(left[open + 1 ..], '}') orelse
                return error.InvalidRule;
            const close = open + 1 + close_relative;
            if (findUnquoted(left[close + 1 ..], '{') != null) {
                return error.InvalidRule;
            }
            ante_text = left[0..open];
            input_text = left[open + 1 .. close];
            post_text = left[close + 1 ..];
        }

        self.group_count = 0;
        const ante = try self.parseInputElements(ante_text);
        const input = try self.parseInputElements(input_text);
        if (input.len == 0) return error.InvalidRule;
        const post = try self.parseInputElements(post_text);
        const output = try self.parseOutputElements(right, self.group_count);
        try self.rules.append(self.arena, .{
            .ante = ante,
            .input = input,
            .post = post,
            .output = output,
            .capture_count = self.group_count,
        });
    }

    fn parseInputElements(self: *Parser, text: []const u8) Error![]const InputElement {
        var elements = std.ArrayList(InputElement).empty;
        errdefer elements.deinit(self.arena);
        var index: usize = 0;
        while (index < text.len) {
            const byte = text[index];
            if (std.ascii.isWhitespace(byte)) {
                index += 1;
                continue;
            }
            switch (byte) {
                '\'' => {
                    const sequence = try parseQuotedCodepoints(
                        self.arena,
                        text,
                        &index,
                    );
                    try elements.append(self.arena, .{
                        .element = .{ .literal = sequence },
                    });
                },
                '\\' => {
                    const codepoint = try decodeEscape(self.arena, text, &index);
                    try elements.append(self.arena, .{
                        .element = .{ .literal = try singleCodepoint(
                            self.arena,
                            codepoint,
                        ) },
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
                    try elements.append(self.arena, .{
                        .element = .{ .set = stored },
                    });
                },
                '.' => {
                    index += 1;
                    try elements.append(self.arena, .{ .element = .any });
                },
                '$' => {
                    const name = try readVariableName(text, &index);
                    const variable = self.variables.get(name) orelse
                        return error.InvalidRule;
                    const element: Element = switch (variable) {
                        .string => |sequence| .{ .variable_string = sequence },
                        .set => |unicode_set| .{ .variable_set = unicode_set },
                    };
                    try elements.append(self.arena, .{ .element = element });
                },
                '(' => {
                    const close = findMatchingParen(text, index) orelse
                        return error.InvalidRule;
                    index += 1;
                    self.group_count += 1;
                    if (self.group_count > max_capture_groups) {
                        return error.UnsupportedRule;
                    }
                    const capture = self.group_count;
                    const group = try self.parseInputElements(text[index..close]);
                    index = close + 1;
                    try elements.append(self.arena, .{
                        .element = .{ .group = .{
                            .capture = capture,
                            .elements = group,
                        } },
                    });
                },
                ')', '|', '&' => return error.UnsupportedRule,
                '{', '}' => return error.InvalidRule,
                '?', '*', '+' => {
                    if (elements.items.len == 0) return error.InvalidRule;
                    elements.items[elements.items.len - 1].quantifier =
                        switch (byte) {
                            '?' => .optional,
                            '*' => .zero_or_more,
                            else => .one_or_more,
                        };
                    index += 1;
                },
                else => {
                    const length = std.unicode.utf8ByteSequenceLength(byte) catch
                        return error.InvalidUtf8;
                    if (index + length > text.len) return error.InvalidUtf8;
                    const codepoint = std.unicode.utf8Decode(
                        text[index..][0..length],
                    ) catch return error.InvalidUtf8;
                    index += length;
                    try elements.append(self.arena, .{
                        .element = .{ .literal = try singleCodepoint(
                            self.arena,
                            codepoint,
                        ) },
                    });
                },
            }
        }
        return elements.toOwnedSlice(self.arena);
    }

    fn parseOutputElements(
        self: *Parser,
        text: []const u8,
        capture_count: u16,
    ) Error![]const OutputElement {
        var elements = std.ArrayList(OutputElement).empty;
        errdefer elements.deinit(self.arena);
        var index: usize = 0;
        while (index < text.len) {
            const byte = text[index];
            if (std.ascii.isWhitespace(byte)) {
                index += 1;
                continue;
            }
            switch (byte) {
                '\'' => {
                    const sequence = try parseQuotedCodepoints(
                        self.arena,
                        text,
                        &index,
                    );
                    try elements.append(self.arena, .{
                        .literal = sequence,
                    });
                },
                '\\' => {
                    const codepoint = try decodeEscape(self.arena, text, &index);
                    try elements.append(self.arena, .{
                        .literal = try singleCodepoint(self.arena, codepoint),
                    });
                },
                '$' => {
                    const name = try readVariableName(text, &index);
                    if (name.len > 0 and std.ascii.isDigit(name[0])) {
                        const capture = std.fmt.parseInt(u16, name, 10) catch
                            return error.InvalidRule;
                        if (capture == 0 or capture > capture_count) {
                            return error.InvalidRule;
                        }
                        try elements.append(self.arena, .{
                            .capture = capture,
                        });
                        continue;
                    }
                    const variable = self.variables.get(name) orelse
                        return error.InvalidRule;
                    switch (variable) {
                        .string => |sequence| try elements.append(self.arena, .{
                            .variable_string = sequence,
                        }),
                        .set => return error.InvalidRule,
                    }
                },
                '|' => {
                    index += 1;
                    try elements.append(self.arena, .cursor);
                },
                '[' => return error.InvalidRule,
                else => {
                    const length = std.unicode.utf8ByteSequenceLength(byte) catch
                        return error.InvalidUtf8;
                    if (index + length > text.len) return error.InvalidUtf8;
                    const codepoint = std.unicode.utf8Decode(
                        text[index..][0..length],
                    ) catch return error.InvalidUtf8;
                    index += length;
                    try elements.append(self.arena, .{
                        .literal = try singleCodepoint(self.arena, codepoint),
                    });
                },
            }
        }
        return elements.toOwnedSlice(self.arena);
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

fn singleCodepoint(
    allocator: std.mem.Allocator,
    codepoint: u21,
) Error![]const u21 {
    const sequence = try allocator.alloc(u21, 1);
    sequence[0] = codepoint;
    return sequence;
}

fn parseLiteralCodepoints(
    allocator: std.mem.Allocator,
    text: []const u8,
) Error![]const u21 {
    var codepoints = std.ArrayList(u21).empty;
    errdefer codepoints.deinit(allocator);
    var index: usize = 0;
    while (index < text.len) {
        const byte = text[index];
        if (std.ascii.isWhitespace(byte)) {
            index += 1;
            continue;
        }
        if (byte == '\'') {
            const sequence = try parseQuotedCodepoints(allocator, text, &index);
            try codepoints.appendSlice(allocator, sequence);
            continue;
        }
        if (byte == '\\') {
            try codepoints.append(
                allocator,
                try decodeEscape(allocator, text, &index),
            );
            continue;
        }
        const length = std.unicode.utf8ByteSequenceLength(byte) catch
            return error.InvalidUtf8;
        if (index + length > text.len) return error.InvalidUtf8;
        const codepoint = std.unicode.utf8Decode(text[index..][0..length]) catch
            return error.InvalidUtf8;
        try codepoints.append(allocator, codepoint);
        index += length;
    }
    return codepoints.toOwnedSlice(allocator);
}

fn parseQuotedCodepoints(
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
            try codepoints.append(
                allocator,
                try decodeEscape(allocator, text, index),
            );
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

fn decodeEscape(
    allocator: std.mem.Allocator,
    text: []const u8,
    index: *usize,
) Error!u21 {
    _ = allocator;
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

fn findArrow(text: []const u8) ?Arrow {
    var index: usize = 0;
    var quoted = false;
    var depth: usize = 0;
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
            if (byte == '[') depth += 1;
            if (byte == ']' and depth > 0) depth -= 1;
            if (depth == 0) {
                if (std.mem.startsWith(u8, text[index..], "\u{2192}")) {
                    return .{ .index = index, .length = 3, .reverse_only = false };
                }
                if (std.mem.startsWith(u8, text[index..], "\u{2190}")) {
                    return .{ .index = index, .length = 3, .reverse_only = true };
                }
                if (std.mem.startsWith(u8, text[index..], "\u{2194}")) {
                    return .{ .index = index, .length = 3, .reverse_only = false };
                }
                if (std.mem.startsWith(u8, text[index..], "<>")) {
                    return .{ .index = index, .length = 2, .reverse_only = false };
                }
                if (byte == '>') {
                    return .{ .index = index, .length = 1, .reverse_only = false };
                }
                if (byte == '<') {
                    return .{ .index = index, .length = 1, .reverse_only = true };
                }
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

fn findUnquoted(text: []const u8, needle: u8) ?usize {
    var index: usize = 0;
    var quoted = false;
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
        if (!quoted and byte == needle) return index;
        index += 1;
    }
    return null;
}

fn expectRules(
    rules_text: []const u8,
    input: []const u8,
    expected: []const u8,
) !void {
    const testing = std.testing;
    var rules = try compileRulesAlloc(testing.allocator, rules_text);
    defer rules.deinit();
    const result = try applyRulesAlloc(testing.allocator, &rules, input);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings(expected, result);
}

test "rule engine literals and order" {
    try expectRules("a > b;", "banana", "bbnbnb");
    try expectRules("ab > X; a > y;", "ab a", "X y");
    try expectRules("a > b; b > c;", "ab", "bc");
    try expectRules("ß > ss;", "maß", "mass");
    try expectRules("\\u00e9 > e;", "café", "cafe");
}

test "rule engine context" {
    try expectRules("a { b } > c;", "ab ba", "ac ba");
    try expectRules("a b > c;", "ab ba", "c ba");
    try expectRules("x{a} > b;", "xa xaa", "xb xba");
    try expectRules("a { b } c > X;", "abc xbc", "aXc xbc");
    try expectRules("{ a } b > X;", "ab ac", "Xb ac");
}

test "rule engine sets and variables" {
    try expectRules("$v = [aeiou]; $v > X;", "banana", "bXnXnX");
    try expectRules("$s = xy; a > $s;", "banana", "bxynxynxy");
    try expectRules("[a-c] > X;", "abcdef", "XXXdef");
    try expectRules(". > X;", "ab", "XX");
    try expectRules("::[a]; a > X; b > Y;", "ab", "XY");
    try expectRules("::Null; a > X;", "a", "X");
}

test "rule engine quantifiers and groups" {
    try expectRules("a+ > X;", "baaa b", "bX b");
    try expectRules("a? b > X;", "ab b", "X X");
    try expectRules("a* b > X;", "aaab b", "X X");
    try expectRules("(ab)+ > X;", "abab ab", "X X");
    try expectRules("'ab'+ > X;", "abab ab", "X X");
    try expectRules("a b+ > X;", "abb ab", "X X");
    try expectRules("'a b' > X;", "a b ab", "X ab");
}

test "rule engine output and cursor" {
    try expectRules("a > ;", "banana", "bnn");
    try expectRules("a > b|;", "aa", "bb");
    try expectRules("$s = x; a > $s|;", "aa", "xx");
}

test "rule engine rejects unsupported syntax" {
    const testing = std.testing;
    try testing.expectError(
        error.UnsupportedRule,
        compileRulesAlloc(testing.allocator, "(a|b) > X;"),
    );
    try testing.expectError(
        error.UnsupportedRule,
        compileRulesAlloc(testing.allocator, "::NFD; a > b;"),
    );
    try testing.expectError(
        error.InvalidRule,
        compileRulesAlloc(testing.allocator, "{ } > x;"),
    );
    try testing.expectError(
        error.InvalidRule,
        compileRulesAlloc(testing.allocator, "$v > X;"),
    );
    try testing.expectError(
        error.InvalidRule,
        compileRulesAlloc(testing.allocator, "$v = [a]; a > $v;"),
    );
}

test "rule engine ignores reverse rules in forward mode" {
    try expectRules("a < b;", "ab", "ab");
    try expectRules("a <> b;", "ab", "bb");
}

test "rule engine conformance" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const fixture = @embedFile("rules_conformance.bin");
    try testing.expect(fixture.len >= 12);
    try testing.expectEqualStrings("CJRL", fixture[0..4]);
    const case_count = std.mem.readInt(u32, fixture[8..12], .little);
    var cursor: usize = 12;
    var failures: usize = 0;
    for (0..case_count) |_| {
        const rules_length = std.mem.readInt(u16, fixture[cursor..][0..2], .little);
        const input_length = std.mem.readInt(u16, fixture[cursor + 2 ..][0..2], .little);
        const expected_length = std.mem.readInt(
            u16,
            fixture[cursor + 4 ..][0..2],
            .little,
        );
        cursor += 8;
        const rules_text = fixture[cursor .. cursor + rules_length];
        cursor += rules_length;
        const input = fixture[cursor .. cursor + input_length];
        cursor += input_length;
        const expected = fixture[cursor .. cursor + expected_length];
        cursor += expected_length;

        var rules = compileRulesAlloc(allocator, rules_text) catch |err| {
            failures += 1;
            std.debug.print(
                "rule compile failure {s}: {s}\n",
                .{ rules_text, @errorName(err) },
            );
            continue;
        };
        defer rules.deinit();
        const actual = applyRulesAlloc(allocator, &rules, input) catch |err| {
            failures += 1;
            std.debug.print(
                "rule apply failure {s} on {s}: {s}\n",
                .{ rules_text, input, @errorName(err) },
            );
            continue;
        };
        defer allocator.free(actual);
        if (!std.mem.eql(u8, actual, expected)) {
            failures += 1;
            std.debug.print(
                "rule mismatch {s} on {s}: got '{s}' expected '{s}'\n",
                .{ rules_text, input, actual, expected },
            );
        }
    }
    std.debug.print("rule conformance: {d}/{d} passed\n", .{ case_count - failures, case_count });
    try testing.expect(failures == 0);
}

test "rule engine capture groups" {
    const testing = @import("std").testing;
    try expectRules("(a)(b) > $2$1;", "ab", "ba");
    try expectRules("((a)(b)) > $3$2$1;", "ab", "baab");
    try expectRules("([ab])+ > $1;", "ab", "b");
    try expectRules("(a)? b > x$1;", "b", "x");
    try testing.expectError(
        error.InvalidRule,
        compileRulesAlloc(testing.allocator, "(a) > $2;"),
    );
    try testing.expectError(
        error.InvalidRule,
        compileRulesAlloc(testing.allocator, "(a) > $0;"),
    );
}
