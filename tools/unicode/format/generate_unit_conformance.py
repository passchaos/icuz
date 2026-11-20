#!/usr/bin/env python3
"""Generate the unit formatting conformance fixture with PyICU.

The unit identifier list is read from the committed units_data.zig so the
fixture always matches the supported CLDR unit set.

Usage:
    generate_unit_conformance.py units_data.zig out_file
"""

from __future__ import annotations

import re
import struct
import sys

import icu

LOCALES = (
    "en", "fr", "de", "ja", "zh", "ko", "ru", "ar", "hi", "th", "pt", "es",
    "ak", "ccp", "chr", "ee", "en-001", "eo", "fa-AF", "ff", "fo", "fr-BE", "ky", "lb", "lrc", "nn", "no", "qu", "se", "su", "vec", "yue", "yue-Hans",
)
CORE_UNITS = (
    "length-meter", "length-kilometer", "length-centimeter", "length-mile",
    "length-foot", "length-inch", "mass-kilogram", "mass-gram", "mass-pound",
    "temperature-celsius", "temperature-fahrenheit", "temperature-kelvin",
    "speed-kilometer-per-hour", "speed-mile-per-hour",
    "area-square-meter", "area-hectare", "area-acre", "volume-liter",
    "volume-gallon", "volume-cup", "duration-second", "duration-minute",
    "duration-hour", "duration-day", "duration-week", "duration-month",
    "duration-year", "digital-bit", "digital-byte", "digital-megabyte",
    "digital-gigabyte", "energy-joule", "energy-calorie", "power-watt",
    "power-horsepower", "pressure-hectopascal", "pressure-millibar",
    "frequency-hertz", "frequency-megahertz", "angle-degree", "angle-radian",
    "concentr-percent", "concentr-permille", "consumption-mile-per-gallon",
    "light-lux", "electric-ampere", "electric-volt", "electric-ohm",
    "torque-newton-meter", "acceleration-g-force", "force-newton",
)
VALUES = (1, 2, 5)


def read_unit_ids(path: str) -> list[str]:
    text = open(path, encoding="utf-8").read()
    block = re.search(r"pub const unit_ids = \[_\]\[\]const u8\{(.*?)\};", text, re.S)
    if block is None:
        raise SystemExit(f"{path}: missing unit_ids")
    return re.findall(r'"([^"]+)"', block.group(1))


def measure_units() -> dict[str, object]:
    result = {}
    for name in dir(icu.MeasureUnit):
        if not name.startswith("create"):
            continue
        try:
            unit = getattr(icu.MeasureUnit, name)()
        except Exception:
            continue
        result[unit.getType() + "-" + unit.getSubtype()] = unit
    return result


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    unit_ids = read_unit_ids(sys.argv[1])
    units = measure_units()

    cases = []
    for locale in LOCALES:
        formatters = {
            "long": icu.MeasureFormat(
                icu.Locale(locale), icu.UMeasureFormatWidth.WIDE
            ),
            "short": icu.MeasureFormat(
                icu.Locale(locale), icu.UMeasureFormatWidth.SHORT
            ),
        }
        selected = unit_ids if locale == "en" else CORE_UNITS
        for unit_id in selected:
            unit = units.get(unit_id)
            if unit is None:
                continue
            for style, formatter in formatters.items():
                if locale != "en" and style == "short":
                    continue
                for value in VALUES:
                    measure = icu.Measure(value, unit)
                    expected = formatter.formatMeasure(measure)
                    cases.append((locale, unit_id, style, value, expected))
    blob = bytearray(b"CJU1")
    blob += struct.pack("<B3xI", 1, len(cases))
    for locale, unit_id, style, value, expected in cases:
        encoded_locale = locale.encode("utf-8")
        encoded_unit = unit_id.encode("utf-8")
        encoded_expected = expected.encode("utf-8")
        blob += struct.pack(
            "<BBBBdHH",
            len(encoded_locale),
            len(encoded_unit),
            0 if style == "long" else 1,
            0,
            float(value),
            len(encoded_expected),
            0,
        )
        blob += encoded_locale
        blob += encoded_unit
        blob += encoded_expected
    with open(sys.argv[2], "wb") as handle:
        handle.write(bytes(blob))
    print(f"wrote {len(cases)} cases", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
