//! Shared result types for charset decoders and encoders.

pub const DecodeResult = union(enum) {
    /// A decoded Unicode scalar value. The decoder consumed the bytes.
    codepoint: u21,
    /// The sequence is malformed; `malformed` is the number of bytes the
    /// decoder consumed. The caller decides whether to substitute or fail.
    malformed: u8,
    /// The buffer ends in the middle of a sequence. No bytes were consumed.
    incomplete,
    /// The input has been fully consumed.
    end,
};

pub const EncodeResult = union(enum) {
    /// Number of bytes written to the output buffer.
    written: u8,
    /// The code point cannot be represented in the target encoding.
    unmappable,
};

pub const ErrorMode = enum {
    /// Return `error.InvalidSequence` or `error.UnmappableCharacter`.
    strict,
    /// Substitute the replacement code point (U+FFFD by default).
    replace,
    /// Drop invalid input and continue.
    ignore,
};

pub const Options = struct {
    on_error: ErrorMode = .replace,
    replacement: u21 = 0xFFFD,
};

pub const Error = error{
    OutOfMemory,
    InvalidSequence,
    UnmappableCharacter,
    InvalidCodepoint,
};
