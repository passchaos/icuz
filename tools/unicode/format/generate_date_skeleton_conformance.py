#!/usr/bin/env python3
"""Generate the date-skeleton conformance fixture with PyICU.

Usage:
    generate_date_skeleton_conformance.py out_file

Cases format the fixed date 2026-11-19 13:45:30 with the skeleton's resolved
single-date pattern (DateIntervalFormat.getDateFormat()).
"""

from __future__ import annotations

import datetime
import struct
import sys

import icu

LOCALES = ("en", "de", "fr", "ja", "ru", "ar", "zh", "hi")

SKELETONS = (
    "yMMMd",
    "yMd",
    "MMMd",
    "Md",
    "Hm",
    "Hms",
    "yMMMMd",
    "dMMMy",
    "yMMMdHm",
    "yMMMdjm",
)

DATE_TIME = datetime.datetime(2026, 11, 19, 13, 45, 30)


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    cases = []
    for locale in LOCALES:
        for skeleton in SKELETONS:
            try:
                formatter = icu.DateIntervalFormat.createInstance(
                    skeleton, icu.Locale(locale)
                )
                expected = formatter.getDateFormat().format(DATE_TIME)
            except Exception:
                continue
            cases.append((locale, skeleton, expected))
    blob = bytearray(b"CJGJ")
    blob += struct.pack("<B3xI", 1, len(cases))
    for locale, skeleton, expected in cases:
        encoded_locale = locale.encode("utf-8")
        encoded_skeleton = skeleton.encode("utf-8")
        encoded_expected = expected.encode("utf-8")
        blob += struct.pack(
            "<BBHH",
            len(encoded_locale),
            len(encoded_skeleton),
            len(encoded_expected),
            0,
        )
        blob += encoded_locale
        blob += encoded_skeleton
        blob += encoded_expected
    with open(sys.argv[1], "wb") as handle:
        handle.write(bytes(blob))
    print(f"wrote {len(cases)} cases", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
