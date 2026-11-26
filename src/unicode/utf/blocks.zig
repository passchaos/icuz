//! Shared UTF-8/16/32 vector kernels.
const decode = @import("decode_blocks.zig");
const encode = @import("encode_blocks.zig");
pub const threeByteLane = decode.threeByteLane;
pub const decodeThreeByteBlock = decode.decodeThreeByteBlock;
pub const decode2 = decode.decode2;
pub const decode3 = decode.decode3;
pub const decode4 = decode.decode4;
pub const pairLanes = encode.pairLanes;
pub const tripleLanes = encode.tripleLanes;
pub const bmpThreeByteLanes = encode.bmpThreeByteLanes;
pub const storeThreeByteScalars = encode.storeThreeByteScalars;
pub const writeScalar = encode.writeScalar;
pub const encode2 = encode.encode2;
pub const encode3 = encode.encode3;
pub const encode4 = encode.encode4;
pub const writeSurrogatePair = encode.writeSurrogatePair;
