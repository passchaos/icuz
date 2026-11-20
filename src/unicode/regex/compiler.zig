//! Compiles a parsed ICU regular expression into a flat backtracking program.

const std = @import("std");
const parser = @import("parser.zig");
const case_data = @import("../case/data.zig");

pub const Error = error{
    InvalidPattern,
    OutOfMemory,
    PatternTooBig,
};

pub const DotMode = struct {
    dotall: bool,
    unix_lines: bool,
};

pub const StringRef = struct {
    offset: u32,
    len: u32,
};

pub const RepeatDecide = struct {
    counter: u16,
    min: u32,
    max: u32,
    greedy: bool,
    body: u32,
    exit: u32,
};

pub const LookInfo = struct {
    ahead: bool,
    positive: bool,
    body: u32,
    after: u32,
    min_len: u32,
    max_len: u32,
};

pub const LiteralAlt = struct {
    offset: u32,
    len: u32,
};

pub const BackrefInfo = struct {
    group: u16,
    case_insensitive: bool,
};

pub const Inst = union(enum) {
    char: u21,
    char_ci: u21,
    string: StringRef,
    string_ci: StringRef,
    set: u32,
    any: DotMode,
    split: struct { first: u32, second: u32 },
    jmp: u32,
    save_start: u16,
    save_end: u16,
    anchor: parser.Anchor,
    backref: BackrefInfo,
    grapheme,
    linebreak,
    atomic_start,
    atomic_end,
    repeat_init: u16,
    repeat_inc: u16,
    repeat_decide: RepeatDecide,
    progress_save: u16,
    progress_check_exit: struct { slot: u16, exit: u32 },
    look: LookInfo,
    look_match,
    match,
};

pub const Program = struct {
    insts: []Inst,
    exact: []u8,
    folded: []u21,
    counter_count: u16,
    progress_count: u16,
    /// ASCII bytes that can begin a non-empty match, or null when no safe
    /// prefilter can be derived.
    first_byte_bitmap: ?[4]u64,
    /// Exact literal prefix required at the start of every match.
    literal_prefix: ?[]u8,
    /// Exact literal substring that every match must contain.
    required_literal: ?[]u8,
    /// Exact literal covering the whole pattern, when no VM is needed.
    full_literal: ?[]u8,
    /// Exact literal alternatives, when the whole pattern is `a|b|c`.
    literal_alternatives: ?[]LiteralAlt,

    pub fn deinit(self: *Program, allocator: std.mem.Allocator) void {
        allocator.free(self.insts);
        allocator.free(self.exact);
        allocator.free(self.folded);
        if (self.literal_prefix) |prefix| allocator.free(prefix);
        if (self.required_literal) |literal| allocator.free(literal);
        if (self.full_literal) |literal| allocator.free(literal);
        if (self.literal_alternatives) |alternatives| allocator.free(alternatives);
    }
};

const max_program_instructions = 1 << 20;

pub fn compile(allocator: std.mem.Allocator, parsed: *const parser.Parsed) Error!Program {
    var compiler = Compiler{
        .allocator = allocator,
        .parsed = parsed,
    };
    defer compiler.fold_buffer.deinit(allocator);

    _ = try compiler.emit(.{ .save_start = 0 });
    try compiler.compileNode(parsed.root);
    _ = try compiler.emit(.{ .save_end = 0 });
    _ = try compiler.emit(.match);

    const first_byte_bitmap = compiler.computeFirstByteBitmap();
    const literal_prefix = try compiler.computeLiteralPrefix();
    errdefer if (literal_prefix) |prefix| allocator.free(prefix);
    const required_literal = try compiler.computeRequiredLiteral();
    errdefer if (required_literal) |literal| allocator.free(literal);
    const full_literal = try compiler.computeFullLiteral();
    errdefer if (full_literal) |literal| allocator.free(literal);
    const literal_alternatives = try compiler.computeLiteralAlternatives();
    errdefer if (literal_alternatives) |alternatives| allocator.free(alternatives);

    return .{
        .insts = try compiler.insts.toOwnedSlice(allocator),
        .exact = try compiler.exact.toOwnedSlice(allocator),
        .folded = try compiler.folded.toOwnedSlice(allocator),
        .counter_count = compiler.counter_count,
        .progress_count = compiler.progress_count,
        .first_byte_bitmap = first_byte_bitmap,
        .literal_prefix = literal_prefix,
        .required_literal = required_literal,
        .full_literal = full_literal,
        .literal_alternatives = literal_alternatives,
    };
}

const Compiler = struct {
    allocator: std.mem.Allocator,
    parsed: *const parser.Parsed,
    insts: std.ArrayList(Inst) = .empty,
    exact: std.ArrayList(u8) = .empty,
    folded: std.ArrayList(u21) = .empty,
    fold_buffer: std.ArrayList(u21) = .empty,
    counter_count: u16 = 0,
    progress_count: u16 = 0,

    fn emit(self: *Compiler, inst: Inst) Error!u32 {
        if (self.insts.items.len >= max_program_instructions) return error.PatternTooBig;
        const index: u32 = @intCast(self.insts.items.len);
        try self.insts.append(self.allocator, inst);
        return index;
    }

    fn patch(self: *Compiler, index: u32, inst: Inst) void {
        self.insts.items[index] = inst;
    }

    fn current(self: *Compiler) u32 {
        return @intCast(self.insts.items.len);
    }

    fn compileNode(self: *Compiler, node: *const parser.Node) Error!void {
        switch (node.*) {
            .empty => {},
            .literal => |literal| try self.emitLiteral(literal.text, literal.case_insensitive),
            .any => |dot| _ = try self.emit(.{ .any = .{
                .dotall = dot.dotall,
                .unix_lines = dot.unix_lines,
            } }),
            .set => |index| _ = try self.emit(.{ .set = index }),
            .concat => |children| try self.compileConcat(children),
            .alternate => |children| try self.compileAlternate(children),
            .repeat => |repeat| try self.compileRepeat(repeat),
            .capture => |capture| {
                _ = try self.emit(.{ .save_start = capture.index });
                try self.compileNode(capture.child);
                _ = try self.emit(.{ .save_end = capture.index });
            },
            .atomic => |child| {
                _ = try self.emit(.atomic_start);
                try self.compileNode(child);
                _ = try self.emit(.atomic_end);
            },
            .look => |look| try self.compileLook(look),
            .anchor => |anchor| _ = try self.emit(.{ .anchor = anchor }),
            .backref => |backref| _ = try self.emit(.{ .backref = .{
                .group = backref.group,
                .case_insensitive = backref.case_insensitive,
            } }),
            .grapheme => _ = try self.emit(.grapheme),
            .linebreak => _ = try self.emit(.linebreak),
        }
    }

    fn compileConcat(self: *Compiler, children: []const *parser.Node) Error!void {
        var index: usize = 0;
        while (index < children.len) {
            if (std.meta.activeTag(children[index].*) != .literal) {
                try self.compileNode(children[index]);
                index += 1;
                continue;
            }
            const case_insensitive = children[index].literal.case_insensitive;
            var text = std.ArrayList(u8).empty;
            defer text.deinit(self.allocator);
            // Gather consecutive literal nodes with the same case mode so
            // folding can expand across atom boundaries (`ss` matching `ß`).
            while (index < children.len and
                std.meta.activeTag(children[index].*) == .literal and
                children[index].literal.case_insensitive == case_insensitive)
            {
                try text.appendSlice(self.allocator, children[index].literal.text);
                index += 1;
            }
            try self.emitLiteral(text.items, case_insensitive);
        }
    }

    fn compileAlternate(self: *Compiler, children: []const *parser.Node) Error!void {
        if (children.len == 0) return;
        if (children.len == 1) return self.compileNode(children[0]);

        var end_jumps = std.ArrayList(u32).empty;
        defer end_jumps.deinit(self.allocator);

        for (children, 0..) |child, child_index| {
            if (child_index + 1 < children.len) {
                const split_index = try self.emit(.{ .split = .{
                    .first = 0,
                    .second = 0,
                } });
                const body_start = self.current();
                try self.compileNode(child);
                const jump_index = try self.emit(.{ .jmp = 0 });
                const next_start = self.current();
                self.patch(split_index, .{ .split = .{
                    .first = body_start,
                    .second = next_start,
                } });
                try end_jumps.append(self.allocator, jump_index);
            } else {
                try self.compileNode(child);
            }
        }

        const end = self.current();
        for (end_jumps.items) |jump_index| {
            self.patch(jump_index, .{ .jmp = end });
        }
    }

    fn compileRepeat(self: *Compiler, repeat: parser.Repeat) Error!void {
        if (repeat.max) |max| {
            if (max == 0) return;
        }

        if (repeat.min == 0 and repeat.max == 1) {
            if (repeat.kind == .possessive) _ = try self.emit(.atomic_start);
            const split_index = try self.emit(.{ .split = .{
                .first = 0,
                .second = 0,
            } });
            const body_start = self.current();
            try self.compileNode(repeat.child);
            const after = self.current();
            self.patch(split_index, .{ .split = switch (repeat.kind) {
                .reluctant => .{ .first = after, .second = body_start },
                else => .{ .first = body_start, .second = after },
            } });
            if (repeat.kind == .possessive) _ = try self.emit(.atomic_end);
            return;
        }

        if (self.counter_count == std.math.maxInt(u16) or
            self.progress_count == std.math.maxInt(u16))
        {
            return error.PatternTooBig;
        }

        const counter = self.counter_count;
        self.counter_count += 1;
        const progress = self.progress_count;
        self.progress_count += 1;
        const unbounded = repeat.max == null;

        if (repeat.kind == .possessive) _ = try self.emit(.atomic_start);

        _ = try self.emit(.{ .repeat_init = counter });
        const decide_index = try self.emit(.{ .repeat_decide = .{
            .counter = counter,
            .min = repeat.min,
            .max = repeat.max orelse std.math.maxInt(u32),
            .greedy = repeat.kind != .reluctant,
            .body = 0,
            .exit = 0,
        } });

        const body_start = self.current();
        if (unbounded) _ = try self.emit(.{ .progress_save = progress });
        try self.compileNode(repeat.child);
        var check_index: ?u32 = null;
        if (unbounded) {
            check_index = try self.emit(.{ .progress_check_exit = .{
                .slot = progress,
                .exit = 0,
            } });
        }
        _ = try self.emit(.{ .repeat_inc = counter });
        _ = try self.emit(.{ .jmp = decide_index });

        const exit_index = self.current();
        self.patch(decide_index, .{ .repeat_decide = .{
            .counter = counter,
            .min = repeat.min,
            .max = repeat.max orelse std.math.maxInt(u32),
            .greedy = repeat.kind != .reluctant,
            .body = body_start,
            .exit = exit_index,
        } });
        if (check_index) |index| {
            self.patch(index, .{ .progress_check_exit = .{
                .slot = progress,
                .exit = exit_index,
            } });
        }
        if (repeat.kind == .possessive) _ = try self.emit(.atomic_end);
    }

    fn compileLook(self: *Compiler, look: parser.Look) Error!void {
        const bounds = parser.lengthBounds(look.child);
        const look_index = try self.emit(.{ .look = .{
            .ahead = look.ahead,
            .positive = look.positive,
            .body = 0,
            .after = 0,
            .min_len = bounds.min,
            .max_len = bounds.max orelse 0,
        } });
        const body_start = self.current();
        try self.compileNode(look.child);
        _ = try self.emit(.look_match);
        const after = self.current();
        self.patch(look_index, .{ .look = .{
            .ahead = look.ahead,
            .positive = look.positive,
            .body = body_start,
            .after = after,
            .min_len = bounds.min,
            .max_len = bounds.max orelse 0,
        } });
    }

    fn computeFirstByteBitmap(self: *Compiler) ?[4]u64 {
        return self.firstBytes(0, 0) catch null;
    }

    fn firstBytes(self: *Compiler, pc: u32, depth: u32) Error!?[4]u64 {
        if (depth > 64 or pc >= self.insts.items.len) return null;
        return switch (self.insts.items[pc]) {
            .char => |codepoint| blk: {
                if (codepoint > 0x7f) break :blk null;
                var bits = [_]u64{0} ** 4;
                bits[codepoint >> 6] |= @as(u64, 1) << @intCast(codepoint & 63);
                break :blk bits;
            },
            .string => |ref| blk: {
                if (ref.len == 0 or self.exact.items[ref.offset] >= 0x80) break :blk null;
                var bits = [_]u64{0} ** 4;
                const byte = self.exact.items[ref.offset];
                bits[byte >> 6] |= @as(u64, 1) << @intCast(byte & 63);
                break :blk bits;
            },
            .set => |index| blk: {
                const set = self.parsed.sets[index];
                var bits = [_]u64{0} ** 4;
                var ranges = set.rangeIterator();
                while (ranges.next()) |range| {
                    if (range.last > 0x7f) break :blk null;
                    var codepoint: u32 = range.first;
                    while (codepoint <= range.last) : (codepoint += 1) {
                        bits[codepoint >> 6] |= @as(u64, 1) << @intCast(codepoint & 63);
                    }
                }
                break :blk bits;
            },
            .split => |split| blk: {
                const first = try self.firstBytes(split.first, depth + 1) orelse break :blk null;
                const second = try self.firstBytes(split.second, depth + 1) orelse break :blk null;
                var bits = first;
                for (&bits, second) |*word, other| word.* |= other;
                break :blk bits;
            },
            .jmp => |target| self.firstBytes(target, depth + 1),
            .repeat_decide => |decide| blk: {
                if (decide.min > 0) break :blk try self.firstBytes(decide.body, depth + 1);
                const body = try self.firstBytes(decide.body, depth + 1) orelse break :blk null;
                const exit = try self.firstBytes(decide.exit, depth + 1) orelse break :blk null;
                var bits = body;
                for (&bits, exit) |*word, other| word.* |= other;
                break :blk bits;
            },
            .progress_check_exit => |check| blk: {
                const exit = try self.firstBytes(check.exit, depth + 1) orelse break :blk null;
                const next = try self.firstBytes(pc + 1, depth + 1) orelse break :blk null;
                var bits = exit;
                for (&bits, next) |*word, other| word.* |= other;
                break :blk bits;
            },
            .save_start,
            .save_end,
            .atomic_start,
            .atomic_end,
            .repeat_init,
            .repeat_inc,
            .progress_save,
            .anchor,
            => self.firstBytes(pc + 1, depth + 1),
            .look => |look| self.firstBytes(look.after, depth + 1),
            .any,
            .char_ci,
            .string_ci,
            .backref,
            .grapheme,
            .linebreak,
            .match,
            .look_match,
            => null,
        };
    }

    fn computeLiteralPrefix(self: *Compiler) Error!?[]u8 {
        var prefix = std.ArrayList(u8).empty;
        errdefer prefix.deinit(self.allocator);
        var pc: u32 = 0;
        var steps: u32 = 0;
        while (steps < 256 and pc < self.insts.items.len) : (steps += 1) {
            switch (self.insts.items[pc]) {
                .save_start, .save_end, .atomic_start, .atomic_end, .anchor => pc += 1,
                .char => |codepoint| {
                    var buffer: [4]u8 = undefined;
                    const length = std.unicode.utf8Encode(codepoint, &buffer) catch break;
                    try prefix.appendSlice(self.allocator, buffer[0..length]);
                    pc += 1;
                },
                .string => |ref| {
                    try prefix.appendSlice(
                        self.allocator,
                        self.exact.items[ref.offset..][0..ref.len],
                    );
                    pc += 1;
                },
                else => break,
            }
        }
        if (prefix.items.len < 2) {
            prefix.deinit(self.allocator);
            return null;
        }
        const owned = try prefix.toOwnedSlice(self.allocator);
        return owned;
    }

    fn computeLiteralAlternatives(self: *Compiler) Error!?[]LiteralAlt {
        const children = switch (self.parsed.root.*) {
            .alternate => |alternatives| alternatives,
            else => return null,
        };
        if (children.len < 2) return null;

        var alternatives = std.ArrayList(LiteralAlt).empty;
        errdefer alternatives.deinit(self.allocator);
        for (children) |child| {
            const text = switch (child.*) {
                .literal => |literal| if (literal.case_insensitive)
                    null
                else
                    literal.text,
                else => null,
            } orelse {
                alternatives.deinit(self.allocator);
                return null;
            };
            if (text.len == 0) {
                alternatives.deinit(self.allocator);
                return null;
            }
            const offset: u32 = @intCast(self.exact.items.len);
            try self.exact.appendSlice(self.allocator, text);
            try alternatives.append(self.allocator, .{
                .offset = offset,
                .len = @intCast(text.len),
            });
        }
        const owned = try alternatives.toOwnedSlice(self.allocator);
        return owned;
    }

    fn computeFullLiteral(self: *Compiler) Error!?[]u8 {
        return self.fullLiteralFromNode(self.parsed.root);
    }

    fn fullLiteralFromNode(self: *Compiler, node: *const parser.Node) Error!?[]u8 {
        return switch (node.*) {
            .literal => |literal| if (literal.case_insensitive)
                null
            else
                try self.allocator.dupe(u8, literal.text),
            .concat => |children| blk: {
                var output = std.ArrayList(u8).empty;
                errdefer output.deinit(self.allocator);
                for (children) |child| {
                    if (std.meta.activeTag(child.*) != .literal or
                        child.literal.case_insensitive)
                    {
                        output.deinit(self.allocator);
                        break :blk null;
                    }
                    try output.appendSlice(self.allocator, child.literal.text);
                }
                const owned = try output.toOwnedSlice(self.allocator);
                break :blk owned;
            },
            else => null,
        };
    }

    fn computeRequiredLiteral(self: *Compiler) Error!?[]u8 {
        const literal = self.requiredFromNode(self.parsed.root) orelse return null;
        if (literal.len < 2) return null;
        return try self.allocator.dupe(u8, literal);
    }

    fn requiredFromNode(self: *Compiler, node: *const parser.Node) ?[]const u8 {
        return switch (node.*) {
            .literal => |literal| if (literal.case_insensitive) null else literal.text,
            .concat => |children| self.requiredFromConcat(children),
            .alternate => |children| blk: {
                if (children.len == 0) break :blk null;
                const first = self.requiredFromNode(children[0]) orelse break :blk null;
                for (children[1..]) |child| {
                    const other = self.requiredFromNode(child) orelse break :blk null;
                    if (!std.mem.eql(u8, first, other)) break :blk null;
                }
                break :blk first;
            },
            .repeat => |repeat| if (repeat.min > 0)
                self.requiredFromNode(repeat.child)
            else
                null,
            .capture => |capture| self.requiredFromNode(capture.child),
            .atomic => |child| self.requiredFromNode(child),
            .look => |look| if (look.positive)
                self.requiredFromNode(look.child)
            else
                null,
            else => null,
        };
    }

    fn requiredFromConcat(self: *Compiler, children: []const *parser.Node) ?[]const u8 {
        var best: ?[]const u8 = null;
        var run: ?[]const u8 = null;
        for (children) |child| {
            if (std.meta.activeTag(child.*) == .literal and
                !child.literal.case_insensitive)
            {
                const text = child.literal.text;
                if (run) |active| {
                    const end = @intFromPtr(active.ptr) + active.len;
                    if (end == @intFromPtr(text.ptr)) {
                        run = active.ptr[0 .. active.len + text.len];
                    } else {
                        best = longer(best, active);
                        run = text;
                    }
                } else {
                    run = text;
                }
            } else {
                if (run) |active| {
                    best = longer(best, active);
                    run = null;
                }
                if (self.requiredFromNode(child)) |literal| {
                    best = longer(best, literal);
                }
            }
        }
        if (run) |active| best = longer(best, active);
        return best;
    }

    fn emitLiteral(self: *Compiler, text: []const u8, case_insensitive: bool) Error!void {
        if (text.len == 0) return;

        if (case_insensitive) {
            self.fold_buffer.clearRetainingCapacity();
            try foldText(self.allocator, text, &self.fold_buffer);
            if (self.fold_buffer.items.len == 0) return;

            if (self.fold_buffer.items.len == 1) {
                _ = try self.emit(.{ .char_ci = self.fold_buffer.items[0] });
                return;
            }
            const offset: u32 = @intCast(self.folded.items.len);
            try self.folded.appendSlice(self.allocator, self.fold_buffer.items);
            _ = try self.emit(.{ .string_ci = .{
                .offset = offset,
                .len = @intCast(self.fold_buffer.items.len),
            } });
            return;
        }

        if (std.unicode.utf8CountCodepoints(text) catch 0 == 1) {
            const codepoint = std.unicode.utf8Decode(text) catch return error.InvalidPattern;
            _ = try self.emit(.{ .char = codepoint });
            return;
        }
        const offset: u32 = @intCast(self.exact.items.len);
        try self.exact.appendSlice(self.allocator, text);
        _ = try self.emit(.{ .string = .{
            .offset = offset,
            .len = @intCast(text.len),
        } });
    }
};

fn longer(current: ?[]const u8, candidate: []const u8) ?[]const u8 {
    if (current) |value| {
        return if (candidate.len > value.len) candidate else value;
    }
    return candidate;
}

fn foldText(
    allocator: std.mem.Allocator,
    text: []const u8,
    output: *std.ArrayList(u21),
) Error!void {
    var iterator = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    while (iterator.nextCodepoint()) |codepoint| {
        if (case_data.fullFold(codepoint)) |components| {
            try output.appendSlice(allocator, components);
        } else {
            try output.append(allocator, case_data.simpleFold(codepoint));
        }
    }
}
