//! Unicode MessageFormat 2 (LDML 48) core subset.
//!
//! Supported: simple messages, `.input`/`.local` declarations, quoted
//! patterns, `.match` matchers with multiple selectors, expressions with
//! `:string`, `:number`, `:integer`, `:offset`, `:currency`, `:date`,
//! `:time`, and `:datetime` functions, numeric and plural selection, and
//! attribute parsing
//! (attributes are ignored). Markup parses and formats as an empty string,
//! matching the spec's default string representation. Date selection and
//! custom functions are rejected.
//!
//! The parsed `Message` borrows the input text and owns only its AST
//! arrays; keep the message string alive while the message is used.

const std = @import("std");
const number = @import("number.zig");
const plural = @import("plurals.zig");
const dates = @import("dates.zig");
const normalization = @import("../normalization/root.zig");

pub const ParseError = error{
    InvalidUtf8,
    OutOfMemory,
    SyntaxError,
    DataModelError,
    UnsupportedMarkup,
};

pub const FormatError = error{
    InvalidUtf8,
    OutOfMemory,
    UnresolvedVariable,
    BadOperand,
    BadOption,
    UnsupportedFunction,
    DataModelError,
};

pub const Value = union(enum) {
    string: []const u8,
    number: f64,
    date: dates.DateTime,
};

pub const Input = struct {
    name: []const u8,
    value: Value,
};

pub const Message = struct {
    arena: std.heap.ArenaAllocator,
    declarations: []const Declaration,
    body: Body,

    pub fn deinit(self: *Message) void {
        self.arena.deinit();
    }
};

pub const Body = union(enum) {
    pattern: Pattern,
    matcher: Matcher,
};

pub const Pattern = struct {
    parts: []const Part,
};

pub const Part = union(enum) {
    /// Raw text; escape sequences are resolved when formatting.
    text: []const u8,
    expression: Expression,
    /// Markup formats as an empty string in plain-text output.
    markup,
};

pub const Expression = struct {
    operand: ?Operand = null,
    function: ?Function = null,
};

pub const Operand = union(enum) {
    variable: []const u8,
    /// Raw literal contents; escapes are resolved on use.
    literal: []const u8,
};

pub const Function = struct {
    name: []const u8,
    options: []const Option,
};

pub const Option = struct {
    name: []const u8,
    value: OptionValue,
};

pub const OptionValue = union(enum) {
    literal: []const u8,
    variable: []const u8,
};

pub const Declaration = struct {
    name: []const u8,
    input: bool,
    expression: Expression,
};

pub const Matcher = struct {
    selectors: []const []const u8,
    variants: []const Variant,
};

pub const Variant = struct {
    keys: []const Key,
    pattern: Pattern,
};

pub const Key = union(enum) {
    wildcard,
    literal: []const u8,
};

/// Parse a message. The returned message borrows `text`.
pub fn parse(
    allocator: std.mem.Allocator,
    text: []const u8,
) ParseError!Message {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var parser = Parser{
        .text = text,
        .allocator = arena.allocator(),
    };
    const message = try parser.parseMessage();
    return .{
        .arena = arena,
        .declarations = message.declarations,
        .body = message.body,
    };
}

const ParsedMessage = struct {
    declarations: []const Declaration,
    body: Body,
};

const Parser = struct {
    text: []const u8,
    index: usize = 0,
    allocator: std.mem.Allocator,

    fn eof(self: *const Parser) bool {
        return self.index >= self.text.len;
    }

    fn startsWith(self: *const Parser, prefix: []const u8) bool {
        return std.mem.startsWith(u8, self.text[self.index..], prefix);
    }

    fn peekCodepoint(self: *const Parser) ?struct { value: u21, length: usize } {
        if (self.index >= self.text.len) return null;
        const length = std.unicode.utf8ByteSequenceLength(
            self.text[self.index],
        ) catch return null;
        if (self.index + length > self.text.len) return null;
        const value = std.unicode.utf8Decode(
            self.text[self.index..][0..length],
        ) catch return null;
        return .{ .value = value, .length = length };
    }

    fn skipO(self: *Parser) void {
        while (self.peekCodepoint()) |decoded| {
            if (isWhitespace(decoded.value) or isBidiControl(decoded.value)) {
                self.index += decoded.length;
            } else {
                return;
            }
        }
    }

    fn skipS(self: *Parser) bool {
        while (self.peekCodepoint()) |decoded| {
            if (isBidiControl(decoded.value)) {
                self.index += decoded.length;
            } else {
                break;
            }
        }
        const start = self.index;
        if (self.peekCodepoint()) |decoded| {
            if (isWhitespace(decoded.value)) {
                self.index += decoded.length;
                self.skipO();
                return true;
            }
        }
        self.index = start;
        return false;
    }

    fn parseMessage(self: *Parser) ParseError!ParsedMessage {
        // A message whose first non-whitespace character is '.' or '{{'
        // is complex; anything else is a simple pattern whose leading
        // whitespace is significant.
        var probe = self.index;
        while (probe < self.text.len) {
            const decoded = decodeAt(self.text, probe) orelse break;
            if (!isWhitespace(decoded.value) and !isBidiControl(decoded.value)) {
                break;
            }
            probe += decoded.length;
        }
        const complex = probe < self.text.len and
            (self.text[probe] == '.' or
                std.mem.startsWith(u8, self.text[probe..], "{{"));
        if (!complex) {
            const pattern = try self.parsePattern(false);
            return .{ .declarations = &.{}, .body = .{ .pattern = pattern } };
        }

        self.skipO();
        var declarations = std.ArrayList(Declaration).empty;
        while (!self.eof() and self.text[self.index] == '.' and
            !self.startsWith(".match"))
        {
            const declaration = try self.parseDeclaration();
            try declarations.append(self.allocator, declaration);
            self.skipO();
        }
        if (declarations.items.len != 0) {
            try validateDeclarations(declarations.items);
        }
        const body = if (self.startsWith("{{"))
            Body{ .pattern = try self.parseQuotedPattern() }
        else if (self.startsWith(".match"))
            Body{ .matcher = try self.parseMatcher() }
        else
            return error.SyntaxError;
        self.skipO();
        if (!self.eof()) return error.SyntaxError;
        return .{
            .declarations = try declarations.toOwnedSlice(self.allocator),
            .body = body,
        };
    }

    fn parseDeclaration(self: *Parser) ParseError!Declaration {
        self.index += 1; // '.'
        const keyword = self.parseName() orelse return error.SyntaxError;
        if (std.mem.eql(u8, keyword, "input")) {
            _ = self.skipS();
            const expression = try self.parseExpression();
            if (expression.operand == null or
                expression.operand.? != .variable)
            {
                return error.SyntaxError;
            }
            return .{
                .name = expression.operand.?.variable,
                .input = true,
                .expression = expression,
            };
        }
        if (std.mem.eql(u8, keyword, "local")) {
            _ = self.skipS();
            const name = try self.parseVariable();
            self.skipO();
            if (self.eof() or self.text[self.index] != '=') {
                return error.SyntaxError;
            }
            self.index += 1;
            self.skipO();
            const expression = try self.parseExpression();
            return .{ .name = name, .input = false, .expression = expression };
        }
        return error.SyntaxError;
    }

    fn parseMatcher(self: *Parser) ParseError!Matcher {
        self.index += ".match".len;
        var selectors = std.ArrayList([]const u8).empty;
        while (true) {
            const save = self.index;
            if (!self.skipS()) {
                self.index = save;
                break;
            }
            if (self.eof() or self.text[self.index] != '$') {
                self.index = save;
                break;
            }
            const name = try self.parseVariable();
            try selectors.append(self.allocator, name);
        }
        if (selectors.items.len == 0) return error.SyntaxError;

        var variants = std.ArrayList(Variant).empty;
        while (true) {
            if (!self.skipS()) return error.SyntaxError;
            const variant = try self.parseVariant(selectors.items.len);
            try variants.append(self.allocator, variant);
            const save = self.index;
            self.skipO();
            if (self.eof()) break;
            self.index = save;
        }
        if (variants.items.len == 0) return error.SyntaxError;
        try validateMatcher(selectors.items, variants.items);
        return .{
            .selectors = try selectors.toOwnedSlice(self.allocator),
            .variants = try variants.toOwnedSlice(self.allocator),
        };
    }

    fn parseVariant(self: *Parser, selector_count: usize) ParseError!Variant {
        var keys = std.ArrayList(Key).empty;
        while (true) {
            const key = try self.parseKey();
            try keys.append(self.allocator, key);
            const save = self.index;
            if (!self.skipS()) {
                self.index = save;
                break;
            }
            if (self.startsWith("{{")) {
                self.index = save;
                break;
            }
        }
        if (keys.items.len != selector_count) return error.DataModelError;
        self.skipO();
        const pattern = try self.parseQuotedPattern();
        return .{
            .keys = try keys.toOwnedSlice(self.allocator),
            .pattern = pattern,
        };
    }

    fn parseKey(self: *Parser) ParseError!Key {
        if (!self.eof() and self.text[self.index] == '*') {
            self.index += 1;
            return .wildcard;
        }
        if (!self.eof() and self.text[self.index] == '|') {
            return .{ .literal = try self.parseQuotedLiteral() };
        }
        const literal = self.parseUnquotedLiteral() orelse
            return error.SyntaxError;
        return .{ .literal = literal };
    }

    fn parseQuotedPattern(self: *Parser) ParseError!Pattern {
        if (!self.startsWith("{{")) return error.SyntaxError;
        self.index += 2;
        const pattern = try self.parsePattern(true);
        if (!self.startsWith("}}")) return error.SyntaxError;
        self.index += 2;
        return pattern;
    }

    fn parsePattern(self: *Parser, quoted: bool) ParseError!Pattern {
        var parts = std.ArrayList(Part).empty;
        var text_start = self.index;
        while (!self.eof()) {
            if (quoted and self.startsWith("}}")) break;
            const byte = self.text[self.index];
            if (byte == '\\') {
                self.index += 1;
                if (self.eof()) return error.SyntaxError;
                const decoded = self.peekCodepoint() orelse
                    return error.SyntaxError;
                if (decoded.value != '\\' and decoded.value != '{' and
                    decoded.value != '|' and decoded.value != '}')
                {
                    return error.SyntaxError;
                }
                self.index += decoded.length;
                continue;
            }
            if (byte == '{') {
                if (self.index > text_start) {
                    try parts.append(self.allocator, .{
                        .text = self.text[text_start..self.index],
                    });
                }
                if (self.index + 1 < self.text.len and
                    (self.text[self.index + 1] == '#' or
                        self.text[self.index + 1] == '/'))
                {
                    try self.parseMarkup();
                    try parts.append(self.allocator, .markup);
                    text_start = self.index;
                    continue;
                }
                const expression = try self.parseExpression();
                try parts.append(self.allocator, .{
                    .expression = expression,
                });
                text_start = self.index;
                continue;
            }
            if (byte == '}') {
                if (quoted and self.startsWith("}}")) break;
                return error.SyntaxError;
            }
            self.index += 1;
        }
        if (self.index > text_start) {
            try parts.append(self.allocator, .{
                .text = self.text[text_start..self.index],
            });
        }
        return .{ .parts = try parts.toOwnedSlice(self.allocator) };
    }

    fn parseMarkup(self: *Parser) ParseError!void {
        self.index += 1; // '{'
        self.skipO();
        if (self.eof()) return error.SyntaxError;
        if (self.text[self.index] == '#' or self.text[self.index] == '/') {
            self.index += 1;
        } else {
            return error.SyntaxError;
        }
        _ = try self.parseIdentifier();
        while (true) {
            const save = self.index;
            if (!self.skipS()) break;
            const decoded = self.peekCodepoint() orelse {
                self.index = save;
                break;
            };
            if (!isNameStart(decoded.value)) {
                self.index = save;
                break;
            }
            _ = try self.parseOption();
        }
        while (true) {
            const save = self.index;
            if (!self.skipS()) break;
            if (self.eof() or self.text[self.index] != '@') {
                self.index = save;
                break;
            }
            try self.parseAttribute();
        }
        self.skipO();
        if (!self.eof() and self.text[self.index] == '/') self.index += 1;
        self.skipO();
        if (self.eof() or self.text[self.index] != '}') {
            return error.SyntaxError;
        }
        self.index += 1;
    }

    fn parseExpression(self: *Parser) ParseError!Expression {
        if (self.eof() or self.text[self.index] != '{') {
            return error.SyntaxError;
        }
        self.index += 1;
        self.skipO();
        var expression = Expression{};
        if (!self.eof()) {
            const byte = self.text[self.index];
            if (byte == '$') {
                expression.operand = .{
                    .variable = try self.parseVariable(),
                };
            } else if (byte == '|') {
                expression.operand = .{
                    .literal = try self.parseQuotedLiteral(),
                };
            } else if (byte == ':') {
                expression.function = try self.parseFunction();
            } else if (self.peekCodepoint()) |decoded| {
                if (isNameChar(decoded.value)) {
                    expression.operand = .{
                        .literal = self.parseUnquotedLiteral().?,
                    };
                } else {
                    return error.SyntaxError;
                }
            }
        }
        if (expression.function == null) {
            const save = self.index;
            if (self.skipS()) {
                if (!self.eof() and self.text[self.index] == ':') {
                    expression.function = try self.parseFunction();
                } else {
                    self.index = save;
                }
            }
        }
        while (true) {
            const save = self.index;
            if (!self.skipS()) break;
            if (self.eof() or self.text[self.index] != '@') {
                self.index = save;
                break;
            }
            try self.parseAttribute();
        }
        self.skipO();
        if (self.eof() or self.text[self.index] != '}') {
            return error.SyntaxError;
        }
        self.index += 1;
        if (expression.operand == null and expression.function == null) {
            return error.SyntaxError;
        }
        return expression;
    }

    fn parseFunction(self: *Parser) ParseError!Function {
        self.index += 1; // ':'
        const name = try self.parseIdentifier();
        var options = std.ArrayList(Option).empty;
        while (true) {
            const save = self.index;
            if (!self.skipS()) {
                self.index = save;
                break;
            }
            const decoded = self.peekCodepoint() orelse {
                self.index = save;
                break;
            };
            if (!isNameStart(decoded.value)) {
                self.index = save;
                break;
            }
            const option = try self.parseOption();
            try options.append(self.allocator, option);
        }
        return .{
            .name = name,
            .options = try options.toOwnedSlice(self.allocator),
        };
    }

    fn parseOption(self: *Parser) ParseError!Option {
        const name = try self.parseIdentifier();
        self.skipO();
        if (self.eof() or self.text[self.index] != '=') {
            return error.SyntaxError;
        }
        self.index += 1;
        self.skipO();
        if (self.eof()) return error.SyntaxError;
        const byte = self.text[self.index];
        const value: OptionValue = if (byte == '$')
            .{ .variable = try self.parseVariable() }
        else if (byte == '|')
            .{ .literal = try self.parseQuotedLiteral() }
        else blk: {
            const literal = self.parseUnquotedLiteral() orelse
                return error.SyntaxError;
            break :blk .{ .literal = literal };
        };
        return .{ .name = name, .value = value };
    }

    fn parseAttribute(self: *Parser) ParseError!void {
        self.index += 1; // '@'
        _ = try self.parseIdentifier();
        const save = self.index;
        self.skipO();
        if (self.eof() or self.text[self.index] != '=') {
            self.index = save;
            return;
        }
        self.index += 1;
        self.skipO();
        if (self.eof()) return error.SyntaxError;
        if (self.text[self.index] == '|') {
            _ = try self.parseQuotedLiteral();
            return;
        }
        if (self.parseUnquotedLiteral() == null) return error.SyntaxError;
    }

    fn parseVariable(self: *Parser) ParseError![]const u8 {
        if (self.eof() or self.text[self.index] != '$') {
            return error.SyntaxError;
        }
        self.index += 1;
        return self.parseName() orelse error.SyntaxError;
    }

    fn parseIdentifier(self: *Parser) ParseError![]const u8 {
        const start = self.index;
        _ = self.parseName() orelse return error.SyntaxError;
        if (!self.eof() and self.text[self.index] == ':') {
            self.index += 1;
            _ = self.parseName() orelse return error.SyntaxError;
        }
        return self.text[start..self.index];
    }

    fn parseName(self: *Parser) ?[]const u8 {
        const start = self.index;
        const first = self.peekCodepoint() orelse return null;
        if (!isNameStart(first.value)) return null;
        self.index += first.length;
        while (self.peekCodepoint()) |decoded| {
            if (!isNameChar(decoded.value)) break;
            self.index += decoded.length;
        }
        return self.text[start..self.index];
    }

    fn parseQuotedLiteral(self: *Parser) ParseError![]const u8 {
        self.index += 1; // '|'
        const start = self.index;
        while (!self.eof()) {
            const byte = self.text[self.index];
            if (byte == '|') {
                const literal = self.text[start..self.index];
                self.index += 1;
                return literal;
            }
            if (byte == '\\') {
                self.index += 1;
                if (self.eof()) return error.SyntaxError;
                const decoded = self.peekCodepoint() orelse
                    return error.SyntaxError;
                if (decoded.value != '\\' and decoded.value != '{' and
                    decoded.value != '|' and decoded.value != '}')
                {
                    return error.SyntaxError;
                }
                self.index += decoded.length;
                continue;
            }
            self.index += 1;
        }
        return error.SyntaxError;
    }

    fn parseUnquotedLiteral(self: *Parser) ?[]const u8 {
        const start = self.index;
        const first = self.peekCodepoint() orelse return null;
        if (!isNameChar(first.value)) return null;
        self.index += first.length;
        while (self.peekCodepoint()) |decoded| {
            if (!isNameChar(decoded.value)) break;
            self.index += decoded.length;
        }
        return self.text[start..self.index];
    }
};

fn decodeAt(text: []const u8, index: usize) ?struct { value: u21, length: usize } {
    if (index >= text.len) return null;
    const length = std.unicode.utf8ByteSequenceLength(text[index]) catch
        return null;
    if (index + length > text.len) return null;
    const value = std.unicode.utf8Decode(text[index..][0..length]) catch
        return null;
    return .{ .value = value, .length = length };
}

fn isWhitespace(codepoint: u21) bool {
    return codepoint == ' ' or codepoint == '\t' or codepoint == '\r' or
        codepoint == '\n' or codepoint == 0x3000;
}

fn isBidiControl(codepoint: u21) bool {
    return codepoint == 0x061c or codepoint == 0x200e or
        codepoint == 0x200f or
        (codepoint >= 0x2066 and codepoint <= 0x2069);
}

fn isNameStart(codepoint: u21) bool {
    if ((codepoint >= 'A' and codepoint <= 'Z') or
        (codepoint >= 'a' and codepoint <= 'z'))
    {
        return true;
    }
    if (codepoint == '+' or codepoint == '_') return true;
    if (codepoint >= 0xa1 and codepoint <= 0x61b) return true;
    if (codepoint >= 0x61d and codepoint <= 0x167f) return true;
    if (codepoint >= 0x1681 and codepoint <= 0x1fff) return true;
    if (codepoint >= 0x200b and codepoint <= 0x200d) return true;
    if (codepoint >= 0x2010 and codepoint <= 0x2027) return true;
    if (codepoint >= 0x2030 and codepoint <= 0x205e) return true;
    if (codepoint >= 0x2060 and codepoint <= 0x2065) return true;
    if (codepoint >= 0x206a and codepoint <= 0x2fff) return true;
    if (codepoint >= 0x3001 and codepoint <= 0xd7ff) return true;
    if (codepoint >= 0xe000 and codepoint <= 0xfdcf) return true;
    if (codepoint >= 0xfdf0 and codepoint <= 0xfffd) return true;
    if (codepoint >= 0x10000 and codepoint <= 0x10fffd) {
        const low: u21 = codepoint & 0xffff;
        return low != 0xfffe and low != 0xffff;
    }
    return false;
}

fn isNameChar(codepoint: u21) bool {
    return isNameStart(codepoint) or
        (codepoint >= '0' and codepoint <= '9') or
        codepoint == '-' or codepoint == '.';
}

fn validateDeclarations(declarations: []const Declaration) ParseError!void {
    for (declarations, 0..) |declaration, index| {
        for (declarations[0..index]) |previous| {
            if (std.mem.eql(u8, previous.name, declaration.name)) {
                return error.DataModelError;
            }
        }
    }
}

fn validateMatcher(
    selectors: []const []const u8,
    variants: []const Variant,
) ParseError!void {
    var has_fallback = false;
    for (variants, 0..) |variant, index| {
        var all_wildcard = true;
        for (variant.keys) |key| {
            if (key != .wildcard) all_wildcard = false;
        }
        if (all_wildcard) has_fallback = true;
        for (variants[0..index]) |previous| {
            if (previous.keys.len != variant.keys.len) continue;
            var same = true;
            for (previous.keys, variant.keys) |a, b| {
                if (!keysEqual(a, b)) {
                    same = false;
                    break;
                }
            }
            if (same) return error.DataModelError;
        }
    }
    if (!has_fallback) return error.DataModelError;
    _ = selectors;
}

fn keysEqual(a: Key, b: Key) bool {
    return switch (a) {
        .wildcard => b == .wildcard,
        .literal => |value| switch (b) {
            .wildcard => false,
            .literal => |other| std.mem.eql(u8, value, other),
        },
    };
}

const Resolved = struct {
    value: Value,
    function: ?Function,
};

const Context = struct {
    allocator: std.mem.Allocator,
    locale: []const u8,
    inputs: []const Input,
    variables: std.ArrayList(Resolved),
    names: std.ArrayList([]const u8),
    scratch: std.ArrayList(u8),
    owned: std.ArrayList([]u8),

    fn deinit(self: *Context) void {
        for (self.owned.items) |value| self.allocator.free(value);
        self.variables.deinit(self.allocator);
        self.names.deinit(self.allocator);
        self.scratch.deinit(self.allocator);
        self.owned.deinit(self.allocator);
    }

    fn findVariable(self: *Context, name: []const u8) ?Resolved {
        for (self.names.items, self.variables.items) |candidate, resolved| {
            if (std.mem.eql(u8, candidate, name)) return resolved;
        }
        return null;
    }

    /// Resolve a variable operand: declared variables first, then external
    /// inputs that appear without a declaration.
    fn resolveVariable(self: *Context, name: []const u8) ?Resolved {
        if (self.findVariable(name)) |resolved| return resolved;
        if (self.findInput(name)) |value| {
            return .{ .value = value, .function = null };
        }
        return null;
    }

    fn findInput(self: *Context, name: []const u8) ?Value {
        for (self.inputs) |input| {
            if (std.mem.eql(u8, input.name, name)) return input.value;
        }
        return null;
    }

    fn unescape(self: *Context, raw: []const u8) FormatError![]const u8 {
        self.scratch.clearRetainingCapacity();
        var index: usize = 0;
        while (index < raw.len) {
            if (raw[index] == '\\' and index + 1 < raw.len) {
                const next = raw[index + 1];
                if (next == '\\' or next == '{' or next == '|' or next == '}') {
                    try self.scratch.append(self.allocator, next);
                    index += 2;
                    continue;
                }
            }
            try self.scratch.append(self.allocator, raw[index]);
            index += 1;
        }
        return self.scratch.items;
    }
};

/// Format a parsed message for `locale` using the supplied external
/// variable values.
pub fn formatAlloc(
    allocator: std.mem.Allocator,
    message: *const Message,
    locale: []const u8,
    inputs: []const Input,
) FormatError![]u8 {
    var context = Context{
        .allocator = allocator,
        .locale = locale,
        .inputs = inputs,
        .variables = .empty,
        .names = .empty,
        .scratch = .empty,
        .owned = .empty,
    };
    defer context.deinit();

    for (message.declarations) |declaration| {
        const resolved = if (declaration.input)
            try resolveInput(&context, declaration)
        else
            try resolveExpression(&context, declaration.expression);
        try context.names.append(allocator, declaration.name);
        try context.variables.append(
            allocator,
            try ownResolved(&context, resolved),
        );
    }

    const pattern = switch (message.body) {
        .pattern => |value| value,
        .matcher => |matcher| (try selectVariant(&context, matcher)).pattern,
    };

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try formatPattern(&context, pattern, &output);
    return output.toOwnedSlice(allocator);
}

fn resolveInput(
    context: *Context,
    declaration: Declaration,
) FormatError!Resolved {
    var value = context.findInput(declaration.name) orelse
        return error.UnresolvedVariable;
    if (declaration.expression.function) |function| {
        value = try applyFunction(context, function, value);
    }
    return .{ .value = value, .function = declaration.expression.function };
}

fn resolveExpression(
    context: *Context,
    expression: Expression,
) FormatError!Resolved {
    var value: Value = undefined;
    var function: ?Function = null;
    if (expression.operand) |operand| {
        switch (operand) {
            .variable => |name| {
                const resolved = context.resolveVariable(name) orelse
                    return error.UnresolvedVariable;
                value = resolved.value;
                function = resolved.function;
            },
            .literal => |raw| {
                value = .{ .string = try context.unescape(raw) };
            },
        }
    } else {
        return error.BadOperand;
    }
    if (expression.function) |own| {
        value = try applyFunction(context, own, value);
        function = own;
    }
    return .{ .value = value, .function = function };
}

fn applyFunction(
    context: *Context,
    function: Function,
    value: Value,
) FormatError!Value {
    if (std.mem.eql(u8, function.name, "string")) {
        if (value != .string) return error.BadOperand;
        return value;
    }
    if (std.mem.eql(u8, function.name, "number") or
        std.mem.eql(u8, function.name, "integer"))
    {
        return switch (value) {
            .number => value,
            .string => |text| blk: {
                const parsed = std.fmt.parseFloat(f64, text) catch
                    return error.BadOperand;
                break :blk .{ .number = parsed };
            },
            else => error.BadOperand,
        };
    }
    if (std.mem.eql(u8, function.name, "date") or
        std.mem.eql(u8, function.name, "time") or
        std.mem.eql(u8, function.name, "datetime"))
    {
        return switch (value) {
            .date => value,
            .string => |text| blk: {
                const parsed = parseIsoDateTime(text) orelse
                    return error.BadOperand;
                break :blk .{ .date = parsed };
            },
            else => error.BadOperand,
        };
    }
    if (std.mem.eql(u8, function.name, "offset")) {
        const base = switch (value) {
            .number => |amount| amount,
            else => return error.BadOperand,
        };
        var delta: f64 = 0;
        var has_add = false;
        var has_subtract = false;
        for (function.options) |option| {
            if (!std.mem.eql(u8, option.name, "add") and
                !std.mem.eql(u8, option.name, "subtract"))
            {
                continue;
            }
            const text = try optionText(context, option);
            const amount = std.fmt.parseInt(u32, text, 10) catch
                return error.BadOption;
            if (std.mem.eql(u8, option.name, "add")) {
                if (has_add or has_subtract) return error.BadOption;
                has_add = true;
                delta = @floatFromInt(amount);
            } else {
                if (has_add or has_subtract) return error.BadOption;
                has_subtract = true;
                delta = -@as(f64, @floatFromInt(amount));
            }
        }
        return .{ .number = base + delta };
    }
    if (std.mem.eql(u8, function.name, "currency")) {
        return switch (value) {
            .number => value,
            .string => |text| blk: {
                const parsed = std.fmt.parseFloat(f64, text) catch
                    return error.BadOperand;
                break :blk .{ .number = parsed };
            },
            else => error.BadOperand,
        };
    }
    return error.UnsupportedFunction;
}

fn formatPattern(
    context: *Context,
    pattern: Pattern,
    output: *std.ArrayList(u8),
) FormatError!void {
    for (pattern.parts) |part| {
        switch (part) {
            .text => |raw| try appendUnescaped(
                context.allocator,
                output,
                raw,
            ),
            .expression => |expression| try formatExpression(
                context,
                expression,
                output,
            ),
            .markup => {},
        }
    }
}

fn appendUnescaped(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    raw: []const u8,
) FormatError!void {
    var index: usize = 0;
    while (index < raw.len) {
        if (raw[index] == '\\' and index + 1 < raw.len) {
            const next = raw[index + 1];
            if (next == '\\' or next == '{' or next == '|' or next == '}') {
                try output.append(allocator, next);
                index += 2;
                continue;
            }
        }
        try output.append(allocator, raw[index]);
        index += 1;
    }
}

fn formatExpression(
    context: *Context,
    expression: Expression,
    output: *std.ArrayList(u8),
) FormatError!void {
    const resolved = try resolveExpression(context, expression);
    try formatResolved(context, resolved, output);
}

fn formatResolved(
    context: *Context,
    resolved: Resolved,
    output: *std.ArrayList(u8),
) FormatError!void {
    const function = resolved.function;
    const name = if (function) |value| value.name else "";
    switch (resolved.value) {
        .string => |text| {
            if (function != null and
                !std.mem.eql(u8, name, "string"))
            {
                return error.BadOperand;
            }
            try output.appendSlice(context.allocator, text);
        },
        .number => |value| {
            if (function != null and !std.mem.eql(u8, name, "number") and
                !std.mem.eql(u8, name, "integer") and
                !std.mem.eql(u8, name, "offset") and
                !std.mem.eql(u8, name, "currency"))
            {
                return error.BadOperand;
            }
            try formatNumber(context, value, function, output);
        },
        .date => |value| {
            if (function != null and !isDateFunction(name)) {
                return error.BadOperand;
            }
            try formatDateValue(context, value, function, output);
        },
    }
}

fn isDateFunction(name: []const u8) bool {
    return std.mem.eql(u8, name, "date") or
        std.mem.eql(u8, name, "time") or
        std.mem.eql(u8, name, "datetime");
}

fn ownResolved(context: *Context, resolved: Resolved) FormatError!Resolved {
    var result = resolved;
    switch (result.value) {
        .string => |text| {
            const copy = try context.allocator.dupe(u8, text);
            errdefer context.allocator.free(copy);
            try context.owned.append(context.allocator, copy);
            result.value = .{ .string = copy };
        },
        else => {},
    }
    return result;
}

const DateFields = enum {
    weekday,
    day_weekday,
    month_day,
    month_day_weekday,
    year_month_day,
    year_month_day_weekday,
};

const DateLength = enum { long, medium, short };
const TimePrecision = enum { hour, minute, second };

fn dateSkeleton(fields: DateFields, length: DateLength) []const u8 {
    return switch (fields) {
        .weekday => switch (length) {
            .long => "EEEE",
            .medium => "EEE",
            .short => "EEEEE",
        },
        .day_weekday => switch (length) {
            .long => "EEEEd",
            .medium, .short => "Ed",
        },
        .month_day => switch (length) {
            .long => "MMMMd",
            .medium => "MMMd",
            .short => "Md",
        },
        .month_day_weekday => switch (length) {
            .long => "MMMMEEEEd",
            .medium => "MMMEd",
            .short => "MEd",
        },
        .year_month_day => switch (length) {
            .long => "yMMMMd",
            .medium => "yMMMd",
            .short => "yMd",
        },
        .year_month_day_weekday => switch (length) {
            .long => "yMMMMEEEEd",
            .medium => "yMMMEd",
            .short => "yMdE",
        },
    };
}

fn formatDateValue(
    context: *Context,
    value: dates.DateTime,
    function: ?Function,
    output: *std.ArrayList(u8),
) FormatError!void {
    var fields: DateFields = .year_month_day;
    var date_length: DateLength = .medium;
    var precision: TimePrecision = .minute;
    var include_date = true;
    var include_time = true;
    const name = if (function) |value_function| value_function.name else
        "datetime";
    if (std.mem.eql(u8, name, "date")) {
        include_time = false;
    } else if (std.mem.eql(u8, name, "time")) {
        include_date = false;
    }
    if (function) |value_function| {
        for (value_function.options) |option| {
            if (include_date and (std.mem.eql(u8, option.name, "fields") or
                std.mem.eql(u8, option.name, "dateFields")))
            {
                const text = try optionText(context, option);
                fields = parseDateFields(text) orelse return error.BadOption;
            } else if (include_date and
                (std.mem.eql(u8, option.name, "length") or
                    std.mem.eql(u8, option.name, "dateLength")))
            {
                const text = try optionText(context, option);
                date_length = parseDateLength(text) orelse
                    return error.BadOption;
            } else if (include_time and
                (std.mem.eql(u8, option.name, "precision") or
                    std.mem.eql(u8, option.name, "timePrecision")))
            {
                const text = try optionText(context, option);
                precision = parseTimePrecision(text) orelse
                    return error.BadOption;
            } else if (std.mem.eql(u8, option.name, "timeZoneStyle")) {
                const text = try optionText(context, option);
                if (!std.mem.eql(u8, text, "long") and
                    !std.mem.eql(u8, text, "short"))
                {
                    return error.BadOption;
                }
            }
        }
    }

    var skeleton: [64]u8 = undefined;
    var length: usize = 0;
    if (include_date) {
        const date_part = dateSkeleton(fields, date_length);
        @memcpy(skeleton[length..][0..date_part.len], date_part);
        length += date_part.len;
    }
    if (include_time) {
        const time_part = switch (precision) {
            .hour => "H",
            .minute => "Hm",
            .second => "Hms",
        };
        @memcpy(skeleton[length..][0..time_part.len], time_part);
        length += time_part.len;
    }
    const formatted = dates.formatSkeletonAlloc(
        context.allocator,
        value,
        context.locale,
        skeleton[0..length],
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadOption,
    };
    defer context.allocator.free(formatted);
    try output.appendSlice(context.allocator, formatted);
}

fn parseDateFields(text: []const u8) ?DateFields {
    if (std.mem.eql(u8, text, "weekday")) return .weekday;
    if (std.mem.eql(u8, text, "day-weekday")) return .day_weekday;
    if (std.mem.eql(u8, text, "month-day")) return .month_day;
    if (std.mem.eql(u8, text, "month-day-weekday")) return .month_day_weekday;
    if (std.mem.eql(u8, text, "year-month-day")) return .year_month_day;
    if (std.mem.eql(u8, text, "year-month-day-weekday")) {
        return .year_month_day_weekday;
    }
    return null;
}

fn parseDateLength(text: []const u8) ?DateLength {
    if (std.mem.eql(u8, text, "long")) return .long;
    if (std.mem.eql(u8, text, "medium")) return .medium;
    if (std.mem.eql(u8, text, "short")) return .short;
    return null;
}

fn parseTimePrecision(text: []const u8) ?TimePrecision {
    if (std.mem.eql(u8, text, "hour")) return .hour;
    if (std.mem.eql(u8, text, "minute")) return .minute;
    if (std.mem.eql(u8, text, "second")) return .second;
    return null;
}

fn parseIsoDateTime(text: []const u8) ?dates.DateTime {
    if (text.len < 10) return null;
    if (text[4] != '-' or text[7] != '-') return null;
    const year = std.fmt.parseInt(i32, text[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, text[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u8, text[8..10], 10) catch return null;
    if (month < 1 or month > 12 or day < 1 or day > 31) return null;
    var result = dates.DateTime{
        .year = year,
        .month = month,
        .day = day,
        .hour = 0,
        .minute = 0,
        .second = 0,
    };
    var rest = text[10..];
    if (rest.len == 0) return result;
    if (rest[0] != 'T') return null;
    rest = rest[1..];
    if (rest.len < 5 or rest[2] != ':') return null;
    result.hour = std.fmt.parseInt(u8, rest[0..2], 10) catch return null;
    result.minute = std.fmt.parseInt(u8, rest[3..5], 10) catch return null;
    if (result.hour > 23 or result.minute > 59) return null;
    var index: usize = 5;
    if (index + 3 <= rest.len and rest[index] == ':') {
        result.second = std.fmt.parseInt(
            u8,
            rest[index + 1 .. index + 3],
            10,
        ) catch return null;
        if (result.second > 59) return null;
        index += 3;
        if (index < rest.len and rest[index] == '.') {
            const start = index + 1;
            var end = start;
            while (end < rest.len and rest[end] >= '0' and
                rest[end] <= '9') : (end += 1)
            {}
            const digits = end - start;
            if (digits == 0 or digits > 9) return null;
            var value = std.fmt.parseInt(
                u32,
                rest[start..end],
                10,
            ) catch return null;
            var scale = digits;
            while (scale < 9) : (scale += 1) value *= 10;
            result.nanosecond = value;
            index = end;
        }
    }
    if (index == rest.len) return result;
    if (rest[index] == 'Z' and index + 1 == rest.len) {
        result.offset_seconds = 0;
        return result;
    }
    if (rest[index] == '+' or rest[index] == '-') {
        if (index + 6 != rest.len or rest[index + 3] != ':') return null;
        const hours = std.fmt.parseInt(
            i32,
            rest[index + 1 .. index + 3],
            10,
        ) catch return null;
        const minutes = std.fmt.parseInt(
            i32,
            rest[index + 4 .. index + 6],
            10,
        ) catch return null;
        if (hours > 23 or minutes > 59) return null;
        const sign: i32 = if (rest[index] == '-') -1 else 1;
        result.offset_seconds = sign * (hours * 3600 + minutes * 60);
        return result;
    }
    return null;
}

fn formatNumber(
    context: *Context,
    value: f64,
    function: ?Function,
    output: *std.ArrayList(u8),
) FormatError!void {
    var options = number.Options{};
    var suppress_sign = false;
    var currency_buffer: [3]u8 = undefined;
    var has_currency = false;
    const is_integer = if (function) |value_function|
        std.mem.eql(u8, value_function.name, "integer")
    else
        false;
    const is_currency = if (function) |value_function|
        std.mem.eql(u8, value_function.name, "currency")
    else
        false;
    if (is_currency) options.style = .currency;
    if (function) |value_function| {
        for (value_function.options) |option| {
            if (std.mem.eql(u8, option.name, "minimumFractionDigits")) {
                options.min_fraction_digits =
                    try optionDigit(context, option);
            } else if (std.mem.eql(
                u8,
                option.name,
                "maximumFractionDigits",
            )) {
                options.max_fraction_digits =
                    try optionDigit(context, option);
            } else if (std.mem.eql(
                u8,
                option.name,
                "minimumIntegerDigits",
            )) {
                options.integer_min_digits = try optionDigit(context, option);
            } else if (std.mem.eql(u8, option.name, "useGrouping")) {
                const text = try optionText(context, option);
                if (std.mem.eql(u8, text, "never")) {
                    options.use_grouping = false;
                } else if (std.mem.eql(u8, text, "auto") or
                    std.mem.eql(u8, text, "always") or
                    std.mem.eql(u8, text, "min2"))
                {
                    options.use_grouping = true;
                } else {
                    return error.BadOption;
                }
            } else if (std.mem.eql(u8, option.name, "signDisplay")) {
                const text = try optionText(context, option);
                if (std.mem.eql(u8, text, "always")) {
                    options.sign = .always;
                } else if (std.mem.eql(u8, text, "exceptZero")) {
                    options.sign = .except_zero;
                } else if (std.mem.eql(u8, text, "never")) {
                    suppress_sign = true;
                } else if (!std.mem.eql(u8, text, "auto") and
                    !std.mem.eql(u8, text, "negative"))
                {
                    return error.BadOption;
                }
            } else if (std.mem.eql(u8, option.name, "select")) {
                // Selection-only option.
            } else if (std.mem.eql(u8, option.name, "currency")) {
                const text = try optionText(context, option);
                if (text.len != 3) return error.BadOption;
                for (text, 0..) |byte, index| {
                    if (!std.ascii.isAlphabetic(byte)) {
                        return error.BadOption;
                    }
                    currency_buffer[index] = std.ascii.toUpper(byte);
                }
                has_currency = true;
            } else if (std.mem.eql(u8, option.name, "currencySign")) {
                const text = try optionText(context, option);
                if (std.mem.eql(u8, text, "accounting")) {
                    options.accounting = true;
                } else if (!std.mem.eql(u8, text, "standard")) {
                    return error.BadOption;
                }
            } else if (std.mem.eql(u8, option.name, "currencyDisplay")) {
                const text = try optionText(context, option);
                if (std.mem.eql(u8, text, "symbol") or
                    std.mem.eql(u8, text, "narrowSymbol"))
                {
                    options.currency_display = .symbol;
                } else if (std.mem.eql(u8, text, "name")) {
                    options.currency_display = .name;
                } else if (std.mem.eql(u8, text, "code")) {
                    options.currency_display = .code;
                } else if (std.mem.eql(u8, text, "never")) {
                    options.currency_display = .hidden;
                } else {
                    return error.BadOption;
                }
            } else if (std.mem.eql(u8, option.name, "fractionDigits")) {
                const text = try optionText(context, option);
                if (!std.mem.eql(u8, text, "auto")) {
                    const digits = std.fmt.parseInt(u16, text, 10) catch
                        return error.BadOption;
                    if (digits > 99) return error.BadOption;
                    options.min_fraction_digits = @intCast(digits);
                    options.max_fraction_digits = @intCast(digits);
                }
            } else {
                // Unknown options are ignored for forward compatibility.
            }
        }
    }
    if (is_currency) {
        if (!has_currency) return error.BadOption;
        options.currency = &currency_buffer;
    }
    if (is_integer) {
        options.min_fraction_digits = 0;
        options.max_fraction_digits = 0;
    }
    const magnitude = if (suppress_sign) @abs(value) else value;
    const formatted = number.formatAlloc(
        context.allocator,
        magnitude,
        context.locale,
        options,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadOption,
    };
    defer context.allocator.free(formatted);
    try output.appendSlice(context.allocator, formatted);
}

fn optionText(context: *Context, option: Option) FormatError![]const u8 {
    return switch (option.value) {
        .literal => |raw| try context.unescape(raw),
        .variable => return error.BadOption,
    };
}

fn optionDigit(context: *Context, option: Option) FormatError!u8 {
    const text = try optionText(context, option);
    const value = std.fmt.parseInt(u16, text, 10) catch
        return error.BadOption;
    if (value > 99) return error.BadOption;
    return @intCast(value);
}

const max_selectors = 16;

const MatchScore = enum(u8) {
    none = 0,
    category = 1,
    exact = 2,
};

fn selectVariant(
    context: *Context,
    matcher: Matcher,
) FormatError!*const Variant {
    if (matcher.selectors.len > max_selectors) return error.DataModelError;
    var resolved: [max_selectors]Resolved = undefined;
    for (matcher.selectors, 0..) |name, index| {
        const value = context.findVariable(name) orelse
            return error.UnresolvedVariable;
        if (value.function == null) return error.DataModelError;
        resolved[index] = value;
    }

    var best: ?*const Variant = null;
    var best_scores: [max_selectors]MatchScore = @splat(.none);
    for (matcher.variants) |*variant| {
        var scores: [max_selectors]MatchScore = @splat(.none);
        if (!(try matchVariant(
            context,
            resolved[0..matcher.selectors.len],
            variant.keys,
            &scores,
        ))) {
            continue;
        }
        if (best == null or
            betterScores(
                scores[0..matcher.selectors.len],
                best_scores[0..matcher.selectors.len],
            ))
        {
            best = variant;
            best_scores = scores;
        }
    }
    return best orelse error.DataModelError;
}

fn matchVariant(
    context: *Context,
    selectors: []const Resolved,
    keys: []const Key,
    scores: *[max_selectors]MatchScore,
) FormatError!bool {
    for (selectors, keys, 0..) |selector, key, index| {
        switch (key) {
            .wildcard => scores[index] = .none,
            .literal => |raw| {
                const text = try context.unescape(raw);
                const score = try matchKey(context, selector, text);
                if (score == .none) return false;
                scores[index] = score;
            },
        }
    }
    return true;
}

fn matchKey(
    context: *Context,
    selector: Resolved,
    key: []const u8,
) FormatError!MatchScore {
    const function = selector.function orelse return error.DataModelError;
    if (std.mem.eql(u8, function.name, "string")) {
        const value = switch (selector.value) {
            .string => |text| text,
            else => return error.BadOperand,
        };
        if (std.mem.eql(u8, value, key)) return .exact;
        return if (try nfcEqual(context, value, key)) .exact else .none;
    }
    if (isDateFunction(function.name) or
        std.mem.eql(u8, function.name, "currency"))
    {
        // Selection on these values is not required by the spec.
        return error.UnsupportedFunction;
    }
    if (std.mem.eql(u8, function.name, "number") or
        std.mem.eql(u8, function.name, "integer") or
        std.mem.eql(u8, function.name, "offset"))
    {
        const value = switch (selector.value) {
            .number => |number_value| number_value,
            else => return error.BadOperand,
        };
        if (std.fmt.parseFloat(f64, key)) |exact| {
            if (exact == value) return .exact;
        } else |_| {}
        var select_mode: []const u8 = "plural";
        for (function.options) |option| {
            if (!std.mem.eql(u8, option.name, "select")) continue;
            select_mode = try optionText(context, option);
        }
        if (std.mem.eql(u8, select_mode, "exact")) return .none;
        var buffer: [64]u8 = undefined;
        const magnitude = @abs(value);
        const text = std.fmt.bufPrint(&buffer, "{d}", .{magnitude}) catch
            return error.BadOperand;
        const category = if (std.mem.eql(u8, select_mode, "ordinal"))
            plural.ordinalCategoryForDecimalString(context.locale, text) catch
                return error.BadOperand
        else
            plural.categoryForDecimalString(context.locale, text) catch
                return error.BadOperand;
        if (std.mem.eql(u8, key, @tagName(category))) return .category;
        return .none;
    }
    return error.UnsupportedFunction;
}

fn nfcEqual(
    context: *Context,
    a: []const u8,
    b: []const u8,
) FormatError!bool {
    const left = normalization.normalizeAlloc(context.allocator, a) catch
        return error.InvalidUtf8;
    defer if (left) |owned| context.allocator.free(owned);
    const right = normalization.normalizeAlloc(context.allocator, b) catch
        return error.InvalidUtf8;
    defer if (right) |owned| context.allocator.free(owned);
    return std.mem.eql(
        u8,
        left orelse a,
        right orelse b,
    );
}

fn betterScores(
    candidate: []const MatchScore,
    current: []const MatchScore,
) bool {
    for (candidate, current) |left, right| {
        if (left == right) continue;
        return @intFromEnum(left) > @intFromEnum(right);
    }
    return false;
}

test "message format 2 simple messages" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    {
        var message = try parse(allocator, "Hello, {$name}!");
        defer message.deinit();
        const inputs = [_]Input{
            .{ .name = "name", .value = .{ .string = "World" } },
        };
        const text = try formatAlloc(allocator, &message, "en", &inputs);
        defer allocator.free(text);
        try testing.expectEqualStrings("Hello, World!", text);
    }
    {
        var message = try parse(allocator, "\\{literal\\} and {|horse|}");
        defer message.deinit();
        const text = try formatAlloc(allocator, &message, "en", &.{});
        defer allocator.free(text);
        try testing.expectEqualStrings("{literal} and horse", text);
    }
    {
        var message = try parse(
            allocator,
            "You have {42 :number} and {1234.5 :number}.",
        );
        defer message.deinit();
        const text = try formatAlloc(allocator, &message, "en", &.{});
        defer allocator.free(text);
        try testing.expectEqualStrings("You have 42 and 1,234.5.", text);
    }
    {
        var message = try parse(allocator, "{1234.5 :number}");
        defer message.deinit();
        const text = try formatAlloc(allocator, &message, "de", &.{});
        defer allocator.free(text);
        try testing.expectEqualStrings("1.234,5", text);
    }
}

test "message format 2 declarations and matching" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    {
        var message = try parse(
            allocator,
            ".input {$count :number}\n.match $count\n" ++
                "one {{You have one notification.}}\n" ++
                "* {{You have {$count} notifications.}}\n",
        );
        defer message.deinit();
        const one = [_]Input{
            .{ .name = "count", .value = .{ .number = 1 } },
        };
        const one_text = try formatAlloc(allocator, &message, "en", &one);
        defer allocator.free(one_text);
        try testing.expectEqualStrings(
            "You have one notification.",
            one_text,
        );
        const five = [_]Input{
            .{ .name = "count", .value = .{ .number = 5 } },
        };
        const five_text = try formatAlloc(allocator, &message, "en", &five);
        defer allocator.free(five_text);
        try testing.expectEqualStrings(
            "You have 5 notifications.",
            five_text,
        );
    }
    {
        var message = try parse(
            allocator,
            ".input {$n :number}\n.match $n\n" ++
                "1 {{exact one}}\none {{category one}}\n* {{other}}\n",
        );
        defer message.deinit();
        const inputs = [_]Input{
            .{ .name = "n", .value = .{ .number = 1 } },
        };
        const text = try formatAlloc(allocator, &message, "en", &inputs);
        defer allocator.free(text);
        try testing.expectEqualStrings("exact one", text);
    }
    {
        var message = try parse(
            allocator,
            ".input {$os :string}\n.match $os\n" ++
                "windows {{Settings}}\n* {{Preferences}}\n",
        );
        defer message.deinit();
        const windows = [_]Input{
            .{ .name = "os", .value = .{ .string = "windows" } },
        };
        const windows_text = try formatAlloc(
            allocator,
            &message,
            "en",
            &windows,
        );
        defer allocator.free(windows_text);
        try testing.expectEqualStrings("Settings", windows_text);
        const linux = [_]Input{
            .{ .name = "os", .value = .{ .string = "linux" } },
        };
        const linux_text = try formatAlloc(allocator, &message, "en", &linux);
        defer allocator.free(linux_text);
        try testing.expectEqualStrings("Preferences", linux_text);
    }
    {
        var message = try parse(
            allocator,
            ".input {$numLikes :integer}\n.input {$numShares :integer}\n" ++
                ".match $numLikes $numShares\n" ++
                "0 0 {{no likes, no shares}}\n" ++
                "0 * {{no likes, some shares}}\n" ++
                "* 0 {{some likes, no shares}}\n" ++
                "* * {{likes and shares}}\n",
        );
        defer message.deinit();
        const inputs = [_]Input{
            .{ .name = "numLikes", .value = .{ .number = 0 } },
            .{ .name = "numShares", .value = .{ .number = 3 } },
        };
        const text = try formatAlloc(allocator, &message, "en", &inputs);
        defer allocator.free(text);
        try testing.expectEqualStrings("no likes, some shares", text);
    }
}

test "message format 2 errors" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    try testing.expectError(
        error.SyntaxError,
        parse(allocator, "Hello, {$name"),
    );
    {
        var message = try parse(allocator, "Hello {#b}world{/b}!");
        defer message.deinit();
        const text = try formatAlloc(allocator, &message, "en", &.{});
        defer allocator.free(text);
        try testing.expectEqualStrings("Hello world!", text);
    }
    {
        var message = try parse(allocator, "a{#b /}b");
        defer message.deinit();
        const text = try formatAlloc(allocator, &message, "en", &.{});
        defer allocator.free(text);
        try testing.expectEqualStrings("ab", text);
    }
    try testing.expectError(
        error.DataModelError,
        parse(
            allocator,
            ".input {$n :number}\n.match $n\none {{a}}\none {{b}}\n* {{c}}\n",
        ),
    );
    try testing.expectError(
        error.DataModelError,
        parse(allocator, ".input {$n :number}\n.match $n\none {{a}}\n"),
    );
    try testing.expectError(
        error.DataModelError,
        parse(allocator, ".input {$a :number}\n.input {$a :number}\n{{x}}\n"),
    );

    var message = try parse(allocator, "{$missing}");
    defer message.deinit();
    try testing.expectError(
        error.UnresolvedVariable,
        formatAlloc(allocator, &message, "en", &.{}),
    );

    var bad = try parse(allocator, "{$value :string}");
    defer bad.deinit();
    const inputs = [_]Input{
        .{ .name = "value", .value = .{ .number = 1 } },
    };
    try testing.expectError(
        error.BadOperand,
        formatAlloc(allocator, &bad, "en", &inputs),
    );
}

test "message format 2 date functions" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    {
        var message = try parse(allocator, "{$d :date}");
        defer message.deinit();
        const inputs = [_]Input{
            .{ .name = "d", .value = .{ .string = "2024-03-05" } },
        };
        const text = try formatAlloc(allocator, &message, "en", &inputs);
        defer allocator.free(text);
        try testing.expectEqualStrings("Mar 5, 2024", text);
    }
    {
        var message = try parse(
            allocator,
            "{$d :date fields=year-month-day-weekday length=long}",
        );
        defer message.deinit();
        const inputs = [_]Input{
            .{ .name = "d", .value = .{ .string = "2024-03-05" } },
        };
        const text = try formatAlloc(allocator, &message, "en", &inputs);
        defer allocator.free(text);
        try testing.expect(std.mem.indexOf(u8, text, "Tuesday") != null);
        try testing.expect(std.mem.indexOf(u8, text, "March") != null);
    }
    {
        var message = try parse(allocator, "{$t :time precision=second}");
        defer message.deinit();
        const inputs = [_]Input{
            .{ .name = "t", .value = .{ .string = "2024-03-05T14:30:45" } },
        };
        const text = try formatAlloc(allocator, &message, "en", &inputs);
        defer allocator.free(text);
        try testing.expect(std.mem.indexOf(u8, text, "14:30:45") != null);
    }
    {
        var message = try parse(allocator, "{$d :datetime}");
        defer message.deinit();
        const inputs = [_]Input{
            .{ .name = "d", .value = .{ .date = .{
                .year = 2024,
                .month = 3,
                .day = 5,
                .hour = 14,
                .minute = 30,
                .second = 0,
            } } },
        };
        const text = try formatAlloc(allocator, &message, "en", &inputs);
        defer allocator.free(text);
        try testing.expect(std.mem.indexOf(u8, text, "2024") != null);
        try testing.expect(std.mem.indexOf(u8, text, "14:30") != null);
    }
    {
        var message = try parse(allocator, "{$d :date}");
        defer message.deinit();
        const inputs = [_]Input{
            .{ .name = "d", .value = .{ .string = "not-a-date" } },
        };
        try testing.expectError(
            error.BadOperand,
            formatAlloc(allocator, &message, "en", &inputs),
        );
    }
}

test "message format 2 currency and offset functions" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    {
        var message = try parse(
            allocator,
            "{12.5 :currency currency=USD}",
        );
        defer message.deinit();
        const text = try formatAlloc(allocator, &message, "en", &.{});
        defer allocator.free(text);
        try testing.expectEqualStrings("$12.50", text);
    }
    {
        var message = try parse(
            allocator,
            "{-12.5 :currency currency=USD currencySign=accounting}",
        );
        defer message.deinit();
        const text = try formatAlloc(allocator, &message, "en", &.{});
        defer allocator.free(text);
        try testing.expectEqualStrings("($12.50)", text);
    }
    {
        var message = try parse(
            allocator,
            ".input {$n :number}\n.local $o = {$n :offset add=1}\n{{{$o}}}",
        );
        defer message.deinit();
        const inputs = [_]Input{
            .{ .name = "n", .value = .{ .number = 4 } },
        };
        const text = try formatAlloc(allocator, &message, "en", &inputs);
        defer allocator.free(text);
        try testing.expectEqualStrings("5", text);
    }
    {
        var message = try parse(
            allocator,
            ".input {$n :number}\n.local $o = {$n :offset add=1}\n" ++
                ".match $o\none {{one}}\n* {{many}}\n",
        );
        defer message.deinit();
        const inputs = [_]Input{
            .{ .name = "n", .value = .{ .number = 0 } },
        };
        const text = try formatAlloc(allocator, &message, "en", &inputs);
        defer allocator.free(text);
        try testing.expectEqualStrings("one", text);
    }
    {
        var message = try parse(
            allocator,
            ".input {$n :number}\n.local $o = {$n :offset subtract=1}\n{{{$o}}}",
        );
        defer message.deinit();
        const inputs = [_]Input{
            .{ .name = "n", .value = .{ .number = 1 } },
        };
        const text = try formatAlloc(allocator, &message, "en", &inputs);
        defer allocator.free(text);
        try testing.expectEqualStrings("0", text);
    }
}
