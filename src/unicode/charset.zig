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
const scalar = @import("scalar/root.zig");
const types = @import("charset/types.zig");
const tables = @import("charset/tables.zig");
const cjk = @import("charset/cjk.zig");
const iso2022jp = @import("charset/iso2022jp.zig");
const utf7 = @import("charset/utf7.zig");
const hz = @import("charset/hz.zig");
const scsu = @import("charset/scsu.zig");
const bocu1 = @import("charset/bocu1.zig");
const iso2022kr = @import("charset/iso2022kr.zig");
const hkscs = @import("charset/hkscs.zig");
const euctw = @import("charset/euctw.zig");
const iso2022cn = @import("charset/iso2022cn.zig");
const utf8_vec = @import("charset/utf8.zig");
const utf32 = @import("charset/utf32.zig");
const single_byte = @import("charset/single_byte.zig");
const dbcs_utf16 = @import("charset/dbcs_utf16.zig");

const native_endian = @import("builtin").target.cpu.arch.endian();

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
    iso_2022_kr,
    hkscs,
    euc_tw,
    iso_2022_cn,
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
        .iso_2022_kr => "ISO-2022-KR",
        .hkscs => "Big5-HKSCS",
        .euc_tw => "EUC-TW",
        .iso_2022_cn => "ISO-2022-CN",
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
        .ascii, .latin1, .ibm866, .iso_8859_2, .iso_8859_3, .iso_8859_4, .iso_8859_5, .iso_8859_6, .iso_8859_7, .iso_8859_8, .iso_8859_8_i, .iso_8859_10, .iso_8859_13, .iso_8859_14, .iso_8859_15, .iso_8859_16, .koi8_r, .koi8_u, .macintosh, .windows_874, .windows_1250, .windows_1251, .windows_1252, .windows_1253, .windows_1254, .windows_1255, .windows_1256, .windows_1257, .windows_1258, .x_mac_cyrillic, .replacement => 1,
        .big5, .shift_jis, .euc_kr, .hkscs => 2,
        .euc_tw => 4,
        .iso_2022_cn => 9,
        .euc_jp => 3,
        .gbk, .gb18030, .x_user_defined => 4,
        .utf7, .iso_2022_jp, .iso_2022_kr => 8,
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

pub const ErrorMode = types.ErrorMode;

pub const Options = types.Options;

pub const Error = types.Error;

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
    .{ .name = "iso2022kr", .encoding = .iso_2022_kr },
    .{ .name = "csiso2022kr", .encoding = .iso_2022_kr },
    .{ .name = "big5hkscs", .encoding = .hkscs },
    .{ .name = "hkscs", .encoding = .hkscs },
    .{ .name = "euctw", .encoding = .euc_tw },
    .{ .name = "iso2022cn", .encoding = .iso_2022_cn },
    .{ .name = "csiso2022cn", .encoding = .iso_2022_cn },

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

/// The IBM page encodings are contiguous in `Encoding`, so the definition
/// index is the enum offset. The compile-time check keeps that true if the
/// enum is reordered, falling back to the scan.
const ibm_pages_contiguous = blk: {
    for (ibm_page_defs, 0..) |def, index| {
        if (@intFromEnum(def.encoding) !=
            @intFromEnum(Encoding.ibm_437) + index) break :blk false;
    }
    break :blk true;
};

fn ibmPageIndex(encoding: Encoding) ?usize {
    if (comptime ibm_pages_contiguous) {
        const index =
            @intFromEnum(encoding) -% @intFromEnum(Encoding.ibm_437);
        return if (index < ibm_page_defs.len) index else null;
    }
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
    iso2022kr_state: iso2022kr.State = .{},
    iso2022cn_state: iso2022cn.State = .{},

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
            .iso_2022_kr => iso2022kr.next(&self.iso2022kr_state, input, index),
            .hkscs => hkscs.next({}, input, index),
            .euc_tw => euctw.next({}, input, index),
            .iso_2022_cn => iso2022cn.next(&self.iso2022cn_state, input, index),
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
    iso2022kr_state: iso2022kr.State = .{},
    iso2022cn_state: iso2022cn.State = .{},

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
            .iso_2022_kr => iso2022kr.encode(&self.iso2022kr_state, codepoint, out),
            .hkscs => hkscs.encode({}, codepoint, out),
            .euc_tw => euctw.encode({}, codepoint, out),
            .iso_2022_cn => iso2022cn.encode(&self.iso2022cn_state, codepoint, out),
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
            .iso_2022_kr => iso2022kr.flush(&self.iso2022kr_state, out),
            .iso_2022_cn => iso2022cn.flush(&self.iso2022cn_state, out),
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
    // Legacy encodings rarely grow the UTF-8 byte length; a tight first
    // allocation usually lets toOwnedSlice reuse the buffer.
    try output.ensureTotalCapacityPrecise(allocator, text.len + 4);
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

fn utf8ToUtf16Into(
    allocator: std.mem.Allocator,
    input: []const u8,
    endian: std.builtin.Endian,
    options: Options,
    output: *std.ArrayList(u8),
) Error!void {
    return switch (endian) {
        .little => utf8ToUtf16IntoEndian(.little, allocator, input, options, output),
        .big => utf8ToUtf16IntoEndian(.big, allocator, input, options, output),
    };
}

fn utf8ToUtf16IntoEndian(
    comptime endian: std.builtin.Endian,
    allocator: std.mem.Allocator,
    input: []const u8,
    options: Options,
    output: *std.ArrayList(u8),
) Error!void {
    try output.ensureUnusedCapacity(allocator, input.len * 2);
    var index: usize = 0;
    while (index < input.len) {
        if (input[index] < 0x80) {
            // Find the ASCII run end a vector at a time, then widen it.
            var end = index;
            while (end + 32 <= input.len) {
                const chunk: @Vector(32, u8) = input[end..][0..32].*;
                if (@reduce(.Or, chunk >= @as(@Vector(32, u8), @splat(0x80)))) {
                    break;
                }
                end += 32;
            }
            while (end < input.len and input[end] < 0x80) end += 1;
            const count = end - index;
            try output.ensureUnusedCapacity(allocator, count * 2);
            const start = output.items.len;
            output.items.len = start + count * 2;
            const destination = output.items[start..];
            // Widen 16 ASCII bytes per step: a u16 vector stores the value
            // and its zero high byte in native order, which is exactly the
            // requested endianness after a byte swap for big-endian output.
            const lanes = 16;
            const Wide = @Vector(lanes, u16);
            var position: usize = 0;
            while (position + lanes <= count) : (position += lanes) {
                const bytes: @Vector(lanes, u8) =
                    input[index + position ..][0..lanes].*;
                var wide: Wide = @intCast(bytes);
                if (endian == .big) wide = @byteSwap(wide);
                destination[position * 2 ..][0 .. lanes * 2].* = @bitCast(wide);
            }
            while (position < count) : (position += 1) {
                if (endian == .little) {
                    destination[position * 2] = input[index + position];
                    destination[position * 2 + 1] = 0;
                } else {
                    destination[position * 2] = 0;
                    destination[position * 2 + 1] = input[index + position];
                }
            }
            index = end;
            continue;
        }
        // Three-byte sequences dominate CJK input; decode a run of them
        // without the general decoder's length ladder or the encoder union.
        if (input[index] >= 0xe0 and input[index] < 0xf0 and
            index + 3 <= input.len)
        {
            var consumed = false;
            // Sixteen sequences per step when a whole block is plain BMP
            // three-byte data.
            while (index + 48 <= input.len) {
                const wide = utf8_vec.decodeThreeByteBlock(input, index) orelse break;
                const start = output.items.len;
                output.items.len = start + 32;
                const stored = if (endian == native_endian)
                    wide
                else
                    @byteSwap(wide);
                output.items[start..][0..32].* = @bitCast(stored);
                index += 48;
                consumed = true;
            }
            while (index + 3 <= input.len and
                input[index] >= 0xe0 and input[index] < 0xf0)
            {
                const first = input[index];
                const second = input[index + 1];
                const third = input[index + 2];
                if (((second | third) & 0xc0) != 0x80) break;
                const codepoint = (@as(u21, first & 0x0f) << 12) |
                    (@as(u21, second & 0x3f) << 6) | (third & 0x3f);
                if (codepoint < 0x800 or
                    (codepoint & 0xf800) == 0xd800) break;
                const start = output.items.len;
                output.items.len = start + 2;
                const value: u16 = @intCast(codepoint);
                const encoded = if (endian == .little) value else @byteSwap(value);
                const dest: *align(1) u16 = @ptrCast(output.items.ptr + start);
                dest.* = encoded;
                index += 3;
                consumed = true;
            }
            if (consumed) continue;
        }
        const decoded = scalar.decodeValidatingPacked(input, index);
        if (decoded == scalar.packed_invalid) {
            // Preserve the replacement contract: a truncated tail consumes
            // the rest, an invalid scalar consumes one byte.
            const length: usize = std.unicode.utf8ByteSequenceLength(
                input[index],
            ) catch 1;
            try appendUtf16Replacement(allocator, output, endian, options);
            if (index + length > input.len) {
                index = input.len;
            } else {
                index += 1;
            }
            continue;
        }
        const codepoint = scalar.packedCodepoint(decoded);
        index += scalar.packedLength(decoded);
        if (codepoint <= 0xFFFF) {
            const start = output.items.len;
            output.items.len = start + 2;
            const value: u16 = @intCast(codepoint);
            const encoded = if (endian == .little) value else @byteSwap(value);
            const dest: *align(1) u16 = @ptrCast(output.items.ptr + start);
            dest.* = encoded;
            continue;
        }
        const value = codepoint - 0x10000;
        const high: u16 = @intCast(0xD800 + (value >> 10));
        const low: u16 = @intCast(0xDC00 + (value & 0x3FF));
        const start = output.items.len;
        output.items.len = start + 4;
        const dest = output.items[start..];
        if (endian == .little) {
            dest[0] = @truncate(high);
            dest[1] = @truncate(high >> 8);
            dest[2] = @truncate(low);
            dest[3] = @truncate(low >> 8);
        } else {
            dest[0] = @truncate(high >> 8);
            dest[1] = @truncate(high);
            dest[2] = @truncate(low >> 8);
            dest[3] = @truncate(low);
        }
    }
}

fn utf8ToUtf16Alloc(
    allocator: std.mem.Allocator,
    input: []const u8,
    endian: std.builtin.Endian,
    options: Options,
) Error![]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try utf8ToUtf16Into(allocator, input, endian, options, &output);
    return output.toOwnedSlice(allocator);
}

/// UTF-16 to UTF-8. ASCII units narrow sixteen at a time and BMP units encode
/// straight into the reserved output region, so neither the generic decoder
/// dispatch nor an intermediate allocation is involved.
fn utf16ToUtf8Into(
    allocator: std.mem.Allocator,
    input: []const u8,
    endian: std.builtin.Endian,
    options: Options,
    output: *std.ArrayList(u8),
) Error!void {
    return switch (endian) {
        .little => utf16ToUtf8IntoEndian(.little, allocator, input, options, output),
        .big => utf16ToUtf8IntoEndian(.big, allocator, input, options, output),
    };
}

fn utf16ToUtf8IntoEndian(
    comptime endian: std.builtin.Endian,
    allocator: std.mem.Allocator,
    input: []const u8,
    options: Options,
    output: *std.ArrayList(u8),
) Error!void {
    // A unit becomes at most three bytes and a surrogate pair four. The
    // largest overrun is an odd trailing byte that turns into a four-byte
    // replacement, which the constant slack covers.
    try output.ensureUnusedCapacity(allocator, input.len * 3 / 2 + 8);
    const spare = output.unusedCapacitySlice();
    var written: usize = 0;
    var replacement: [4]u8 = undefined;
    var replacement_len: usize = 0;
    if (options.on_error == .replace) {
        for ([_]u21{ options.replacement, '?', 0x1A }) |candidate| {
            if (std.unicode.utf8Encode(candidate, replacement[0..4])) |length| {
                replacement_len = length;
                break;
            } else |_| {}
        }
    }
    var index: usize = 0;
    while (index + 2 <= input.len) {
        const unit = std.mem.readInt(u16, input[index..][0..2], endian);
        if (unit < 0x80) {
            // Narrow a run of ASCII units. A u16 vector holds one unit per
            // lane, so the narrowing store is one contiguous byte vector.
            var end = index;
            while (end + 32 <= input.len) {
                var units: @Vector(16, u16) = @bitCast(input[end..][0..32].*);
                if (endian != native_endian) units = @byteSwap(units);
                if (!@reduce(.And, units < @as(@Vector(16, u16), @splat(0x80)))) {
                    break;
                }
                const bytes: @Vector(16, u8) = @intCast(units);
                spare[written..][0..16].* = @bitCast(bytes);
                written += 16;
                end += 32;
            }
            while (end + 2 <= input.len) {
                const next = std.mem.readInt(u16, input[end..][0..2], endian);
                if (next >= 0x80) break;
                spare[written] = @intCast(next);
                written += 1;
                end += 2;
            }
            index = end;
            continue;
        }
        // BMP units at or above U+0800 encode to three bytes; pack sixteen
        // at a time when none is a surrogate.
        if (unit >= 0x800 and (unit < 0xD800 or unit > 0xDFFF)) {
            var consumed = false;
            while (index + 32 <= input.len) {
                var units: @Vector(16, u16) = @bitCast(input[index..][0..32].*);
                if (endian != native_endian) units = @byteSwap(units);
                if (!utf8_vec.bmpThreeByteLanes(u16, units)) break;
                written = utf8_vec.storeThreeByteScalars(
                    u16,
                    spare,
                    written,
                    units,
                );
                index += 32;
                consumed = true;
            }
            if (consumed) continue;
        }
        index += 2;
        var codepoint: u21 = 0;
        var status: enum { ok, malformed, incomplete } = .ok;
        if (unit >= 0xD800 and unit <= 0xDBFF) {
            if (index + 2 > input.len) {
                status = .incomplete;
            } else {
                const low = std.mem.readInt(u16, input[index..][0..2], endian);
                if (low < 0xDC00 or low > 0xDFFF) {
                    status = .malformed;
                } else {
                    index += 2;
                    codepoint = 0x10000 +
                        (@as(u21, unit - 0xD800) << 10) + (low - 0xDC00);
                }
            }
        } else if (unit >= 0xDC00 and unit <= 0xDFFF) {
            status = .malformed;
        } else {
            codepoint = unit;
        }
        switch (status) {
            .ok => written = utf8_vec.writeScalar(spare, written, codepoint),
            .malformed => if (utf8_vec.writeError(
                options,
                spare,
                &written,
                replacement[0..replacement_len],
            )) {
                output.items.len += written;
                return error.InvalidSequence;
            },
            .incomplete => {
                if (utf8_vec.writeError(
                    options,
                    spare,
                    &written,
                    replacement[0..replacement_len],
                )) {
                    output.items.len += written;
                    return error.InvalidSequence;
                }
                index = input.len;
                break;
            },
        }
    }
    if (index < input.len) {
        // An odd trailing byte cannot form a unit.
        if (utf8_vec.writeError(
            options,
            spare,
            &written,
            replacement[0..replacement_len],
        )) {
            output.items.len += written;
            return error.InvalidSequence;
        }
    }
    output.items.len += written;
}

fn utf16ToUtf8Alloc(
    allocator: std.mem.Allocator,
    input: []const u8,
    endian: std.builtin.Endian,
    options: Options,
) Error![]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try utf16ToUtf8Into(allocator, input, endian, options, &output);
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
        var buffer: [16]u8 = undefined;
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
    comptime encode: fn (u21, *[4]u8) u8,
    allocator: std.mem.Allocator,
    input: []const u8,
) error{OutOfMemory}!?[]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try output.ensureTotalCapacityPrecise(allocator, input.len + 8);
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
            // Two adjacent three-byte sequences cover CJK prose, which
            // dominates DBCS conversion. Validate and decode them together so
            // the bounds, lead, and continuation tests amortize.
            if (first >= 0xE0 and first < 0xF0 and index + 6 <= input.len) {
                const fourth = input[index + 3];
                if (fourth >= 0xE0 and fourth < 0xF0) {
                    const second = input[index + 1];
                    const third = input[index + 2];
                    const fifth = input[index + 4];
                    const sixth = input[index + 5];
                    if (((second | third | fifth | sixth) & 0xC0) == 0x80) {
                        const first_value =
                            (@as(u21, first & 0x0F) << 12) |
                            (@as(u21, second & 0x3F) << 6) |
                            (third & 0x3F);
                        const second_value =
                            (@as(u21, fourth & 0x0F) << 12) |
                            (@as(u21, fifth & 0x3F) << 6) |
                            (sixth & 0x3F);
                        if (first_value >= 0x800 and second_value >= 0x800 and
                            (first_value & 0xF800) != 0xD800 and
                            (second_value & 0xF800) != 0xD800)
                        {
                            const first_length = @call(.always_inline, encode, .{
                                first_value,
                                spare[written..][0..4],
                            });
                            if (first_length != 0) {
                                const second_length = @call(.always_inline, encode, .{
                                    second_value,
                                    spare[written + first_length ..][0..4],
                                });
                                if (second_length != 0) {
                                    written += first_length + second_length;
                                    index += 6;
                                    continue;
                                }
                            }
                            break :blk false;
                        }
                    }
                }
            }
            // Each branch yields an immutable codepoint so the value stays in
            // a register instead of a `var` stack slot.
            const codepoint: u21 = decode: {
                if (first < 0xE0) {
                    if (first < 0xC2 or index + 2 > input.len) {
                        break :blk false;
                    }
                    const second = input[index + 1];
                    if (second < 0x80 or second > 0xBF) break :blk false;
                    index += 2;
                    break :decode (@as(u21, first & 0x1F) << 6) |
                        (second & 0x3F);
                }
                if (first < 0xF0) {
                    if (index + 3 > input.len) break :blk false;
                    const second = input[index + 1];
                    const third = input[index + 2];
                    // One OR covers both continuation checks: the pair is
                    // valid only when both bytes have the 10xxxxxx shape.
                    if (((second | third) & 0xC0) != 0x80) break :blk false;
                    const value = (@as(u21, first & 0x0F) << 12) |
                        (@as(u21, second & 0x3F) << 6) |
                        (third & 0x3F);
                    if (value < 0x800 or
                        (value >= 0xD800 and value <= 0xDFFF))
                    {
                        break :blk false;
                    }
                    index += 3;
                    break :decode value;
                }
                break :blk false;
            };
            // The reserved slack always leaves four writable bytes here, so
            // the encoder stores straight into the output and the length
            // switch and its byte copies disappear.
            const length = @call(.always_inline, encode, .{
                codepoint,
                spare[written..][0..4],
            });
            if (length == 0) break :blk false;
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
    // Single-byte DBCS values can expand to three UTF-8 bytes (GBK 0x80 is
    // U+20AC, Shift_JIS 0xA0 is U+F8F0), so reserve three bytes per input.
    try output.ensureTotalCapacity(allocator, input.len * 3 + 8);
    const spare = output.unusedCapacitySlice();
    var index: usize = 0;
    var written: usize = 0;
    while (index < input.len) {
        switch (@call(.always_inline, decode, .{ input, &index })) {
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

/// Fused GBK-to-UTF-8 fast path. The generic DBCS converter dispatches
/// through a decoder function and a result union per scalar; GBK prose is
/// dominated by two-byte sequences, so decoding inline avoids both.
fn convertGbkToUtf8Fast(
    allocator: std.mem.Allocator,
    input: []const u8,
) error{OutOfMemory}!?[]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    // 0x80 decodes to U+20AC, so one input byte can become three UTF-8 bytes.
    try output.ensureTotalCapacity(allocator, input.len * 3 + 8);
    const spare = output.unusedCapacitySlice();
    var index: usize = 0;
    var written: usize = 0;
    while (index < input.len) {
        const codepoint = cjk.gbkNextFast(input, &index) orelse {
            output.deinit(allocator);
            return null;
        };
        if (codepoint < 0x80) {
            spare[written] = @intCast(codepoint);
            written += 1;
            continue;
        }
        if (codepoint < 0x800) {
            spare[written] = @intCast(0xC0 | (codepoint >> 6));
            spare[written + 1] = @intCast(0x80 | (codepoint & 0x3F));
            written += 2;
            continue;
        }
        // GBK prose pairs two-byte syllables, so the next scalar is usually
        // another three-byte UTF-8 sequence. Encode both into one 64-bit
        // store; the reserved slack keeps the two extra bytes writable.
        if (index < input.len) {
            const retry_at = index;
            if (cjk.gbkNextFast(input, &index)) |second| {
                if (second >= 0x800 and second < 0x10000) {
                    const bytes: u64 =
                        (@as(u64, 0xE0 | (codepoint >> 12))) |
                        (@as(u64, 0x80 | ((codepoint >> 6) & 0x3F)) << 8) |
                        (@as(u64, 0x80 | (codepoint & 0x3F)) << 16) |
                        (@as(u64, 0xE0 | (second >> 12)) << 24) |
                        (@as(u64, 0x80 | ((second >> 6) & 0x3F)) << 32) |
                        (@as(u64, 0x80 | (second & 0x3F)) << 40);
                    std.mem.writeInt(
                        u64,
                        spare[written..][0..8],
                        bytes,
                        .little,
                    );
                    written += 6;
                    continue;
                }
                index = retry_at;
            } else {
                output.deinit(allocator);
                return null;
            }
        }
        spare[written] = @intCast(0xE0 | (codepoint >> 12));
        spare[written + 1] = @intCast(
            0x80 | ((codepoint >> 6) & 0x3F),
        );
        spare[written + 2] = @intCast(0x80 | (codepoint & 0x3F));
        written += 3;
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
            if (try convertGbkToUtf8Fast(allocator, input)) |result| {
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
        switch (@call(.always_inline, decode, .{ input, &index })) {
            .end => break,
            .codepoint => |codepoint| {
                var buffer: [16]u8 = undefined;
                switch (@call(.always_inline, encode, .{ codepoint, &buffer })) {
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

/// Convert `input` from one encoding to another, appending to `output`.
pub fn convertInto(
    allocator: std.mem.Allocator,
    input: []const u8,
    from: Encoding,
    to: Encoding,
    output: *std.ArrayList(u8),
    options: Options,
) Error!void {
    if (asciiCompatible(from) and asciiCompatible(to) and isAscii(input)) {
        try output.appendSlice(allocator, input);
        return;
    }
    if (to == .utf16_le or to == .utf16_be) {
        if (try dbcsToUtf16IntoFast(
            allocator,
            input,
            from,
            if (to == .utf16_le) .little else .big,
            output,
        )) return;
    }
    if (from == .utf16_le or from == .utf16_be) {
        if (try utf16ToDbcsIntoFast(
            allocator,
            input,
            to,
            if (from == .utf16_le) .little else .big,
            output,
        )) return;
    }
    if (to == .utf8) {
        if (singleByteKind(from)) |kind| {
            return single_byte.decodeInto(allocator, input, kind, options, output);
        }
    }
    if (from == .utf8) {
        if (singleByteEncodeKind(to)) |kind| {
            return single_byte.encodeInto(allocator, input, kind, options, output);
        }
    }
    if (from == .utf8 and (to == .utf16_le or to == .utf16_be)) {
        return utf8ToUtf16Into(
            allocator,
            input,
            if (to == .utf16_le) .little else .big,
            options,
            output,
        );
    }
    if ((from == .utf16_le or from == .utf16_be) and to == .utf8) {
        return utf16ToUtf8Into(
            allocator,
            input,
            if (from == .utf16_le) .little else .big,
            options,
            output,
        );
    }
    if ((from == .utf16_le or from == .utf16_be) and
        (to == .utf32_le or to == .utf32_be))
    {
        return utf32.utf16ToUtf32Into(
            allocator,
            input,
            if (from == .utf16_le) .little else .big,
            if (to == .utf32_le) .little else .big,
            options,
            output,
        );
    }
    if ((from == .utf32_le or from == .utf32_be) and
        (to == .utf16_le or to == .utf16_be))
    {
        return utf32.utf32ToUtf16Into(
            allocator,
            input,
            if (from == .utf32_le) .little else .big,
            if (to == .utf16_le) .little else .big,
            options,
            output,
        );
    }
    if (from == .utf8 and (to == .utf32_le or to == .utf32_be)) {
        return utf32.utf8ToUtf32Into(
            allocator,
            input,
            if (to == .utf32_le) .little else .big,
            options,
            output,
        );
    }
    if ((from == .utf32_le or from == .utf32_be) and to == .utf8) {
        return utf32.utf32ToUtf8Into(
            allocator,
            input,
            if (from == .utf32_le) .little else .big,
            options,
            output,
        );
    }
    const converted = try convertAlloc(allocator, input, from, to, options);
    defer allocator.free(converted);
    try output.appendSlice(allocator, converted);
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
    if (to == .utf16_le or to == .utf16_be) {
        var fast = std.ArrayList(u8).empty;
        errdefer fast.deinit(allocator);
        if (try dbcsToUtf16IntoFast(
            allocator,
            input,
            from,
            if (to == .utf16_le) .little else .big,
            &fast,
        )) {
            return fast.toOwnedSlice(allocator);
        }
        fast.deinit(allocator);
    }
    if (from == .utf16_le or from == .utf16_be) {
        var fast = std.ArrayList(u8).empty;
        errdefer fast.deinit(allocator);
        if (try utf16ToDbcsIntoFast(
            allocator,
            input,
            to,
            if (from == .utf16_le) .little else .big,
            &fast,
        )) {
            return fast.toOwnedSlice(allocator);
        }
        fast.deinit(allocator);
    }
    if (to == .utf8) {
        if (singleByteKind(from)) |kind| {
            return single_byte.decodeAlloc(allocator, input, kind, options);
        }
    }
    if (from == .utf8) {
        if (singleByteEncodeKind(to)) |kind| {
            return single_byte.encodeAlloc(allocator, input, kind, options);
        }
    }
    if (from == .utf8 and (to == .utf16_le or to == .utf16_be)) {
        return utf8ToUtf16Alloc(
            allocator,
            input,
            if (to == .utf16_le) .little else .big,
            options,
        );
    }
    if ((from == .utf16_le or from == .utf16_be) and to == .utf8) {
        return utf16ToUtf8Alloc(
            allocator,
            input,
            if (from == .utf16_le) .little else .big,
            options,
        );
    }
    if ((from == .utf16_le or from == .utf16_be) and
        (to == .utf32_le or to == .utf32_be))
    {
        return utf32.utf16ToUtf32Alloc(
            allocator,
            input,
            if (from == .utf16_le) .little else .big,
            if (to == .utf32_le) .little else .big,
            options,
        );
    }
    if ((from == .utf32_le or from == .utf32_be) and
        (to == .utf16_le or to == .utf16_be))
    {
        return utf32.utf32ToUtf16Alloc(
            allocator,
            input,
            if (from == .utf32_le) .little else .big,
            if (to == .utf16_le) .little else .big,
            options,
        );
    }
    if (from == .utf8 and (to == .utf32_le or to == .utf32_be)) {
        return utf32.utf8ToUtf32Alloc(
            allocator,
            input,
            if (to == .utf32_le) .little else .big,
            options,
        );
    }
    if ((from == .utf32_le or from == .utf32_be) and to == .utf8) {
        return utf32.utf32ToUtf8Alloc(
            allocator,
            input,
            if (from == .utf32_le) .little else .big,
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
        .gbk, .gb18030, .big5, .hkscs, .euc_tw, .euc_jp, .shift_jis, .euc_kr => true,
        else => singleByteIndex(encoding) != null,
    };
}

/// Resolve a single-byte source to its direct decoder, if one exists.
fn singleByteKind(encoding: Encoding) ?single_byte.Kind {
    return switch (encoding) {
        .ascii => .ascii_identity,
        .latin1 => .latin1_identity,
        .x_user_defined => .user_defined,
        else => if (ibmPageIndex(encoding)) |page|
            .{ .ibm_page = page }
        else if (singleByteIndex(encoding)) |table_index|
            .{ .table = table_index }
        else
            null,
    };
}

/// Resolve a single-byte target. IBM pages keep the generic reverse scan.
fn singleByteEncodeKind(encoding: Encoding) ?single_byte.Kind {
    return switch (encoding) {
        .ascii => .ascii_identity,
        .latin1 => .latin1_identity,
        .x_user_defined => .user_defined,
        else => if (singleByteIndex(encoding)) |table_index|
            .{ .table = table_index }
        else
            null,
    };
}

/// Direct DBCS to UTF-16 for valid input; false means the generic converter
/// must apply the error mode.
fn dbcsToUtf16IntoFast(
    allocator: std.mem.Allocator,
    input: []const u8,
    from: Encoding,
    endian: std.builtin.Endian,
    output: *std.ArrayList(u8),
) error{OutOfMemory}!bool {
    return switch (endian) {
        .little => dbcsToUtf16IntoFastEndian(.little, allocator, input, from, output),
        .big => dbcsToUtf16IntoFastEndian(.big, allocator, input, from, output),
    };
}

/// Fused GBK-to-UTF-16 fast path. The generic converter dispatches through a
/// decoder function and a result union per scalar; GBK prose is dominated by
/// two-byte syllables, so decoding inline and pairing adjacent units avoids
/// both.
fn gbkToUtf16Into(
    comptime endian: std.builtin.Endian,
    allocator: std.mem.Allocator,
    input: []const u8,
    output: *std.ArrayList(u8),
) error{OutOfMemory}!bool {
    // Every GBK scalar is BMP, so one unit per input byte bounds the output.
    try output.ensureUnusedCapacity(allocator, input.len * 2 + 8);
    const spare = output.unusedCapacitySlice();
    var index: usize = 0;
    var written: usize = 0;
    while (index < input.len) {
        const codepoint = cjk.gbkNextFast(input, &index) orelse return false;
        if (codepoint >= 0xD800 and codepoint <= 0xDFFF) return false;
        if (index < input.len) {
            const retry_at = index;
            if (cjk.gbkNextFast(input, &index)) |second| {
                if (second < 0xD800 or second > 0xDFFF) {
                    const units: u32 = if (endian == .little)
                        (@as(u32, @intCast(codepoint)) |
                            (@as(u32, @intCast(second)) << 16))
                    else
                        ((@as(u32, @intCast(codepoint)) << 16) |
                            @as(u32, @intCast(second)));
                    std.mem.writeInt(u32, spare[written..][0..4], units, endian);
                    written += 4;
                    continue;
                }
                index = retry_at;
            } else {
                return false;
            }
        }
        std.mem.writeInt(
            u16,
            spare[written..][0..2],
            @intCast(codepoint),
            endian,
        );
        written += 2;
    }
    output.items.len += written;
    return true;
}

fn dbcsToUtf16IntoFastEndian(
    comptime endian: std.builtin.Endian,
    allocator: std.mem.Allocator,
    input: []const u8,
    from: Encoding,
    output: *std.ArrayList(u8),
) error{OutOfMemory}!bool {
    return switch (from) {
        .gbk => gbkToUtf16Into(endian, allocator, input, output),
        .gb18030 => dbcs_utf16.dbcsToUtf16Into(cjk.gb18030Next, endian, allocator, input, output),
        .big5 => dbcs_utf16.dbcsToUtf16Into(cjk.big5Next, endian, allocator, input, output),
        .euc_jp => dbcs_utf16.dbcsToUtf16Into(cjk.eucJpNext, endian, allocator, input, output),
        .shift_jis => dbcs_utf16.dbcsToUtf16Into(cjk.shiftJisNext, endian, allocator, input, output),
        .euc_kr => dbcs_utf16.dbcsToUtf16Into(cjk.eucKrNext, endian, allocator, input, output),
        else => false,
    };
}

fn utf16ToDbcsIntoFast(
    allocator: std.mem.Allocator,
    input: []const u8,
    to: Encoding,
    endian: std.builtin.Endian,
    output: *std.ArrayList(u8),
) error{OutOfMemory}!bool {
    return switch (endian) {
        .little => utf16ToDbcsIntoFastEndian(.little, allocator, input, to, output),
        .big => utf16ToDbcsIntoFastEndian(.big, allocator, input, to, output),
    };
}

/// Fused UTF-16-to-GBK fast path. The generic converter encodes into a stack
/// buffer and copies through a length switch per unit; GBK prose is BMP and
/// mostly ASCII or two-byte codes, so encode straight into the output and
/// pair adjacent ASCII units.
fn gbkFromUtf16Into(
    comptime endian: std.builtin.Endian,
    allocator: std.mem.Allocator,
    input: []const u8,
    output: *std.ArrayList(u8),
) error{OutOfMemory}!bool {
    // A BMP unit becomes at most two GBK bytes.
    try output.ensureUnusedCapacity(allocator, input.len + 8);
    const spare = output.unusedCapacitySlice();
    var index: usize = 0;
    var written: usize = 0;
    while (index + 2 <= input.len) {
        const unit = std.mem.readInt(u16, input[index..][0..2], endian);
        index += 2;
        if (unit < 0x80) {
            if (index + 2 <= input.len) {
                const next = std.mem.readInt(u16, input[index..][0..2], endian);
                if (next < 0x80) {
                    const pair: u16 = unit | (next << 8);
                    std.mem.writeInt(u16, spare[written..][0..2], pair, .little);
                    written += 2;
                    index += 2;
                    continue;
                }
            }
            spare[written] = @intCast(unit);
            written += 1;
            continue;
        }
        // GBK has no supplementary mappings, so any surrogate is unmappable.
        if (unit >= 0xD800 and unit <= 0xDFFF) return false;
        const length = cjk.gbkEncodeFast(unit, spare[written..][0..4]);
        if (length == 0) return false;
        written += length;
    }
    if (index < input.len) return false;
    output.items.len += written;
    return true;
}

fn utf16ToDbcsIntoFastEndian(
    comptime endian: std.builtin.Endian,
    allocator: std.mem.Allocator,
    input: []const u8,
    to: Encoding,
    output: *std.ArrayList(u8),
) error{OutOfMemory}!bool {
    return switch (to) {
        .gbk => gbkFromUtf16Into(endian, allocator, input, output),
        .gb18030 => dbcs_utf16.utf16ToDbcsInto(cjk.gbkEncodeFast, endian, allocator, input, output),
        .big5 => dbcs_utf16.utf16ToDbcsInto(cjk.big5EncodeFast, endian, allocator, input, output),
        .euc_jp => dbcs_utf16.utf16ToDbcsInto(cjk.eucJpEncodeFast, endian, allocator, input, output),
        .shift_jis => dbcs_utf16.utf16ToDbcsInto(cjk.shiftJisEncodeFast, endian, allocator, input, output),
        .euc_kr => dbcs_utf16.utf16ToDbcsInto(cjk.eucKrEncodeFast, endian, allocator, input, output),
        else => false,
    };
}

fn isAscii(input: []const u8) bool {
    var index: usize = 0;
    while (index + 32 <= input.len) : (index += 32) {
        const chunk: @Vector(32, u8) = input[index..][0..32].*;
        if (@reduce(.Or, chunk >= @as(@Vector(32, u8), @splat(0x80)))) {
            return false;
        }
    }
    while (index < input.len) : (index += 1) {
        if (input[index] >= 0x80) return false;
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
    var buffer: [16]u8 = undefined;
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
        var buffer: [16]u8 = undefined;
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
    try testing.expectEqual(Encoding.hkscs, fromLabel("Big5-HKSCS").?);
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

test "UTF-8 three-byte runs convert with and without malformed input" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    // More than one 48-byte vector block of BMP three-byte sequences, plus
    // an ASCII tail so the scalar paths still run.
    const text = "\u{4F60}" ** 20 ++ "A\u{00E9}";
    inline for ([_]Encoding{ .utf16_le, .utf16_be }) |encoding| {
        const encoded = try encodeAlloc(allocator, text, encoding, .{});
        defer allocator.free(encoded);
        const decoded = try decodeAlloc(allocator, encoded, encoding, .{});
        defer allocator.free(decoded);
        try testing.expectEqualStrings(text, decoded);
    }

    // A full vector block whose last sequence is malformed must fall back to
    // the scalar decoder for the whole run.
    const malformed = [_]struct { tail: [3]u8, expected: []const u8 }{
        // Overlong U+0000.
        .{ .tail = .{ 0xE0, 0x80, 0x80 }, .expected = "\u{FFFD}\u{FFFD}\u{FFFD}" },
        // UTF-16 surrogate U+D800.
        .{ .tail = .{ 0xED, 0xA0, 0x80 }, .expected = "\u{FFFD}\u{FFFD}\u{FFFD}" },
        // Broken continuation byte.
        .{ .tail = .{ 0xE4, 0x41, 0x42 }, .expected = "\u{FFFD}AB" },
    };
    for (malformed) |case| {
        var input: [48]u8 = undefined;
        for (0..15) |index| {
            input[index * 3] = 0xE4;
            input[index * 3 + 1] = 0xBD;
            input[index * 3 + 2] = 0xA0;
        }
        @memcpy(input[45..], &case.tail);
        const decoded = try decodeAlloc(allocator, &input, .utf8, .{});
        defer allocator.free(decoded);
        var expected: [15 * 3 + 16]u8 = undefined;
        var expected_len: usize = 0;
        for (0..15) |_| {
            @memcpy(expected[expected_len..][0..3], "\u{4F60}");
            expected_len += 3;
        }
        @memcpy(expected[expected_len..][0..case.expected.len], case.expected);
        expected_len += case.expected.len;
        try testing.expectEqualStrings(expected[0..expected_len], decoded);
    }
}

test "UTF-16 to UTF-8 conversion" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const text = "abcdefghijklmnopqrstuvwxyz0123456789" ** 2 ++
        "A\u{00E9}\u{4E16}\u{1F600}" ** 4 ++ "\u{4F60}" ** 20;
    inline for ([_]Encoding{ .utf16_le, .utf16_be }) |encoding| {
        const encoded = try encodeAlloc(allocator, text, encoding, .{});
        defer allocator.free(encoded);
        const decoded = try decodeAlloc(allocator, encoded, encoding, .{});
        defer allocator.free(decoded);
        try testing.expectEqualStrings(text, decoded);

        // convertInto appends to the caller's existing contents.
        var output = std.ArrayList(u8).empty;
        defer output.deinit(allocator);
        try output.appendSlice(allocator, "prefix:");
        try convertInto(allocator, encoded, encoding, .utf8, &output, .{});
        try testing.expectEqualStrings("prefix:" ++ text, output.items);
    }

    const malformed = [_]struct {
        input: []const u8,
        replaced: []const u8,
        ignored: []const u8,
    }{
        // Lone low surrogate.
        .{ .input = &.{ 0x00, 0xDC }, .replaced = "\u{FFFD}", .ignored = "" },
        // High surrogate without its pair; the next unit still decodes.
        .{
            .input = &.{ 0x00, 0xD8, 0x41, 0x00 },
            .replaced = "\u{FFFD}A",
            .ignored = "A",
        },
        // High surrogate at the end of the input.
        .{ .input = &.{ 0x00, 0xD8 }, .replaced = "\u{FFFD}", .ignored = "" },
        // Odd trailing byte.
        .{
            .input = &.{ 0x41, 0x00, 0x00 },
            .replaced = "A\u{FFFD}",
            .ignored = "A",
        },
    };
    for (malformed) |case| {
        const replaced = try convertAlloc(allocator, case.input, .utf16_le, .utf8, .{});
        defer allocator.free(replaced);
        try testing.expectEqualStrings(case.replaced, replaced);
        const ignored = try convertAlloc(
            allocator,
            case.input,
            .utf16_le,
            .utf8,
            .{ .on_error = .ignore },
        );
        defer allocator.free(ignored);
        try testing.expectEqualStrings(case.ignored, ignored);
        try testing.expectError(
            error.InvalidSequence,
            convertAlloc(allocator, case.input, .utf16_le, .utf8, .{ .on_error = .strict }),
        );
    }

    const custom = try convertAlloc(
        allocator,
        &.{ 0x00, 0xDC },
        .utf16_le,
        .utf8,
        .{ .replacement = 'X' },
    );
    defer allocator.free(custom);
    try testing.expectEqualStrings("X", custom);

    // Big-endian malformed input follows the same rules.
    const be = try convertAlloc(allocator, &.{ 0xD8, 0x00 }, .utf16_be, .utf8, .{});
    defer allocator.free(be);
    try testing.expectEqualStrings("\u{FFFD}", be);
}

test "UTF-8 and UTF-32 conversion" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const text = "abcdefghijklmnopqrstuvwxyz0123456789" ** 2 ++
        "A\u{00E9}\u{4E16}\u{1F600}" ** 4 ++ "\u{4F60}" ** 20;
    inline for ([_]Encoding{ .utf32_le, .utf32_be }) |encoding| {
        const encoded = try encodeAlloc(allocator, text, encoding, .{});
        defer allocator.free(encoded);
        const decoded = try decodeAlloc(allocator, encoded, encoding, .{});
        defer allocator.free(decoded);
        try testing.expectEqualStrings(text, decoded);

        var output = std.ArrayList(u8).empty;
        defer output.deinit(allocator);
        try output.appendSlice(allocator, "prefix:");
        try convertInto(allocator, encoded, encoding, .utf8, &output, .{});
        try testing.expectEqualStrings("prefix:" ++ text, output.items);
    }

    // Malformed UTF-8 becomes U+FFFD in the target scalar width.
    const malformed_utf8 = [_]struct { input: []const u8, count: usize }{
        .{ .input = &.{ 0xE0, 0x80, 0x80 }, .count = 3 },
        .{ .input = &.{ 0xED, 0xA0, 0x80 }, .count = 3 },
        .{ .input = &.{ 0xF0, 0x9F }, .count = 1 },
    };
    for (malformed_utf8) |case| {
        const converted = try convertAlloc(
            allocator,
            case.input,
            .utf8,
            .utf32_le,
            .{},
        );
        defer allocator.free(converted);
        try testing.expectEqual(case.count * 4, converted.len);
        for (0..case.count) |index| {
            try testing.expectEqual(
                @as(u32, 0xFFFD),
                std.mem.readInt(u32, converted[index * 4 ..][0..4], .little),
            );
        }
        try testing.expectError(
            error.InvalidSequence,
            convertAlloc(allocator, case.input, .utf8, .utf32_le, .{ .on_error = .strict }),
        );
    }

    const malformed_utf32 = [_]struct {
        input: []const u8,
        replaced: []const u8,
        ignored: []const u8,
    }{
        // UTF-16 surrogate.
        .{
            .input = &.{ 0x00, 0xD8, 0x00, 0x00 },
            .replaced = "\u{FFFD}",
            .ignored = "",
        },
        // Above U+10FFFF.
        .{
            .input = &.{ 0x00, 0x00, 0x11, 0x00 },
            .replaced = "\u{FFFD}",
            .ignored = "",
        },
        // Partial unit at the end.
        .{
            .input = &.{ 0x41, 0x00, 0x00, 0x00, 0x42 },
            .replaced = "A\u{FFFD}",
            .ignored = "A",
        },
    };
    for (malformed_utf32) |case| {
        const replaced = try convertAlloc(allocator, case.input, .utf32_le, .utf8, .{});
        defer allocator.free(replaced);
        try testing.expectEqualStrings(case.replaced, replaced);
        const ignored = try convertAlloc(
            allocator,
            case.input,
            .utf32_le,
            .utf8,
            .{ .on_error = .ignore },
        );
        defer allocator.free(ignored);
        try testing.expectEqualStrings(case.ignored, ignored);
        try testing.expectError(
            error.InvalidSequence,
            convertAlloc(allocator, case.input, .utf32_le, .utf8, .{ .on_error = .strict }),
        );
    }

    const custom = try convertAlloc(
        allocator,
        &.{ 0x00, 0xD8, 0x00, 0x00 },
        .utf32_le,
        .utf8,
        .{ .replacement = 'X' },
    );
    defer allocator.free(custom);
    try testing.expectEqualStrings("X", custom);

    // Big-endian malformed input follows the same rules.
    const be = try convertAlloc(
        allocator,
        &.{ 0x00, 0x00, 0xD8, 0x00 },
        .utf32_be,
        .utf8,
        .{},
    );
    defer allocator.free(be);
    try testing.expectEqualStrings("\u{FFFD}", be);
}

test "UTF-16 and UTF-32 conversion" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const text = "abcdefghijklmnopqrstuvwxyz0123456789" ** 2 ++
        "A\u{00E9}\u{4E16}\u{1F600}" ** 4 ++ "\u{4F60}" ** 20;
    inline for ([_]Encoding{ .utf16_le, .utf16_be }) |utf16_encoding| {
        inline for ([_]Encoding{ .utf32_le, .utf32_be }) |utf32_encoding| {
            const utf16_bytes = try encodeAlloc(allocator, text, utf16_encoding, .{});
            defer allocator.free(utf16_bytes);
            const utf32_bytes = try convertAlloc(
                allocator,
                utf16_bytes,
                utf16_encoding,
                utf32_encoding,
                .{},
            );
            defer allocator.free(utf32_bytes);
            const back = try convertAlloc(
                allocator,
                utf32_bytes,
                utf32_encoding,
                utf16_encoding,
                .{},
            );
            defer allocator.free(back);
            try testing.expectEqualSlices(u8, utf16_bytes, back);

            const utf8_bytes = try convertAlloc(
                allocator,
                utf32_bytes,
                utf32_encoding,
                .utf8,
                .{},
            );
            defer allocator.free(utf8_bytes);
            try testing.expectEqualStrings(text, utf8_bytes);

            var output = std.ArrayList(u8).empty;
            defer output.deinit(allocator);
            try output.appendSlice(allocator, "prefix:");
            try convertInto(
                allocator,
                utf16_bytes,
                utf16_encoding,
                utf32_encoding,
                &output,
                .{},
            );
            try testing.expectEqualSlices(u8, utf32_bytes, output.items[7..]);
        }
    }

    // A lone surrogate becomes the target's replacement scalar.
    const lone = try convertAlloc(
        allocator,
        &.{ 0x00, 0xD8 },
        .utf16_le,
        .utf32_le,
        .{},
    );
    defer allocator.free(lone);
    try testing.expectEqual(@as(usize, 4), lone.len);
    try testing.expectEqual(
        @as(u32, 0xFFFD),
        std.mem.readInt(u32, lone[0..4], .little),
    );
    try testing.expectError(
        error.InvalidSequence,
        convertAlloc(allocator, &.{ 0x00, 0xD8 }, .utf16_le, .utf32_le, .{ .on_error = .strict }),
    );

    // An invalid UTF-32 scalar becomes U+FFFD in UTF-16.
    const bad = try convertAlloc(
        allocator,
        &.{ 0x00, 0x00, 0x11, 0x00 },
        .utf32_le,
        .utf16_le,
        .{},
    );
    defer allocator.free(bad);
    try testing.expectEqualSlices(u8, &.{ 0xFD, 0xFF }, bad);

    // Supplementary scalars round-trip through a surrogate pair.
    const emoji = "\u{1F600}";
    const emoji32 = try encodeAlloc(allocator, emoji, .utf32_le, .{});
    defer allocator.free(emoji32);
    const emoji16 = try convertAlloc(allocator, emoji32, .utf32_le, .utf16_le, .{});
    defer allocator.free(emoji16);
    const emoji_utf8 = try convertAlloc(allocator, emoji16, .utf16_le, .utf8, .{});
    defer allocator.free(emoji_utf8);
    try testing.expectEqualStrings(emoji, emoji_utf8);
}

test "direct single-byte conversion" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    // Latin-1 is an identity mapping in both directions.
    const latin1 = try convertAlloc(allocator, "A\u{00E9}\u{00FF}", .utf8, .latin1, .{});
    defer allocator.free(latin1);
    try testing.expectEqualSlices(u8, &.{ 0x41, 0xE9, 0xFF }, latin1);
    const latin1_back = try convertAlloc(allocator, latin1, .latin1, .utf8, .{});
    defer allocator.free(latin1_back);
    try testing.expectEqualStrings("A\u{00E9}\u{00FF}", latin1_back);

    // x-user-defined maps 0x80..0xFF to U+F780..U+F7FF.
    const user = try convertAlloc(
        allocator,
        &.{ 0x41, 0x80, 0xFF },
        .x_user_defined,
        .utf8,
        .{},
    );
    defer allocator.free(user);
    try testing.expectEqualStrings("A\u{F780}\u{F7FF}", user);
    const user_back = try convertAlloc(allocator, user, .utf8, .x_user_defined, .{});
    defer allocator.free(user_back);
    try testing.expectEqualSlices(u8, &.{ 0x41, 0x80, 0xFF }, user_back);

    // ASCII rejects high bytes on decode and non-ASCII scalars on encode.
    const ascii_replaced = try convertAlloc(
        allocator,
        &.{ 0x41, 0xE9, 0x42 },
        .ascii,
        .utf8,
        .{},
    );
    defer allocator.free(ascii_replaced);
    try testing.expectEqualStrings("A\u{FFFD}B", ascii_replaced);
    try testing.expectError(
        error.InvalidSequence,
        convertAlloc(allocator, &.{0xE9}, .ascii, .utf8, .{ .on_error = .strict }),
    );
    const unmappable = try convertAlloc(allocator, "A\u{4E16}B", .utf8, .ascii, .{});
    defer allocator.free(unmappable);
    try testing.expectEqualStrings("A?B", unmappable);
    try testing.expectError(
        error.UnmappableCharacter,
        convertAlloc(allocator, "\u{4E16}", .utf8, .ascii, .{ .on_error = .strict }),
    );

    // IBM pages decode through their full 256-byte table.
    const ibm = try convertAlloc(allocator, &.{ 0x80, 0x81 }, .ibm866, .utf8, .{});
    defer allocator.free(ibm);
    try testing.expectEqualStrings("\u{0410}\u{0411}", ibm);

    // convertInto appends to the caller's buffer.
    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);
    try output.appendSlice(allocator, "p:");
    try convertInto(allocator, &.{0xE9}, .windows_1252, .utf8, &output, .{});
    try testing.expectEqualStrings("p:\u{00E9}", output.items);
}

test "DBCS and UTF-16 conversion" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const cases = [_]struct { encoding: Encoding, text: []const u8 }{
        .{ .encoding = .gbk, .text = "\u{4F60}\u{597D}\u{FF0C}\u{4E16}\u{754C}\u{FF01}\u{4E2D}\u{6587}\u{7F16}\u{7801}\u{8F6C}\u{6362}\u{57FA}\u{51C6}\u{6D4B}\u{8BD5}\u{3002}" ** 4 },
        .{ .encoding = .big5, .text = "\u{4F60}\u{597D}\u{FF0C}\u{4E16}\u{754C}\u{FF01}\u{4E2D}\u{6587}\u{7DE8}\u{78BC}\u{8F49}\u{63DB}\u{57FA}\u{6E96}\u{6E2C}\u{8A66}\u{3002}" ** 4 },
        .{ .encoding = .shift_jis, .text = "\u{3053}\u{3093}\u{306B}\u{3061}\u{306F}\u{4E16}\u{754C}\u{3002}\u{65E5}\u{672C}\u{8A9E}\u{306E}\u{6587}\u{5B57}\u{30B3}\u{30FC}\u{30C9}\u{5909}\u{63DB}\u{3002}" ** 4 },
        .{ .encoding = .euc_kr, .text = "\u{C548}\u{B155}\u{D558}\u{C138}\u{C694} \u{C138}\u{ACC4}. \u{D55C}\u{AD6D}\u{C5B4} \u{C778}\u{CF54}\u{B529} \u{BCC0}\u{D658}." ** 4 },
        .{ .encoding = .euc_jp, .text = "\u{3053}\u{3093}\u{306B}\u{3061}\u{306F}\u{4E16}\u{754C}\u{3002}\u{65E5}\u{672C}\u{8A9E}\u{306E}\u{6587}\u{5B57}\u{30B3}\u{30FC}\u{30C9}\u{5909}\u{63DB}\u{3002}" ** 4 },
    };
    for (cases) |case| {
        inline for ([_]Encoding{ .utf16_le, .utf16_be }) |utf16_encoding| {
            const dbcs = try encodeAlloc(allocator, case.text, case.encoding, .{});
            defer allocator.free(dbcs);
            const utf16 = try convertAlloc(
                allocator,
                dbcs,
                case.encoding,
                utf16_encoding,
                .{},
            );
            defer allocator.free(utf16);
            const back = try convertAlloc(
                allocator,
                utf16,
                utf16_encoding,
                case.encoding,
                .{},
            );
            defer allocator.free(back);
            try testing.expectEqualSlices(u8, dbcs, back);
            const utf8 = try convertAlloc(
                allocator,
                utf16,
                utf16_encoding,
                .utf8,
                .{},
            );
            defer allocator.free(utf8);
            try testing.expectEqualStrings(case.text, utf8);
        }
    }

    // Malformed DBCS input still takes the generic error path.
    const bad = try convertAlloc(allocator, &.{ 0xFF, 0x41 }, .gbk, .utf16_le, .{});
    defer allocator.free(bad);
    try testing.expectEqualSlices(u8, &.{ 0xFD, 0xFF, 0x41, 0x00 }, bad);
    try testing.expectError(
        error.InvalidSequence,
        convertAlloc(allocator, &.{0xFF}, .gbk, .utf16_le, .{ .on_error = .strict }),
    );

    // Unmappable scalars in the target DBCS use the replacement path.
    const unmappable = try convertAlloc(allocator, "A\u{1F600}B", .utf8, .gbk, .{});
    defer allocator.free(unmappable);
    try testing.expectEqualStrings("A?B", unmappable);
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

    // Single-byte values that expand to three UTF-8 bytes exercise the
    // fast-path capacity bound.
    const gbk_bytes = [_]u8{ 0x80, 0x80, 'A' };
    const euro = try convertAlloc(allocator, &gbk_bytes, .gbk, .utf8, .{});
    defer allocator.free(euro);
    try testing.expectEqualStrings("\u{20AC}\u{20AC}A", euro);
    const sjis_bytes = [_]u8{ 0xA0, 'A' };
    const sjis = try convertAlloc(
        allocator,
        &sjis_bytes,
        .shift_jis,
        .utf8,
        .{},
    );
    defer allocator.free(sjis);
    try testing.expectEqualStrings("\u{F8F0}A", sjis);
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

test "ISO-2022-KR conversion" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const cases = [_][]const u8{
        "Hello",
        "한국어",
        "Hello 한국",
        "A",
        "",
    };
    for (cases) |text| {
        const encoded = try encodeAlloc(allocator, text, .iso_2022_kr, .{});
        defer allocator.free(encoded);
        const decoded = try decodeAlloc(allocator, encoded, .iso_2022_kr, .{});
        defer allocator.free(decoded);
        try testing.expectEqualStrings(text, decoded);
    }
    const korean = try encodeAlloc(allocator, "한국어", .iso_2022_kr, .{});
    defer allocator.free(korean);
    try testing.expectEqualSlices(
        u8,
        &[_]u8{
            0x1B, 0x24, 0x29, 0x43, 0x0E,
            0x47, 0x51, 0x31, 0x39, 0x3E,
            0x6E, 0x0F,
        },
        korean,
    );
    try testing.expectEqualStrings("ISO-2022-KR", encodingName(.iso_2022_kr));
    try testing.expectEqual(
        @as(?Encoding, .iso_2022_kr),
        fromLabel("ISO-2022-KR"),
    );
    try testing.expectEqual(@as(u8, 8), maxCharSize(.iso_2022_kr));
}

test "Big5-HKSCS conversion" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const cases = [_]struct { text: []const u8, encoded: []const u8 }{
        .{ .text = "香港", .encoded = "\xAD\xBB\xB4\xE4" },
        .{ .text = "€", .encoded = "\xA3\xE1" },
        .{ .text = "\u{27267}", .encoded = "\x87\x45" },
        .{ .text = "Hello 香港", .encoded = "Hello \xAD\xBB\xB4\xE4" },
    };
    for (cases) |case| {
        const encoded = try encodeAlloc(allocator, case.text, .hkscs, .{});
        defer allocator.free(encoded);
        try testing.expectEqualStrings(case.encoded, encoded);
        const decoded = try decodeAlloc(allocator, encoded, .hkscs, .{});
        defer allocator.free(decoded);
        try testing.expectEqualStrings(case.text, decoded);
    }
    try testing.expectEqualStrings("Big5-HKSCS", encodingName(.hkscs));
    try testing.expectEqual(
        @as(?Encoding, .hkscs),
        fromLabel("Big5-HKSCS"),
    );
    try testing.expectEqual(@as(u8, 2), maxCharSize(.hkscs));
}

test "EUC-TW conversion" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const cases = [_]struct { text: []const u8, encoded: []const u8 }{
        .{ .text = "中文測試", .encoded = "\xC4\xE3\xC5\xC6\xE0\xC1\xE6\xDC" },
        .{ .text = "香港", .encoded = "\xD3\xFC\xE0\xAB" },
        .{ .text = "€", .encoded = "\xC2\xC2" },
        .{ .text = "Hello 中文", .encoded = "Hello \xC4\xE3\xC5\xC6" },
        .{ .text = "𠀋", .encoded = "\x8E\xA3\xA1\xC4" },
        .{ .text = "㐀", .encoded = "\x8E\xA6\xA2\xAC" },
    };
    for (cases) |case| {
        const encoded = try encodeAlloc(allocator, case.text, .euc_tw, .{});
        defer allocator.free(encoded);
        try testing.expectEqualStrings(case.encoded, encoded);
        const decoded = try decodeAlloc(allocator, encoded, .euc_tw, .{});
        defer allocator.free(decoded);
        try testing.expectEqualStrings(case.text, decoded);
    }
    try testing.expectEqualStrings("EUC-TW", encodingName(.euc_tw));
    try testing.expectEqual(@as(?Encoding, .euc_tw), fromLabel("EUC-TW"));
    try testing.expectEqual(@as(u8, 4), maxCharSize(.euc_tw));
}

test "ISO-2022-CN conversion" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const cases = [_][]const u8{
        "中文",
        "測試",
        "香港",
        "中文測試",
        "Hello 中文",
        "繁體中文",
        "简体中文",
        "ABC",
        "",
    };
    for (cases) |text| {
        const encoded = try encodeAlloc(allocator, text, .iso_2022_cn, .{});
        defer allocator.free(encoded);
        const decoded = try decodeAlloc(allocator, encoded, .iso_2022_cn, .{});
        defer allocator.free(decoded);
        try testing.expectEqualStrings(text, decoded);
    }
    const traditional = try encodeAlloc(
        allocator,
        "測試",
        .iso_2022_cn,
        .{},
    );
    defer allocator.free(traditional);
    try testing.expectEqualSlices(
        u8,
        &[_]u8{
            0x1B, 0x24, 0x29, 0x47, 0x0E,
            0x60, 0x41, 0x66, 0x5C, 0x0F,
        },
        traditional,
    );
    try testing.expectEqualStrings("ISO-2022-CN", encodingName(.iso_2022_cn));
    try testing.expectEqual(
        @as(?Encoding, .iso_2022_cn),
        fromLabel("ISO-2022-CN"),
    );
    try testing.expectEqual(@as(u8, 9), maxCharSize(.iso_2022_cn));
}

test "ICU stateful charset conformance fixture" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const fixture = @embedFile("charset/stateful_conformance.bin");

    try testing.expect(fixture.len >= 12);
    try testing.expectEqualStrings("CJGP", fixture[0..4]);
    try testing.expectEqual(@as(u8, 1), fixture[4]);
    const record_count = std.mem.readInt(u32, fixture[8..12], .little);

    const encodings = [_]Encoding{ .utf7, .hz, .scsu, .bocu1, .iso_2022_kr, .hkscs, .euc_tw, .iso_2022_cn };
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
                if (encoding == .utf7 or encoding == .bocu1 or
                    encoding == .iso_2022_kr or encoding == .hkscs or
                    encoding == .euc_tw or encoding == .iso_2022_cn)
                {
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
