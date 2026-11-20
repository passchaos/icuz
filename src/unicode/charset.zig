//! Charset conversion: UTF-8/16/32, ASCII, Latin-1, legacy single-byte
//! encodings, and the WHATWG East Asian multi-byte encodings.
//!
//! Labels are matched case-insensitively with punctuation removed. For the
//! historically ambiguous labels this module follows ICU rather than the
//! WHATWG Encoding Standard: `ascii` selects strict US-ASCII and `latin1`
//! (with `iso-8859-1`) selects ISO-8859-1, while the WHATWG standard maps both
//! labels to windows-1252.
//!
//! Decoders consume one scalar value at a time and report malformed or
//! incomplete input without guessing. The allocation helpers apply an
//! [`ErrorMode`] so callers can fail, substitute, or skip invalid input.

const std = @import("std");
const types = @import("charset/types.zig");
const tables = @import("charset/tables.zig");
const cjk = @import("charset/cjk.zig");
const iso2022jp = @import("charset/iso2022jp.zig");
const utf7 = @import("charset/utf7.zig");
const hz = @import("charset/hz.zig");
const scsu = @import("charset/scsu.zig");
const bocu1 = @import("charset/bocu1.zig");

pub const DecodeResult = types.DecodeResult;
pub const EncodeResult = types.EncodeResult;

pub const Encoding = enum {
    utf8,
    utf16_le,
    utf16_be,
    utf32_le,
    utf32_be,
    utf7,
    hz,
    scsu,
    bocu1,
    ascii,
    latin1,
    ibm866,
    iso_8859_2,
    iso_8859_3,
    iso_8859_4,
    iso_8859_5,
    iso_8859_6,
    iso_8859_7,
    iso_8859_8,
    iso_8859_8_i,
    iso_8859_10,
    iso_8859_13,
    iso_8859_14,
    iso_8859_15,
    iso_8859_16,
    koi8_r,
    koi8_u,
    macintosh,
    windows_874,
    windows_1250,
    windows_1251,
    windows_1252,
    windows_1253,
    windows_1254,
    windows_1255,
    windows_1256,
    windows_1257,
    windows_1258,
    x_mac_cyrillic,
    ibm_437,
    ibm_850,
    ibm_852,
    ibm_855,
    ibm_857,
    ibm_858,
    ibm_860,
    ibm_861,
    ibm_862,
    ibm_863,
    ibm_864,
    ibm_865,
    ibm_869,
    ibm_1026,
    ibm_1047,
    ibm_1140,
    ibm_1141,
    ibm_1142,
    ibm_1143,
    ibm_1144,
    ibm_1145,
    ibm_1146,
    ibm_1147,
    ibm_1148,
    ibm_1149,
    ibm_1160,
    ibm_1162,
    ibm_1164,
    gbk,
    gb18030,
    big5,
    euc_jp,
    iso_2022_jp,
    shift_jis,
    euc_kr,
    x_user_defined,
    replacement,
};

/// Canonical ICU-style converter name.
pub fn encodingName(encoding: Encoding) []const u8 {
    if (ibmPageIndex(encoding)) |index| {
        return tables.ibmPageName(index) orelse "IBM";
    }
    return switch (encoding) {
        .utf8 => "UTF-8",
        .utf16_le => "UTF-16LE",
        .utf16_be => "UTF-16BE",
        .utf32_le => "UTF-32LE",
        .utf32_be => "UTF-32BE",
        .utf7 => "UTF-7",
        .hz => "HZ",
        .scsu => "SCSU",
        .bocu1 => "BOCU-1",
        .ascii => "US-ASCII",
        .latin1 => "ISO-8859-1",
        .ibm866 => "IBM866",
        .iso_8859_2 => "ISO-8859-2",
        .iso_8859_3 => "ISO-8859-3",
        .iso_8859_4 => "ISO-8859-4",
        .iso_8859_5 => "ISO-8859-5",
        .iso_8859_6 => "ISO-8859-6",
        .iso_8859_7 => "ISO-8859-7",
        .iso_8859_8 => "ISO-8859-8",
        .iso_8859_8_i => "ISO-8859-8-I",
        .iso_8859_10 => "ISO-8859-10",
        .iso_8859_13 => "ISO-8859-13",
        .iso_8859_14 => "ISO-8859-14",
        .iso_8859_15 => "ISO-8859-15",
        .iso_8859_16 => "ISO-8859-16",
        .koi8_r => "KOI8-R",
        .koi8_u => "KOI8-U",
        .macintosh => "macintosh",
        .windows_874 => "windows-874",
        .windows_1250 => "windows-1250",
        .windows_1251 => "windows-1251",
        .windows_1252 => "windows-1252",
        .windows_1253 => "windows-1253",
        .windows_1254 => "windows-1254",
        .windows_1255 => "windows-1255",
        .windows_1256 => "windows-1256",
        .windows_1257 => "windows-1257",
        .windows_1258 => "windows-1258",
        .x_mac_cyrillic => "x-mac-cyrillic",
        .gbk => "GBK",
        .gb18030 => "GB18030",
        .big5 => "Big5",
        .euc_jp => "EUC-JP",
        .iso_2022_jp => "ISO-2022-JP",
        .shift_jis => "Shift_JIS",
        .euc_kr => "EUC-KR",
        .x_user_defined => "x-user-defined",
        .replacement => "replacement",
        else => unreachable,
    };
}

/// Maximum bytes a converter emits for one code point (ICU
/// `ucnv_getMaxCharSize`).
pub fn maxCharSize(encoding: Encoding) u8 {
    if (ibmPageIndex(encoding) != null) return 1;
    return switch (encoding) {
        .utf8, .utf16_le, .utf16_be, .utf32_le, .utf32_be => 4,
        .ascii, .latin1, .ibm866, .iso_8859_2, .iso_8859_3, .iso_8859_4,
        .iso_8859_5, .iso_8859_6, .iso_8859_7, .iso_8859_8, .iso_8859_8_i,
        .iso_8859_10, .iso_8859_13, .iso_8859_14, .iso_8859_15,
        .iso_8859_16, .koi8_r, .koi8_u, .macintosh, .windows_874,
        .windows_1250, .windows_1251, .windows_1252, .windows_1253,
        .windows_1254, .windows_1255, .windows_1256, .windows_1257,
        .windows_1258, .x_mac_cyrillic, .replacement => 1,
        .big5, .shift_jis, .euc_kr => 2,
        .euc_jp => 3,
        .gbk, .gb18030, .x_user_defined => 4,
        .utf7, .iso_2022_jp => 8,
        .hz => 4,
        .scsu => 6,
        .bocu1 => 4,
        else => unreachable,
    };
}

/// Minimum bytes a converter emits for one code point.
pub fn minCharSize(encoding: Encoding) u8 {
    return switch (encoding) {
        .utf16_le, .utf16_be => 2,
        .utf32_le, .utf32_be => 4,
        else => 1,
    };
}

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

const Alias = struct {
    name: []const u8,
    encoding: Encoding,
};

// Labels are normalized to lowercase alphanumerics before lookup.
const base_aliases = [_]Alias{
    .{ .name = "utf8", .encoding = .utf8 },
    .{ .name = "unicode11utf8", .encoding = .utf8 },
    .{ .name = "unicode20utf8", .encoding = .utf8 },
    .{ .name = "xunicode20utf8", .encoding = .utf8 },

    .{ .name = "utf16", .encoding = .utf16_le },
    .{ .name = "utf16le", .encoding = .utf16_le },
    .{ .name = "csunicode", .encoding = .utf16_le },
    .{ .name = "iso10646ucs2", .encoding = .utf16_le },
    .{ .name = "ucs2", .encoding = .utf16_le },
    .{ .name = "unicode", .encoding = .utf16_le },
    .{ .name = "unicodefeff", .encoding = .utf16_le },
    .{ .name = "utf16be", .encoding = .utf16_be },
    .{ .name = "unicodefffe", .encoding = .utf16_be },
    .{ .name = "utf32le", .encoding = .utf32_le },
    .{ .name = "utf32be", .encoding = .utf32_be },
    .{ .name = "utf7", .encoding = .utf7 },
    .{ .name = "unicode11utf7", .encoding = .utf7 },
    .{ .name = "csunicode11utf7", .encoding = .utf7 },
    .{ .name = "hz", .encoding = .hz },
    .{ .name = "hzgb2312", .encoding = .hz },
    .{ .name = "scsu", .encoding = .scsu },
    .{ .name = "bocu1", .encoding = .bocu1 },

    .{ .name = "ascii", .encoding = .ascii },
    .{ .name = "usascii", .encoding = .ascii },
    .{ .name = "ansix341968", .encoding = .ascii },
    .{ .name = "iso646us", .encoding = .ascii },
    .{ .name = "us", .encoding = .ascii },
    .{ .name = "iso646", .encoding = .ascii },
    .{ .name = "cp367", .encoding = .ascii },
    .{ .name = "ibm367", .encoding = .ascii },
    .{ .name = "csascii", .encoding = .ascii },
    .{ .name = "latin1", .encoding = .latin1 },
    .{ .name = "iso88591", .encoding = .latin1 },
    .{ .name = "iso885911987", .encoding = .latin1 },
    .{ .name = "l1", .encoding = .latin1 },
    .{ .name = "cp819", .encoding = .latin1 },
    .{ .name = "ibm819", .encoding = .latin1 },
    .{ .name = "csisolatin1", .encoding = .latin1 },
    .{ .name = "isoir100", .encoding = .latin1 },

    .{ .name = "ibm866", .encoding = .ibm866 },
    .{ .name = "866", .encoding = .ibm866 },
    .{ .name = "cp866", .encoding = .ibm866 },
    .{ .name = "csibm866", .encoding = .ibm866 },

    .{ .name = "iso88592", .encoding = .iso_8859_2 },
    .{ .name = "iso885921987", .encoding = .iso_8859_2 },
    .{ .name = "latin2", .encoding = .iso_8859_2 },
    .{ .name = "l2", .encoding = .iso_8859_2 },
    .{ .name = "csisolatin2", .encoding = .iso_8859_2 },
    .{ .name = "isoir101", .encoding = .iso_8859_2 },
    .{ .name = "iso88593", .encoding = .iso_8859_3 },
    .{ .name = "iso885931988", .encoding = .iso_8859_3 },
    .{ .name = "latin3", .encoding = .iso_8859_3 },
    .{ .name = "l3", .encoding = .iso_8859_3 },
    .{ .name = "csisolatin3", .encoding = .iso_8859_3 },
    .{ .name = "isoir109", .encoding = .iso_8859_3 },
    .{ .name = "iso88594", .encoding = .iso_8859_4 },
    .{ .name = "iso885941988", .encoding = .iso_8859_4 },
    .{ .name = "latin4", .encoding = .iso_8859_4 },
    .{ .name = "l4", .encoding = .iso_8859_4 },
    .{ .name = "csisolatin4", .encoding = .iso_8859_4 },
    .{ .name = "isoir110", .encoding = .iso_8859_4 },
    .{ .name = "iso88595", .encoding = .iso_8859_5 },
    .{ .name = "iso885951988", .encoding = .iso_8859_5 },
    .{ .name = "cyrillic", .encoding = .iso_8859_5 },
    .{ .name = "csisolatincyrillic", .encoding = .iso_8859_5 },
    .{ .name = "isoir144", .encoding = .iso_8859_5 },
    .{ .name = "iso88596", .encoding = .iso_8859_6 },
    .{ .name = "iso885961987", .encoding = .iso_8859_6 },
    .{ .name = "iso88596e", .encoding = .iso_8859_6 },
    .{ .name = "iso88596i", .encoding = .iso_8859_6 },
    .{ .name = "arabic", .encoding = .iso_8859_6 },
    .{ .name = "asmo708", .encoding = .iso_8859_6 },
    .{ .name = "csiso88596e", .encoding = .iso_8859_6 },
    .{ .name = "csiso88596i", .encoding = .iso_8859_6 },
    .{ .name = "csisolatinarabic", .encoding = .iso_8859_6 },
    .{ .name = "ecma114", .encoding = .iso_8859_6 },
    .{ .name = "isoir127", .encoding = .iso_8859_6 },
    .{ .name = "iso88597", .encoding = .iso_8859_7 },
    .{ .name = "iso885971987", .encoding = .iso_8859_7 },
    .{ .name = "greek", .encoding = .iso_8859_7 },
    .{ .name = "greek8", .encoding = .iso_8859_7 },
    .{ .name = "ecma118", .encoding = .iso_8859_7 },
    .{ .name = "elot928", .encoding = .iso_8859_7 },
    .{ .name = "csisolatingreek", .encoding = .iso_8859_7 },
    .{ .name = "isoir126", .encoding = .iso_8859_7 },
    .{ .name = "suneugreek", .encoding = .iso_8859_7 },
    .{ .name = "iso88598", .encoding = .iso_8859_8 },
    .{ .name = "iso885981988", .encoding = .iso_8859_8 },
    .{ .name = "iso88598e", .encoding = .iso_8859_8 },
    .{ .name = "hebrew", .encoding = .iso_8859_8 },
    .{ .name = "csiso88598e", .encoding = .iso_8859_8 },
    .{ .name = "csisolatinhebrew", .encoding = .iso_8859_8 },
    .{ .name = "isoir138", .encoding = .iso_8859_8 },
    .{ .name = "visual", .encoding = .iso_8859_8 },
    .{ .name = "iso88598i", .encoding = .iso_8859_8_i },
    .{ .name = "csiso88598i", .encoding = .iso_8859_8_i },
    .{ .name = "logical", .encoding = .iso_8859_8_i },
    .{ .name = "iso885910", .encoding = .iso_8859_10 },
    .{ .name = "latin6", .encoding = .iso_8859_10 },
    .{ .name = "l6", .encoding = .iso_8859_10 },
    .{ .name = "csisolatin6", .encoding = .iso_8859_10 },
    .{ .name = "isoir157", .encoding = .iso_8859_10 },
    .{ .name = "iso885913", .encoding = .iso_8859_13 },
    .{ .name = "latin7", .encoding = .iso_8859_13 },
    .{ .name = "l7", .encoding = .iso_8859_13 },
    .{ .name = "iso885914", .encoding = .iso_8859_14 },
    .{ .name = "latin8", .encoding = .iso_8859_14 },
    .{ .name = "l8", .encoding = .iso_8859_14 },
    .{ .name = "csisolatin8", .encoding = .iso_8859_14 },
    .{ .name = "isoceltic", .encoding = .iso_8859_14 },
    .{ .name = "isoir199", .encoding = .iso_8859_14 },
    .{ .name = "iso885915", .encoding = .iso_8859_15 },
    .{ .name = "latin9", .encoding = .iso_8859_15 },
    .{ .name = "l9", .encoding = .iso_8859_15 },
    .{ .name = "csisolatin9", .encoding = .iso_8859_15 },
    .{ .name = "iso885916", .encoding = .iso_8859_16 },
    .{ .name = "latin10", .encoding = .iso_8859_16 },
    .{ .name = "l10", .encoding = .iso_8859_16 },

    .{ .name = "koi8r", .encoding = .koi8_r },
    .{ .name = "koi8", .encoding = .koi8_r },
    .{ .name = "koi", .encoding = .koi8_r },
    .{ .name = "cskoi8r", .encoding = .koi8_r },
    .{ .name = "koi8u", .encoding = .koi8_u },
    .{ .name = "koi8ru", .encoding = .koi8_u },
    .{ .name = "macintosh", .encoding = .macintosh },
    .{ .name = "mac", .encoding = .macintosh },
    .{ .name = "csmacintosh", .encoding = .macintosh },
    .{ .name = "macroman", .encoding = .macintosh },
    .{ .name = "xmacroman", .encoding = .macintosh },
    .{ .name = "windows874", .encoding = .windows_874 },
    .{ .name = "dos874", .encoding = .windows_874 },
    .{ .name = "iso885911", .encoding = .windows_874 },
    .{ .name = "tis620", .encoding = .windows_874 },
    .{ .name = "cp874", .encoding = .windows_874 },
    .{ .name = "win874", .encoding = .windows_874 },
    .{ .name = "windows1250", .encoding = .windows_1250 },
    .{ .name = "cp1250", .encoding = .windows_1250 },
    .{ .name = "xcp1250", .encoding = .windows_1250 },
    .{ .name = "win1250", .encoding = .windows_1250 },
    .{ .name = "windows1251", .encoding = .windows_1251 },
    .{ .name = "cp1251", .encoding = .windows_1251 },
    .{ .name = "xcp1251", .encoding = .windows_1251 },
    .{ .name = "win1251", .encoding = .windows_1251 },
    .{ .name = "windows1252", .encoding = .windows_1252 },
    .{ .name = "cp1252", .encoding = .windows_1252 },
    .{ .name = "xcp1252", .encoding = .windows_1252 },
    .{ .name = "win1252", .encoding = .windows_1252 },
    .{ .name = "windows1253", .encoding = .windows_1253 },
    .{ .name = "cp1253", .encoding = .windows_1253 },
    .{ .name = "xcp1253", .encoding = .windows_1253 },
    .{ .name = "windows1254", .encoding = .windows_1254 },
    .{ .name = "cp1254", .encoding = .windows_1254 },
    .{ .name = "xcp1254", .encoding = .windows_1254 },
    .{ .name = "iso88599", .encoding = .windows_1254 },
    .{ .name = "iso885991989", .encoding = .windows_1254 },
    .{ .name = "latin5", .encoding = .windows_1254 },
    .{ .name = "l5", .encoding = .windows_1254 },
    .{ .name = "csisolatin5", .encoding = .windows_1254 },
    .{ .name = "isoir148", .encoding = .windows_1254 },
    .{ .name = "windows1255", .encoding = .windows_1255 },
    .{ .name = "cp1255", .encoding = .windows_1255 },
    .{ .name = "xcp1255", .encoding = .windows_1255 },
    .{ .name = "windows1256", .encoding = .windows_1256 },
    .{ .name = "cp1256", .encoding = .windows_1256 },
    .{ .name = "xcp1256", .encoding = .windows_1256 },
    .{ .name = "windows1257", .encoding = .windows_1257 },
    .{ .name = "cp1257", .encoding = .windows_1257 },
    .{ .name = "xcp1257", .encoding = .windows_1257 },
    .{ .name = "windows1258", .encoding = .windows_1258 },
    .{ .name = "cp1258", .encoding = .windows_1258 },
    .{ .name = "xcp1258", .encoding = .windows_1258 },
    .{ .name = "xmaccyrillic", .encoding = .x_mac_cyrillic },
    .{ .name = "xmacukrainian", .encoding = .x_mac_cyrillic },

    .{ .name = "gbk", .encoding = .gbk },
    .{ .name = "gb2312", .encoding = .gbk },
    .{ .name = "gb231280", .encoding = .gbk },
    .{ .name = "chinese", .encoding = .gbk },
    .{ .name = "csgb2312", .encoding = .gbk },
    .{ .name = "csiso58gb231280", .encoding = .gbk },
    .{ .name = "isoir58", .encoding = .gbk },
    .{ .name = "cp936", .encoding = .gbk },
    .{ .name = "ms936", .encoding = .gbk },
    .{ .name = "windows936", .encoding = .gbk },
    .{ .name = "xgbk", .encoding = .gbk },
    .{ .name = "gb18030", .encoding = .gb18030 },
    .{ .name = "gb180302000", .encoding = .gb18030 },
    .{ .name = "gb180302005", .encoding = .gb18030 },
    .{ .name = "gb180302022", .encoding = .gb18030 },
    .{ .name = "big5", .encoding = .big5 },
    .{ .name = "big5hkscs", .encoding = .big5 },
    .{ .name = "cnbig5", .encoding = .big5 },
    .{ .name = "csbig5", .encoding = .big5 },
    .{ .name = "xxbig5", .encoding = .big5 },
    .{ .name = "cp950", .encoding = .big5 },
    .{ .name = "windows950", .encoding = .big5 },
    .{ .name = "eucjp", .encoding = .euc_jp },
    .{ .name = "cseucpkdfmtjapanese", .encoding = .euc_jp },
    .{ .name = "xeucjp", .encoding = .euc_jp },
    .{ .name = "ujis", .encoding = .euc_jp },
    .{ .name = "iso2022jp", .encoding = .iso_2022_jp },
    .{ .name = "csiso2022jp", .encoding = .iso_2022_jp },
    .{ .name = "shiftjis", .encoding = .shift_jis },
    .{ .name = "sjis", .encoding = .shift_jis },
    .{ .name = "csshiftjis", .encoding = .shift_jis },
    .{ .name = "ms932", .encoding = .shift_jis },
    .{ .name = "mskanji", .encoding = .shift_jis },
    .{ .name = "windows31j", .encoding = .shift_jis },
    .{ .name = "cp932", .encoding = .shift_jis },
    .{ .name = "xsjis", .encoding = .shift_jis },
    .{ .name = "euckr", .encoding = .euc_kr },
    .{ .name = "cseuckr", .encoding = .euc_kr },
    .{ .name = "csksc56011987", .encoding = .euc_kr },
    .{ .name = "ksc5601", .encoding = .euc_kr },
    .{ .name = "ksc56011987", .encoding = .euc_kr },
    .{ .name = "ksc56011989", .encoding = .euc_kr },
    .{ .name = "korean", .encoding = .euc_kr },
    .{ .name = "isoir149", .encoding = .euc_kr },
    .{ .name = "windows949", .encoding = .euc_kr },
    .{ .name = "cp949", .encoding = .euc_kr },
    .{ .name = "uhc", .encoding = .euc_kr },

    .{ .name = "xuserdefined", .encoding = .x_user_defined },
    .{ .name = "replacement", .encoding = .replacement },
    .{ .name = "csiso2022kr", .encoding = .replacement },
    .{ .name = "hzgb2312", .encoding = .replacement },
    .{ .name = "iso2022cn", .encoding = .replacement },
    .{ .name = "iso2022cnext", .encoding = .replacement },
    .{ .name = "iso2022kr", .encoding = .replacement },
};

const IbmPageDef = struct {
    encoding: Encoding,
    name: []const u8,
    number: []const u8,
};

const ibm_page_defs = [_]IbmPageDef{
    .{ .encoding = .ibm_437, .name = "ibm437", .number = "437" },
    .{ .encoding = .ibm_850, .name = "ibm850", .number = "850" },
    .{ .encoding = .ibm_852, .name = "ibm852", .number = "852" },
    .{ .encoding = .ibm_855, .name = "ibm855", .number = "855" },
    .{ .encoding = .ibm_857, .name = "ibm857", .number = "857" },
    .{ .encoding = .ibm_858, .name = "ibm858", .number = "858" },
    .{ .encoding = .ibm_860, .name = "ibm860", .number = "860" },
    .{ .encoding = .ibm_861, .name = "ibm861", .number = "861" },
    .{ .encoding = .ibm_862, .name = "ibm862", .number = "862" },
    .{ .encoding = .ibm_863, .name = "ibm863", .number = "863" },
    .{ .encoding = .ibm_864, .name = "ibm864", .number = "864" },
    .{ .encoding = .ibm_865, .name = "ibm865", .number = "865" },
    .{ .encoding = .ibm_869, .name = "ibm869", .number = "869" },
    .{ .encoding = .ibm_1026, .name = "ibm1026", .number = "1026" },
    .{ .encoding = .ibm_1047, .name = "ibm1047", .number = "1047" },
    .{ .encoding = .ibm_1140, .name = "ibm1140", .number = "1140" },
    .{ .encoding = .ibm_1141, .name = "ibm1141", .number = "1141" },
    .{ .encoding = .ibm_1142, .name = "ibm1142", .number = "1142" },
    .{ .encoding = .ibm_1143, .name = "ibm1143", .number = "1143" },
    .{ .encoding = .ibm_1144, .name = "ibm1144", .number = "1144" },
    .{ .encoding = .ibm_1145, .name = "ibm1145", .number = "1145" },
    .{ .encoding = .ibm_1146, .name = "ibm1146", .number = "1146" },
    .{ .encoding = .ibm_1147, .name = "ibm1147", .number = "1147" },
    .{ .encoding = .ibm_1148, .name = "ibm1148", .number = "1148" },
    .{ .encoding = .ibm_1149, .name = "ibm1149", .number = "1149" },
    .{ .encoding = .ibm_1160, .name = "ibm1160", .number = "1160" },
    .{ .encoding = .ibm_1162, .name = "ibm1162", .number = "1162" },
    .{ .encoding = .ibm_1164, .name = "ibm1164", .number = "1164" },
};

const ibm_aliases = blk: {
    var list: [ibm_page_defs.len * 4]Alias = undefined;
    for (ibm_page_defs, 0..) |def, index| {
        list[index * 4] = .{ .name = def.name, .encoding = def.encoding };
        list[index * 4 + 1] = .{
            .name = "cp" ++ def.number,
            .encoding = def.encoding,
        };
        list[index * 4 + 2] = .{
            .name = def.number,
            .encoding = def.encoding,
        };
        list[index * 4 + 3] = .{
            .name = "cs" ++ def.name,
            .encoding = def.encoding,
        };
    }
    break :blk list;
};

const aliases = base_aliases ++ ibm_aliases;

fn ibmPageIndex(encoding: Encoding) ?usize {
    for (ibm_page_defs, 0..) |def, index| {
        if (def.encoding == encoding) return index;
    }
    return null;
}

/// Resolve an encoding label such as `UTF-8`, `windows-1252`, or `GB18030`.
pub fn fromLabel(label: []const u8) ?Encoding {
    var buffer: [64]u8 = undefined;
    const normalized = normalizeLabel(label, &buffer) orelse return null;
    for (aliases) |entry| {
        if (std.mem.eql(u8, normalized, entry.name)) return entry.encoding;
    }
    return null;
}

fn normalizeLabel(label: []const u8, buffer: []u8) ?[]const u8 {
    var length: usize = 0;
    for (label) |byte| {
        if (!std.ascii.isAlphanumeric(byte)) continue;
        if (length == buffer.len) return null;
        buffer[length] = std.ascii.toLower(byte);
        length += 1;
    }
    if (length == 0) return null;
    return buffer[0..length];
}

pub const Decoder = struct {
    encoding: Encoding,
    state: iso2022jp.State = .{},
    utf7_state: utf7.State = .{},
    hz_state: hz.State = .{},
    scsu_state: scsu.State = .{},
    bocu1_state: bocu1.State = .{},

    pub fn init(encoding: Encoding) Decoder {
        return .{ .encoding = encoding };
    }

    pub fn next(self: *Decoder, input: []const u8, index: *usize) DecodeResult {
        if (index.* >= input.len) return .end;
        return switch (self.encoding) {
            .utf8 => utf8Next(input, index),
            .utf16_le => utf16Next(input, index, .little),
            .utf16_be => utf16Next(input, index, .big),
            .utf32_le => utf32Next(input, index, .little),
            .utf32_be => utf32Next(input, index, .big),
            .utf7 => utf7.next(&self.utf7_state, input, index),
            .hz => hz.next(&self.hz_state, input, index),
            .scsu => scsu.next(&self.scsu_state, input, index),
            .bocu1 => bocu1.next(&self.bocu1_state, input, index),
            .ascii => asciiNext(input, index),
            .latin1 => latin1Next(input, index),
            .x_user_defined => xUserDefinedNext(input, index),
            .replacement => replacementNext(index),
            .iso_2022_jp => iso2022jp.next(&self.state, input, index),
            .gbk => cjk.gbkNext(input, index),
            .gb18030 => cjk.gb18030Next(input, index),
            .big5 => cjk.big5Next(input, index),
            .euc_jp => cjk.eucJpNext(input, index),
            .shift_jis => cjk.shiftJisNext(input, index),
            .euc_kr => cjk.eucKrNext(input, index),
            else => singleByteNext(self.encoding, input, index),
        };
    }
};

pub const Encoder = struct {
    encoding: Encoding,
    state: iso2022jp.State = .{},
    utf7_state: utf7.State = .{},
    hz_state: hz.State = .{},
    scsu_state: scsu.State = .{},
    bocu1_state: bocu1.State = .{},

    pub fn init(encoding: Encoding) Encoder {
        return .{ .encoding = encoding };
    }

    pub fn encode(self: *Encoder, codepoint: u21, out: []u8) EncodeResult {
        return switch (self.encoding) {
            .utf8 => utf8Encode(codepoint, out),
            .utf16_le => utf16Encode(codepoint, out, .little),
            .utf16_be => utf16Encode(codepoint, out, .big),
            .utf32_le => utf32Encode(codepoint, out, .little),
            .utf32_be => utf32Encode(codepoint, out, .big),
            .utf7 => utf7.encode(&self.utf7_state, codepoint, out),
            .hz => hz.encode(&self.hz_state, codepoint, out),
            .scsu => scsu.encode(&self.scsu_state, codepoint, out),
            .bocu1 => bocu1.encode(&self.bocu1_state, codepoint, out),
            .ascii => if (codepoint < 0x80)
                writeByte(codepoint, out)
            else
                .unmappable,
            .latin1 => if (codepoint <= 0xFF)
                writeByte(codepoint, out)
            else
                .unmappable,
            .x_user_defined => xUserDefinedEncode(codepoint, out),
            .replacement => .unmappable,
            .iso_2022_jp => iso2022jp.encode(&self.state, codepoint, out),
            .gbk => cjk.gbkEncode(codepoint, out),
            .gb18030 => cjk.gb18030Encode(codepoint, out),
            .big5 => cjk.big5Encode(codepoint, out),
            .euc_jp => cjk.eucJpEncode(codepoint, out),
            .shift_jis => cjk.shiftJisEncode(codepoint, out),
            .euc_kr => cjk.eucKrEncode(codepoint, out),
            else => singleByteEncode(self.encoding, codepoint, out),
        };
    }

    /// Emit any trailing state-reset bytes (only ISO-2022-JP needs this).
    pub fn flush(self: *Encoder, out: []u8) u8 {
        return switch (self.encoding) {
            .utf7 => utf7.flush(&self.utf7_state, out),
            .hz => hz.flush(&self.hz_state, out),
            .scsu => scsu.flush(&self.scsu_state, out),
            .bocu1 => bocu1.flush(&self.bocu1_state, out),
            .iso_2022_jp => iso2022jp.flush(&self.state, out),
            else => 0,
        };
    }
};

fn writeByte(codepoint: u21, out: []u8) EncodeResult {
    out[0] = @intCast(codepoint);
    return .{ .written = 1 };
}

fn utf8Next(input: []const u8, index: *usize) DecodeResult {
    const start = index.*;
    const first = input[start];
    if (first < 0x80) {
        index.* = start + 1;
        return .{ .codepoint = first };
    }
    const length: usize = std.unicode.utf8ByteSequenceLength(first) catch {
        index.* = start + 1;
        return .{ .malformed = 1 };
    };
    if (start + length > input.len) return .incomplete;
    const codepoint = std.unicode.utf8Decode(input[start..][0..length]) catch {
        index.* = start + 1;
        return .{ .malformed = 1 };
    };
    index.* = start + length;
    return .{ .codepoint = codepoint };
}

fn utf16Next(
    input: []const u8,
    index: *usize,
    endian: std.builtin.Endian,
) DecodeResult {
    const start = index.*;
    if (start + 2 > input.len) return .incomplete;
    const unit = std.mem.readInt(u16, input[start..][0..2], endian);
    if (unit >= 0xD800 and unit <= 0xDBFF) {
        if (start + 4 > input.len) return .incomplete;
        const low = std.mem.readInt(u16, input[start + 2 ..][0..2], endian);
        if (low < 0xDC00 or low > 0xDFFF) {
            index.* = start + 2;
            return .{ .malformed = 2 };
        }
        index.* = start + 4;
        const codepoint: u21 = 0x10000 +
            (@as(u21, unit - 0xD800) << 10) +
            (low - 0xDC00);
        return .{ .codepoint = codepoint };
    }
    index.* = start + 2;
    if (unit >= 0xDC00 and unit <= 0xDFFF) return .{ .malformed = 2 };
    return .{ .codepoint = unit };
}

fn utf32Next(
    input: []const u8,
    index: *usize,
    endian: std.builtin.Endian,
) DecodeResult {
    const start = index.*;
    if (start + 4 > input.len) return .incomplete;
    const value = std.mem.readInt(u32, input[start..][0..4], endian);
    index.* = start + 4;
    if (value > 0x10FFFF or (value >= 0xD800 and value <= 0xDFFF)) {
        return .{ .malformed = 4 };
    }
    return .{ .codepoint = @intCast(value) };
}

fn asciiNext(input: []const u8, index: *usize) DecodeResult {
    const byte = input[index.*];
    index.* += 1;
    if (byte > 0x7F) return .{ .malformed = 1 };
    return .{ .codepoint = byte };
}

fn latin1Next(input: []const u8, index: *usize) DecodeResult {
    const byte = input[index.*];
    index.* += 1;
    return .{ .codepoint = byte };
}

fn singleByteNext(
    encoding: Encoding,
    input: []const u8,
    index: *usize,
) DecodeResult {
    const byte = input[index.*];
    index.* += 1;
    if (ibmPageIndex(encoding)) |page| {
        const codepoint = tables.ibmForward(page, byte) orelse
            return .{ .malformed = 1 };
        return .{ .codepoint = codepoint };
    }
    if (byte < 0x80) return .{ .codepoint = byte };
    const table_index = singleByteIndex(encoding) orelse return .{ .malformed = 1 };
    const codepoint = tables.singleByteForward(table_index, byte) orelse
        return .{ .malformed = 1 };
    return .{ .codepoint = codepoint };
}

fn xUserDefinedNext(input: []const u8, index: *usize) DecodeResult {
    const byte = input[index.*];
    index.* += 1;
    if (byte < 0x80) return .{ .codepoint = byte };
    return .{ .codepoint = @as(u21, 0xF780) + byte - 0x80 };
}

fn replacementNext(index: *usize) DecodeResult {
    index.* += 1;
    return .{ .malformed = 1 };
}

fn singleByteIndex(encoding: Encoding) ?usize {
    return switch (encoding) {
        .ibm866 => 0,
        .iso_8859_2 => 1,
        .iso_8859_3 => 2,
        .iso_8859_4 => 3,
        .iso_8859_5 => 4,
        .iso_8859_6 => 5,
        .iso_8859_7 => 6,
        .iso_8859_8 => 7,
        .iso_8859_8_i => 8,
        .iso_8859_10 => 9,
        .iso_8859_13 => 10,
        .iso_8859_14 => 11,
        .iso_8859_15 => 12,
        .iso_8859_16 => 13,
        .koi8_r => 14,
        .koi8_u => 15,
        .macintosh => 16,
        .windows_874 => 17,
        .windows_1250 => 18,
        .windows_1251 => 19,
        .windows_1252 => 20,
        .windows_1253 => 21,
        .windows_1254 => 22,
        .windows_1255 => 23,
        .windows_1256 => 24,
        .windows_1257 => 25,
        .windows_1258 => 26,
        .x_mac_cyrillic => 27,
        else => null,
    };
}

fn utf8Encode(codepoint: u21, out: []u8) EncodeResult {
    if (codepoint > 0x10FFFF or (codepoint >= 0xD800 and codepoint <= 0xDFFF)) {
        return .unmappable;
    }
    const length = std.unicode.utf8Encode(codepoint, out[0..4]) catch
        return .unmappable;
    return .{ .written = length };
}

fn utf16Encode(
    codepoint: u21,
    out: []u8,
    endian: std.builtin.Endian,
) EncodeResult {
    if (codepoint >= 0x10000) {
        if (codepoint > 0x10FFFF) return .unmappable;
        const value = codepoint - 0x10000;
        const high: u16 = @intCast(0xD800 + (value >> 10));
        const low: u16 = @intCast(0xDC00 + (value & 0x3FF));
        std.mem.writeInt(u16, out[0..2], high, endian);
        std.mem.writeInt(u16, out[2..4], low, endian);
        return .{ .written = 4 };
    }
    if (codepoint >= 0xD800 and codepoint <= 0xDFFF) return .unmappable;
    std.mem.writeInt(u16, out[0..2], @intCast(codepoint), endian);
    return .{ .written = 2 };
}

fn utf32Encode(
    codepoint: u21,
    out: []u8,
    endian: std.builtin.Endian,
) EncodeResult {
    if (codepoint > 0x10FFFF or (codepoint >= 0xD800 and codepoint <= 0xDFFF)) {
        return .unmappable;
    }
    std.mem.writeInt(u32, out[0..4], codepoint, endian);
    return .{ .written = 4 };
}

fn singleByteEncode(
    encoding: Encoding,
    codepoint: u21,
    out: []u8,
) EncodeResult {
    if (ibmPageIndex(encoding)) |page| {
        const byte = tables.ibmReverse(page, codepoint) orelse
            return .unmappable;
        out[0] = byte;
        return .{ .written = 1 };
    }
    if (codepoint < 0x80) return writeByte(codepoint, out);
    const table_index = singleByteIndex(encoding) orelse return .unmappable;
    const byte = tables.singleByteReverse(table_index, codepoint) orelse
        return .unmappable;
    out[0] = byte;
    return .{ .written = 1 };
}

fn xUserDefinedEncode(codepoint: u21, out: []u8) EncodeResult {
    if (codepoint < 0x80) return writeByte(codepoint, out);
    if (codepoint >= 0xF780 and codepoint <= 0xF7FF) {
        out[0] = @intCast(0x80 + codepoint - 0xF780);
        return .{ .written = 1 };
    }
    return .unmappable;
}

/// Decode `input` to UTF-8.
pub fn decodeAlloc(
    allocator: std.mem.Allocator,
    input: []const u8,
    encoding: Encoding,
    options: Options,
) Error![]u8 {
    if (asciiCompatible(encoding) and isAscii(input)) {
        return allocator.dupe(u8, input);
    }
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    var decoder = Decoder.init(encoding);
    var index: usize = 0;
    while (true) {
        switch (decoder.next(input, &index)) {
            .end => break,
            .codepoint => |codepoint| try appendUtf8(allocator, &output, codepoint),
            .malformed => switch (options.on_error) {
                .strict => return error.InvalidSequence,
                .ignore => {},
                .replace => try appendUtf8(allocator, &output, options.replacement),
            },
            .incomplete => {
                switch (options.on_error) {
                    .strict => return error.InvalidSequence,
                    .ignore => {},
                    .replace => try appendUtf8(
                        allocator,
                        &output,
                        options.replacement,
                    ),
                }
                index = input.len;
            },
        }
    }
    return output.toOwnedSlice(allocator);
}

/// Encode UTF-8 `text` to `encoding`.
pub fn encodeAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
    encoding: Encoding,
    options: Options,
) Error![]u8 {
    if (asciiCompatible(encoding) and isAscii(text)) {
        return allocator.dupe(u8, text);
    }
    if (encoding == .utf16_le or encoding == .utf16_be) {
        return utf8ToUtf16Alloc(
            allocator,
            text,
            if (encoding == .utf16_le) .little else .big,
            options,
        );
    }
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    var encoder = Encoder.init(encoding);
    var index: usize = 0;
    while (index < text.len) {
        const length: usize = std.unicode.utf8ByteSequenceLength(text[index]) catch {
            try handleInvalidInput(allocator, &output, &encoder, options);
            index += 1;
            continue;
        };
        if (index + length > text.len) {
            try handleInvalidInput(allocator, &output, &encoder, options);
            index = text.len;
            continue;
        }
        const codepoint = std.unicode.utf8Decode(text[index..][0..length]) catch {
            try handleInvalidInput(allocator, &output, &encoder, options);
            index += 1;
            continue;
        };
        index += length;
        try encodeCodepoint(allocator, &output, &encoder, codepoint, options);
    }
    var buffer: [8]u8 = undefined;
    const flushed = encoder.flush(&buffer);
    try output.appendSlice(allocator, buffer[0..flushed]);
    return output.toOwnedSlice(allocator);
}

/// Append a replacement codepoint as UTF-16, honoring the error mode.
fn appendUtf16Replacement(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    endian: std.builtin.Endian,
    options: Options,
) Error!void {
    if (options.on_error == .strict) return error.InvalidSequence;
    if (options.on_error == .ignore) return;
    const candidates = [_]u21{ options.replacement, '?', 0x1A };
    for (candidates) |candidate| {
        var buffer: [4]u8 = undefined;
        switch (utf16Encode(candidate, &buffer, endian)) {
            .written => |length| {
                try output.appendSlice(allocator, buffer[0..length]);
                return;
            },
            else => {},
        }
    }
}

/// UTF-8 to UTF-16 conversion with one capacity reservation. Valid UTF-8
/// never needs more than two output bytes per input byte, so the hot loop
/// appends without capacity checks.
fn utf8ToUtf16Alloc(
    allocator: std.mem.Allocator,
    input: []const u8,
    endian: std.builtin.Endian,
    options: Options,
) Error![]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try output.ensureTotalCapacity(allocator, input.len * 2);
    var index: usize = 0;
    while (index < input.len) {
        if (input[index] < 0x80) {
            // Widen the whole ASCII run directly into the output buffer.
            var end = index;
            while (end < input.len and input[end] < 0x80) end += 1;
            const count = end - index;
            try output.ensureUnusedCapacity(allocator, count * 2);
            const start = output.items.len;
            output.items.len = start + count * 2;
            const destination = output.items[start..];
            if (endian == .little) {
                for (input[index..end], 0..) |value, position| {
                    destination[position * 2] = value;
                    destination[position * 2 + 1] = 0;
                }
            } else {
                for (input[index..end], 0..) |value, position| {
                    destination[position * 2] = 0;
                    destination[position * 2 + 1] = value;
                }
            }
            index = end;
            continue;
        }
        const length: usize = std.unicode.utf8ByteSequenceLength(input[index]) catch {
            try appendUtf16Replacement(allocator, &output, endian, options);
            index += 1;
            continue;
        };
        if (index + length > input.len) {
            try appendUtf16Replacement(allocator, &output, endian, options);
            index = input.len;
            continue;
        }
        const codepoint = std.unicode.utf8Decode(input[index..][0..length]) catch {
            try appendUtf16Replacement(allocator, &output, endian, options);
            index += 1;
            continue;
        };
        index += length;
        var buffer: [4]u8 = undefined;
        switch (utf16Encode(codepoint, &buffer, endian)) {
            .written => |written| output.appendSliceAssumeCapacity(
                buffer[0..written],
            ),
            else => try appendUtf16Replacement(
                allocator,
                &output,
                endian,
                options,
            ),
        }
    }
    return output.toOwnedSlice(allocator);
}

/// Convert `input` from one encoding to another without an intermediate
/// allocation.
/// Direct decoder/encoder pairs for stateless encodings. Comptime dispatch
/// removes the per-character encoding switch from the conversion loop.
fn decoderFor(comptime encoding: Encoding) fn ([]const u8, *usize) DecodeResult {
    return switch (encoding) {
        .utf8 => utf8Next,
        .gbk => cjk.gbkNext,
        .gb18030 => cjk.gb18030Next,
        .big5 => cjk.big5Next,
        .euc_jp => cjk.eucJpNext,
        .shift_jis => cjk.shiftJisNext,
        .euc_kr => cjk.eucKrNext,
        else => @compileError("unsupported stateless decoder"),
    };
}

fn encoderFor(comptime encoding: Encoding) fn (u21, []u8) EncodeResult {
    return switch (encoding) {
        .utf8 => utf8Encode,
        .gbk => cjk.gbkEncode,
        .gb18030 => cjk.gb18030Encode,
        .big5 => cjk.big5Encode,
        .euc_jp => cjk.eucJpEncode,
        .shift_jis => cjk.shiftJisEncode,
        .euc_kr => cjk.eucKrEncode,
        else => @compileError("unsupported stateless encoder"),
    };
}

fn writeReplacementFor(
    comptime to: Encoding,
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    options: Options,
) Error!void {
    const encode = comptime encoderFor(to);
    const candidates = [_]u21{ options.replacement, '?', 0x1A };
    for (candidates) |candidate| {
        var buffer: [8]u8 = undefined;
        switch (encode(candidate, &buffer)) {
            .written => |length| {
                try output.appendSlice(allocator, buffer[0..length]);
                return;
            },
            .unmappable => {},
        }
    }
    return error.UnmappableCharacter;
}

/// Fast path for well-formed UTF-8 text that a DBCS encoder can map.
/// Returns null when the input needs the generic error handling.
fn convertUtf8ToDbcsFast(
    comptime encode: fn (u21, *[4]u8) ?u8,
    allocator: std.mem.Allocator,
    input: []const u8,
) error{OutOfMemory}!?[]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try output.ensureTotalCapacity(allocator, input.len + 8);
    const spare = output.unusedCapacitySlice();
    var index: usize = 0;
    var written: usize = 0;
    const complete = blk: {
        while (index < input.len) {
            const first = input[index];
            if (first < 0x80) {
                spare[written] = first;
                written += 1;
                index += 1;
                continue;
            }
            var codepoint: u21 = undefined;
            if (first >= 0xC2 and first <= 0xDF) {
                if (index + 2 > input.len) break :blk false;
                const second = input[index + 1];
                if (second < 0x80 or second > 0xBF) break :blk false;
                codepoint = (@as(u21, first & 0x1F) << 6) |
                    (second & 0x3F);
                index += 2;
            } else if (first >= 0xE0 and first <= 0xEF) {
                if (index + 3 > input.len) break :blk false;
                const second = input[index + 1];
                const third = input[index + 2];
                if (second < 0x80 or second > 0xBF or
                    third < 0x80 or third > 0xBF)
                {
                    break :blk false;
                }
                codepoint = (@as(u21, first & 0x0F) << 12) |
                    (@as(u21, second & 0x3F) << 6) |
                    (third & 0x3F);
                if (codepoint < 0x800 or
                    (codepoint >= 0xD800 and codepoint <= 0xDFFF))
                {
                    break :blk false;
                }
                index += 3;
            } else {
                break :blk false;
            }
            var buffer: [4]u8 = undefined;
            const length = encode(codepoint, &buffer) orelse
                break :blk false;
            switch (length) {
                1 => spare[written] = buffer[0],
                2 => {
                    spare[written] = buffer[0];
                    spare[written + 1] = buffer[1];
                },
                3 => {
                    spare[written] = buffer[0];
                    spare[written + 1] = buffer[1];
                    spare[written + 2] = buffer[2];
                },
                4 => {
                    spare[written] = buffer[0];
                    spare[written + 1] = buffer[1];
                    spare[written + 2] = buffer[2];
                    spare[written + 3] = buffer[3];
                },
                else => break :blk false,
            }
            written += length;
        }
        output.items.len = written;
        break :blk true;
    };
    if (!complete) {
        output.deinit(allocator);
        return null;
    }
    return try output.toOwnedSlice(allocator);
}

/// Fast path for well-formed DBCS input, writing UTF-8 bytes directly
/// into the reserved output. Returns null when the input needs the generic
/// error handling.
fn convertDbcsToUtf8Fast(
    comptime decode: fn ([]const u8, *usize) DecodeResult,
    allocator: std.mem.Allocator,
    input: []const u8,
) error{OutOfMemory}!?[]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try output.ensureTotalCapacity(allocator, input.len * 2 + 8);
    const spare = output.unusedCapacitySlice();
    var index: usize = 0;
    var written: usize = 0;
    while (index < input.len) {
        switch (decode(input, &index)) {
            .end => break,
            .codepoint => |codepoint| {
                if (codepoint < 0x80) {
                    spare[written] = @intCast(codepoint);
                    written += 1;
                    continue;
                }
                if (codepoint >= 0xD800 and codepoint <= 0xDFFF) {
                    output.deinit(allocator);
                    return null;
                }
                if (codepoint < 0x800) {
                    spare[written] = @intCast(0xC0 | (codepoint >> 6));
                    spare[written + 1] = @intCast(
                        0x80 | (codepoint & 0x3F),
                    );
                    written += 2;
                    continue;
                }
                if (codepoint < 0x10000) {
                    spare[written] = @intCast(0xE0 | (codepoint >> 12));
                    spare[written + 1] = @intCast(
                        0x80 | ((codepoint >> 6) & 0x3F),
                    );
                    spare[written + 2] = @intCast(
                        0x80 | (codepoint & 0x3F),
                    );
                    written += 3;
                    continue;
                }
                spare[written] = @intCast(0xF0 | (codepoint >> 18));
                spare[written + 1] = @intCast(
                    0x80 | ((codepoint >> 12) & 0x3F),
                );
                spare[written + 2] = @intCast(
                    0x80 | ((codepoint >> 6) & 0x3F),
                );
                spare[written + 3] = @intCast(
                    0x80 | (codepoint & 0x3F),
                );
                written += 4;
            },
            .malformed, .incomplete => {
                output.deinit(allocator);
                return null;
            },
        }
    }
    output.items.len = written;
    return try output.toOwnedSlice(allocator);
}

fn convertAllocStateless(
    comptime from: Encoding,
    comptime to: Encoding,
    allocator: std.mem.Allocator,
    input: []const u8,
    options: Options,
) Error![]u8 {
    if (comptime to == .utf8) {
        if (comptime from == .gbk) {
            if (try convertDbcsToUtf8Fast(
                cjk.gbkNext,
                allocator,
                input,
            )) |result| {
                return result;
            }
        } else if (comptime from == .gb18030) {
            if (try convertDbcsToUtf8Fast(
                cjk.gb18030Next,
                allocator,
                input,
            )) |result| {
                return result;
            }
        } else if (comptime from == .big5) {
            if (try convertDbcsToUtf8Fast(
                cjk.big5Next,
                allocator,
                input,
            )) |result| {
                return result;
            }
        } else if (comptime from == .shift_jis) {
            if (try convertDbcsToUtf8Fast(
                cjk.shiftJisNext,
                allocator,
                input,
            )) |result| {
                return result;
            }
        } else if (comptime from == .euc_kr) {
            if (try convertDbcsToUtf8Fast(
                cjk.eucKrNext,
                allocator,
                input,
            )) |result| {
                return result;
            }
        } else if (comptime from == .euc_jp) {
            if (try convertDbcsToUtf8Fast(
                cjk.eucJpNext,
                allocator,
                input,
            )) |result| {
                return result;
            }
        }
    }
    if (comptime from == .utf8) {
        if (comptime to == .gbk or to == .gb18030) {
            if (try convertUtf8ToDbcsFast(
                cjk.gbkEncodeFast,
                allocator,
                input,
            )) |result| {
                return result;
            }
        } else if (comptime to == .big5) {
            if (try convertUtf8ToDbcsFast(
                cjk.big5EncodeFast,
                allocator,
                input,
            )) |result| {
                return result;
            }
        } else if (comptime to == .shift_jis) {
            if (try convertUtf8ToDbcsFast(
                cjk.shiftJisEncodeFast,
                allocator,
                input,
            )) |result| {
                return result;
            }
        } else if (comptime to == .euc_kr) {
            if (try convertUtf8ToDbcsFast(
                cjk.eucKrEncodeFast,
                allocator,
                input,
            )) |result| {
                return result;
            }
        } else if (comptime to == .euc_jp) {
            if (try convertUtf8ToDbcsFast(
                cjk.eucJpEncodeFast,
                allocator,
                input,
            )) |result| {
                return result;
            }
        }
    }
    // Valid input never grows past this bound: a 3-byte UTF-8 sequence maps
    // to at most 2 DBCS bytes (4 for GB18030 supplementary), and a 2-byte
    // DBCS sequence maps to 3 UTF-8 bytes. Error replacements use the
    // checked path below.
    const growth: usize = comptime switch (from) {
        .utf8 => if (to == .gb18030) 2 else 1,
        else => 2,
    };
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try output.ensureTotalCapacity(allocator, input.len * growth + 8);
    const decode = comptime decoderFor(from);
    const encode = comptime encoderFor(to);
    var index: usize = 0;
    while (index < input.len) {
        switch (decode(input, &index)) {
            .end => break,
            .codepoint => |codepoint| {
                var buffer: [8]u8 = undefined;
                switch (encode(codepoint, &buffer)) {
                    .written => |length| {
                        output.appendSliceAssumeCapacity(buffer[0..length]);
                    },
                    .unmappable => switch (options.on_error) {
                        .strict => return error.UnmappableCharacter,
                        .ignore => {},
                        .replace => {
                            try writeReplacementFor(
                                to,
                                allocator,
                                &output,
                                options,
                            );
                            try output.ensureUnusedCapacity(
                                allocator,
                                (input.len - index) * growth + 8,
                            );
                        },
                    },
                }
            },
            .malformed => switch (options.on_error) {
                .strict => return error.InvalidSequence,
                .ignore => {},
                .replace => {
                    try writeReplacementFor(
                        to,
                        allocator,
                        &output,
                        options,
                    );
                    try output.ensureUnusedCapacity(
                        allocator,
                        (input.len - index) * growth + 8,
                    );
                },
            },
            .incomplete => {
                switch (options.on_error) {
                    .strict => return error.InvalidSequence,
                    .ignore => {},
                    .replace => try writeReplacementFor(
                        to,
                        allocator,
                        &output,
                        options,
                    ),
                }
                index = input.len;
            },
        }
    }
    return output.toOwnedSlice(allocator);
}

pub fn convertAlloc(
    allocator: std.mem.Allocator,
    input: []const u8,
    from: Encoding,
    to: Encoding,
    options: Options,
) Error![]u8 {
    if (asciiCompatible(from) and asciiCompatible(to) and isAscii(input)) {
        return allocator.dupe(u8, input);
    }
    if (from == .utf8 and (to == .utf16_le or to == .utf16_be)) {
        return utf8ToUtf16Alloc(
            allocator,
            input,
            if (to == .utf16_le) .little else .big,
            options,
        );
    }
    switch (from) {
        .utf8 => switch (to) {
            .gbk => return convertAllocStateless(.utf8, .gbk, allocator, input, options),
            .gb18030 => return convertAllocStateless(.utf8, .gb18030, allocator, input, options),
            .big5 => return convertAllocStateless(.utf8, .big5, allocator, input, options),
            .euc_jp => return convertAllocStateless(.utf8, .euc_jp, allocator, input, options),
            .shift_jis => return convertAllocStateless(.utf8, .shift_jis, allocator, input, options),
            .euc_kr => return convertAllocStateless(.utf8, .euc_kr, allocator, input, options),
            else => {},
        },
        .gbk => if (to == .utf8) return convertAllocStateless(.gbk, .utf8, allocator, input, options),
        .gb18030 => if (to == .utf8) return convertAllocStateless(.gb18030, .utf8, allocator, input, options),
        .big5 => if (to == .utf8) return convertAllocStateless(.big5, .utf8, allocator, input, options),
        .euc_jp => if (to == .utf8) return convertAllocStateless(.euc_jp, .utf8, allocator, input, options),
        .shift_jis => if (to == .utf8) return convertAllocStateless(.shift_jis, .utf8, allocator, input, options),
        .euc_kr => if (to == .utf8) return convertAllocStateless(.euc_kr, .utf8, allocator, input, options),
        else => {},
    }
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    var decoder = Decoder.init(from);
    var encoder = Encoder.init(to);
    var index: usize = 0;
    while (true) {
        switch (decoder.next(input, &index)) {
            .end => break,
            .codepoint => |codepoint| try encodeCodepoint(
                allocator,
                &output,
                &encoder,
                codepoint,
                options,
            ),
            .malformed => switch (options.on_error) {
                .strict => return error.InvalidSequence,
                .ignore => {},
                .replace => try writeReplacement(
                    allocator,
                    &output,
                    &encoder,
                    options,
                ),
            },
            .incomplete => {
                switch (options.on_error) {
                    .strict => return error.InvalidSequence,
                    .ignore => {},
                    .replace => try writeReplacement(
                        allocator,
                        &output,
                        &encoder,
                        options,
                    ),
                }
                index = input.len;
            },
        }
    }
    var buffer: [8]u8 = undefined;
    const flushed = encoder.flush(&buffer);
    try output.appendSlice(allocator, buffer[0..flushed]);
    return output.toOwnedSlice(allocator);
}

/// Return true when `input` is a complete, valid sequence in `encoding`.
pub fn validate(input: []const u8, encoding: Encoding) bool {
    var decoder = Decoder.init(encoding);
    var index: usize = 0;
    while (true) {
        switch (decoder.next(input, &index)) {
            .end => return true,
            .codepoint => {},
            .malformed, .incomplete => return false,
        }
    }
}

fn asciiCompatible(encoding: Encoding) bool {
    if (ibmPageIndex(encoding)) |index| {
        return tables.ibmPageAsciiCompatible(index);
    }
    return switch (encoding) {
        .utf8, .ascii, .latin1, .x_user_defined => true,
        .gbk, .gb18030, .big5, .euc_jp, .shift_jis, .euc_kr => true,
        else => singleByteIndex(encoding) != null,
    };
}

fn isAscii(input: []const u8) bool {
    for (input) |byte| {
        if (byte >= 0x80) return false;
    }
    return true;
}

fn appendUtf8(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    codepoint: u21,
) Error!void {
    var buffer: [4]u8 = undefined;
    const length = std.unicode.utf8Encode(codepoint, &buffer) catch
        return error.InvalidCodepoint;
    try output.appendSlice(allocator, buffer[0..length]);
}

fn encodeCodepoint(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    encoder: *Encoder,
    codepoint: u21,
    options: Options,
) Error!void {
    var buffer: [8]u8 = undefined;
    switch (encoder.encode(codepoint, &buffer)) {
        .written => |length| try output.appendSlice(allocator, buffer[0..length]),
        .unmappable => switch (options.on_error) {
            .strict => return error.UnmappableCharacter,
            .ignore => {},
            .replace => try writeReplacement(allocator, output, encoder, options),
        },
    }
}

fn writeReplacement(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    encoder: *Encoder,
    options: Options,
) Error!void {
    const candidates = [_]u21{ options.replacement, '?', 0x1A };
    for (candidates) |candidate| {
        var buffer: [8]u8 = undefined;
        switch (encoder.encode(candidate, &buffer)) {
            .written => |length| {
                try output.appendSlice(allocator, buffer[0..length]);
                return;
            },
            .unmappable => {},
        }
    }
    return error.UnmappableCharacter;
}

fn handleInvalidInput(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    encoder: *Encoder,
    options: Options,
) Error!void {
    switch (options.on_error) {
        .strict => return error.InvalidCodepoint,
        .ignore => {},
        .replace => try writeReplacement(allocator, output, encoder, options),
    }
}

test "encoding labels" {
    const testing = @import("std").testing;

    try testing.expectEqual(Encoding.utf8, fromLabel("UTF-8").?);
    try testing.expectEqual(Encoding.utf8, fromLabel("utf8").?);
    try testing.expectEqual(Encoding.utf16_le, fromLabel("UTF-16").?);
    try testing.expectEqual(Encoding.utf16_be, fromLabel("UTF-16BE").?);
    try testing.expectEqual(Encoding.ascii, fromLabel("US-ASCII").?);
    try testing.expectEqual(Encoding.latin1, fromLabel("ISO-8859-1").?);
    try testing.expectEqual(Encoding.windows_1252, fromLabel("CP1252").?);
    try testing.expectEqual(Encoding.windows_1251, fromLabel("windows_1251").?);
    try testing.expectEqual(Encoding.shift_jis, fromLabel("Shift_JIS").?);
    try testing.expectEqual(Encoding.gbk, fromLabel("GB2312").?);
    try testing.expectEqual(Encoding.big5, fromLabel("Big5-HKSCS").?);
    try testing.expectEqual(Encoding.euc_kr, fromLabel("EUC-KR").?);
    try testing.expectEqual(Encoding.iso_2022_jp, fromLabel("ISO-2022-JP").?);
    try testing.expectEqual(Encoding.ibm866, fromLabel("cp866").?);
    try testing.expectEqual(Encoding.koi8_r, fromLabel("KOI8-R").?);
    try testing.expectEqual(Encoding.macintosh, fromLabel("MacRoman").?);
    try testing.expectEqual(Encoding.x_user_defined, fromLabel("x-user-defined").?);
    try testing.expectEqual(null, fromLabel("no-such-charset"));
}

test "ASCII fast paths" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const text = "plain ASCII text 123";

    inline for ([_]Encoding{
        .utf8,
        .ascii,
        .windows_1252,
        .gbk,
        .shift_jis,
        .euc_kr,
    }) |encoding| {
        const decoded = try decodeAlloc(allocator, text, encoding, .{});
        defer allocator.free(decoded);
        try testing.expectEqualStrings(text, decoded);

        const encoded = try encodeAlloc(allocator, text, encoding, .{});
        defer allocator.free(encoded);
        try testing.expectEqualStrings(text, encoded);
    }

    const converted = try convertAlloc(allocator, text, .gbk, .shift_jis, .{});
    defer allocator.free(converted);
    try testing.expectEqualStrings(text, converted);
}

test "single-byte decoding and encoding" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const decoded = try decodeAlloc(
        allocator,
        &.{ 0x80, 0x93, 0x94, 0xE9 },
        .windows_1252,
        .{},
    );
    defer allocator.free(decoded);
    try testing.expectEqualStrings("\u{20AC}\u{201C}\u{201D}\u{00E9}", decoded);

    const encoded = try encodeAlloc(
        allocator,
        "\u{20AC}\u{201C}\u{201D}\u{00E9}",
        .windows_1252,
        .{},
    );
    defer allocator.free(encoded);
    try testing.expectEqualSlices(u8, &.{ 0x80, 0x93, 0x94, 0xE9 }, encoded);

    const cyrillic = try decodeAlloc(
        allocator,
        &.{ 0x80, 0x81 },
        .ibm866,
        .{},
    );
    defer allocator.free(cyrillic);
    try testing.expectEqualStrings("\u{0410}\u{0411}", cyrillic);

    const latin2 = try decodeAlloc(allocator, &.{0xA1}, .iso_8859_2, .{});
    defer allocator.free(latin2);
    try testing.expectEqualStrings("\u{0104}", latin2);
}

test "UTF encodings and malformed input" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const text = "A\u{00E9}\u{4E16}\u{1F600}";
    inline for ([_]Encoding{
        .utf8,
        .utf16_le,
        .utf16_be,
        .utf32_le,
        .utf32_be,
    }) |encoding| {
        const encoded = try encodeAlloc(allocator, text, encoding, .{});
        defer allocator.free(encoded);
        const decoded = try decodeAlloc(allocator, encoded, encoding, .{});
        defer allocator.free(decoded);
        try testing.expectEqualStrings(text, decoded);
    }

    try testing.expectEqual(false, validate(&.{ 0xC0, 0xAF }, .utf8));
    try testing.expectEqual(false, validate(&.{ 0xED, 0xA0, 0x80 }, .utf8));
    try testing.expectEqual(false, validate(&.{ 0x00, 0xD8 }, .utf16_le));

    const replaced = try decodeAlloc(allocator, &.{ 0x41, 0xFF, 0x42 }, .utf8, .{});
    defer allocator.free(replaced);
    try testing.expectEqualStrings("A\u{FFFD}B", replaced);

    const ignored = try decodeAlloc(
        allocator,
        &.{ 0x41, 0xFF, 0x42 },
        .utf8,
        .{ .on_error = .ignore },
    );
    defer allocator.free(ignored);
    try testing.expectEqualStrings("AB", ignored);

    try testing.expectError(
        error.InvalidSequence,
        decodeAlloc(allocator, &.{0xFF}, .utf8, .{ .on_error = .strict }),
    );
    try testing.expectError(
        error.UnmappableCharacter,
        encodeAlloc(allocator, "\u{4E16}", .ascii, .{ .on_error = .strict }),
    );

    const substituted = try encodeAlloc(allocator, "\u{4E16}", .ascii, .{});
    defer allocator.free(substituted);
    try testing.expectEqualStrings("?", substituted);
}

test "multi-byte conversion" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const cases = [_]struct {
        encoding: Encoding,
        text: []const u8,
        bytes: []const u8,
    }{
        .{ .encoding = .shift_jis, .text = "\u{3042}", .bytes = &.{ 0x82, 0xA0 } },
        .{ .encoding = .euc_jp, .text = "\u{3042}", .bytes = &.{ 0xA4, 0xA2 } },
        .{ .encoding = .gbk, .text = "\u{4F60}", .bytes = &.{ 0xC4, 0xE3 } },
        .{ .encoding = .big5, .text = "\u{4F60}", .bytes = &.{ 0xA7, 0x41 } },
        .{ .encoding = .euc_kr, .text = "\u{AC00}", .bytes = &.{ 0xB0, 0xA1 } },
        .{
            .encoding = .gb18030,
            .text = "\u{10000}",
            .bytes = &.{ 0x90, 0x30, 0x81, 0x30 },
        },
        .{
            .encoding = .iso_2022_jp,
            .text = "\u{3053}\u{3093}\u{306B}\u{3061}\u{306F}",
            .bytes = &.{
                0x1B, 0x24, 0x42, 0x24, 0x33, 0x24, 0x73, 0x24,
                0x4B, 0x24, 0x41, 0x24, 0x4F, 0x1B, 0x28, 0x42,
            },
        },
    };

    for (cases) |case| {
        const encoded = try encodeAlloc(allocator, case.text, case.encoding, .{});
        defer allocator.free(encoded);
        try testing.expectEqualSlices(u8, case.bytes, encoded);

        const decoded = try decodeAlloc(allocator, case.bytes, case.encoding, .{});
        defer allocator.free(decoded);
        try testing.expectEqualStrings(case.text, decoded);
    }

    const converted = try convertAlloc(
        allocator,
        "\u{4F60}\u{597D}",
        .utf8,
        .gbk,
        .{},
    );
    defer allocator.free(converted);
    try testing.expectEqualSlices(u8, &.{ 0xC4, 0xE3, 0xBA, 0xC3 }, converted);
    const round_trip = try convertAlloc(
        allocator,
        converted,
        .gbk,
        .utf8,
        .{},
    );
    defer allocator.free(round_trip);
    try testing.expectEqualStrings("\u{4F60}\u{597D}", round_trip);
}

test "replacement and user-defined encodings" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const replaced = try decodeAlloc(allocator, "abc", .replacement, .{});
    defer allocator.free(replaced);
    try testing.expectEqualStrings("\u{FFFD}\u{FFFD}\u{FFFD}", replaced);

    const user_defined = try decodeAlloc(
        allocator,
        &.{ 0x41, 0x80, 0xFF },
        .x_user_defined,
        .{},
    );
    defer allocator.free(user_defined);
    try testing.expectEqualStrings("A\u{F780}\u{F7FF}", user_defined);

    const encoded = try encodeAlloc(
        allocator,
        "A\u{F780}\u{F7FF}",
        .x_user_defined,
        .{},
    );
    defer allocator.free(encoded);
    try testing.expectEqualSlices(u8, &.{ 0x41, 0x80, 0xFF }, encoded);
}

test "converter metadata" {
    const testing = @import("std").testing;
    try testing.expectEqualStrings(
        "windows-1252",
        encodingName(.windows_1252),
    );
    try testing.expectEqualStrings("UTF-8", encodingName(.utf8));
    try testing.expectEqual(@as(u8, 4), maxCharSize(.utf8));
    try testing.expectEqual(@as(u8, 1), maxCharSize(.latin1));
    try testing.expectEqual(@as(u8, 8), maxCharSize(.iso_2022_jp));
    try testing.expectEqual(@as(u8, 2), minCharSize(.utf16_le));
    try testing.expectEqual(@as(u8, 1), minCharSize(.utf8));
}

test "UTF-7 and HZ conversion" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const utf7_cases = [_]struct { text: []const u8, encoded: []const u8 }{
        .{ .text = "Hello, World!", .encoded = "Hello, World!" },
        .{ .text = "Hi Mom -☺-!", .encoded = "Hi Mom -+Jjo--!" },
        .{ .text = "€", .encoded = "+IKw-" },
        .{ .text = "😀", .encoded = "+2D3eAA-" },
        .{ .text = "a€b", .encoded = "a+IKw-b" },
        .{ .text = "+", .encoded = "+-" },
    };
    for (utf7_cases) |case| {
        const encoded = try encodeAlloc(allocator, case.text, .utf7, .{});
        defer allocator.free(encoded);
        try testing.expectEqualStrings(case.encoded, encoded);
        const decoded = try decodeAlloc(allocator, encoded, .utf7, .{});
        defer allocator.free(decoded);
        try testing.expectEqualStrings(case.text, decoded);
    }

    const hz_cases = [_]struct { text: []const u8, encoded: []const u8 }{
        .{ .text = "Hello", .encoded = "Hello" },
        .{ .text = "中国", .encoded = "~{VP9z~}" },
        .{ .text = "a~b", .encoded = "a~~b" },
        .{ .text = "中国abc", .encoded = "~{VP9z~}abc" },
        .{ .text = "中文~test", .encoded = "~{VPND~}~~test" },
    };
    for (hz_cases) |case| {
        const encoded = try encodeAlloc(allocator, case.text, .hz, .{});
        defer allocator.free(encoded);
        try testing.expectEqualStrings(case.encoded, encoded);
        const decoded = try decodeAlloc(allocator, encoded, .hz, .{});
        defer allocator.free(decoded);
        try testing.expectEqualStrings(case.text, decoded);
    }

    try testing.expectEqualStrings("UTF-7", encodingName(.utf7));
    try testing.expectEqualStrings("HZ", encodingName(.hz));
    try testing.expectEqual(@as(?Encoding, .utf7), fromLabel("UTF-7"));
    try testing.expectEqual(@as(?Encoding, .hz), fromLabel("HZ-GB-2312"));
    try testing.expectEqual(@as(u8, 8), maxCharSize(.utf7));
    try testing.expectEqual(@as(u8, 4), maxCharSize(.hz));
}

test "SCSU conversion" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const cases = [_][]const u8{
        "Hello, World!",
        "Привет",
        "日本語テスト",
        "😀😁😂",
        "€£¥",
        "\x00\t\n\r",
        "→←↑↓",
        "𝕳𝖊𝖑𝖑𝖔",
    };
    for (cases) |text| {
        const encoded = try encodeAlloc(allocator, text, .scsu, .{});
        defer allocator.free(encoded);
        const decoded = try decodeAlloc(allocator, encoded, .scsu, .{});
        defer allocator.free(decoded);
        try testing.expectEqualStrings(text, decoded);
    }
    try testing.expectEqualStrings("SCSU", encodingName(.scsu));
    try testing.expectEqual(@as(?Encoding, .scsu), fromLabel("SCSU"));
    try testing.expectEqual(@as(u8, 6), maxCharSize(.scsu));
}

test "BOCU-1 conversion" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const encoded = try encodeAlloc(allocator, "Hello", .bocu1, .{});
    defer allocator.free(encoded);
    try testing.expectEqualSlices(
        u8,
        &[_]u8{ 0x98, 0xB5, 0xBC, 0xBC, 0xBF },
        encoded,
    );
    const decoded = try decodeAlloc(allocator, encoded, .bocu1, .{});
    defer allocator.free(decoded);
    try testing.expectEqualStrings("Hello", decoded);

    const cases = [_][]const u8{
        "Hello, World!",
        "Привет",
        "日本語テスト",
        "😀😁😂",
        "€£¥",
        "\x00\t\n\r",
        "→←↑↓",
        "𝕳𝖊𝖑𝖑𝖔",
        "café naïve",
    };
    for (cases) |text| {
        const bytes = try encodeAlloc(allocator, text, .bocu1, .{});
        defer allocator.free(bytes);
        const roundtrip = try decodeAlloc(allocator, bytes, .bocu1, .{});
        defer allocator.free(roundtrip);
        try testing.expectEqualStrings(text, roundtrip);
    }
    try testing.expectEqualStrings("BOCU-1", encodingName(.bocu1));
    try testing.expectEqual(@as(?Encoding, .bocu1), fromLabel("BOCU-1"));
    try testing.expectEqual(@as(u8, 4), maxCharSize(.bocu1));
}

test "ICU UTF-7, HZ, SCSU, and BOCU-1 conformance fixture" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const fixture = @embedFile("charset/stateful_conformance.bin");

    try testing.expect(fixture.len >= 12);
    try testing.expectEqualStrings("CJGP", fixture[0..4]);
    try testing.expectEqual(@as(u8, 1), fixture[4]);
    const record_count = std.mem.readInt(u32, fixture[8..12], .little);

    const encodings = [_]Encoding{ .utf7, .hz, .scsu, .bocu1 };
    var cursor: usize = 12;
    var failures: usize = 0;
    var record_index: usize = 0;
    while (record_index < record_count) : (record_index += 1) {
        const converter_index = fixture[cursor];
        cursor += 1;
        const kind = fixture[cursor];
        cursor += 1;
        if (converter_index >= encodings.len) return error.InvalidFixture;
        const encoding = encodings[converter_index];

        switch (kind) {
            0 => {
                const unit_length = std.mem.readInt(
                    u16,
                    fixture[cursor..][0..2],
                    .little,
                );
                cursor += 2;
                const input = try fixtureUtf16ToUtf8(
                    allocator,
                    fixture,
                    cursor,
                    unit_length,
                );
                defer allocator.free(input);
                cursor += @as(usize, unit_length) * 2;
                const byte_length = std.mem.readInt(
                    u16,
                    fixture[cursor..][0..2],
                    .little,
                );
                cursor += 2;
                const expected = fixture[cursor..][0..byte_length];
                cursor += byte_length;

                const actual = encodeAlloc(
                    allocator,
                    input,
                    encoding,
                    .{},
                ) catch {
                    failures += 1;
                    continue;
                };
                defer allocator.free(actual);
                if (encoding == .utf7 or encoding == .bocu1) {
                    if (!std.mem.eql(u8, actual, expected)) {
                        failures += 1;
                        if (failures <= 10) {
                            std.debug.print(
                                "charset encode mismatch: converter {d} input [{s}] got {any} want {any}\n",
                                .{ converter_index, input, actual, expected },
                            );
                        }
                    }
                } else {
                    // HZ permits different mode-switch placement; verify that
                    // our output decodes back to the input.
                    const roundtrip = decodeAlloc(
                        allocator,
                        actual,
                        encoding,
                        .{},
                    ) catch {
                        failures += 1;
                        continue;
                    };
                    defer allocator.free(roundtrip);
                    if (!std.mem.eql(u8, roundtrip, input)) {
                        failures += 1;
                        if (failures <= 10) {
                            std.debug.print(
                                "charset HZ round-trip mismatch: input [{s}] encoded {any} decoded [{s}]\n",
                                .{ input, actual, roundtrip },
                            );
                        }
                    }
                }
            },
            1 => {
                const byte_length = std.mem.readInt(
                    u16,
                    fixture[cursor..][0..2],
                    .little,
                );
                cursor += 2;
                const input = fixture[cursor..][0..byte_length];
                cursor += byte_length;
                const unit_length = std.mem.readInt(
                    u16,
                    fixture[cursor..][0..2],
                    .little,
                );
                cursor += 2;
                const expected = try fixtureUtf16ToUtf8(
                    allocator,
                    fixture,
                    cursor,
                    unit_length,
                );
                defer allocator.free(expected);
                cursor += @as(usize, unit_length) * 2;

                const actual = decodeAlloc(
                    allocator,
                    input,
                    encoding,
                    .{},
                ) catch {
                    failures += 1;
                    continue;
                };
                defer allocator.free(actual);
                if (!std.mem.eql(u8, actual, expected)) {
                    failures += 1;
                    if (failures <= 10) {
                        std.debug.print(
                            "charset decode mismatch: converter {d} input {any} got [{s}] want [{s}]\n",
                            .{ converter_index, input, actual, expected },
                        );
                    }
                }
            },
            else => return error.InvalidFixture,
        }
    }
    try testing.expectEqual(fixture.len, cursor);
    try testing.expectEqual(@as(usize, 0), failures);
    std.debug.print(
        "stateful charset conformance: {d} records passed\n",
        .{record_count},
    );
}

fn fixtureUtf16ToUtf8(
    allocator: std.mem.Allocator,
    fixture: []const u8,
    offset: usize,
    length: u16,
) ![]u8 {
    const units = try allocator.alloc(u16, length);
    defer allocator.free(units);
    for (units, 0..) |*unit, index| {
        unit.* = std.mem.readInt(
            u16,
            fixture[offset + index * 2 ..][0..2],
            .little,
        );
    }
    return std.unicode.utf16LeToUtf8Alloc(allocator, units);
}

test "IBM code pages" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    try testing.expectEqual(@as(?Encoding, .ibm_437), fromLabel("cp437"));
    try testing.expectEqual(@as(?Encoding, .ibm_437), fromLabel("IBM-437"));
    try testing.expectEqual(@as(?Encoding, .ibm_437), fromLabel("437"));
    try testing.expectEqual(@as(?Encoding, .ibm_1047), fromLabel("1047"));
    try testing.expectEqualStrings("ibm-437", encodingName(.ibm_437));
    try testing.expectEqualStrings("ibm-1047", encodingName(.ibm_1047));
    try testing.expectEqual(@as(u8, 1), maxCharSize(.ibm_437));

    const cp437_cases = [_]struct { byte: u8, codepoint: u21 }{
        .{ .byte = 0x80, .codepoint = 0x00C7 },
        .{ .byte = 0x9C, .codepoint = 0x00A3 },
        .{ .byte = 0xE1, .codepoint = 0x00DF },
    };
    for (cp437_cases) |case| {
        const input = [_]u8{case.byte};
        const text = try decodeAlloc(allocator, &input, .ibm_437, .{});
        defer allocator.free(text);
        var buffer: [4]u8 = undefined;
        const length = try std.unicode.utf8Encode(case.codepoint, &buffer);
        try testing.expectEqualStrings(buffer[0..length], text);
        const encoded = try encodeAlloc(allocator, text, .ibm_437, .{});
        defer allocator.free(encoded);
        try testing.expectEqualSlices(u8, &input, encoded);
    }

    const ebcdic = try decodeAlloc(allocator, "ABC", .ibm_1047, .{});
    defer allocator.free(ebcdic);
    try testing.expect(!std.mem.eql(u8, "ABC", ebcdic));
    const a = [_]u8{0xC1};
    const a_text = try decodeAlloc(allocator, &a, .ibm_1047, .{});
    defer allocator.free(a_text);
    try testing.expectEqualStrings("A", a_text);
    const a_encoded = try encodeAlloc(allocator, "A", .ibm_1047, .{});
    defer allocator.free(a_encoded);
    try testing.expectEqualSlices(u8, &a, a_encoded);

    const pages = [_]Encoding{
        .ibm_437,
        .ibm_850,
        .ibm_869,
        .ibm_1047,
        .ibm_1162,
    };
    for (pages) |encoding| {
        var byte: usize = 0;
        while (byte < 256) : (byte += 1) {
            const input = [_]u8{@intCast(byte)};
            const text = decodeAlloc(
                allocator,
                &input,
                encoding,
                .{ .on_error = .ignore },
            ) catch continue;
            defer allocator.free(text);
            if (text.len == 0) continue;
            const encoded = encodeAlloc(allocator, text, encoding, .{}) catch
                continue;
            defer allocator.free(encoded);
            if (encoded.len != 1) continue;
            const roundtrip = decodeAlloc(
                allocator,
                encoded,
                encoding,
                .{ .on_error = .ignore },
            ) catch continue;
            defer allocator.free(roundtrip);
            try testing.expectEqualStrings(text, roundtrip);
        }
    }
}
