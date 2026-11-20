#!/usr/bin/env python3
"""Generate the udat_getSymbols conformance fixture with the ICU C API.

Usage:
    generate_date_symbols_conformance.py dates_data.zig out_file

Every locale in the committed Gregorian date data is opened with udat_open
and each UDateFormatSymbolType is read with udat_countSymbols /
udat_getSymbols. Set ICU_I18N_LIB when the library is not in a standard
location.

Fixture format (CJYS version 1):

    magic "CJYS", u8 version, 3 reserved bytes, u32 record_count
    per record:
        u8 symbol type
        u16 locale_len, locale UTF-8 bytes
        u8 count
        per symbol: u16 value_len, value UTF-8 bytes
"""

from __future__ import annotations

import ctypes
import ctypes.util
import glob
import os
import re
import struct
import sys
from pathlib import Path

MAGIC = b"CJYS"
FORMAT_VERSION = 1

SYMBOL_TYPES = (
    0,  # ERAS
    1,  # MONTHS
    2,  # SHORT_MONTHS
    3,  # WEEKDAYS
    4,  # SHORT_WEEKDAYS
    5,  # AM_PMS
    7,  # ERA_NAMES
    8,  # NARROW_MONTHS
    9,  # NARROW_WEEKDAYS
    10,  # STANDALONE_MONTHS
    11,  # STANDALONE_SHORT_MONTHS
    12,  # STANDALONE_NARROW_MONTHS
    13,  # STANDALONE_WEEKDAYS
    14,  # STANDALONE_SHORT_WEEKDAYS
    15,  # STANDALONE_NARROW_WEEKDAYS
    16,  # QUARTERS
    17,  # SHORT_QUARTERS
    18,  # STANDALONE_QUARTERS
    19,  # STANDALONE_SHORT_QUARTERS
    20,  # SHORTER_WEEKDAYS
    21,  # STANDALONE_SHORTER_WEEKDAYS
)


def load_library() -> ctypes.CDLL:
    candidates = []
    override = os.environ.get("ICU_I18N_LIB")
    if override:
        candidates.append(override)
    found = ctypes.util.find_library("icui18n")
    if found:
        candidates.append(found)
    for pattern in (
        "/usr/local/lib/libicui18n.*.dylib",
        "/opt/homebrew/lib/libicui18n.*.dylib",
        os.path.expanduser("~/.pixi/envs/*/lib/libicui18n.*.dylib"),
    ):
        candidates.extend(sorted(glob.glob(pattern)))
    for candidate in candidates:
        try:
            return ctypes.CDLL(candidate)
        except OSError:
            continue
    raise SystemExit("could not load libicui18n; set ICU_I18N_LIB")


# CLDR 48 revised stand-alone abbreviated quarters and en-CA month
# abbreviations after the CLDR data shipped with ICU 78; skip those known
# data-version differences so the fixture stays a pure behavior check.
SKIP_RECORDS = {
    ("ar", 19),
    ("km", 19),
    ("ml", 19),
    ("ne", 19),
    ("ps", 19),
    ("qu", 19),
    ("se", 19),
    ("su", 19),
    ("sw", 19),
    ("th", 19),
    ("ur", 19),
    ("vi", 19),
    ("yue", 19),
    ("yue-Hans", 19),
    ("zh-Hant", 19),
    ("en-CA", 2),
    ("en-CA", 11),
}


def locale_ids(path: Path) -> list[str]:
    text = path.read_text(encoding="utf-8")
    return sorted(set(re.findall(r'\.\{ \.id = "([^"]+)", \.skeletons', text)))


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    source_path = Path(sys.argv[1])
    out_path = Path(sys.argv[2])
    locales = locale_ids(source_path)
    if not locales:
        raise SystemExit(f"{source_path}: no locales found")

    library = load_library()
    version = None
    for candidate in ("72", "73", "74", "75", "76", "77", "78", "79", "80"):
        if hasattr(library, f"udat_open_{candidate}"):
            version = candidate
            break
    if version is None:
        raise SystemExit("could not find versioned udat symbols")

    P = ctypes.POINTER(ctypes.c_int)
    U16 = ctypes.c_uint16

    def bind(name, restype, argtypes):
        func = getattr(library, f"{name}_{version}")
        func.restype = restype
        func.argtypes = argtypes
        return func

    udat_open = bind(
        "udat_open",
        ctypes.c_void_p,
        [
            ctypes.c_int32,
            ctypes.c_int32,
            ctypes.c_char_p,
            ctypes.POINTER(U16),
            ctypes.c_int32,
            ctypes.POINTER(U16),
            ctypes.c_int32,
            P,
        ],
    )
    udat_close = bind("udat_close", None, [ctypes.c_void_p])
    udat_count = bind(
        "udat_countSymbols",
        ctypes.c_int32,
        [ctypes.c_void_p, ctypes.c_int32, P],
    )
    udat_get = bind(
        "udat_getSymbols",
        ctypes.c_int32,
        [ctypes.c_void_p, ctypes.c_int32, ctypes.c_int32, ctypes.POINTER(U16), ctypes.c_int32, P],
    )

    records: list[tuple[int, bytes, list[bytes]]] = []
    for locale in locales:
        status = ctypes.c_int(0)
        fmt = udat_open(
            0,
            0,
            f"{locale}@calendar=gregorian".encode("utf-8"),
            None,
            0,
            None,
            0,
            ctypes.byref(status),
        )
        if status.value != 0 or not fmt:
            raise SystemExit(f"udat_open failed for {locale}: {status.value}")
        for symbol_type in SYMBOL_TYPES:
            if (locale, symbol_type) in SKIP_RECORDS:
                continue
            status = ctypes.c_int(0)
            count = udat_count(fmt, symbol_type, ctypes.byref(status))
            if status.value != 0 or count < 0:
                raise SystemExit(
                    f"udat_countSymbols failed for {locale} type {symbol_type}"
                )
            values: list[bytes] = []
            for index in range(count):
                buffer = (U16 * 256)()
                status = ctypes.c_int(0)
                written = udat_get(
                    fmt,
                    symbol_type,
                    index,
                    buffer,
                    len(buffer),
                    ctypes.byref(status),
                )
                if status.value != 0 or written < 0:
                    raise SystemExit(
                        f"udat_getSymbols failed for {locale} "
                        f"type {symbol_type} index {index}"
                    )
                raw = ctypes.string_at(ctypes.addressof(buffer), written * 2)
                values.append(raw.decode("utf-16-le").encode("utf-8"))
            records.append((symbol_type, locale.encode("utf-8"), values))
        udat_close(fmt)

    blob = bytearray(MAGIC)
    blob += struct.pack("<B3xI", FORMAT_VERSION, len(records))
    for symbol_type, locale, values in records:
        blob += struct.pack("<BHB", symbol_type, len(locale), len(values))
        blob += locale
        for value in values:
            blob += struct.pack("<H", len(value))
            blob += value
    out_path.write_bytes(bytes(blob))
    print(
        f"wrote {len(blob)} bytes, {len(records)} symbol records",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
