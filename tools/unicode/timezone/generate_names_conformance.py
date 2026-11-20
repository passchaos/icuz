#!/usr/bin/env python3
"""Generate the localized time zone name conformance fixture with PyICU.

Usage:
    generate_names_conformance.py out_file

Cases cover `z`, `zzzz`, `v`, `vvvv`, `O`, `OOOO`, and `ZZZZ` for a sample of
locales and zones at a winter and a summer instant in 2024.
"""

from __future__ import annotations

import datetime
import struct
import sys

import icu

LOCALES = (
    "en", "fr", "de", "es", "it", "pt", "nl", "ru", "pl", "ja",
    "zh", "ko", "ar", "hi", "tr", "sv",
    "ak", "ccp", "chr", "ee", "eo", "ff", "fo",
    "fr-BE", "ky", "lb", "nn", "no", "qu", "se", "vec",
    "yue", "yue-Hans",
)

ZONES = (
    "America/New_York",
    "Europe/Berlin",
    "Europe/London",
    "Asia/Kolkata",
    "Asia/Tokyo",
    "Australia/Sydney",
    "America/Sao_Paulo",
    "Africa/Cairo",
)

INSTANTS = (1705320000, 1721044800)

PATTERNS = (
    ("z", 0),
    ("zzzz", 1),
    ("v", 2),
    ("vvvv", 3),
    ("O", 4),
    ("OOOO", 5),
    ("ZZZZ", 6),
)


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    cases = []
    for locale in LOCALES:
        for zone in ZONES:
            for instant in INSTANTS:
                moment = datetime.datetime.fromtimestamp(
                    instant, datetime.timezone.utc
                )
                for pattern, field in PATTERNS:
                    formatter = icu.SimpleDateFormat(
                        pattern, icu.Locale(locale)
                    )
                    formatter.setTimeZone(icu.TimeZone.createTimeZone(zone))
                    expected = formatter.format(moment)
                    cases.append((locale, zone, instant, field, expected))

    blob = bytearray(b"CJZQ")
    blob += struct.pack("<B3xI", 1, len(cases))
    for locale, zone, instant, field, expected in cases:
        encoded_locale = locale.encode("utf-8")
        encoded_zone = zone.encode("utf-8")
        encoded_expected = expected.encode("utf-8")
        blob += struct.pack(
            "<BBHqBBH",
            len(encoded_locale),
            len(encoded_zone),
            len(encoded_expected),
            instant,
            field,
            0,
            0,
        )
        blob += encoded_locale
        blob += encoded_zone
        blob += encoded_expected
    with open(sys.argv[1], "wb") as handle:
        handle.write(bytes(blob))
    print(f"wrote {len(cases)} cases", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
