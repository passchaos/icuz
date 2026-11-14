//! Allocation-free scalar cursor contract for fragmented immutable UTF-8.
//!
//! A cursor supplies `Error`, `next(*Cursor) Error!?Scalar`, `position() usize`,
//! `end() usize`, and `fork() Cursor`. A fork traverses the same immutable proof
//! with independent traversal state and chunk caches. Positions are UTF-8 byte
//! offsets in one fixed domain; null means its real end, never a chunk seam.
//! Segmentation starts at domain offset zero. A client can provide a smaller
//! domain only after proving that its start resets the Unicode boundary rules.

const scalar_value = @import("root.zig");

pub const Scalar = struct {
    codepoint: u21,
    byte_start: usize,
    byte_end: usize,
};

pub const ValidationError = error{InvalidScalarCursor};

/// Internal checked adapter. Bounds checks do not inspect or copy source bytes;
/// decoding and immutable-source/staleness checks belong to the supplied cursor.
pub fn Reader(comptime Cursor: type) type {
    return struct {
        const Self = @This();
        pub const Error = Cursor.Error || ValidationError;

        cursor: Cursor,
        offset: usize,
        domain_end: usize,

        pub fn init(cursor: Cursor) Error!Self {
            if (cursor.position() != 0) return error.InvalidScalarCursor;
            return .{ .cursor = cursor, .offset = 0, .domain_end = cursor.end() };
        }

        pub fn fork(self: Self) Error!Self {
            const cursor = self.cursor.fork();
            if (cursor.position() != self.offset or cursor.end() != self.domain_end)
                return error.InvalidScalarCursor;
            return .{ .cursor = cursor, .offset = self.offset, .domain_end = self.domain_end };
        }

        pub fn next(self: *Self) Error!?Scalar {
            if (self.cursor.position() != self.offset or self.cursor.end() != self.domain_end)
                return error.InvalidScalarCursor;
            const decoded = try self.cursor.next();
            if (self.cursor.end() != self.domain_end) return error.InvalidScalarCursor;
            const scalar = decoded orelse {
                if (self.offset != self.domain_end or self.cursor.position() != self.offset)
                    return error.InvalidScalarCursor;
                return null;
            };
            if (!scalar_value.isValid(scalar.codepoint) or
                scalar.byte_start != self.offset or scalar.byte_end <= scalar.byte_start or
                scalar.byte_end > self.domain_end or self.cursor.position() != scalar.byte_end)
                return error.InvalidScalarCursor;
            const encoded_len: usize = if (scalar.codepoint < 0x80) 1 else if (scalar.codepoint < 0x800) 2 else if (scalar.codepoint < 0x10000) 3 else 4;
            if (scalar.byte_end - scalar.byte_start != encoded_len)
                return error.InvalidScalarCursor;
            self.offset = scalar.byte_end;
            return .{ .codepoint = scalar.codepoint, .byte_start = scalar.byte_start, .byte_end = scalar.byte_end };
        }
    };
}

test "scalar cursor rejects malformed scalar bounds lengths ordering and premature EOF" {
    const std = @import("std");
    const FaultCursor = struct {
        const Self = @This();
        pub const Error = error{SourceFailure};
        scalar: ?Scalar,
        offset: usize = 0,
        domain_end: usize = 4,
        bad_position: bool = false,
        changed_end: bool = false,
        bad_fork: bool = false,

        pub fn position(self: Self) usize {
            return self.offset;
        }
        pub fn end(self: Self) usize {
            return self.domain_end;
        }
        pub fn fork(self: Self) Self {
            var result = self;
            if (self.bad_fork) result.offset += 1;
            return result;
        }
        pub fn next(self: *Self) Error!?Scalar {
            const result = self.scalar;
            self.scalar = null;
            if (result) |scalar| {
                if (!self.bad_position) self.offset = scalar.byte_end;
            }
            if (self.changed_end) self.domain_end += 1;
            return result;
        }
    };
    const invalid = [_]FaultCursor{
        .{ .scalar = null },
        .{ .scalar = .{ .codepoint = 0xd800, .byte_start = 0, .byte_end = 3 } },
        .{ .scalar = .{ .codepoint = 0x110000, .byte_start = 0, .byte_end = 4 } },
        .{ .scalar = .{ .codepoint = 'a', .byte_start = 0, .byte_end = 2 } },
        .{ .scalar = .{ .codepoint = 'a', .byte_start = 1, .byte_end = 2 } },
        .{ .scalar = .{ .codepoint = 'a', .byte_start = 0, .byte_end = 0 } },
        .{ .scalar = .{ .codepoint = 'a', .byte_start = 0, .byte_end = 5 } },
        .{ .scalar = .{ .codepoint = 'a', .byte_start = 0, .byte_end = 1 }, .bad_position = true },
        .{ .scalar = .{ .codepoint = 'a', .byte_start = 0, .byte_end = 1 }, .changed_end = true },
    };
    for (invalid) |cursor| {
        var reader = try Reader(FaultCursor).init(cursor);
        try std.testing.expectError(error.InvalidScalarCursor, reader.next());
    }
    try std.testing.expectError(error.InvalidScalarCursor, Reader(FaultCursor).init(.{ .scalar = null, .offset = 1 }));
    const bad_fork = try Reader(FaultCursor).init(.{ .scalar = null, .bad_fork = true });
    try std.testing.expectError(error.InvalidScalarCursor, bad_fork.fork());

    var reader = try Reader(FaultCursor).init(.{ .scalar = .{ .codepoint = 'a', .byte_start = 0, .byte_end = 1 }, .domain_end = 1 });
    try std.testing.expectEqualDeep(Scalar{ .codepoint = 'a', .byte_start = 0, .byte_end = 1 }, (try reader.next()).?);
    try std.testing.expectEqual(null, try reader.next());
    reader.cursor.scalar = .{ .codepoint = 'b', .byte_start = 1, .byte_end = 2 };
    try std.testing.expectError(error.InvalidScalarCursor, reader.next());

    reader = try Reader(FaultCursor).init(.{ .scalar = .{ .codepoint = 'a', .byte_start = 0, .byte_end = 1 } });
    _ = try reader.next();
    reader.cursor.scalar = .{ .codepoint = 'b', .byte_start = 0, .byte_end = 1 };
    try std.testing.expectError(error.InvalidScalarCursor, reader.next());
}
