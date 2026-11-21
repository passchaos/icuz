//! ICU regular-expression pattern parser.
//!
//! The accepted syntax follows ICU's `uregex`/`RegexPattern`: literals,
//! character classes with `&&`/`--` set operations, `\p{...}` properties,
//! quantifiers with greedy/reluctant/possessive forms, capturing and named
//! groups, lookaround, back references, inline flags, quoting, and the
//! ICU-specific `\X` (grapheme cluster) and `\R` (line break) atoms.
//!
//! Parsing produces an arena-backed AST plus a list of owned UnicodeSets.
//! The compiler in `compiler.zig` turns that AST into a flat program.

const std = @import("std");
const set_mod = @import("../set.zig");
const properties = @import("../properties.zig");
const aliases = @import("../properties/aliases.zig");
const name_mod = @import("../name.zig");

pub const Error = error{
    InvalidPattern,
    OutOfMemory,
};

pub const Flags = struct {
    case_insensitive: bool = false,
    comments: bool = false,
    dotall: bool = false,
    literal: bool = false,
    multiline: bool = false,
    unix_lines: bool = false,
    uword: bool = false,
    error_on_unknown_escapes: bool = false,
};

pub const AnchorKind = enum {
    input_start,
    input_end,
    input_end_final,
    line_start,
    line_end,
    word,
    non_word,
    prev_match_end,
};

pub const RepeatKind = enum { greedy, reluctant, possessive };

pub const Literal = struct {
    /// Original UTF-8 text. Owned by the caller's pattern slice.
    text: []const u8,
    case_insensitive: bool = false,
};

pub const Dot = struct {
    dotall: bool,
    unix_lines: bool,
};

pub const Repeat = struct {
    child: *Node,
    min: u32,
    max: ?u32,
    kind: RepeatKind,
};

pub const Capture = struct {
    child: *Node,
    index: u16,
    name: ?[]const u8 = null,
};

pub const Look = struct {
    child: *Node,
    ahead: bool,
    positive: bool,
};

pub const Anchor = struct {
    kind: AnchorKind,
    uword: bool = false,
    unix_lines: bool = false,
};

pub const Backref = struct {
    /// Digits for a numeric back reference, or empty for a named one.
    digits: []const u8 = "",
    name: ?[]const u8 = null,
    case_insensitive: bool,
    group: u16 = 0,
};

pub const Node = union(enum) {
    empty,
    literal: Literal,
    any: Dot,
    set: u32,
    concat: []*Node,
    alternate: []*Node,
    repeat: Repeat,
    capture: Capture,
    atomic: *Node,
    look: Look,
    anchor: Anchor,
    backref: Backref,
    grapheme,
    linebreak,
};

pub const NamedGroup = struct {
    name: []const u8,
    index: u16,
};

pub const Parsed = struct {
    arena: std.heap.ArenaAllocator,
    root: *Node,
    sets: []set_mod.Set,
    names: []NamedGroup,
    group_count: u16,
    flags: Flags,

    pub fn deinit(self: *Parsed, allocator: std.mem.Allocator) void {
        for (self.sets) |*set| set.deinit();
        allocator.free(self.sets);
        allocator.free(self.names);
        self.arena.deinit();
    }
};

/// Parse `pattern`. On failure `error_offset` receives the byte offset where
/// the parser stopped.
pub fn parse(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    flags: Flags,
    error_offset: *usize,
) Error!Parsed {
    if (pattern.len == 0) {
        error_offset.* = 0;
        return error.InvalidPattern;
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    var sets = std.ArrayList(set_mod.Set).empty;
    errdefer {
        for (sets.items) |*set| set.deinit();
        sets.deinit(allocator);
    }

    var names = std.ArrayList(NamedGroup).empty;
    errdefer names.deinit(allocator);

    if (flags.literal) {
        const literal_root = try arena.allocator().create(Node);
        literal_root.* = .{ .literal = .{
            .text = pattern,
            .case_insensitive = flags.case_insensitive,
        } };
        return .{
            .arena = arena,
            .root = literal_root,
            .sets = try sets.toOwnedSlice(allocator),
            .names = try names.toOwnedSlice(allocator),
            .group_count = 0,
            .flags = flags,
        };
    }

    var parser = Parser{
        .allocator = allocator,
        .arena = arena.allocator(),
        .pattern = pattern,
        .flags = flags,
        .sets = &sets,
        .names = &names,
        .error_offset = error_offset,
    };

    const root = try parser.parseAlternation();
    if (parser.index < pattern.len) {
        // A stray ')' is the only way to stop before the end.
        error_offset.* = parser.index;
        return error.InvalidPattern;
    }

    try parser.resolveBackrefs(root);

    return .{
        .arena = arena,
        .root = root,
        .sets = try sets.toOwnedSlice(allocator),
        .names = try names.toOwnedSlice(allocator),
        .group_count = parser.group_count,
        .flags = flags,
    };
}

const Parser = struct {
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    pattern: []const u8,
    index: usize = 0,
    flags: Flags,
    sets: *std.ArrayList(set_mod.Set),
    names: *std.ArrayList(NamedGroup),
    group_count: u16 = 0,
    error_offset: *usize,
    depth: u32 = 0,

    const max_depth = 256;

    fn fail(self: *Parser) Error {
        self.error_offset.* = self.index;
        return error.InvalidPattern;
    }

    fn peek(self: *Parser) ?u8 {
        if (self.index >= self.pattern.len) return null;
        return self.pattern[self.index];
    }

    fn peekAt(self: *Parser, offset: usize) ?u8 {
        const at = self.index + offset;
        if (at >= self.pattern.len) return null;
        return self.pattern[at];
    }

    fn node(self: *Parser, value: Node) Error!*Node {
        const result = try self.arena.create(Node);
        result.* = value;
        return result;
    }

    fn emptyNode(self: *Parser) Error!*Node {
        return self.node(.empty);
    }

    fn dupeNodes(self: *Parser, nodes: []const *Node) Error![]*Node {
        return self.arena.dupe(*Node, nodes);
    }

    fn skipIgnored(self: *Parser) void {
        if (!self.flags.comments) return;
        while (self.index < self.pattern.len) {
            const byte = self.pattern[self.index];
            switch (byte) {
                ' ', '\t', '\n', '\r', 0x0b, 0x0c => self.index += 1,
                '#' => {
                    while (self.index < self.pattern.len and
                        self.pattern[self.index] != '\n')
                    {
                        self.index += 1;
                    }
                },
                else => return,
            }
        }
    }

    fn parseAlternation(self: *Parser) Error!*Node {
        var branches = std.ArrayList(*Node).empty;
        defer branches.deinit(self.allocator);

        try branches.append(self.allocator, try self.parseConcat());
        while (true) {
            self.skipIgnored();
            if (self.peek() != '|') break;
            self.index += 1;
            try branches.append(self.allocator, try self.parseConcat());
        }

        if (branches.items.len == 1) return branches.items[0];
        return self.node(.{ .alternate = try self.dupeNodes(branches.items) });
    }

    fn parseConcat(self: *Parser) Error!*Node {
        var nodes = std.ArrayList(*Node).empty;
        defer nodes.deinit(self.allocator);

        while (true) {
            self.skipIgnored();
            const byte = self.peek() orelse break;
            if (byte == '|' or byte == ')') break;
            try nodes.append(self.allocator, try self.parseQuantified());
        }

        if (nodes.items.len == 0) return self.emptyNode();
        if (nodes.items.len == 1) return nodes.items[0];
        return self.node(.{ .concat = try self.dupeNodes(nodes.items) });
    }

    fn parseQuantified(self: *Parser) Error!*Node {
        var atom = try self.parseAtom();
        self.skipIgnored();

        var min: u32 = 0;
        var max: ?u32 = null;
        const quantifier = self.peek() orelse return atom;
        switch (quantifier) {
            '*' => {
                self.index += 1;
            },
            '+' => {
                self.index += 1;
                min = 1;
            },
            '?' => {
                self.index += 1;
                max = 1;
            },
            '{' => {
                const interval = try self.parseInterval();
                min = interval.min;
                max = interval.max;
            },
            else => return atom,
        }

        self.skipIgnored();
        var kind: RepeatKind = .greedy;
        if (self.peek()) |suffix| {
            if (suffix == '?') {
                kind = .reluctant;
                self.index += 1;
            } else if (suffix == '+') {
                kind = .possessive;
                self.index += 1;
            }
        }

        if (self.peek()) |next| {
            if (next == '*' or next == '+' or next == '?' or next == '{') {
                return self.fail();
            }
        }

        atom = try self.node(.{ .repeat = .{
            .child = atom,
            .min = min,
            .max = max,
            .kind = kind,
        } });
        return atom;
    }

    const Interval = struct { min: u32, max: ?u32 };

    fn parseInterval(self: *Parser) Error!Interval {
        std.debug.assert(self.peek() == '{');
        self.index += 1;

        const min = try self.parseDecimal();
        var max: ?u32 = min;
        if (self.peek() == ',') {
            self.index += 1;
            if (self.peek() == '}') {
                max = null;
            } else {
                max = try self.parseDecimal();
            }
        }
        if (self.peek() != '}') return self.fail();
        self.index += 1;

        if (max) |upper| {
            if (upper < min) return self.fail();
        }
        return .{ .min = min, .max = max };
    }

    fn parseDecimal(self: *Parser) Error!u32 {
        const start = self.index;
        var value: u32 = 0;
        while (self.peek()) |byte| {
            if (byte < '0' or byte > '9') break;
            const digit: u32 = byte - '0';
            value = std.math.mul(u32, value, 10) catch return self.fail();
            value = std.math.add(u32, value, digit) catch return self.fail();
            self.index += 1;
        }
        if (self.index == start) return self.fail();
        return value;
    }

    fn parseAtom(self: *Parser) Error!*Node {
        self.skipIgnored();
        const byte = self.peek() orelse return self.fail();
        switch (byte) {
            '(' => return self.parseGroup(),
            '[' => return self.parseClassNode(),
            '.' => {
                self.index += 1;
                return self.node(.{ .any = .{
                    .dotall = self.flags.dotall,
                    .unix_lines = self.flags.unix_lines,
                } });
            },
            '^' => {
                self.index += 1;
                return self.node(.{ .anchor = .{
                    .kind = if (self.flags.multiline) .line_start else .input_start,
                } });
            },
            '$' => {
                self.index += 1;
                return self.node(.{ .anchor = .{
                    .kind = if (self.flags.multiline) .line_end else .input_end_final,
                    .unix_lines = self.flags.unix_lines,
                } });
            },
            '\\' => return self.parseEscapeAtom(),
            '*', '+', '?', '{' => return self.fail(),
            else => return self.parseLiteralChar(),
        }
    }

    fn parseLiteralChar(self: *Parser) Error!*Node {
        const start = self.index;
        const length = std.unicode.utf8ByteSequenceLength(self.pattern[start]) catch
            return self.fail();
        if (start + length > self.pattern.len) return self.fail();
        _ = std.unicode.utf8Decode(self.pattern[start..][0..length]) catch
            return self.fail();
        self.index += length;
        return self.node(.{ .literal = .{
            .text = self.pattern[start..self.index],
            .case_insensitive = self.flags.case_insensitive,
        } });
    }

    fn parseGroup(self: *Parser) Error!*Node {
        std.debug.assert(self.peek() == '(');
        self.index += 1;
        self.depth += 1;
        defer self.depth -= 1;
        if (self.depth > max_depth) return self.fail();

        var name: ?[]const u8 = null;
        var look_ahead: ?bool = null;
        var positive: ?bool = null;
        var atomic = false;
        var capture = true;
        var scoped_flags: ?Flags = null;

        if (self.peek() == '?') {
            self.index += 1;
            const marker = self.peek() orelse return self.fail();
            switch (marker) {
                ':' => {
                    self.index += 1;
                    capture = false;
                },
                '=' => {
                    self.index += 1;
                    capture = false;
                    look_ahead = true;
                    positive = true;
                },
                '!' => {
                    self.index += 1;
                    capture = false;
                    look_ahead = true;
                    positive = false;
                },
                '>' => {
                    self.index += 1;
                    capture = false;
                    atomic = true;
                },
                '#' => {
                    self.index += 1;
                    while (self.peek()) |byte| {
                        self.index += 1;
                        if (byte == ')') return self.emptyNode();
                    }
                    return self.fail();
                },
                '<' => {
                    self.index += 1;
                    const next = self.peek() orelse return self.fail();
                    if (next == '=' or next == '!') {
                        self.index += 1;
                        capture = false;
                        look_ahead = false;
                        positive = next == '=';
                    } else {
                        name = try self.parseGroupName();
                        capture = true;
                    }
                },
                else => {
                    scoped_flags = try self.parseInlineFlags();
                    if (self.peek() == ':') {
                        self.index += 1;
                        capture = false;
                    } else if (self.peek() == ')') {
                        self.index += 1;
                        // Flag-only group applies to the remainder of the
                        // enclosing scope.
                        self.flags = scoped_flags.?;
                        return self.emptyNode();
                    } else {
                        return self.fail();
                    }
                },
            }
        }

        const saved_flags = self.flags;
        if (scoped_flags) |flags| self.flags = flags;
        defer self.flags = saved_flags;

        const child = try self.parseAlternation();
        if (self.peek() != ')') return self.fail();
        self.index += 1;

        if (look_ahead) |ahead| {
            if (!ahead) try self.checkLookbehind(child);
            return self.node(.{ .look = .{
                .child = child,
                .ahead = ahead,
                .positive = positive.?,
            } });
        }
        if (atomic) return self.node(.{ .atomic = child });
        if (!capture) return child;

        if (self.group_count == std.math.maxInt(u16)) return self.fail();
        self.group_count += 1;
        const index = self.group_count;
        if (name) |group_name| {
            for (self.names.items) |existing| {
                if (std.mem.eql(u8, existing.name, group_name)) return self.fail();
            }
            try self.names.append(self.allocator, .{
                .name = group_name,
                .index = index,
            });
        }
        return self.node(.{ .capture = .{
            .child = child,
            .index = index,
            .name = name,
        } });
    }

    fn parseGroupName(self: *Parser) Error![]const u8 {
        const start = self.index;
        const first = self.peek() orelse return self.fail();
        if (!std.ascii.isAlphabetic(first)) return self.fail();
        self.index += 1;
        while (self.peek()) |byte| {
            if (!std.ascii.isAlphanumeric(byte)) break;
            self.index += 1;
        }
        if (self.peek() != '>') return self.fail();
        const name = self.pattern[start..self.index];
        self.index += 1;
        return name;
    }

    fn parseInlineFlags(self: *Parser) Error!Flags {
        var flags = self.flags;
        var negate = false;
        while (self.peek()) |byte| {
            switch (byte) {
                '-' => {
                    negate = true;
                    self.index += 1;
                },
                'i' => {
                    flags.case_insensitive = !negate;
                    self.index += 1;
                },
                'm' => {
                    flags.multiline = !negate;
                    self.index += 1;
                },
                's' => {
                    flags.dotall = !negate;
                    self.index += 1;
                },
                'd' => {
                    flags.unix_lines = !negate;
                    self.index += 1;
                },
                'w' => {
                    flags.uword = !negate;
                    self.index += 1;
                },
                'x' => {
                    flags.comments = !negate;
                    self.index += 1;
                },
                else => return flags,
            }
        }
        return flags;
    }

    fn checkLookbehind(self: *Parser, child: *Node) Error!void {
        const bounds = lengthBounds(child);
        if (bounds.max == null) return self.fail();
    }

    fn parseEscapeAtom(self: *Parser) Error!*Node {
        std.debug.assert(self.peek() == '\\');
        self.index += 1;
        const byte = self.peek() orelse return self.fail();

        switch (byte) {
            'A' => {
                self.index += 1;
                return self.node(.{ .anchor = .{ .kind = .input_start } });
            },
            'G' => {
                self.index += 1;
                return self.node(.{ .anchor = .{ .kind = .prev_match_end } });
            },
            'Z' => {
                self.index += 1;
                return self.node(.{ .anchor = .{ .kind = .input_end_final } });
            },
            'z' => {
                self.index += 1;
                return self.node(.{ .anchor = .{ .kind = .input_end } });
            },
            'b' => {
                self.index += 1;
                return self.node(.{ .anchor = .{
                    .kind = .word,
                    .uword = self.flags.uword,
                } });
            },
            'B' => {
                self.index += 1;
                return self.node(.{ .anchor = .{
                    .kind = .non_word,
                    .uword = self.flags.uword,
                } });
            },
            'R' => {
                self.index += 1;
                return self.node(.linebreak);
            },
            'X' => {
                self.index += 1;
                return self.node(.grapheme);
            },
            'Q' => {
                self.index += 1;
                const start = self.index;
                while (self.index + 1 < self.pattern.len) {
                    if (self.pattern[self.index] == '\\' and
                        self.pattern[self.index + 1] == 'E')
                    {
                        break;
                    }
                    self.index += 1;
                }
                const text = self.pattern[start..self.index];
                if (self.index + 1 < self.pattern.len) self.index += 2; // \E
                if (text.len == 0) return self.emptyNode();
                return self.node(.{ .literal = .{
                    .text = text,
                    .case_insensitive = self.flags.case_insensitive,
                } });
            },
            'p', 'P' => {
                const negated = byte == 'P';
                self.index += 1;
                const name = try self.parseBracedName();
                const set = try self.propertySet(name, negated);
                return self.pushSetNode(set);
            },
            'd', 'D', 's', 'S', 'w', 'W', 'h', 'H', 'v', 'V' => {
                self.index += 1;
                const set = try self.predefinedSet(byte);
                return self.pushSetNode(set);
            },
            'k' => {
                self.index += 1;
                if (self.peek() != '<') return self.fail();
                self.index += 1;
                const start = self.index;
                while (self.peek()) |name_byte| {
                    if (!std.ascii.isAlphanumeric(name_byte)) break;
                    self.index += 1;
                }
                if (self.index == start) return self.fail();
                const name = self.pattern[start..self.index];
                if (self.peek() != '>') return self.fail();
                self.index += 1;
                return self.node(.{ .backref = .{
                    .name = name,
                    .case_insensitive = self.flags.case_insensitive,
                } });
            },
            '1'...'9' => {
                const start = self.index;
                while (self.peek()) |digit| {
                    if (digit < '0' or digit > '9') break;
                    self.index += 1;
                }
                return self.node(.{ .backref = .{
                    .digits = self.pattern[start..self.index],
                    .case_insensitive = self.flags.case_insensitive,
                } });
            },
            '0' => {
                self.index += 1;
                const codepoint = try self.parseOctal();
                return self.literalNode(codepoint);
            },
            'x' => {
                self.index += 1;
                if (self.peek() == '{') {
                    self.index += 1;
                    const start = self.index;
                    while (self.peek()) |hex| {
                        if (!std.ascii.isHex(hex)) break;
                        self.index += 1;
                    }
                    if (self.index == start or self.peek() != '}') return self.fail();
                    const value = std.fmt.parseInt(u21, self.pattern[start..self.index], 16) catch
                        return self.fail();
                    self.index += 1;
                    return self.literalNode(value);
                }
                return self.literalNode(try self.parseHex(2));
            },
            'u' => {
                self.index += 1;
                return self.literalNode(try self.parseHex(4));
            },
            'U' => {
                self.index += 1;
                return self.literalNode(try self.parseHex(8));
            },
            'c' => {
                self.index += 1;
                const control = self.peek() orelse return self.fail();
                self.index += 1;
                if (!std.ascii.isAlphabetic(control)) return self.fail();
                return self.literalNode(control & 0x1f);
            },
            'N' => {
                self.index += 1;
                if (self.peek() != '{') return self.fail();
                self.index += 1;
                const start = self.index;
                while (self.peek()) |name_byte| {
                    if (name_byte == '}') break;
                    self.index += 1;
                }
                if (self.peek() != '}') return self.fail();
                const name = self.pattern[start..self.index];
                self.index += 1;
                const codepoint = name_mod.findByName(name) orelse return self.fail();
                return self.literalNode(codepoint);
            },
            't' => {
                self.index += 1;
                return self.literalNode('\t');
            },
            'n' => {
                self.index += 1;
                return self.literalNode('\n');
            },
            'r' => {
                self.index += 1;
                return self.literalNode('\r');
            },
            'f' => {
                self.index += 1;
                return self.literalNode(0x0c);
            },
            'a' => {
                self.index += 1;
                return self.literalNode(0x07);
            },
            'e' => {
                self.index += 1;
                return self.literalNode(0x1b);
            },
            else => {
                if (std.ascii.isAlphabetic(byte) and self.flags.error_on_unknown_escapes) {
                    return self.fail();
                }
                const start = self.index;
                const length = std.unicode.utf8ByteSequenceLength(byte) catch
                    return self.fail();
                if (start + length > self.pattern.len) return self.fail();
                _ = std.unicode.utf8Decode(self.pattern[start..][0..length]) catch
                    return self.fail();
                self.index += length;
                return self.node(.{ .literal = .{
                    .text = self.pattern[start..self.index],
                    .case_insensitive = self.flags.case_insensitive,
                } });
            },
        }
    }

    fn parseBracedName(self: *Parser) Error![]const u8 {
        if (self.peek() != '{') return self.fail();
        self.index += 1;
        const start = self.index;
        while (self.peek()) |byte| {
            if (byte == '}') break;
            self.index += 1;
        }
        if (self.peek() != '}') return self.fail();
        const name = self.pattern[start..self.index];
        self.index += 1;
        return name;
    }

    fn parseHex(self: *Parser, digits: usize) Error!u21 {
        if (self.index + digits > self.pattern.len) return self.fail();
        const value = std.fmt.parseInt(u21, self.pattern[self.index..][0..digits], 16) catch
            return self.fail();
        self.index += digits;
        if (!std.unicode.utf8ValidCodepoint(value)) return self.fail();
        return value;
    }

    fn parseOctal(self: *Parser) Error!u21 {
        var value: u32 = 0;
        var count: usize = 0;
        while (self.peek()) |byte| {
            if (byte < '0' or byte > '7' or count == 3) break;
            value = value * 8 + (byte - '0');
            self.index += 1;
            count += 1;
        }
        if (count == 0) return self.fail();
        if (!std.unicode.utf8ValidCodepoint(@intCast(value))) return self.fail();
        return @intCast(value);
    }

    fn literalNode(self: *Parser, codepoint: u21) Error!*Node {
        var buffer: [4]u8 = undefined;
        const length = std.unicode.utf8Encode(codepoint, &buffer) catch return self.fail();
        const text = try self.arena.dupe(u8, buffer[0..length]);
        return self.node(.{ .literal = .{
            .text = text,
            .case_insensitive = self.flags.case_insensitive,
        } });
    }

    fn pushSetNode(self: *Parser, set: set_mod.Set) Error!*Node {
        const index: u32 = @intCast(self.sets.items.len);
        try self.sets.append(self.allocator, set);
        return self.node(.{ .set = index });
    }

    fn pushSet(self: *Parser, set: set_mod.Set) Error!u32 {
        const index: u32 = @intCast(self.sets.items.len);
        try self.sets.append(self.allocator, set);
        return index;
    }

    fn propertySet(self: *Parser, name: []const u8, negated: bool) Error!set_mod.Set {
        if (std.ascii.eqlIgnoreCase(name, "word")) {
            var set = try wordSet(self.allocator);
            try self.closeCase(&set);
            if (negated) try set.complement();
            return set;
        }
        if (std.mem.eql(u8, name, "all")) {
            var set = try set_mod.full(self.allocator);
            if (negated) try set.complement();
            return set;
        }

        var rewritten: [256]u8 = undefined;
        var effective = name;
        if (name.len > 3 and std.mem.startsWith(u8, name, "In") and
            std.mem.indexOfScalar(u8, name, '=') == null)
        {
            effective = std.fmt.bufPrint(&rewritten, "Block={s}", .{name[2..]}) catch
                return self.fail();
        } else if (name.len > 2 and std.mem.startsWith(u8, name, "Is") and
            std.mem.indexOfScalar(u8, name, '=') == null)
        {
            effective = name[2..];
        }

        var buffer: [300]u8 = undefined;
        const pattern = std.fmt.bufPrint(&buffer, "\\p{{{s}}}", .{effective}) catch
            return self.fail();
        var set = set_mod.parse(self.allocator, pattern) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return self.fail(),
        };
        try self.closeCase(&set);
        if (negated) try set.complement();
        try set.finalize();
        return set;
    }

    fn predefinedSet(self: *Parser, byte: u8) Error!set_mod.Set {
        const negated = byte >= 'A' and byte <= 'Z';
        const lower = if (negated) byte + ('a' - 'A') else byte;
        var set = switch (lower) {
            'd' => try set_mod.fromCategoryMask(
                self.allocator,
                aliases.generalCategoryMaskFromAlias("Nd").?,
            ),
            's' => try set_mod.fromProperty(self.allocator, .white_space),
            'w' => try wordSet(self.allocator),
            'h' => try horizontalSpaceSet(self.allocator),
            'v' => try verticalSpaceSet(self.allocator),
            else => return self.fail(),
        };
        try self.closeCase(&set);
        if (negated) try set.complement();
        try set.finalize();
        return set;
    }

    fn parseClassNode(self: *Parser) Error!*Node {
        const set = try self.parseClass();
        return self.pushSetNode(set);
    }

    fn parseClass(self: *Parser) Error!set_mod.Set {
        std.debug.assert(self.peek() == '[');
        self.index += 1;
        self.depth += 1;
        defer self.depth -= 1;
        if (self.depth > max_depth) return self.fail();

        var negated = false;
        if (self.peek() == '^') {
            negated = true;
            self.index += 1;
        }

        var result = set_mod.Set.init(self.allocator);
        errdefer result.deinit();

        // A ']' immediately after '[' or '[^' is a literal.
        if (self.peek() == ']') {
            try result.add(']');
            self.index += 1;
        }

        while (true) {
            self.skipIgnoredInClass();
            const byte = self.peek() orelse return self.fail();
            if (byte == ']') {
                self.index += 1;
                break;
            }
            var chunk = try self.parseClassIntersection();
            defer chunk.deinit();
            try result.unionWith(chunk);
        }

        try self.closeCase(&result);
        if (negated) try result.complement();
        try result.finalize();
        return result;
    }

    fn skipIgnoredInClass(self: *Parser) void {
        if (!self.flags.comments) return;
        while (self.index < self.pattern.len) {
            const byte = self.pattern[self.index];
            switch (byte) {
                ' ', '\t', '\n', '\r', 0x0b, 0x0c => self.index += 1,
                '#' => {
                    while (self.index < self.pattern.len and
                        self.pattern[self.index] != '\n')
                    {
                        self.index += 1;
                    }
                },
                else => return,
            }
        }
    }

    fn parseClassIntersection(self: *Parser) Error!set_mod.Set {
        var left = try self.parseClassUnion();
        while (true) {
            self.skipIgnoredInClass();
            const byte = self.peek() orelse break;
            if (byte != '&' and byte != '-') break;
            const next = self.peekAt(1) orelse break;
            if (next != byte) break;
            self.index += 2;
            var right = try self.parseClassUnion();
            defer right.deinit();
            if (byte == '&') {
                try left.intersectWith(right);
            } else {
                try left.subtract(right);
            }
        }
        return left;
    }

    fn parseClassUnion(self: *Parser) Error!set_mod.Set {
        var result = set_mod.Set.init(self.allocator);
        errdefer result.deinit();

        while (true) {
            self.skipIgnoredInClass();
            const byte = self.peek() orelse return self.fail();
            if (byte == ']') break;
            if ((byte == '&' or byte == '-') and self.peekAt(1) == byte) break;

            const atom = try self.parseClassAtom();
            switch (atom) {
                .scalar => |start| {
                    if (self.peek() == '-' and self.peekAt(1) != null and
                        self.peekAt(1).? != ']' and self.peekAt(1).? != '-')
                    {
                        self.index += 1;
                        const end_atom = try self.parseClassAtom();
                        switch (end_atom) {
                            .scalar => |end| {
                                if (end < start) return self.fail();
                                try result.addRange(start, end);
                            },
                            .set => |owned| {
                                var set = owned;
                                set.deinit();
                                return self.fail();
                            },
                        }
                    } else {
                        try result.add(start);
                    }
                },
                .set => |owned| {
                    var set = owned;
                    defer set.deinit();
                    try result.unionWith(set);
                },
            }
        }
        try result.finalize();
        return result;
    }

    const ClassAtom = union(enum) {
        scalar: u21,
        set: set_mod.Set,
    };

    fn parseClassAtom(self: *Parser) Error!ClassAtom {
        const byte = self.peek() orelse return self.fail();
        if (byte == '[') {
            if (self.peekAt(1) == ':') return self.parsePosixClass();
            const set = try self.parseClass();
            return .{ .set = set };
        }
        if (byte == '\\') return self.parseClassEscape();
        if (byte == '{' or byte == '}') {
            self.index += 1;
            return .{ .scalar = byte };
        }
        return .{ .scalar = try self.parseClassLiteral() };
    }

    fn parseClassLiteral(self: *Parser) Error!u21 {
        const start = self.index;
        const length = std.unicode.utf8ByteSequenceLength(self.pattern[start]) catch
            return self.fail();
        if (start + length > self.pattern.len) return self.fail();
        const codepoint = std.unicode.utf8Decode(self.pattern[start..][0..length]) catch
            return self.fail();
        self.index += length;
        return codepoint;
    }

    fn parseClassEscape(self: *Parser) Error!ClassAtom {
        std.debug.assert(self.peek() == '\\');
        self.index += 1;
        const byte = self.peek() orelse return self.fail();
        switch (byte) {
            'p', 'P' => {
                const negated = byte == 'P';
                self.index += 1;
                const name = try self.parseBracedName();
                return .{ .set = try self.propertySet(name, negated) };
            },
            'd', 'D', 's', 'S', 'w', 'W', 'h', 'H', 'v', 'V' => {
                self.index += 1;
                return .{ .set = try self.predefinedSet(byte) };
            },
            'b' => {
                self.index += 1;
                return .{ .scalar = 0x08 };
            },
            't' => {
                self.index += 1;
                return .{ .scalar = '\t' };
            },
            'n' => {
                self.index += 1;
                return .{ .scalar = '\n' };
            },
            'r' => {
                self.index += 1;
                return .{ .scalar = '\r' };
            },
            'f' => {
                self.index += 1;
                return .{ .scalar = 0x0c };
            },
            'a' => {
                self.index += 1;
                return .{ .scalar = 0x07 };
            },
            'e' => {
                self.index += 1;
                return .{ .scalar = 0x1b };
            },
            'x' => {
                self.index += 1;
                if (self.peek() == '{') {
                    self.index += 1;
                    const start = self.index;
                    while (self.peek()) |hex| {
                        if (!std.ascii.isHex(hex)) break;
                        self.index += 1;
                    }
                    if (self.index == start or self.peek() != '}') return self.fail();
                    const value = std.fmt.parseInt(u21, self.pattern[start..self.index], 16) catch
                        return self.fail();
                    self.index += 1;
                    return .{ .scalar = value };
                }
                return .{ .scalar = try self.parseHex(2) };
            },
            'u' => {
                self.index += 1;
                return .{ .scalar = try self.parseHex(4) };
            },
            'U' => {
                self.index += 1;
                return .{ .scalar = try self.parseHex(8) };
            },
            '0' => {
                self.index += 1;
                return .{ .scalar = try self.parseOctal() };
            },
            'c' => {
                self.index += 1;
                const control = self.peek() orelse return self.fail();
                self.index += 1;
                if (!std.ascii.isAlphabetic(control)) return self.fail();
                return .{ .scalar = control & 0x1f };
            },
            'N' => {
                self.index += 1;
                if (self.peek() != '{') return self.fail();
                self.index += 1;
                const start = self.index;
                while (self.peek()) |name_byte| {
                    if (name_byte == '}') break;
                    self.index += 1;
                }
                if (self.peek() != '}') return self.fail();
                const name = self.pattern[start..self.index];
                self.index += 1;
                const codepoint = name_mod.findByName(name) orelse return self.fail();
                return .{ .scalar = codepoint };
            },
            else => {
                if (std.ascii.isAlphabetic(byte) and self.flags.error_on_unknown_escapes) {
                    return self.fail();
                }
                return .{ .scalar = try self.parseClassLiteral() };
            },
        }
    }

    fn parsePosixClass(self: *Parser) Error!ClassAtom {
        std.debug.assert(self.peek() == '[' and self.peekAt(1) == ':');
        self.index += 2;
        const start = self.index;
        while (self.peek()) |byte| {
            if (byte == ':') break;
            self.index += 1;
        }
        if (self.peek() != ':' or self.peekAt(1) != ']') return self.fail();
        const name = self.pattern[start..self.index];
        self.index += 2;
        return .{ .set = try self.posixSet(name) };
    }

    fn posixSet(self: *Parser, name: []const u8) Error!set_mod.Set {
        var set = set_mod.Set.init(self.allocator);
        errdefer set.deinit();

        if (std.ascii.eqlIgnoreCase(name, "alnum")) {
            var alpha = try set_mod.fromProperty(self.allocator, .alphabetic);
            defer alpha.deinit();
            try set.unionWith(alpha);
            var digits = try set_mod.fromCategoryMask(
                self.allocator,
                aliases.generalCategoryMaskFromAlias("Nd").?,
            );
            defer digits.deinit();
            try set.unionWith(digits);
        } else if (std.ascii.eqlIgnoreCase(name, "alpha")) {
            var alpha = try set_mod.fromProperty(self.allocator, .alphabetic);
            defer alpha.deinit();
            try set.unionWith(alpha);
        } else if (std.ascii.eqlIgnoreCase(name, "ascii")) {
            try set.addRange(0, 0x7f);
        } else if (std.ascii.eqlIgnoreCase(name, "blank")) {
            var zs = try set_mod.fromCategoryMask(
                self.allocator,
                aliases.generalCategoryMaskFromAlias("Zs").?,
            );
            defer zs.deinit();
            try set.unionWith(zs);
            try set.add('\t');
        } else if (std.ascii.eqlIgnoreCase(name, "cntrl")) {
            var cc = try set_mod.fromCategoryMask(
                self.allocator,
                aliases.generalCategoryMaskFromAlias("Cc").?,
            );
            defer cc.deinit();
            try set.unionWith(cc);
        } else if (std.ascii.eqlIgnoreCase(name, "digit")) {
            var digits = try set_mod.fromCategoryMask(
                self.allocator,
                aliases.generalCategoryMaskFromAlias("Nd").?,
            );
            defer digits.deinit();
            try set.unionWith(digits);
        } else if (std.ascii.eqlIgnoreCase(name, "graph")) {
            var graph = try graphSet(self.allocator);
            defer graph.deinit();
            try set.unionWith(graph);
        } else if (std.ascii.eqlIgnoreCase(name, "lower")) {
            var lower = try set_mod.fromProperty(self.allocator, .lowercase);
            defer lower.deinit();
            try set.unionWith(lower);
        } else if (std.ascii.eqlIgnoreCase(name, "print")) {
            var print = try graphSet(self.allocator);
            defer print.deinit();
            try set.unionWith(print);
            var zs = try set_mod.fromCategoryMask(
                self.allocator,
                aliases.generalCategoryMaskFromAlias("Zs").?,
            );
            defer zs.deinit();
            try set.unionWith(zs);
            try set.add('\t');
        } else if (std.ascii.eqlIgnoreCase(name, "punct")) {
            var punct = try set_mod.fromCategoryMask(
                self.allocator,
                aliases.generalCategoryMaskFromAlias("P").?,
            );
            defer punct.deinit();
            try set.unionWith(punct);
        } else if (std.ascii.eqlIgnoreCase(name, "space")) {
            var space = try set_mod.fromProperty(self.allocator, .white_space);
            defer space.deinit();
            try set.unionWith(space);
        } else if (std.ascii.eqlIgnoreCase(name, "upper")) {
            var upper = try set_mod.fromProperty(self.allocator, .uppercase);
            defer upper.deinit();
            try set.unionWith(upper);
        } else if (std.ascii.eqlIgnoreCase(name, "word")) {
            var word = try wordSet(self.allocator);
            defer word.deinit();
            try set.unionWith(word);
        } else if (std.ascii.eqlIgnoreCase(name, "xdigit")) {
            var hex = try set_mod.fromProperty(self.allocator, .hex_digit);
            defer hex.deinit();
            try set.unionWith(hex);
            var digits = try set_mod.fromCategoryMask(
                self.allocator,
                aliases.generalCategoryMaskFromAlias("Nd").?,
            );
            defer digits.deinit();
            try set.unionWith(digits);
        } else if (std.mem.eql(u8, name, "all")) {
            var full = try set_mod.full(self.allocator);
            defer full.deinit();
            try set.unionWith(full);
        } else {
            // POSIX class names are property aliases in ICU.
            const set_from_property = self.propertySet(name, false) catch
                return self.fail();
            return set_from_property;
        }

        try self.closeCase(&set);
        try set.finalize();
        return set;
    }

    fn closeCase(self: *Parser, set: *set_mod.Set) Error!void {
        if (!self.flags.case_insensitive) return;
        set.closeOver(.simple_case_insensitive) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return self.fail(),
        };
    }

    fn resolveBackrefs(self: *Parser, current: *Node) Error!void {
        switch (current.*) {
            .concat => |children| {
                for (children) |child| try self.resolveBackrefs(child);
            },
            .alternate => |children| {
                for (children) |child| try self.resolveBackrefs(child);
            },
            .repeat => |*repeat| try self.resolveBackrefs(repeat.child),
            .capture => |*capture| try self.resolveBackrefs(capture.child),
            .atomic => |child| try self.resolveBackrefs(child),
            .look => |*look| try self.resolveBackrefs(look.child),
            .backref => |*backref| {
                if (backref.name) |name| {
                    var found: ?u16 = null;
                    for (self.names.items) |group| {
                        if (std.mem.eql(u8, group.name, name)) {
                            found = group.index;
                            break;
                        }
                    }
                    backref.group = found orelse return self.fail();
                    return;
                }
                if (backref.digits.len == 0) return self.fail();
                var length = backref.digits.len;
                while (length > 0) : (length -= 1) {
                    const value = std.fmt.parseInt(u32, backref.digits[0..length], 10) catch
                        continue;
                    if (value > 0 and value <= self.group_count) {
                        backref.group = @intCast(value);
                        if (length < backref.digits.len) {
                            const rest = try self.arena.dupe(u8, backref.digits[length..]);
                            const literal = try self.node(.{ .literal = .{
                                .text = rest,
                                .case_insensitive = self.flags.case_insensitive,
                            } });
                            const ref = try self.arena.create(Node);
                            ref.* = current.*;
                            current.* = .{ .concat = try self.arena.dupe(*Node, &.{ ref, literal }) };
                        }
                        return;
                    }
                }
                return self.fail();
            },
            else => {},
        }
    }
};

pub fn wordSet(allocator: std.mem.Allocator) Error!set_mod.Set {
    // Alphabetic plus the mark, decimal-digit and connector-punctuation
    // categories. Both live in the packed property word, so one page-mask
    // pass covers the whole definition.
    const category_mask = aliases.generalCategoryMaskFromAlias("M").? |
        aliases.generalCategoryMaskFromAlias("Nd").? |
        aliases.generalCategoryMaskFromAlias("Pc").?;

    var set = set_mod.Set.init(allocator);
    errdefer set.deinit();
    try set.addMasks(
        category_mask,
        @as(u64, 1) << @intFromEnum(properties.BinaryProperty.alphabetic),
    );
    try set.add(0x200c);
    try set.add(0x200d);
    try set.finalize();
    return set;
}

fn horizontalSpaceSet(allocator: std.mem.Allocator) Error!set_mod.Set {
    var set = try set_mod.fromCategoryMask(
        allocator,
        aliases.generalCategoryMaskFromAlias("Zs").?,
    );
    errdefer set.deinit();
    try set.add('\t');
    try set.finalize();
    return set;
}

fn verticalSpaceSet(allocator: std.mem.Allocator) Error!set_mod.Set {
    var set = set_mod.Set.init(allocator);
    errdefer set.deinit();
    try set.addRange(0x0a, 0x0d);
    try set.add(0x85);
    try set.addRange(0x2028, 0x2029);
    try set.finalize();
    return set;
}

fn graphSet(allocator: std.mem.Allocator) Error!set_mod.Set {
    var set = try set_mod.full(allocator);
    errdefer set.deinit();
    var space = try set_mod.fromProperty(allocator, .white_space);
    defer space.deinit();
    try set.subtract(space);
    inline for ([_][]const u8{ "Cc", "Cs", "Cn", "Zl", "Zp" }) |category| {
        var part = try set_mod.fromCategoryMask(
            allocator,
            aliases.generalCategoryMaskFromAlias(category).?,
        );
        defer part.deinit();
        try set.subtract(part);
    }
    try set.finalize();
    return set;
}

pub const LengthBounds = struct {
    min: u32,
    max: ?u32,
};

/// Minimum and maximum number of scalars a node can match.
pub fn lengthBounds(node: *const Node) LengthBounds {
    return switch (node.*) {
        .empty, .anchor, .look => .{ .min = 0, .max = 0 },
        .literal => |literal| blk: {
            const count: u32 = @intCast(std.unicode.utf8CountCodepoints(literal.text) catch 0);
            break :blk .{ .min = count, .max = count };
        },
        .any, .set, .linebreak => .{ .min = 1, .max = 1 },
        .grapheme, .backref => .{ .min = 0, .max = null },
        .concat => |children| blk: {
            var min: u32 = 0;
            var max: ?u32 = 0;
            for (children) |child| {
                const bounds = lengthBounds(child);
                min = saturatingAdd(min, bounds.min);
                max = addOptional(max, bounds.max);
            }
            break :blk .{ .min = min, .max = max };
        },
        .alternate => |children| blk: {
            var min: u32 = std.math.maxInt(u32);
            var max: ?u32 = 0;
            for (children) |child| {
                const bounds = lengthBounds(child);
                min = @min(min, bounds.min);
                max = maxOptional(max, bounds.max);
            }
            if (children.len == 0) min = 0;
            break :blk .{ .min = min, .max = max };
        },
        .repeat => |repeat| blk: {
            const child = lengthBounds(repeat.child);
            var min = saturatingMul(repeat.min, child.min);
            var max: ?u32 = if (child.max) |child_max|
                saturatingMulOptional(repeat.max, child_max)
            else if (repeat.max == 0)
                0
            else
                null;
            if (repeat.max == 0) {
                min = 0;
                max = 0;
            }
            break :blk .{ .min = min, .max = max };
        },
        .capture => |capture| lengthBounds(capture.child),
        .atomic => |child| lengthBounds(child),
    };
}

fn saturatingAdd(a: u32, b: u32) u32 {
    return std.math.add(u32, a, b) catch std.math.maxInt(u32);
}

fn saturatingMul(a: u32, b: u32) u32 {
    return std.math.mul(u32, a, b) catch std.math.maxInt(u32);
}

fn addOptional(a: ?u32, b: ?u32) ?u32 {
    if (a == null or b == null) return null;
    return saturatingAdd(a.?, b.?);
}

fn maxOptional(a: ?u32, b: ?u32) ?u32 {
    if (a == null or b == null) return null;
    return @max(a.?, b.?);
}

fn saturatingMulOptional(a: ?u32, b: u32) ?u32 {
    if (a == null) return null;
    return saturatingMul(a.?, b);
}
