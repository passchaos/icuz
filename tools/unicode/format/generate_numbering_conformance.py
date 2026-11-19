#!/usr/bin/env python3
"""Generate the numbering-system conformance fixture with PyICU.

Usage:
    generate_numbering_conformance.py out_file

Covers decimal numbers and Gregorian dates for a sample of locales and
numbering systems.
"""

from __future__ import annotations

import datetime
import struct
import sys

import icu

LOCALES = ("en", "ar", "fa", "hi", "th", "zh", "ja", "ko", "ru", "fr")
SYSTEMS = ("latn", "arab", "arabext", "thai", "deva", "beng", "hanidec", "fullwide")
VALUES = (0.0, 1.0, 7.0, 42.0, 1234.5, -42.0, 1000000.0)
DATE_LOCALES = ("en", "fr", "ja", "ar", "th", "hi")
DATE_SYSTEMS = ("latn", "arab", "thai", "deva", "beng")
DATE_INSTANTS = (1705320000, 946684800)


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    icu.TimeZone.setDefault(icu.TimeZone.createTimeZone("UTC"))
    cases = []
    for locale in LOCALES:
        for system in SYSTEMS:
            formatter = icu.NumberFormat.createInstance(
                icu.Locale(locale + "@numbers=" + system)
            )
            for value in VALUES:
                # CLDR 48 changed the French Arabic minus signs; ICU 78.3
                # still uses the root symbols, so these negatives are skipped.
                if value < 0 and locale == "fr" and system in ("arab", "arabext"):
                    continue
                expected = formatter.format(value)
                cases.append((0, locale, system, value, expected))
    for locale in DATE_LOCALES:
        for system in DATE_SYSTEMS:
            tag = locale + "@calendar=gregorian;numbers=" + system
            formatter = icu.SimpleDateFormat("y-MM-dd", icu.Locale(tag))
            for instant in DATE_INSTANTS:
                moment = datetime.datetime.fromtimestamp(
                    instant, datetime.timezone.utc
                )
                expected = formatter.format(moment)
                cases.append((1, locale, system, float(instant), expected))

    blob = bytearray(b"CJNS")
    blob += struct.pack("<B3xI", 1, len(cases))
    for kind, locale, system, value, expected in cases:
        encoded_locale = locale.encode("utf-8")
        encoded_system = system.encode("utf-8")
        encoded_expected = expected.encode("utf-8")
        blob += struct.pack(
            "<BBBBQHH",
            kind,
            len(encoded_locale),
            len(encoded_system),
            0,
            struct.unpack("<Q", struct.pack("<d", value))[0],
            len(encoded_expected),
            0,
        )
        blob += encoded_locale
        blob += encoded_system
        blob += encoded_expected
    with open(sys.argv[1], "wb") as handle:
        handle.write(bytes(blob))
    print(f"wrote {len(cases)} cases", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
