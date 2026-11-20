#!/usr/bin/env python3
"""Generate the USpoofChecker conformance fixture with the ICU C API.

Usage:
    generate_check_conformance.py out_file

Every curated string is run through ICU's uspoof_checkUTF8 under a matrix of
check masks, restriction-level thresholds, and allowed-character sets.
Confusable pairs are run through uspoof_areConfusableUTF8. Set ICU_I18N_LIB
when the library is not in a standard location.

Fixture format (CJSP version 1):

    magic "CJSP", u8 version, 3 reserved bytes, u32 case_count
    per case:
        u8 kind (0 = check, 1 = confusable)
        u8 restriction level (0 = ASCII .. 5 = Unrestricted)
        u8 allowed set index (0 = all, 1 = [a-z], 2 = [a-zA-Z0-9_],
                              3 = [\\u0000-\\u007F])
        u8 reserved
        u32 checks
        u16 input_len, input bytes
        u16 second_len, second bytes (confusable only)
        u32 expected bitmask
"""

from __future__ import annotations

import ctypes
import ctypes.util
import glob
import os
import struct
import sys
from pathlib import Path

MAGIC = b"CJSP"
FORMAT_VERSION = 1

ASCII_ONLY = 0x10000000
SINGLE_SCRIPT = 0x20000000
HIGHLY_RESTRICTIVE = 0x30000000
MODERATELY_RESTRICTIVE = 0x40000000
MINIMALLY_RESTRICTIVE = 0x50000000
UNRESTRICTIVE = 0x60000000

SINGLE_SCRIPT_CONFUSABLE = 0x1
MIXED_SCRIPT_CONFUSABLE = 0x2
WHOLE_SCRIPT_CONFUSABLE = 0x4
CONFUSABLE = 0x7
RESTRICTION_LEVEL = 0x10
INVISIBLE = 0x20
CHAR_LIMIT = 0x40
MIXED_NUMBERS = 0x80
HIDDEN_OVERLAY = 0x100
ALL_CHECKS = 0xFFFF
AUX_INFO = 0x40000000

ALLOWED_PATTERNS = (
    None,
    "[a-z]",
    "[a-zA-Z0-9_]",
    "[\\u0000-\\u007F]",
)

LEVELS = (
    ASCII_ONLY,
    SINGLE_SCRIPT,
    HIGHLY_RESTRICTIVE,
    MODERATELY_RESTRICTIVE,
    MINIMALLY_RESTRICTIVE,
    UNRESTRICTIVE,
)

STRINGS = (
    "",
    "abc",
    "abc123",
    "a b",
    "caf\u00e9",
    "\u00e9",
    "e\u0301",
    "\U0001F600",
    "\u65e5\u672c\u8a9e",
    "abc\u65e5",
    "abc\uD55C",
    "abc\u05D0",
    "\u0421\u0456\u0433\u0441\u04c0\u0435",
    "\u03A9mega",
    "abc\u10D0",
    "abc\u13A0",
    "\u13A0\u13A1",
    "\u0430\u0431\u0432",
    "p\u0430ypal",
    "1\u0662",
    "1\u06F2",
    "\u0661\u0662",
    "1\u0967",
    "\u2460",
    "\u2167",
    "\u00b2",
    "i\u0307",
    "j\u0307",
    "\u0237\u0307",
    "l\u0307",
    "1\u0307",
    "i\u0301\u0307",
    "i\u0307\u0307",
    "\u00ed\u0307",
    "\u0131\u0307",
    "I\u0307",
    "\u2170\u0307",
    "a\u0301\u0301",
    "a\u0301b\u0301",
    "a\u0301\u0302\u0301",
    "a\u0301\u0302",
    "\u0301\u0301",
    "a\u0301\u0302\u0303",
    "a\u0301\u0301b\u0302\u0302",
    "\u0307",
    "\u00a0abc",
    "abc\u200b",
    "\u202eabc",
)

CONFIGS = (
    (ALL_CHECKS, HIGHLY_RESTRICTIVE, 0),
    (0, HIGHLY_RESTRICTIVE, 0),
    (RESTRICTION_LEVEL, ASCII_ONLY, 0),
    (RESTRICTION_LEVEL, SINGLE_SCRIPT, 0),
    (RESTRICTION_LEVEL, HIGHLY_RESTRICTIVE, 0),
    (RESTRICTION_LEVEL, MODERATELY_RESTRICTIVE, 0),
    (RESTRICTION_LEVEL, MINIMALLY_RESTRICTIVE, 0),
    (RESTRICTION_LEVEL, UNRESTRICTIVE, 0),
    (RESTRICTION_LEVEL | AUX_INFO, HIGHLY_RESTRICTIVE, 0),
    (INVISIBLE, HIGHLY_RESTRICTIVE, 0),
    (MIXED_NUMBERS, HIGHLY_RESTRICTIVE, 0),
    (HIDDEN_OVERLAY, HIGHLY_RESTRICTIVE, 0),
    (CHAR_LIMIT, HIGHLY_RESTRICTIVE, 1),
    (CHAR_LIMIT, HIGHLY_RESTRICTIVE, 2),
    (CHAR_LIMIT, HIGHLY_RESTRICTIVE, 3),
    (RESTRICTION_LEVEL | CHAR_LIMIT, HIGHLY_RESTRICTIVE, 1),
    (ALL_CHECKS, HIGHLY_RESTRICTIVE, 1),
    (ALL_CHECKS, HIGHLY_RESTRICTIVE, 2),
    (ALL_CHECKS, HIGHLY_RESTRICTIVE, 3),
)

CONFUSABLE_PAIRS = (
    ("paypal", "p\u0430ypal"),
    ("paypal", "paypa1"),
    ("scope", "s\u0441ope"),
    ("scope", "\u0455\u0441\u043e\u0440\u0435"),
    ("abc", "\u0430\u0432\u0441"),
    ("abc", "abd"),
    ("l", "1"),
    ("I", "l"),
    ("microsoft", "rnicrosoft"),
    ("hello", "he11o"),
    ("caf\u00e9", "cafe\u0301"),
)


def load_library(name: str) -> ctypes.CDLL:
    candidates = []
    override = os.environ.get("ICU_I18N_LIB" if name == "icui18n" else "ICU_UC_LIB")
    if override:
        candidates.append(override)
    found = ctypes.util.find_library(name)
    if found:
        candidates.append(found)
    for pattern in (
        f"/usr/local/lib/lib{name}.*.dylib",
        f"/opt/homebrew/lib/lib{name}.*.dylib",
        os.path.expanduser(f"~/.pixi/envs/*/lib/lib{name}.*.dylib"),
    ):
        candidates.extend(sorted(glob.glob(pattern)))
    for candidate in candidates:
        try:
            return ctypes.CDLL(candidate)
        except OSError:
            continue
    raise SystemExit(f"could not load {name}")


def find_version(library: ctypes.CDLL, symbol: str) -> str:
    for candidate in ("72", "73", "74", "75", "76", "77", "78", "79", "80"):
        if hasattr(library, f"{symbol}_{candidate}"):
            return candidate
    raise SystemExit(f"could not find versioned {symbol} symbols")


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    out_path = Path(sys.argv[1])

    i18n = load_library("icui18n")
    uc = load_library("icuuc")
    version = find_version(i18n, "uspoof_open")
    P = ctypes.POINTER(ctypes.c_int)

    def bind(library: ctypes.CDLL, name: str, restype, argtypes):
        func = getattr(library, f"{name}_{version}")
        func.restype = restype
        func.argtypes = argtypes
        return func

    uspoof_open = bind(i18n, "uspoof_open", ctypes.c_void_p, [P])
    uspoof_close = bind(i18n, "uspoof_close", None, [ctypes.c_void_p])
    uspoof_set_checks = bind(
        i18n, "uspoof_setChecks", None, [ctypes.c_void_p, ctypes.c_int32, P]
    )
    uspoof_set_level = bind(
        i18n, "uspoof_setRestrictionLevel", None, [ctypes.c_void_p, ctypes.c_int32]
    )
    uspoof_set_allowed = bind(
        i18n, "uspoof_setAllowedChars", None, [ctypes.c_void_p, ctypes.c_void_p, P]
    )
    uspoof_check = bind(
        i18n,
        "uspoof_checkUTF8",
        ctypes.c_int32,
        [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int32, P, P],
    )
    uspoof_are_confusable = bind(
        i18n,
        "uspoof_areConfusableUTF8",
        ctypes.c_int32,
        [
            ctypes.c_void_p,
            ctypes.c_char_p,
            ctypes.c_int32,
            ctypes.c_char_p,
            ctypes.c_int32,
            P,
        ],
    )
    uset_open_pattern = bind(
        uc,
        "uset_openPattern",
        ctypes.c_void_p,
        [ctypes.POINTER(ctypes.c_uint16), ctypes.c_int32, P],
    )
    uset_close = bind(uc, "uset_close", None, [ctypes.c_void_p])

    allowed_sets: list[int | None] = [None]
    for pattern in ALLOWED_PATTERNS[1:]:
        encoded = pattern.encode("utf-16-le")
        units = (ctypes.c_uint16 * (len(encoded) // 2)).from_buffer_copy(encoded)
        status = ctypes.c_int(0)
        uset = uset_open_pattern(units, len(encoded) // 2, ctypes.byref(status))
        if status.value != 0 or not uset:
            raise SystemExit(f"uset_openPattern failed for {pattern!r}")
        allowed_sets.append(uset)

    status = ctypes.c_int(0)
    checker = uspoof_open(ctypes.byref(status))
    if status.value != 0 or not checker:
        raise SystemExit(f"uspoof_open failed with status {status.value}")

    records: list[tuple[int, int, int, int, bytes, bytes, int]] = []

    for checks, level, allowed_index in CONFIGS:
        if allowed_index != 0:
            status.value = 0
            uspoof_set_allowed(checker, allowed_sets[allowed_index], ctypes.byref(status))
            if status.value != 0:
                raise SystemExit("uspoof_setAllowedChars failed")
        status.value = 0
        uspoof_set_level(checker, level)
        status.value = 0
        uspoof_set_checks(checker, checks, ctypes.byref(status))
        if status.value != 0:
            raise SystemExit(f"uspoof_setChecks failed for {checks:#x}")
        for text in STRINGS:
            encoded = text.encode("utf-8")
            status.value = 0
            position = ctypes.c_int(0)
            result = uspoof_check(
                checker,
                encoded,
                len(encoded),
                ctypes.byref(position),
                ctypes.byref(status),
            )
            if status.value != 0:
                raise SystemExit(f"uspoof_checkUTF8 failed for {text!r}")
            records.append(
                (
                    0,
                    LEVELS.index(level),
                    allowed_index,
                    checks,
                    encoded,
                    b"",
                    result & 0xFFFFFFFF,
                )
            )

    status.value = 0
    uspoof_set_checks(checker, CONFUSABLE, ctypes.byref(status))
    if status.value != 0:
        raise SystemExit("uspoof_setChecks failed for confusable checks")
    for first, second in CONFUSABLE_PAIRS:
        encoded_first = first.encode("utf-8")
        encoded_second = second.encode("utf-8")
        status.value = 0
        result = uspoof_are_confusable(
            checker,
            encoded_first,
            len(encoded_first),
            encoded_second,
            len(encoded_second),
            ctypes.byref(status),
        )
        if status.value != 0:
            raise SystemExit(f"uspoof_areConfusableUTF8 failed for {first!r}")
        records.append(
            (
                1,
                2,
                0,
                CONFUSABLE,
                encoded_first,
                encoded_second,
                result & 0xFFFFFFFF,
            )
        )

    uspoof_close(checker)
    for uset in allowed_sets[1:]:
        uset_close(uset)

    blob = bytearray(MAGIC)
    blob += struct.pack("<B3xI", FORMAT_VERSION, len(records))
    for kind, level, allowed_index, checks, first, second, expected in records:
        blob += struct.pack("<BBBB", kind, level, allowed_index, 0)
        blob += struct.pack("<I", checks)
        blob += struct.pack("<H", len(first))
        blob += first
        blob += struct.pack("<H", len(second))
        blob += second
        blob += struct.pack("<I", expected)
    out_path.write_bytes(bytes(blob))
    print(f"wrote {len(blob)} bytes, {len(records)} cases", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
