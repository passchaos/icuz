//! Charset error handling and shared UTF vector helpers.

const std = @import("std");
const types = @import("types.zig");
const Options = types.Options;
const blocks = @import("../utf/blocks.zig");

pub const threeByteLane = blocks.threeByteLane;
pub const decodeThreeByteBlock = blocks.decodeThreeByteBlock;
pub const pairLanes = blocks.pairLanes;
pub const tripleLanes = blocks.tripleLanes;
pub const bmpThreeByteLanes = blocks.bmpThreeByteLanes;
pub const storeThreeByteScalars = blocks.storeThreeByteScalars;
pub const writeScalar = blocks.writeScalar;

/// Apply the configured error mode for one malformed or incomplete unit.
/// Returns true when the caller must fail with `error.InvalidSequence`.
pub inline fn writeError(
    options: Options,
    spare: []u8,
    written: *usize,
    replacement: []const u8,
) bool {
    switch (options.on_error) {
        .strict => return true,
        .ignore => {},
        .replace => {
            @memcpy(spare[written.*..][0..replacement.len], replacement);
            written.* += replacement.len;
        },
    }
    return false;
}
