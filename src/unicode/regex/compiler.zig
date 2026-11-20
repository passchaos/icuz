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

    pub fn deinit(self: *Program, allocator: std.mem.Allocator) void {
        allocator.free(self.insts);
        allocator.free(self.exact);
        allocator.free(self.folded);
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

    return .{
        .insts = try compiler.insts.toOwnedSlice(allocator),
        .exact = try compiler.exact.toOwnedSlice(allocator),
        .folded = try compiler.folded.toOwnedSlice(allocator),
        .counter_count = compiler.counter_count,
        .progress_count = compiler.progress_count,
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
