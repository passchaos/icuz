//! ICU-compatible regular expressions.
//!
//! `Regex` compiles ICU `uregex` patterns; `Matcher` runs them over UTF-8
//! text. Match and capture offsets are UTF-8 byte offsets. ICU reports
//! UTF-16 code-unit indices, so `Matcher.start16`/`end16` expose those when
//! interop with ICU or Java callers needs them.

const std = @import("std");
const parser = @import("parser.zig");
const compiler = @import("compiler.zig");
const vm = @import("vm.zig");
const set_mod = @import("../set.zig");

pub const Flags = parser.Flags;
pub const Span = vm.Span;

pub const ParseError = struct {
    /// Byte offset in the pattern where parsing stopped.
    offset: usize = 0,
};

pub const Error = error{
    InvalidPattern,
    InvalidUtf8,
    OutOfMemory,
    PatternTooBig,
};

pub const MatchError = error{
    MatchLimit,
    OutOfMemory,
};

pub const ReplaceError = error{
    InvalidUtf8,
    OutOfMemory,
    MatchLimit,
    InvalidReplacement,
};

pub const SplitError = error{
    InvalidUtf8,
    OutOfMemory,
    MatchLimit,
};

pub const MatcherOptions = struct {
    transparent_bounds: bool = false,
    anchoring_bounds: bool = true,
    max_steps: usize = 10_000_000,
    max_backtrack: usize = 1_000_000,
};

/// A compiled ICU regular expression.
pub const Regex = struct {
    allocator: std.mem.Allocator,
    program: compiler.Program,
    sets: []set_mod.Set,
    names: []parser.NamedGroup,
    group_count: u16,
    flags: parser.Flags,
    word_set: set_mod.Set,
    pattern_text: []u8,

    pub fn compileAlloc(
        allocator: std.mem.Allocator,
        pattern: []const u8,
        flags: Flags,
    ) Error!Regex {
        return compileAllocWithError(allocator, pattern, flags, null);
    }

    pub fn compileAllocWithError(
        allocator: std.mem.Allocator,
        pattern: []const u8,
        flags: Flags,
        parse_error: ?*ParseError,
    ) Error!Regex {
        if (!std.unicode.utf8ValidateSlice(pattern)) return error.InvalidUtf8;

        var offset: usize = 0;
        var parsed = parser.parse(allocator, pattern, flags, &offset) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidPattern => {
                if (parse_error) |report| report.offset = offset;
                return error.InvalidPattern;
            },
        };
        var parsed_owned = true;
        defer if (parsed_owned) parsed.deinit(allocator);

        const program = compiler.compile(allocator, &parsed) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidPattern => {
                if (parse_error) |report| report.offset = offset;
                return error.InvalidPattern;
            },
            error.PatternTooBig => return error.PatternTooBig,
        };
        errdefer {
            var mutable = program;
            mutable.deinit(allocator);
        }

        const names = try allocator.alloc(parser.NamedGroup, parsed.names.len);
        errdefer allocator.free(names);
        var names_initialized: usize = 0;
        errdefer for (names[0..names_initialized]) |name| allocator.free(name.name);
        for (parsed.names, 0..) |name, index| {
            names[index] = .{
                .name = try allocator.dupe(u8, name.name),
                .index = name.index,
            };
            names_initialized = index + 1;
        }

        const pattern_text = try allocator.dupe(u8, pattern);
        errdefer allocator.free(pattern_text);

        const word_set = parser.wordSet(allocator) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidPattern => return error.InvalidPattern,
        };
        errdefer {
            var mutable = word_set;
            mutable.deinit();
        }

        const sets = parsed.sets;
        parsed_owned = false;
        parsed.arena.deinit();
        allocator.free(parsed.names);

        return .{
            .allocator = allocator,
            .program = program,
            .sets = sets,
            .names = names,
            .group_count = parsed.group_count,
            .flags = flags,
            .word_set = word_set,
            .pattern_text = pattern_text,
        };
    }

    pub fn deinit(self: *Regex) void {
        self.program.deinit(self.allocator);
        for (self.sets) |*set| set.deinit();
        self.allocator.free(self.sets);
        for (self.names) |name| self.allocator.free(name.name);
        self.allocator.free(self.names);
        self.word_set.deinit();
        self.allocator.free(self.pattern_text);
    }

    pub fn patternText(self: *const Regex) []const u8 {
        return self.pattern_text;
    }

    pub fn groupCount(self: *const Regex) u16 {
        return self.group_count;
    }

    pub fn groupIndexFromName(self: *const Regex, name: []const u8) ?u16 {
        for (self.names) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.index;
        }
        return null;
    }

    pub fn matcher(self: *const Regex, text: []const u8) error{ InvalidUtf8, OutOfMemory }!Matcher {
        return Matcher.init(self, text, .{});
    }

    pub fn matcherWithOptions(
        self: *const Regex,
        text: []const u8,
        options: MatcherOptions,
    ) error{ InvalidUtf8, OutOfMemory }!Matcher {
        return Matcher.init(self, text, options);
    }

    pub fn isMatchAlloc(
        self: *const Regex,
        text: []const u8,
    ) error{ InvalidUtf8, OutOfMemory, MatchLimit }!bool {
        var m = try self.matcher(text);
        defer m.deinit();
        return m.find();
    }

    pub fn replaceAllAlloc(
        self: *const Regex,
        allocator: std.mem.Allocator,
        text: []const u8,
        replacement: []const u8,
    ) ReplaceError![]u8 {
        var m = try self.matcher(text);
        defer m.deinit();

        var output = std.ArrayList(u8).empty;
        errdefer output.deinit(allocator);
        var append_position: usize = 0;

        var found = try m.find();
        while (found) {
            const span = m.groupSpan(0).?;
            try output.appendSlice(allocator, text[append_position..span.start]);
            try self.appendReplacement(allocator, &output, replacement, &m);
            append_position = span.end;
            found = try m.findNext();
        }
        try output.appendSlice(allocator, text[append_position..]);
        return output.toOwnedSlice(allocator);
    }

    pub fn replaceFirstAlloc(
        self: *const Regex,
        allocator: std.mem.Allocator,
        text: []const u8,
        replacement: []const u8,
    ) ReplaceError![]u8 {
        var m = try self.matcher(text);
        defer m.deinit();

        var output = std.ArrayList(u8).empty;
        errdefer output.deinit(allocator);

        if (try m.find()) {
            const span = m.groupSpan(0).?;
            try output.appendSlice(allocator, text[0..span.start]);
            try self.appendReplacement(allocator, &output, replacement, &m);
            try output.appendSlice(allocator, text[span.end..]);
        } else {
            try output.appendSlice(allocator, text);
        }
        return output.toOwnedSlice(allocator);
    }

    pub fn splitAlloc(
        self: *const Regex,
        allocator: std.mem.Allocator,
        text: []const u8,
        limit: ?usize,
    ) SplitError![][]u8 {
        var m = try self.matcher(text);
        defer m.deinit();

        var fields = std.ArrayList([]u8).empty;
        errdefer {
            for (fields.items) |field| allocator.free(field);
            fields.deinit(allocator);
        }

        var next_start: usize = 0;
        while (true) {
            if (limit) |maximum| {
                if (maximum != 0 and fields.items.len + 1 >= maximum) break;
            }
            if (!try m.findNext()) break;
            const span = m.groupSpan(0).?;
            try fields.append(
                allocator,
                try allocator.dupe(u8, text[next_start..span.start]),
            );
            next_start = span.end;

            var group: u16 = 1;
            while (group <= self.group_count) : (group += 1) {
                if (limit) |maximum| {
                    if (maximum != 0 and fields.items.len + 1 >= maximum) break;
                }
                const piece = if (m.groupSpan(group)) |group_span|
                    text[group_span.start..group_span.end]
                else
                    "";
                try fields.append(allocator, try allocator.dupe(u8, piece));
            }
        }

        try fields.append(allocator, try allocator.dupe(u8, text[next_start..]));
        return fields.toOwnedSlice(allocator);
    }

    fn appendReplacement(
        self: *const Regex,
        allocator: std.mem.Allocator,
        output: *std.ArrayList(u8),
        replacement: []const u8,
        m: *const Matcher,
    ) ReplaceError!void {
        var index: usize = 0;
        while (index < replacement.len) {
            const byte = replacement[index];
            if (byte == '\\') {
                index += 1;
                if (index >= replacement.len) break;
                if (replacement[index] == 'u' or replacement[index] == 'U') {
                    const digits: usize = if (replacement[index] == 'u') 4 else 8;
                    const value = parseHexEscape(replacement[index + 1 ..], digits);
                    if (value) |codepoint| {
                        var encoded: [4]u8 = undefined;
                        const length = std.unicode.utf8Encode(codepoint, &encoded) catch {
                            try output.appendSlice(allocator, replacement[index - 1 .. index + 1 + digits]);
                            index += 1 + digits;
                            continue;
                        };
                        try output.appendSlice(allocator, encoded[0..length]);
                        index += 1 + digits;
                        continue;
                    }
                    try output.append(allocator, '\\');
                    continue;
                }
                const length = std.unicode.utf8ByteSequenceLength(replacement[index]) catch {
                    try output.append(allocator, replacement[index]);
                    index += 1;
                    continue;
                };
                if (index + length > replacement.len) return error.InvalidReplacement;
                try output.appendSlice(allocator, replacement[index..][0..length]);
                index += length;
                continue;
            }

            if (byte != '$') {
                const length = std.unicode.utf8ByteSequenceLength(byte) catch {
                    try output.append(allocator, byte);
                    index += 1;
                    continue;
                };
                if (index + length > replacement.len) return error.InvalidReplacement;
                try output.appendSlice(allocator, replacement[index..][0..length]);
                index += length;
                continue;
            }

            index += 1;
            if (index >= replacement.len) return error.InvalidReplacement;
            if (replacement[index] == '{') {
                index += 1;
                const name_start = index;
                while (index < replacement.len and replacement[index] != '}') {
                    if (!std.ascii.isAlphanumeric(replacement[index])) {
                        return error.InvalidReplacement;
                    }
                    index += 1;
                }
                if (index >= replacement.len) return error.InvalidReplacement;
                const name = replacement[name_start..index];
                index += 1;
                const group = self.groupIndexFromName(name) orelse
                    return error.InvalidReplacement;
                try appendGroup(allocator, output, m, group);
                continue;
            }

            var group: u32 = 0;
            var digits: usize = 0;
            while (index < replacement.len) {
                const digit = replacement[index];
                if (digit < '0' or digit > '9') break;
                const next = group * 10 + (digit - '0');
                if (next > self.group_count) break;
                group = next;
                digits += 1;
                index += 1;
            }
            if (digits == 0) return error.InvalidReplacement;
            try appendGroup(allocator, output, m, @intCast(group));
        }
    }
};

pub const Matcher = struct {
    regex: *const Regex,
    runner: vm.Runner,

    pub fn init(
        regex: *const Regex,
        text: []const u8,
        options: MatcherOptions,
    ) error{ InvalidUtf8, OutOfMemory }!Matcher {
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
        const runner = try vm.Runner.init(
            regex.allocator,
            regex.program.insts,
            regex.sets,
            regex.program.exact,
            regex.program.folded,
            &regex.word_set,
            regex.flags,
            text,
            regex.group_count,
            regex.program.first_byte_bitmap,
            regex.program.literal_prefix,
            regex.program.required_literal,
            regex.program.full_literal,
            regex.program.literal_alternatives,
            .{
                .transparent_bounds = options.transparent_bounds,
                .anchoring_bounds = options.anchoring_bounds,
                .max_steps = options.max_steps,
                .max_backtrack = options.max_backtrack,
            },
        );
        return .{ .regex = regex, .runner = runner };
    }

    pub fn deinit(self: *Matcher) void {
        self.runner.deinit();
    }

    pub fn reset(self: *Matcher, text: []const u8) error{InvalidUtf8}!void {
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
        self.runner.reset(text);
    }

    pub fn setRegion(self: *Matcher, region_start: usize, region_end: usize) void {
        self.runner.setRegion(region_start, region_end);
    }

    pub fn regionStart(self: *const Matcher) usize {
        return self.runner.region_start;
    }

    pub fn regionEnd(self: *const Matcher) usize {
        return self.runner.region_end;
    }

    pub fn setTransparentBounds(self: *Matcher, transparent: bool) void {
        self.runner.setBounds(transparent, self.runner.anchoring_bounds);
    }

    pub fn setAnchoringBounds(self: *Matcher, anchoring: bool) void {
        self.runner.setBounds(self.runner.transparent_bounds, anchoring);
    }

    pub fn hasTransparentBounds(self: *const Matcher) bool {
        return self.runner.transparent_bounds;
    }

    pub fn hasAnchoringBounds(self: *const Matcher) bool {
        return self.runner.anchoring_bounds;
    }

    pub fn matches(self: *Matcher) MatchError!bool {
        return self.runner.matches();
    }

    pub fn lookingAt(self: *Matcher) MatchError!bool {
        return self.runner.lookingAt();
    }

    pub fn find(self: *Matcher) MatchError!bool {
        return self.runner.findNext();
    }

    pub fn findNext(self: *Matcher) MatchError!bool {
        return self.runner.findNext();
    }

    pub fn findAt(self: *Matcher, start_index: usize) MatchError!bool {
        return self.runner.findAt(start_index);
    }

    pub fn groupCount(self: *const Matcher) u16 {
        return self.regex.group_count;
    }

    pub fn groupSpan(self: *const Matcher, group_index: u16) ?Span {
        return self.runner.groupSpan(group_index);
    }

    pub fn group(self: *const Matcher, group_index: u16) ?[]const u8 {
        return self.runner.group(group_index);
    }

    pub fn start(self: *const Matcher, group_index: u16) ?usize {
        const span = self.runner.groupSpan(group_index) orelse return null;
        return span.start;
    }

    pub fn end(self: *const Matcher, group_index: u16) ?usize {
        const span = self.runner.groupSpan(group_index) orelse return null;
        return span.end;
    }

    pub fn start16(self: *const Matcher, group_index: u16) ?usize {
        const span = self.runner.groupSpan(group_index) orelse return null;
        return utf16Offset(self.runner.text, span.start);
    }

    pub fn end16(self: *const Matcher, group_index: u16) ?usize {
        const span = self.runner.groupSpan(group_index) orelse return null;
        return utf16Offset(self.runner.text, span.end);
    }

    pub fn hitEnd(self: *const Matcher) bool {
        return self.runner.hit_end;
    }

    pub fn requireEnd(self: *const Matcher) bool {
        return self.runner.require_end;
    }

    pub fn subject(self: *const Matcher) []const u8 {
        return self.runner.text;
    }
};

fn appendGroup(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    m: *const Matcher,
    group_index: u16,
) ReplaceError!void {
    if (m.group(group_index)) |text| {
        try output.appendSlice(allocator, text);
    }
}

fn parseHexEscape(text: []const u8, digits: usize) ?u21 {
    if (text.len < digits) return null;
    var value: u32 = 0;
    for (text[0..digits]) |byte| {
        const digit = std.fmt.charToDigit(byte, 16) catch return null;
        value = value * 16 + digit;
    }
    if (!std.unicode.utf8ValidCodepoint(@intCast(value))) return null;
    return @intCast(value);
}

fn utf16Offset(text: []const u8, byte_offset: usize) usize {
    var units: usize = 0;
    var index: usize = 0;
    const limit = @min(byte_offset, text.len);
    while (index < limit) {
        const length = std.unicode.utf8ByteSequenceLength(text[index]) catch break;
        if (index + length > limit) break;
        const codepoint = std.unicode.utf8Decode(text[index..][0..length]) catch break;
        units += if (codepoint > 0xffff) 2 else 1;
        index += length;
    }
    return units;
}
