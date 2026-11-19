#!/usr/bin/env python3
"""Generate the localized date pattern parsing conformance fixture with ICU.

Usage:
    generate_date_parse_conformance.py out_file

For each locale, pattern, and civil date the generator formats the date in
UTC with ICU and stores the text together with the civil fields. The Zig
parser must recover the same fields from the formatted text. Set
ICU_I18N_LIB when the library is not in a standard location.
"""

from __future__ import annotations

import ctypes
import ctypes.util
import datetime
import glob
import os
import struct
import sys

UDAT_PATTERN = -2

LOCALES = (
    "en", "en_GB", "de", "fr", "es", "it", "pt_BR", "ru", "uk", "pl",
    "cs", "sv", "da", "fi", "nb", "nl", "tr", "ar", "fa", "hi",
    "bn", "th", "ja", "ko", "zh", "he", "el", "vi", "id", "ms",
)

PATTERNS = (
    "y-MM-dd",
    "d MMMM y",
    "MMM d, y",
    "EEEE, d MMMM y",
    "dd.MM.y",
    "h:mm a",
    "HH:mm:ss",
    "y-MM-dd'T'HH:mm:ss",
)

DATES = (
    (2024, 3, 5, 14, 30, 45),
    (2023, 12, 31, 23, 59, 59),
    (2000, 2, 29, 0, 0, 0),
    (1999, 7, 4, 9, 5, 6),
    (2021, 1, 1, 12, 0, 0),
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
    raise SystemExit(
        "could not load libicui18n; set ICU_I18N_LIB to the ICU i18n library"
    )


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    out_path = sys.argv[1]

    library = load_library()
    version = None
    for candidate in ("72", "73", "74", "75", "76", "77", "78", "79", "80"):
        if hasattr(library, f"udat_open_{candidate}"):
            version = candidate
            break
    if version is None:
        raise SystemExit("could not find versioned udat symbols")

    udat_open = getattr(library, f"udat_open_{version}")
    udat_open.restype = ctypes.c_void_p
    udat_open.argtypes = [
        ctypes.c_int,
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_void_p,
        ctypes.c_int32,
        ctypes.c_char_p,
        ctypes.c_int32,
        ctypes.POINTER(ctypes.c_int),
    ]
    udat_get_calendar = getattr(library, f"udat_getCalendar_{version}")
    udat_get_calendar.restype = ctypes.c_void_p
    udat_get_calendar.argtypes = [ctypes.c_void_p]
    ucal_set_time_zone = getattr(library, f"ucal_setTimeZone_{version}")
    ucal_set_time_zone.restype = None
    ucal_set_time_zone.argtypes = [
        ctypes.c_void_p,
        ctypes.c_void_p,
        ctypes.c_int32,
        ctypes.POINTER(ctypes.c_int),
    ]
    udat_format = getattr(library, f"udat_format_{version}")
    udat_format.restype = ctypes.c_int32
    udat_format.argtypes = [
        ctypes.c_void_p,
        ctypes.c_double,
        ctypes.c_void_p,
        ctypes.c_int32,
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_int),
    ]
    udat_close = getattr(library, f"udat_close_{version}")
    udat_close.argtypes = [ctypes.c_void_p]

    gmt = (ctypes.c_uint16 * 3)(ord("G"), ord("M"), ord("T"))

    cases: list[tuple[tuple[int, ...], str, str, str]] = []
    for locale in LOCALES:
        encoded_locale = locale.encode("utf-8")
        icu_locale = encoded_locale + b"@calendar=gregorian"
        for pattern in PATTERNS:
            pattern_units = pattern.encode("utf-16-le")
            status = ctypes.c_int(0)
            formatter = udat_open(
                UDAT_PATTERN,
                UDAT_PATTERN,
                icu_locale,
                None,
                0,
                pattern_units,
                len(pattern_units) // 2,
                ctypes.byref(status),
            )
            if status.value > 0 or not formatter:
                raise SystemExit(
                    f"udat_open failed for {locale} '{pattern}': "
                    f"{status.value}"
                )
            calendar = udat_get_calendar(formatter)
            status.value = 0
            ucal_set_time_zone(
                calendar,
                ctypes.cast(gmt, ctypes.c_void_p),
                3,
                ctypes.byref(status),
            )
            if status.value > 0:
                raise SystemExit(
                    f"ucal_setTimeZone failed for {locale}: {status.value}"
                )
            for fields in DATES:
                year, month, day, hour, minute, second = fields
                moment = datetime.datetime(
                    year, month, day, hour, minute, second,
                    tzinfo=datetime.timezone.utc,
                )
                millis = moment.timestamp() * 1000.0
                buffer = ctypes.create_string_buffer(512 * 2)
                status.value = 0
                length = udat_format(
                    formatter,
                    millis,
                    buffer,
                    len(buffer),
                    None,
                    ctypes.byref(status),
                )
                if length < 0:
                    raise SystemExit(
                        f"udat_format failed for {locale} '{pattern}'"
                    )
                text = buffer.raw[: length * 2].decode("utf-16-le")
                cases.append((fields, locale, pattern, text))
            udat_close(formatter)

    blob = bytearray(b"CJXD")
    blob += struct.pack("<B3xI", 1, len(cases))
    for fields, locale, pattern, text in cases:
        year, month, day, hour, minute, second = fields
        encoded_locale = locale.encode("utf-8")
        encoded_pattern = pattern.encode("utf-8")
        encoded_text = text.encode("utf-8")
        if len(encoded_locale) > 255 or len(encoded_pattern) > 255 or \
                len(encoded_text) > 0xFFFF:
            raise SystemExit("fixture field too long")
        blob += struct.pack(
            "<i5BBBH",
            year,
            month,
            day,
            hour,
            minute,
            second,
            len(encoded_locale),
            len(encoded_pattern),
            len(encoded_text),
        )
        blob += encoded_locale
        blob += encoded_pattern
        blob += encoded_text
    with open(out_path, "wb") as handle:
        handle.write(bytes(blob))
    print(
        f"wrote {len(blob)} bytes, {len(cases)} date parse cases",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
