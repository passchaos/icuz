//! ICU-compatible Arabic letter shaping (`u_shapeArabic`).
//!
//! The engine converts Arabic letters in the U+06xx range to their positional
//! presentation forms in the U+FBxx/U+FExx ranges, or converts presentation
//! forms back to base letters. It also implements ICU's Lam-Alef handling,
//! tashkeel positioning, digit conversion, and visual-order modes.
//!
//! The state machine and its data tables mirror ICU 78's `ushape.cpp` so the
//! output matches ICU byte for byte. The tables are Unicode-derived positional
//! form data; see `licenses/Unicode-3.0.txt`.

const std = @import("std");
const tables = @import("tables.zig");
const scalar = @import("../scalar/root.zig");
const bidi = @import("../bidi/paragraph.zig");

const IRRELEVANT: u16 = 4;
const LAMTYPE: u16 = 16;
const ALEFTYPE: u16 = 32;
const LINKR: u16 = 1;
const LINKL: u16 = 2;
const APRESENT: u16 = 8;
const SHADDA: u16 = 64;
const CSHADDA: u16 = 128;
const COMBINE: u16 = SHADDA + CSHADDA;

const HAMZAFE_CHAR: u21 = 0xfe80;
const HAMZA06_CHAR: u21 = 0x0621;
const YEH_HAMZA_CHAR: u21 = 0x0626;
const LAMALEF_SPACE_SUB: u21 = 0xffff;
const TASHKEEL_SPACE_SUB: u21 = 0xfffe;
const NEW_TAIL_CHAR: u21 = 0xfe73;
const OLD_TAIL_CHAR: u21 = 0x200b;
const LAM_CHAR: u21 = 0x0644;
const SPACE_CHAR: u21 = 0x0020;
const SHADDA_CHAR: u21 = 0xfe7c;
const TATWEEL_CHAR: u21 = 0x0640;
const SHADDA_TATWEEL_CHAR: u21 = 0xfe7d;
const SHADDA06_CHAR: u21 = 0x0651;

/// Positional letter forms. `noop` leaves the text unchanged.
pub const Letters = enum(u8) {
    noop = 0,
    shape = 8,
    unshape = 0x10,
    shape_tashkeel_isolated = 0x18,
};

/// ICU's visual right-to-left mode is an alias of logical mode.
pub const TextDirection = enum(u8) {
    logical = 0,
    visual_ltr = 4,
};

pub const Tashkeel = enum(u32) {
    noop = 0,
    begin = 0x40000,
    end = 0x60000,
    resize = 0x80000,
    replace_by_tatweel = 0xc0000,
};

/// Where generated Lam-Alef and tashkeel spaces go.
pub const LamAlef = enum(u32) {
    resize = 0,
    near = 1,
    end = 2,
    begin = 3,
    auto = 0x10000,
};

pub const Digits = enum(u8) {
    noop = 0,
    en2an = 0x20,
    an2en = 0x40,
    alen2an_init_lr = 0x60,
    alen2an_init_al = 0x80,
};

pub const DigitType = enum(u16) {
    an = 0,
    an_extended = 0x100,
};

/// Options for `shapeArabicAlloc`, mirroring `U_SHAPE_*` bits.
pub const Options = struct {
    letters: Letters = .noop,
    text_direction: TextDirection = .logical,
    tashkeel: Tashkeel = .noop,
    lam_alef: LamAlef = .resize,
    digits: Digits = .noop,
    digit_type: DigitType = .an,
    preserve_presentation: bool = false,
    seen_twocell_near: bool = false,
    yeh_hamza_twocell_near: bool = false,
    spaces_relative_to_text: bool = false,
    tail_new_unicode: bool = false,
    aggregate_tashkeel: bool = false,

    /// Decode ICU `U_SHAPE_*` option bits.
    pub fn fromRaw(raw: u32) Options {
        var result = Options{};
        result.letters = switch (raw & 0x18) {
            8 => .shape,
            0x10 => .unshape,
            0x18 => .shape_tashkeel_isolated,
            else => .noop,
        };
        result.text_direction = if (raw & 4 != 0) .visual_ltr else .logical;
        result.tashkeel = switch (raw & 0xe0000) {
            0x40000 => .begin,
            0x60000 => .end,
            0x80000 => .resize,
            0xc0000 => .replace_by_tatweel,
            else => .noop,
        };
        result.lam_alef = switch (raw & 0x10003) {
            1 => .near,
            2 => .end,
            3 => .begin,
            0x10000 => .auto,
            else => .resize,
        };
        result.digits = switch (raw & 0xe0) {
            0x20 => .en2an,
            0x40 => .an2en,
            0x60 => .alen2an_init_lr,
            0x80 => .alen2an_init_al,
            else => .noop,
        };
        result.digit_type = if (raw & 0x100 != 0) .an_extended else .an;
        result.preserve_presentation = raw & 0x8000 != 0;
        result.seen_twocell_near = raw & 0x200000 != 0;
        result.yeh_hamza_twocell_near = raw & 0x1000000 != 0;
        result.spaces_relative_to_text = raw & 0x4000000 != 0;
        result.tail_new_unicode = raw & 0x8000000 != 0;
        result.aggregate_tashkeel = raw & 0x4000 != 0;
        return result;
    }

    /// Encode the options as ICU `U_SHAPE_*` bits.
    pub fn toRaw(self: Options) u32 {
        var raw: u32 = @intFromEnum(self.letters) |
            @intFromEnum(self.text_direction) |
            @intFromEnum(self.tashkeel) |
            @intFromEnum(self.lam_alef) |
            @intFromEnum(self.digits) |
            @intFromEnum(self.digit_type);
        if (self.preserve_presentation) raw |= 0x8000;
        if (self.seen_twocell_near) raw |= 0x200000;
        if (self.yeh_hamza_twocell_near) raw |= 0x1000000;
        if (self.spaces_relative_to_text) raw |= 0x4000000;
        if (self.tail_new_unicode) raw |= 0x8000000;
        if (self.aggregate_tashkeel) raw |= 0x4000;
        return raw;
    }
};

pub const Error = error{
    InvalidUtf8,
    InvalidOption,
    NoSpaceAvailable,
    OutOfMemory,
};

const ShapeVariables = struct {
    tail_char: u21,
    lam_begin: LamAlef,
    lam_end: LamAlef,
    tashkeel_begin: Tashkeel,
    tashkeel_end: Tashkeel,
    spaces_relative: bool,
};

const Aggregated = struct {
    storage: []u21,
    slice: []u21,
};

/// Shape or unshape Arabic text. The result is allocator-owned UTF-8.
pub fn shapeArabicAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
    options: Options,
) Error![]u8 {
    // Shaping inputs are short and the pipeline allocates decoded scalars,
    // a work buffer, and the encoded result; run it against a stack arena and
    // hand back one exact allocation. Longer inputs retry on the heap.
    var stack: [8192]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&stack);
    if (shapeArabicInner(fixed.allocator(), text, options)) |result| {
        return allocator.dupe(u8, result);
    } else |err| switch (err) {
        error.OutOfMemory => {},
        else => return err,
    }
    return shapeArabicInner(allocator, text, options);
}

fn shapeArabicInner(
    allocator: std.mem.Allocator,
    text: []const u8,
    options: Options,
) Error![]u8 {
    try validateOptions(options);

    var source = std.ArrayList(u21).empty;
    defer source.deinit(allocator);
    try source.ensureTotalCapacity(allocator, text.len);
    var cursor: usize = 0;
    while (cursor < text.len) {
        const decoded = scalar.decodeValidating(text, cursor) orelse
            return error.InvalidUtf8;
        source.appendAssumeCapacity(decoded.codepoint);
        cursor = decoded.next;
    }
    if (source.items.len == 0) return allocator.alloc(u8, 0);

    var shape_vars = ShapeVariables{
        .tail_char = if (options.tail_new_unicode) NEW_TAIL_CHAR else OLD_TAIL_CHAR,
        .lam_begin = .begin,
        .lam_end = .end,
        .tashkeel_begin = .begin,
        .tashkeel_end = .end,
        .spaces_relative = false,
    };

    var aggregated: ?Aggregated = null;
    defer if (aggregated) |value| allocator.free(value.storage);
    var working: []const u21 = source.items;
    if (options.aggregate_tashkeel) {
        aggregated = try aggregateTashkeel(allocator, working, options);
        working = aggregated.?.slice;
    }

    var shaped: ?[]u21 = null;
    defer if (shaped) |storage| allocator.free(storage);
    var result: []const u21 = working;

    if (options.letters != .noop) {
        const output_size = if (options.lam_alef == .resize or
            options.tashkeel == .resize)
            calculateSize(working, options)
        else
            working.len;
        const storage = try allocator.alloc(u21, @max(output_size, working.len));
        shaped = storage;
        @memcpy(storage[0..working.len], working);
        @memset(storage[working.len..], 0);

        if (options.text_direction == .logical) {
            invertBufferSpaces(storage[0..working.len]);
        }
        if (options.text_direction == .visual_ltr and
            options.spaces_relative_to_text)
        {
            shape_vars.spaces_relative = true;
            shape_vars.lam_begin = .end;
            shape_vars.lam_end = .begin;
            shape_vars.tashkeel_begin = .end;
            shape_vars.tashkeel_end = .begin;
        }

        var length: usize = undefined;
        switch (options.letters) {
            .shape => {
                if (options.tashkeel != .noop and
                    options.tashkeel != .replace_by_tatweel)
                {
                    length = try shapeUnicode(
                        allocator,
                        storage,
                        working.len,
                        options,
                        2,
                        shape_vars,
                    );
                } else {
                    length = try shapeUnicode(
                        allocator,
                        storage,
                        working.len,
                        options,
                        1,
                        shape_vars,
                    );
                    if (options.tashkeel == .replace_by_tatweel) {
                        length = handleTashkeelWithTatweel(storage[0..length]);
                    }
                }
            },
            .shape_tashkeel_isolated => {
                length = try shapeUnicode(
                    allocator,
                    storage,
                    working.len,
                    options,
                    0,
                    shape_vars,
                );
            },
            .unshape => {
                length = try deShapeUnicode(
                    allocator,
                    storage,
                    working.len,
                    options,
                    shape_vars,
                );
            },
            .noop => unreachable,
        }

        if (options.text_direction == .logical) {
            invertBufferSpaces(storage[0..length]);
        }
        result = storage[0..length];
    }

    try shapeDigits(@constCast(result), options);
    return encodeUtf8(allocator, result);
}

fn validateOptions(options: Options) Error!void {
    if (options.tashkeel != .noop and
        options.letters == .shape_tashkeel_isolated)
    {
        return error.InvalidOption;
    }
    if (options.tashkeel != .noop and options.letters == .unshape) {
        return error.InvalidOption;
    }
    if (options.aggregate_tashkeel) {
        if (options.lam_alef != .resize) return error.InvalidOption;
        if (options.letters != .shape_tashkeel_isolated) {
            return error.InvalidOption;
        }
    }
}

fn encodeUtf8(
    allocator: std.mem.Allocator,
    codepoints: []const u21,
) Error![]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try output.ensureTotalCapacity(allocator, codepoints.len * 4);
    for (codepoints) |codepoint| {
        const spare = output.unusedCapacitySlice();
        const length = scalar.encodeUtf8(spare[0..4], codepoint);
        output.items.len += length;
    }
    return output.toOwnedSlice(allocator);
}

fn aggregateTashkeel(
    allocator: std.mem.Allocator,
    source: []const u21,
    options: Options,
) Error!Aggregated {
    const logical = options.text_direction == .logical;
    const step: isize = if (logical) 1 else -1;
    const end: isize = if (logical) @intCast(source.len) else -1;
    var i: isize = if (logical) -1 else @intCast(source.len);
    var j: isize = if (logical) -1 else 2 * @as(isize, @intCast(source.len));
    var aggregation_possible = true;
    var prev: u21 = 0;
    var prev_link: u16 = 0;
    var curr_link: u16 = 0;
    var new_length: usize = 0;

    const storage = try allocator.alloc(u21, 2 * source.len);
    errdefer allocator.free(storage);

    while (true) {
        i += step;
        if (i == end) break;
        prev_link = curr_link;
        curr_link = getLink(source[@intCast(i)]);
        if (((prev_link | curr_link) & COMBINE) == COMBINE and
            aggregation_possible)
        {
            aggregation_possible = false;
            const lower = @min(prev, source[@intCast(i)]);
            const combined = lower - 0x064c + 0xfc5e;
            storage[@intCast(j)] = combined;
            curr_link = getLink(combined);
        } else {
            aggregation_possible = true;
            j += step;
            if (j < 0) return error.InvalidOption;
            storage[@intCast(j)] = source[@intCast(i)];
            prev = source[@intCast(i)];
            new_length += 1;
        }
    }

    if (logical) {
        return .{ .storage = storage, .slice = storage[0..new_length] };
    }
    const start: usize = @intCast(j);
    std.mem.copyForwards(u21, storage[0..new_length], storage[start .. start + new_length]);
    return .{ .storage = storage, .slice = storage[0..new_length] };
}

fn getLink(codepoint: u21) u16 {
    if (codepoint >= 0x0622 and codepoint <= 0x06d3) {
        return tables.ara_link[codepoint - 0x0622];
    }
    if (codepoint == 0x200d) return 3;
    if (codepoint >= 0x206d and codepoint <= 0x206f) return 4;
    if (codepoint >= 0xfb50 and codepoint <= 0xfc62) {
        return tables.pres_a_link[codepoint - 0xfb50];
    }
    if (codepoint >= 0xfe70 and codepoint <= 0xfefc) {
        return tables.pres_b_link[codepoint - 0xfe70];
    }
    return 0;
}

fn changeLamAlef(codepoint: u21) u21 {
    return switch (codepoint) {
        0x0622 => 0x065c,
        0x0623 => 0x065d,
        0x0625 => 0x065e,
        0x0627 => 0x065f,
        else => 0,
    };
}

fn isTashkeelChar(codepoint: u21) bool {
    return codepoint >= 0x064b and codepoint <= 0x0652;
}

fn isTashkeelCharFe(codepoint: u21) bool {
    return codepoint >= 0xfe70 and codepoint <= 0xfe7f;
}

fn isAlefChar(codepoint: u21) bool {
    return codepoint == 0x0622 or codepoint == 0x0623 or
        codepoint == 0x0625 or codepoint == 0x0627;
}

fn isLamAlefChar(codepoint: u21) bool {
    return codepoint >= 0xfef5 and codepoint <= 0xfefc;
}

fn isTailChar(codepoint: u21) bool {
    return codepoint == OLD_TAIL_CHAR or codepoint == NEW_TAIL_CHAR;
}

fn isSeenTailFamilyChar(codepoint: u21) bool {
    if (codepoint >= 0xfeb1 and codepoint < 0xfebf) {
        return tables.tail_family_isolated_final[codepoint - 0xfeb1] != 0;
    }
    return false;
}

fn isSeenFamilyChar(codepoint: u21) bool {
    return codepoint >= 0x0633 and codepoint <= 0x0636;
}

fn isAlefMaksouraChar(codepoint: u21) bool {
    return codepoint == 0xfeef or codepoint == 0xfef0 or codepoint == 0x0649;
}

fn isYehHamzaChar(codepoint: u21) bool {
    return codepoint == 0xfe89 or codepoint == 0xfe8a;
}

fn isTashkeelOnTatweelChar(codepoint: u21) u8 {
    if (codepoint >= 0xfe70 and codepoint <= 0xfe7f and
        codepoint != NEW_TAIL_CHAR and codepoint != 0xfe75 and
        codepoint != SHADDA_TATWEEL_CHAR)
    {
        return tables.tashkeel_medial[codepoint - 0xfe70];
    }
    if ((codepoint >= 0xfcf2 and codepoint <= 0xfcf4) or
        codepoint == SHADDA_TATWEEL_CHAR)
    {
        return 2;
    }
    return 0;
}

fn isIsolatedTashkeelChar(codepoint: u21) u8 {
    if (codepoint >= 0xfe70 and codepoint <= 0xfe7f and
        codepoint != NEW_TAIL_CHAR and codepoint != 0xfe75)
    {
        return 1 - tables.tashkeel_medial[codepoint - 0xfe70];
    }
    if (codepoint >= 0xfc5e and codepoint <= 0xfc63) return 1;
    return 0;
}

fn shapeUnicode(
    allocator: std.mem.Allocator,
    storage: []u21,
    length: usize,
    options: Options,
    tashkeel_flag: u8,
    shape_vars: ShapeVariables,
) Error!usize {
    const dest = storage[0..length];

    if (!options.preserve_presentation) {
        for (dest) |*codepoint| {
            const input = codepoint.*;
            if (input >= 0xfb50 and input <= 0xfbff) {
                const converted = tables.convert_fb[input - 0xfb50];
                if (converted != 0) codepoint.* = converted;
            } else if (input >= 0xfe70 and input <= 0xfefc) {
                codepoint.* = tables.convert_fe[input - 0xfe70];
            }
        }
    }

    var lamalef_found = false;
    var seenfam_found = false;
    var yehhamza_found = false;
    var tashkeel_found = false;

    var i: isize = @as(isize, @intCast(length)) - 1;
    const iend: isize = -1;
    const step: isize = -1;

    var curr_link = getLink(dest[@intCast(i)]);
    var last_pos: isize = i;
    var nx: isize = -2;
    var nw: isize = 0;
    var prev_link: u16 = 0;
    var last_link: u16 = 0;
    var next_link: u16 = 0;

    while (i != iend) {
        const current = dest[@intCast(i)];
        if ((curr_link & 0xff00) > 0 or
            (getLink(current) & IRRELEVANT) != 0)
        {
            nw = i + step;
            while (nx < 0) {
                if (nw == iend) {
                    next_link = 0;
                    nx = 3000;
                } else {
                    next_link = getLink(dest[@intCast(nw)]);
                    if ((next_link & IRRELEVANT) == 0) {
                        nx = nw;
                    } else {
                        nw += step;
                    }
                }
            }

            if ((curr_link & ALEFTYPE) > 0 and (last_link & LAMTYPE) > 0) {
                lamalef_found = true;
                const w_lamalef = changeLamAlef(dest[@intCast(i)]);
                if (w_lamalef != 0) {
                    dest[@intCast(i)] = LAMALEF_SPACE_SUB;
                    dest[@intCast(last_pos)] = w_lamalef;
                    i = last_pos;
                }
                last_link = prev_link;
                curr_link = getLink(w_lamalef);
            }

            if (i > 0 and dest[@intCast(i - 1)] == SPACE_CHAR) {
                if (isSeenFamilyChar(dest[@intCast(i)])) {
                    seenfam_found = true;
                } else if (dest[@intCast(i)] == YEH_HAMZA_CHAR) {
                    yehhamza_found = true;
                }
            } else if (i == 0) {
                if (isSeenFamilyChar(dest[0])) {
                    seenfam_found = true;
                } else if (dest[0] == YEH_HAMZA_CHAR) {
                    yehhamza_found = true;
                }
            }

            var shape: u16 = tables.shape_table[
                ((next_link & (LINKR | LINKL)) * 4 +
                    (last_link & (LINKR | LINKL))) * 4 +
                    (curr_link & (LINKR | LINKL))
            ];

            const shaped_char = dest[@intCast(i)];
            if ((curr_link & (LINKR | LINKL)) == 1) {
                shape &= 1;
            } else if (isTashkeelChar(shaped_char)) {
                if ((last_link & LINKL) != 0 and
                    (next_link & LINKR) != 0 and
                    tashkeel_flag == 1 and
                    shaped_char != 0x064c and shaped_char != 0x064d)
                {
                    shape = 1;
                    if ((next_link & ALEFTYPE) == ALEFTYPE and
                        (last_link & LAMTYPE) == LAMTYPE)
                    {
                        shape = 0;
                    }
                } else if (tashkeel_flag == 2 and
                    shaped_char == SHADDA06_CHAR)
                {
                    shape = 1;
                } else {
                    shape = 0;
                }
            }

            if ((shaped_char ^ 0x0600) < 0x100) {
                if (isTashkeelChar(shaped_char)) {
                    if (tashkeel_flag == 2 and shaped_char != SHADDA06_CHAR) {
                        dest[@intCast(i)] = TASHKEEL_SPACE_SUB;
                        tashkeel_found = true;
                    } else {
                        const position = irrelevantPosition(shaped_char);
                        dest[@intCast(i)] = 0xfe70 + position + shape;
                    }
                } else if ((curr_link & APRESENT) > 0) {
                    dest[@intCast(i)] = 0xfb50 + (curr_link >> 8) + shape;
                } else if ((curr_link >> 8) > 0 and
                    (curr_link & IRRELEVANT) == 0)
                {
                    dest[@intCast(i)] = 0xfe70 + (curr_link >> 8) + shape;
                }
            }
        }

        if ((curr_link & IRRELEVANT) == 0) {
            prev_link = last_link;
            last_link = curr_link;
            last_pos = i;
        }

        i += step;
        if (i == nx) {
            curr_link = next_link;
            nx = -2;
        } else if (i != iend) {
            curr_link = getLink(dest[@intCast(i)]);
        }
    }

    var dest_length = length;
    if (lamalef_found or tashkeel_found) {
        dest_length = handleGeneratedSpaces(dest[0..dest_length], options, shape_vars);
    }
    if (seenfam_found or yehhamza_found) {
        dest_length = try expandCompositChar(
            allocator,
            storage,
            dest_length,
            options,
            shape_vars,
            false,
        );
    }
    return dest_length;
}

fn irrelevantPosition(codepoint: u21) u21 {
    const index = codepoint - 0x064b;
    return @as(u21, index) * 2;
}

fn deShapeUnicode(
    allocator: std.mem.Allocator,
    storage: []u21,
    length: usize,
    options: Options,
    shape_vars: ShapeVariables,
) Error!usize {
    const buffer = storage[0..length];
    const yeh_hamza_compose = options.yeh_hamza_twocell_near;
    const seen_compose = options.seen_twocell_near;
    var lamalef_found = false;

    for (buffer, 0..) |*codepoint, index| {
        const input = codepoint.*;
        if (input >= 0xfb50 and input <= 0xfbff) {
            const converted = tables.convert_fb[input - 0xfb50];
            if (converted != 0) codepoint.* = converted;
        } else if (yeh_hamza_compose and
            (input == HAMZA06_CHAR or input == HAMZAFE_CHAR) and
            index + 1 < buffer.len and
            isAlefMaksouraChar(buffer[index + 1]))
        {
            codepoint.* = SPACE_CHAR;
            buffer[index + 1] = YEH_HAMZA_CHAR;
        } else if (seen_compose and isTailChar(input) and
            index + 1 < buffer.len and
            isSeenTailFamilyChar(buffer[index + 1]))
        {
            codepoint.* = SPACE_CHAR;
        } else if (input >= 0xfe70 and input <= 0xfef4) {
            codepoint.* = tables.convert_fe[input - 0xfe70];
        }
        if (isLamAlefChar(codepoint.*)) lamalef_found = true;
    }

    if (lamalef_found) {
        return expandCompositChar(allocator, storage, length, options, shape_vars, true);
    }
    return length;
}

fn calculateSize(source: []const u21, options: Options) usize {
    var size = source.len;
    const lam_alef_resize = options.lam_alef == .resize;
    const tashkeel_resize = options.tashkeel == .resize;
    const shaping = options.letters == .shape or
        options.letters == .shape_tashkeel_isolated;

    if (shaping and lam_alef_resize or
        (options.letters == .shape and tashkeel_resize))
    {
        if (options.text_direction == .visual_ltr) {
            for (source, 0..) |codepoint, index| {
                if ((isAlefChar(codepoint) and index + 1 < source.len and
                    source[index + 1] == LAM_CHAR) or
                    isTashkeelCharFe(codepoint))
                {
                    size -= 1;
                }
            }
        } else {
            for (source, 0..) |codepoint, index| {
                if ((codepoint == LAM_CHAR and index + 1 < source.len and
                    isAlefChar(source[index + 1])) or
                    isTashkeelCharFe(codepoint))
                {
                    size -= 1;
                }
            }
        }
    }

    if (options.letters == .unshape and lam_alef_resize) {
        for (source) |codepoint| {
            if (isLamAlefChar(codepoint)) size += 1;
        }
    }
    return size;
}

fn handleGeneratedSpaces(
    buffer: []u21,
    options: Options,
    shape_vars: ShapeVariables,
) usize {
    var length = buffer.len;

    const lam_resize = options.lam_alef == .resize;
    const tashkeel_resize = options.tashkeel == .resize;
    if (lam_resize or tashkeel_resize) {
        length = compactMarkers(buffer, lam_resize, tashkeel_resize);
    }

    if (options.lam_alef == .near) {
        replaceMarkers(buffer[0..length], true, false);
    }

    const lam_begin = options.lam_alef == shape_vars.lam_begin or
        (options.lam_alef == .auto and shape_vars.spaces_relative);
    const tashkeel_begin = options.tashkeel == shape_vars.tashkeel_begin;
    if (lam_begin or tashkeel_begin) {
        moveMarkersToBegin(buffer[0..length], lam_begin, tashkeel_begin);
    }

    const lam_end = options.lam_alef == shape_vars.lam_end or
        (options.lam_alef == .auto and !shape_vars.spaces_relative);
    const tashkeel_end = options.tashkeel == shape_vars.tashkeel_end;
    if (lam_end or tashkeel_end) {
        moveMarkersToEnd(buffer[0..length], lam_end, tashkeel_end);
    }
    return length;
}

fn compactMarkers(buffer: []u21, lam: bool, tashkeel: bool) usize {
    var write: usize = 0;
    for (buffer) |codepoint| {
        if ((lam and codepoint == LAMALEF_SPACE_SUB) or
            (tashkeel and codepoint == TASHKEEL_SPACE_SUB))
        {
            continue;
        }
        buffer[write] = codepoint;
        write += 1;
    }
    return write;
}

fn replaceMarkers(buffer: []u21, lam: bool, tashkeel: bool) void {
    for (buffer) |*codepoint| {
        if ((lam and codepoint.* == LAMALEF_SPACE_SUB) or
            (tashkeel and codepoint.* == TASHKEEL_SPACE_SUB))
        {
            codepoint.* = SPACE_CHAR;
        }
    }
}

fn moveMarkersToBegin(buffer: []u21, lam: bool, tashkeel: bool) void {
    var count: usize = 0;
    var write = buffer.len;
    var read = buffer.len;
    while (read > 0) {
        read -= 1;
        const codepoint = buffer[read];
        if ((lam and codepoint == LAMALEF_SPACE_SUB) or
            (tashkeel and codepoint == TASHKEEL_SPACE_SUB))
        {
            count += 1;
            continue;
        }
        write -= 1;
        buffer[write] = codepoint;
    }
    @memset(buffer[0..count], SPACE_CHAR);
}

fn moveMarkersToEnd(buffer: []u21, lam: bool, tashkeel: bool) void {
    var write: usize = 0;
    var count: usize = 0;
    for (buffer) |codepoint| {
        if ((lam and codepoint == LAMALEF_SPACE_SUB) or
            (tashkeel and codepoint == TASHKEEL_SPACE_SUB))
        {
            count += 1;
            continue;
        }
        buffer[write] = codepoint;
        write += 1;
    }
    @memset(buffer[write .. write + count], SPACE_CHAR);
}

fn expandCompositChar(
    allocator: std.mem.Allocator,
    storage: []u21,
    length: usize,
    options: Options,
    shape_vars: ShapeVariables,
    deshape: bool,
) Error!usize {
    if (deshape) {
        switch (options.lam_alef) {
            .auto => {
                if (!shape_vars.spaces_relative) {
                    expandAtEnd(allocator, storage[0..length]) catch |err| switch (err) {
                        error.NoSpaceAvailable => {
                            expandAtBegin(allocator, storage[0..length]) catch |begin_err| switch (begin_err) {
                                error.NoSpaceAvailable => {
                                    try expandAtNear(
                                        storage[0..length],
                                        false,
                                        false,
                                        true,
                                        shape_vars,
                                    );
                                },
                                else => return begin_err,
                            };
                        },
                        else => return err,
                    };
                } else {
                    expandAtBegin(allocator, storage[0..length]) catch |err| switch (err) {
                        error.NoSpaceAvailable => {
                            expandAtEnd(allocator, storage[0..length]) catch |end_err| switch (end_err) {
                                error.NoSpaceAvailable => {
                                    try expandAtNear(
                                        storage[0..length],
                                        false,
                                        false,
                                        true,
                                        shape_vars,
                                    );
                                },
                                else => return end_err,
                            };
                        },
                        else => return err,
                    };
                }
            },
            .end => try expandAtEnd(allocator, storage[0..length]),
            .begin => try expandAtBegin(allocator, storage[0..length]),
            .near => try expandAtNear(
                storage[0..length],
                false,
                false,
                true,
                shape_vars,
            ),
            .resize => return expandResize(storage, length),
        }
        return length;
    }

    if (options.yeh_hamza_twocell_near or options.seen_twocell_near) {
        try expandAtNear(
            storage[0..length],
            options.seen_twocell_near,
            options.yeh_hamza_twocell_near,
            false,
            shape_vars,
        );
    }
    return length;
}

fn expandResize(storage: []u21, length: usize) Error!usize {
    var count: usize = 0;
    for (storage[0..length]) |codepoint| {
        if (isLamAlefChar(codepoint)) count += 1;
    }
    if (count == 0) return length;
    const new_length = length + count;
    if (new_length > storage.len) return error.OutOfMemory;

    var read = length;
    var write = new_length;
    while (read > 0) {
        read -= 1;
        const codepoint = storage[read];
        if (isLamAlefChar(codepoint)) {
            write -= 1;
            storage[write] = LAM_CHAR;
            write -= 1;
            storage[write] = tables.convert_lam_alef[codepoint - 0xfef5];
        } else {
            write -= 1;
            storage[write] = codepoint;
        }
    }
    return new_length;
}

fn expandAtBegin(allocator: std.mem.Allocator, buffer: []u21) Error!void {
    var count_left: usize = 0;
    while (count_left < buffer.len and buffer[count_left] == SPACE_CHAR) {
        count_left += 1;
    }
    if (count_left == buffer.len) return;

    const temp = try allocator.alloc(u21, buffer.len);
    defer allocator.free(temp);
    @memset(temp, 0);

    var i: isize = @as(isize, @intCast(buffer.len)) - 1;
    var j: isize = i;
    while (i >= 0 and j >= 0) {
        const codepoint = buffer[@intCast(i)];
        if (count_left > 0 and isLamAlefChar(codepoint)) {
            temp[@intCast(j)] = LAM_CHAR;
            temp[@intCast(j - 1)] = tables.convert_lam_alef[codepoint - 0xfef5];
            j -= 1;
            count_left -= 1;
        } else {
            if (count_left == 0 and isLamAlefChar(codepoint)) {
                return error.NoSpaceAvailable;
            }
            temp[@intCast(j)] = codepoint;
        }
        i -= 1;
        j -= 1;
    }
    @memcpy(buffer, temp);
}

fn expandAtEnd(allocator: std.mem.Allocator, buffer: []u21) Error!void {
    var count_right: usize = 0;
    var input_size = buffer.len;
    while (input_size > 0 and buffer[input_size - 1] == SPACE_CHAR) {
        count_right += 1;
        input_size -= 1;
    }

    const temp = try allocator.alloc(u21, buffer.len);
    defer allocator.free(temp);
    @memset(temp, 0);

    var i: isize = @as(isize, @intCast(buffer.len - count_right)) - 1;
    var j: isize = @as(isize, @intCast(buffer.len)) - 1;
    while (i >= 0 and j >= 0) {
        const codepoint = buffer[@intCast(i)];
        if (count_right > 0 and isLamAlefChar(codepoint)) {
            temp[@intCast(j)] = LAM_CHAR;
            temp[@intCast(j - 1)] = tables.convert_lam_alef[codepoint - 0xfef5];
            j -= 1;
            count_right -= 1;
        } else {
            if (count_right == 0 and isLamAlefChar(codepoint)) {
                return error.NoSpaceAvailable;
            }
            temp[@intCast(j)] = codepoint;
        }
        i -= 1;
        j -= 1;
    }

    if (count_right > 0) {
        std.mem.copyForwards(
            u21,
            temp[0 .. buffer.len - count_right],
            temp[count_right..],
        );
        @memset(temp[buffer.len - count_right ..], SPACE_CHAR);
    }
    @memcpy(buffer, temp);
}

fn expandAtNear(
    buffer: []u21,
    seen_tail: bool,
    yeh_hamza: bool,
    lam_alef: bool,
    shape_vars: ShapeVariables,
) Error!void {
    var i: usize = 0;
    while (i < buffer.len) : (i += 1) {
        if (seen_tail and isSeenTailFamilyChar(buffer[i])) {
            if (i > 0 and buffer[i - 1] == SPACE_CHAR) {
                buffer[i - 1] = shape_vars.tail_char;
            } else {
                return error.NoSpaceAvailable;
            }
        } else if (yeh_hamza and isYehHamzaChar(buffer[i])) {
            if (i > 0 and buffer[i - 1] == SPACE_CHAR) {
                const converted = buffer[i];
                buffer[i] = tables.yeh_hamza_to_yeh[converted - 0xfe89];
                buffer[i - 1] = HAMZAFE_CHAR;
            } else {
                return error.NoSpaceAvailable;
            }
        } else if (lam_alef and i + 1 < buffer.len and
            isLamAlefChar(buffer[i + 1]))
        {
            if (buffer[i] == SPACE_CHAR) {
                const lamalef = buffer[i + 1];
                buffer[i + 1] = LAM_CHAR;
                buffer[i] = tables.convert_lam_alef[lamalef - 0xfef5];
            } else {
                return error.NoSpaceAvailable;
            }
        }
    }
}

fn handleTashkeelWithTatweel(buffer: []u21) usize {
    for (buffer) |*codepoint| {
        const on_tatweel = isTashkeelOnTatweelChar(codepoint.*);
        if (on_tatweel == 1) {
            codepoint.* = TATWEEL_CHAR;
        } else if (on_tatweel == 2) {
            codepoint.* = SHADDA_TATWEEL_CHAR;
        } else if (isIsolatedTashkeelChar(codepoint.*) != 0 and
            codepoint.* != SHADDA_CHAR)
        {
            codepoint.* = SPACE_CHAR;
        }
    }
    return buffer.len;
}

fn invertBufferSpaces(buffer: []u21) void {
    if (buffer.len == 0) return;
    var count_left: usize = 0;
    while (count_left < buffer.len and buffer[count_left] == SPACE_CHAR) {
        count_left += 1;
    }
    var count_right: usize = 0;
    if (count_left < buffer.len) {
        while (buffer[buffer.len - 1 - count_right] == SPACE_CHAR) {
            count_right += 1;
        }
    }
    var i = count_left;
    var j = buffer.len - count_right;
    while (i < j) {
        j -= 1;
        if (i >= j) break;
        const temp = buffer[i];
        buffer[i] = buffer[j];
        buffer[j] = temp;
        i += 1;
    }
}

fn shapeDigits(buffer: []u21, options: Options) Error!void {
    if (options.digits == .noop) return;
    const digit_base: u21 = switch (options.digit_type) {
        .an => 0x0660,
        .an_extended => 0x06f0,
    };
    switch (options.digits) {
        .en2an => {
            const offset = digit_base - 0x30;
            for (buffer) |*codepoint| {
                if (codepoint.* >= 0x30 and codepoint.* <= 0x39) {
                    codepoint.* += offset;
                }
            }
        },
        .an2en => {
            const offset = digit_base - 0x30;
            for (buffer) |*codepoint| {
                if (codepoint.* >= digit_base and
                    codepoint.* <= digit_base + 9)
                {
                    codepoint.* -= offset;
                }
            }
        },
        .alen2an_init_lr => try shapeDigitsWithContext(
            buffer,
            digit_base,
            options.text_direction == .logical,
            false,
        ),
        .alen2an_init_al => try shapeDigitsWithContext(
            buffer,
            digit_base,
            options.text_direction == .logical,
            true,
        ),
        .noop => unreachable,
    }
}

fn shapeDigitsWithContext(
    buffer: []u21,
    digit_base: u21,
    logical: bool,
    initial_al: bool,
) Error!void {
    var last_strong_was_al = initial_al;
    const offset = digit_base - 0x30;
    if (logical) {
        for (buffer) |*codepoint| {
            switch (bidi.classForCodepoint(codepoint.*)) {
                .l, .r => last_strong_was_al = false,
                .al => last_strong_was_al = true,
                .en => {
                    if (last_strong_was_al and
                        codepoint.* >= 0x30 and codepoint.* <= 0x39)
                    {
                        codepoint.* += offset;
                    }
                },
                else => {},
            }
        }
    } else {
        var index = buffer.len;
        while (index > 0) {
            index -= 1;
            const codepoint = &buffer[index];
            switch (bidi.classForCodepoint(codepoint.*)) {
                .l, .r => last_strong_was_al = false,
                .al => last_strong_was_al = true,
                .en => {
                    if (last_strong_was_al and
                        codepoint.* >= 0x30 and codepoint.* <= 0x39)
                    {
                        codepoint.* += offset;
                    }
                },
                else => {},
            }
        }
    }
}

test "shape and unshape Arabic letters" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const shaped = try shapeArabicAlloc(allocator, "سلام", .{ .letters = .shape });
    defer allocator.free(shaped);
    try testing.expectEqualStrings("ﺳﻼﻡ", shaped);

    const unshaped = try shapeArabicAlloc(allocator, "ﻻ", .{ .letters = .unshape });
    defer allocator.free(unshaped);
    try testing.expectEqualStrings("لا", unshaped);

    const word = try shapeArabicAlloc(
        allocator,
        "العربية",
        .{ .letters = .shape },
    );
    defer allocator.free(word);
    try testing.expectEqualStrings("ﺍﻟﻌﺮﺑﻴﺔ", word);
}

test "shape digits and preserve presentation forms" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const digits = try shapeArabicAlloc(
        allocator,
        "abc 123 سلام 456",
        .{ .digits = .en2an },
    );
    defer allocator.free(digits);
    try testing.expectEqualStrings("abc ١٢٣ سلام ٤٥٦", digits);

    const preserved = try shapeArabicAlloc(
        allocator,
        "ﺑ",
        .{ .letters = .shape, .preserve_presentation = true },
    );
    defer allocator.free(preserved);
    try testing.expectEqualStrings("ﺑ", preserved);
}

const conformance = @embedFile("conformance.bin");

test "ICU Arabic shaping conformance" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    try testing.expect(conformance.len >= 12);
    try testing.expectEqualSlices(u8, "CJSH", conformance[0..4]);
    try testing.expectEqual(@as(u8, 1), conformance[4]);
    const case_count = std.mem.readInt(u32, conformance[8..12], .little);
    var offset: usize = 12;
    var index: usize = 0;
    while (index < case_count) : (index += 1) {
        const raw = std.mem.readInt(u32, conformance[offset..][0..4], .little);
        const input_len = std.mem.readInt(
            u16,
            conformance[offset + 4 ..][0..2],
            .little,
        );
        const expected_len = std.mem.readInt(
            u16,
            conformance[offset + 6 ..][0..2],
            .little,
        );
        offset += 8;
        const input = conformance[offset..][0..input_len];
        offset += input_len;
        const expected = conformance[offset..][0..expected_len];
        offset += expected_len;

        const actual = try shapeArabicAlloc(
            allocator,
            input,
            Options.fromRaw(raw),
        );
        defer allocator.free(actual);
        testing.expectEqualStrings(expected, actual) catch |err| {
            std.debug.print(
                "shaping case {d} options=0x{x}\n",
                .{ index, raw },
            );
            return err;
        };
    }
    try testing.expectEqual(conformance.len, offset);
}
