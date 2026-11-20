//! Edit tracking for case mappings, mirroring ICU's `Edits`.
//!
//! Case mapping APIs that accept an `Edits` record which source spans were
//! copied unchanged and which were replaced, so editors and input methods can
//! map cursor positions between the source and destination text.

const std = @import("std");

pub const Edit = struct {
    /// Source byte offset where this edit starts.
    source_index: usize,
    /// Destination byte offset where this edit starts.
    destination_index: usize,
    old_length: usize,
    new_length: usize,
    /// True for a replaced span; false for an unchanged span.
    replacement: bool,
};

pub const Edits = struct {
    allocator: std.mem.Allocator,
    edits: std.ArrayList(Edit) = .empty,
    source_length: usize = 0,
    destination_length: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Edits {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Edits) void {
        self.edits.deinit(self.allocator);
    }

    /// Discard all edits while keeping the allocation.
    pub fn clearRetainingCapacity(self: *Edits) void {
        self.edits.clearRetainingCapacity();
        self.source_length = 0;
        self.destination_length = 0;
    }

    /// Record that `old_length` source bytes at `source_index` were copied
    /// unchanged. Gaps before `source_index` are recorded as unchanged too.
    pub fn addUnchanged(
        self: *Edits,
        source_index: usize,
        old_length: usize,
    ) error{OutOfMemory}!void {
        if (source_index > self.source_length) {
            try self.appendUnchanged(source_index - self.source_length);
        }
        if (old_length == 0) return;
        try self.appendUnchanged(old_length);
    }

    /// Record that the next `old_length` source bytes were replaced by
    /// `new_length` destination bytes.
    pub fn addReplace(
        self: *Edits,
        old_length: usize,
        new_length: usize,
    ) error{OutOfMemory}!void {
        if (old_length == 0 and new_length == 0) return;
        try self.edits.append(self.allocator, .{
            .source_index = self.source_length,
            .destination_index = self.destination_length,
            .old_length = old_length,
            .new_length = new_length,
            .replacement = true,
        });
        self.source_length += old_length;
        self.destination_length += new_length;
    }

    /// Map a source byte index to the destination byte index.
    ///
    /// Positions inside a replaced span map to the start of its replacement;
    /// the position at the end maps to the end of the replacement.
    pub fn mapIndex(self: *const Edits, source_index: usize) usize {
        if (self.edits.items.len == 0) return source_index;
        var low: usize = 0;
        var high: usize = self.edits.items.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (self.edits.items[middle].source_index <= source_index) {
                low = middle + 1;
            } else {
                high = middle;
            }
        }
        if (low == 0) return source_index;
        const edit = self.edits.items[low - 1];
        if (source_index >= edit.source_index + edit.old_length) {
            return edit.destination_index + edit.new_length;
        }
        if (edit.replacement) return edit.destination_index;
        return edit.destination_index + (source_index - edit.source_index);
    }

    /// Map a destination byte index back to the source byte index.
    pub fn sourceIndexFromDestination(
        self: *const Edits,
        destination_index: usize,
    ) usize {
        if (self.edits.items.len == 0) return destination_index;
        var low: usize = 0;
        var high: usize = self.edits.items.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (self.edits.items[middle].destination_index <= destination_index) {
                low = middle + 1;
            } else {
                high = middle;
            }
        }
        if (low == 0) return destination_index;
        const edit = self.edits.items[low - 1];
        if (destination_index >= edit.destination_index + edit.new_length) {
            return edit.source_index + edit.old_length;
        }
        if (edit.replacement) return edit.source_index;
        return edit.source_index + (destination_index - edit.destination_index);
    }

    pub fn hasChanges(self: *const Edits) bool {
        for (self.edits.items) |edit| {
            if (edit.replacement) return true;
        }
        return false;
    }

    pub fn changeCount(self: *const Edits) usize {
        var count: usize = 0;
        for (self.edits.items) |edit| {
            if (edit.replacement) count += 1;
        }
        return count;
    }

    /// The `index`-th replaced span, in source order.
    pub fn changeAt(self: *const Edits, index: usize) ?Edit {
        var seen: usize = 0;
        for (self.edits.items) |edit| {
            if (!edit.replacement) continue;
            if (seen == index) return edit;
            seen += 1;
        }
        return null;
    }

    pub fn sourceLength(self: *const Edits) usize {
        return self.source_length;
    }

    pub fn destinationLength(self: *const Edits) usize {
        return self.destination_length;
    }

    fn appendUnchanged(self: *Edits, length: usize) error{OutOfMemory}!void {
        if (length == 0) return;
        if (self.edits.items.len != 0) {
            const last = &self.edits.items[self.edits.items.len - 1];
            if (!last.replacement) {
                last.old_length += length;
                last.new_length += length;
                self.source_length += length;
                self.destination_length += length;
                return;
            }
        }
        try self.edits.append(self.allocator, .{
            .source_index = self.source_length,
            .destination_index = self.destination_length,
            .old_length = length,
            .new_length = length,
            .replacement = false,
        });
        self.source_length += length;
        self.destination_length += length;
    }
};

test "edits merge unchanged spans and map indices" {
    const testing = @import("std").testing;
    var edits = Edits.init(testing.allocator);
    defer edits.deinit();

    try edits.addUnchanged(0, 2);
    try edits.addReplace(1, 2);
    try edits.addUnchanged(3, 2);

    try testing.expect(edits.hasChanges());
    try testing.expectEqual(@as(usize, 1), edits.changeCount());
    try testing.expectEqual(@as(usize, 5), edits.sourceLength());
    try testing.expectEqual(@as(usize, 6), edits.destinationLength());
    try testing.expectEqual(@as(usize, 0), edits.mapIndex(0));
    try testing.expectEqual(@as(usize, 2), edits.mapIndex(2));
    try testing.expectEqual(@as(usize, 4), edits.mapIndex(3));
    try testing.expectEqual(@as(usize, 5), edits.mapIndex(4));
    try testing.expectEqual(@as(usize, 6), edits.mapIndex(5));
    try testing.expectEqual(@as(usize, 2), edits.sourceIndexFromDestination(2));
    try testing.expectEqual(@as(usize, 2), edits.sourceIndexFromDestination(3));
    try testing.expectEqual(@as(usize, 3), edits.sourceIndexFromDestination(4));
    try testing.expectEqual(@as(usize, 5), edits.sourceIndexFromDestination(6));
}

test "edits record gaps as unchanged" {
    const testing = @import("std").testing;
    var edits = Edits.init(testing.allocator);
    defer edits.deinit();

    try edits.addUnchanged(3, 1);
    try testing.expectEqual(@as(usize, 4), edits.sourceLength());
    try testing.expect(!edits.hasChanges());
    try testing.expectEqual(@as(usize, 2), edits.mapIndex(2));
    try testing.expectEqual(@as(usize, 4), edits.mapIndex(4));
}
