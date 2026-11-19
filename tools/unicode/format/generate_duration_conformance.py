#!/usr/bin/env python3
"""Generate the duration unit-pattern conformance fixture with PyICU.

Usage:
    generate_duration_conformance.py out_file

Validates the long and short duration unit patterns through
MeasureFormat.formatMeasure (the same CLDR unit patterns DurationFormat uses).
"""

from __future__ import annotations

import struct
import sys

import icu

LOCALES = (
    "en", "fr", "de", "es", "it", "pt", "ru", "pl", "ja", "zh", "ko", "ar",
)

UNITS = (
    ("hour", 0, 3600),
    ("minute", 1, 60),
    ("second", 2, 1),
)

VALUES = (0, 1, 2, 5, 21)
WIDTHS = (0, 1)  # long, short


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    cases = []
    for locale in LOCALES:
        for width in WIDTHS:
            formatter = icu.MeasureFormat(icu.Locale(locale), width)
            for unit_name, unit_id, factor in UNITS:
                unit = getattr(icu.MeasureUnit, "create" + unit_name.capitalize())()
                for value in VALUES:
                    if value == 0 and unit_id != 2:
                        # A zero duration has no hours or minutes.
                        continue
                    expected = formatter.formatMeasure(
                        icu.Measure(value, unit)
                    )
                    cases.append(
                        (locale, width, unit_id, float(value * factor), expected)
                    )

    blob = bytearray(b"CJQK")
    blob += struct.pack("<B3xI", 1, len(cases))
    for locale, width, unit_id, seconds, expected in cases:
        encoded_locale = locale.encode("utf-8")
        encoded_expected = expected.encode("utf-8")
        blob += struct.pack(
            "<BBBBdHH",
            len(encoded_locale),
            width,
            unit_id,
            0,
            seconds,
            len(encoded_expected),
            0,
        )
        blob += encoded_locale
        blob += encoded_expected
    with open(sys.argv[1], "wb") as handle:
        handle.write(bytes(blob))
    print(f"wrote {len(cases)} cases", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
