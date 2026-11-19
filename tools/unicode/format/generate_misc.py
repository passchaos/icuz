#!/usr/bin/env python3
"""Generate CLDR 48 list, relative-time, and unit pattern tables.

Usage:
    generate_misc.py cldr-common-48.zip out_dir
"""

from __future__ import annotations

import hashlib
import sys
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

CLDR_SHA256 = "06c7c698d6fd8d67cefac15a0206b0109b00e0ef1636f86f84449fa959561f74"
CLDR_VERSION = 48

LOCALES = (
    "af", "am", "ar", "az", "be", "bg", "bn", "bs", "ca", "cs",
    "cy", "da", "de", "de-AT", "de-CH", "el", "en", "en-AU", "en-CA",
    "en-GB", "en-IN", "es", "es-419", "es-MX", "et", "eu", "fa", "fi",
    "fil", "fr", "fr-CA", "ga", "gl", "gu", "he", "hi", "hr", "hu",
    "hy", "id", "is", "it", "ja", "ka", "kk", "km", "kn", "ko", "lo",
    "lt", "lv", "mk", "ml", "mn", "mr", "ms", "mt", "my", "nb", "ne",
    "nl", "nl-BE", "pa", "pl", "ps", "pt", "pt-PT", "ro", "ru", "si",
    "sk", "sl", "sq", "sr", "sv", "sw", "ta", "te", "th", "tr", "uk",
    "ur", "uz", "vi", "zh", "zh-Hant", "zu",
)

PARENT = {
    "de-AT": "de",
    "de-CH": "de",
    "en-AU": "en",
    "en-CA": "en",
    "en-GB": "en",
    "en-IN": "en",
    "es-419": "es",
    "es-MX": "es",
    "fr-CA": "fr",
    "nl-BE": "nl",
    "pt-PT": "pt",
    "zh-Hant": "zh",
    "nb": "no",
    "nb": "no",
}

LIST_STYLES = (
    "standard",
    "standard-short",
    "standard-narrow",
    "or",
    "or-short",
    "or-narrow",
    "unit",
    "unit-short",
    "unit-narrow",
)

STYLE_CHAINS = {
    "standard": ("standard",),
    "standard-short": ("standard-short", "standard"),
    "standard-narrow": ("standard-narrow", "standard-short", "standard"),
    "or": ("or",),
    "or-short": ("or-short", "or"),
    "or-narrow": ("or-narrow", "or-short", "or"),
    "unit": ("unit",),
    "unit-short": ("unit-short", "unit"),
    "unit-narrow": ("unit-narrow", "unit-short", "unit"),
}

LIST_PARTS = ("start", "middle", "end", "2")

RELATIVE_UNITS = ("year", "month", "week", "day", "hour", "minute", "second")
CATEGORIES = ("zero", "one", "two", "few", "many", "other")

CURRENCIES = (
    "USD", "EUR", "GBP", "JPY", "CNY", "KRW", "INR", "RUB", "BRL",
    "CAD", "AUD", "CHF", "SEK", "NOK", "DKK", "PLN", "TRY", "SAR",
    "AED", "ILS", "THB", "VND", "IDR", "MXN", "ZAR",
)

UNITS = (
    ("meter", "length-meter"),
    ("kilometer", "length-kilometer"),
    ("centimeter", "length-centimeter"),
    ("millimeter", "length-millimeter"),
    ("mile", "length-mile"),
    ("yard", "length-yard"),
    ("foot", "length-foot"),
    ("inch", "length-inch"),
    ("kilogram", "mass-kilogram"),
    ("gram", "mass-gram"),
    ("milligram", "mass-milligram"),
    ("pound", "mass-pound"),
    ("ounce", "mass-ounce"),
    ("celsius", "temperature-celsius"),
    ("fahrenheit", "temperature-fahrenheit"),
    ("kelvin", "temperature-kelvin"),
    ("kilometer_per_hour", "speed-kilometer-per-hour"),
    ("mile_per_hour", "speed-mile-per-hour"),
    ("meter_per_second", "speed-meter-per-second"),
    ("square_meter", "area-square-meter"),
    ("square_kilometer", "area-square-kilometer"),
    ("hectare", "area-hectare"),
    ("acre", "area-acre"),
    ("square_foot", "area-square-foot"),
    ("liter", "volume-liter"),
    ("milliliter", "volume-milliliter"),
    ("gallon", "volume-gallon"),
    ("quart", "volume-quart"),
    ("pint", "volume-pint"),
    ("cup", "volume-cup"),
    ("second", "duration-second"),
    ("minute", "duration-minute"),
    ("hour", "duration-hour"),
    ("day", "duration-day"),
    ("week", "duration-week"),
    ("month", "duration-month"),
    ("year", "duration-year"),
    ("bit", "digital-bit"),
    ("byte", "digital-byte"),
    ("kilobyte", "digital-kilobyte"),
    ("megabyte", "digital-megabyte"),
    ("gigabyte", "digital-gigabyte"),
    ("terabyte", "digital-terabyte"),
    ("joule", "energy-joule"),
    ("kilojoule", "energy-kilojoule"),
    ("calorie", "energy-calorie"),
    ("kilocalorie", "energy-kilocalorie"),
    ("watt", "power-watt"),
    ("kilowatt", "power-kilowatt"),
    ("horsepower", "power-horsepower"),
    ("hectopascal", "pressure-hectopascal"),
    ("millibar", "pressure-millibar"),
    ("atmosphere", "pressure-atmosphere"),
    ("hertz", "frequency-hertz"),
    ("kilohertz", "frequency-kilohertz"),
    ("megahertz", "frequency-megahertz"),
    ("degree", "angle-degree"),
    ("radian", "angle-radian"),
    ("percent", "concentr-percent"),
    ("permille", "concentr-permille"),
)


def checked_zip(path: Path) -> zipfile.ZipFile:
    actual = hashlib.sha256(path.read_bytes()).hexdigest()
    if actual != CLDR_SHA256:
        raise SystemExit(
            f"{path}: expected CLDR 48 SHA-256 {CLDR_SHA256}, found {actual}"
        )
    return zipfile.ZipFile(path)


def parse_locale(archive: zipfile.ZipFile, locale: str) -> dict:
    filename = "common/main/" + locale.replace("-", "_") + ".xml"
    try:
        text = archive.read(filename).decode("utf-8")
    except KeyError:
        return {
            "list": {},
            "relative": {},
            "units": {"long": {}, "short": {}},
            "currencies": {},
        }
    root = ET.fromstring(text)
    data = {
        "list": {},
        "relative": {},
        "units": {"long": {}, "short": {}},
        "currencies": {},
    }

    for pattern in root.findall(".//listPatterns/listPattern"):
        style = pattern.get("type", "standard")
        parts = {}
        for part in pattern.findall("listPatternPart"):
            kind = part.get("type")
            if kind and part.text:
                parts[kind] = part.text
        if parts:
            data["list"][style] = parts

    for field in root.findall(".//dates/fields/field"):
        unit = field.get("type")
        if unit not in RELATIVE_UNITS:
            continue
        entry = {
            "relative": {},
            "future": {},
            "past": {},
        }
        for relative in field.findall("relative"):
            kind = relative.get("type")
            if kind and relative.text:
                entry["relative"][kind] = relative.text
        for relative_time in field.findall("relativeTime"):
            direction = relative_time.get("type")
            if direction not in ("future", "past"):
                continue
            for pattern in relative_time.findall("relativeTimePattern"):
                category = pattern.get("count")
                if category and pattern.text:
                    entry[direction][category] = pattern.text
        data["relative"][unit] = entry

    for unit_length in root.findall(".//units/unitLength"):
        form = unit_length.get("type")
        if form not in ("long", "short"):
            continue
        for unit in unit_length.findall("unit"):
            unit_id = unit.get("type")
            if unit_id is None:
                continue
            patterns = {}
            for pattern in unit.findall("unitPattern"):
                if pattern.get("case") is not None:
                    continue
                category = pattern.get("count")
                if category and pattern.text:
                    patterns[category] = pattern.text
            if patterns:
                data["units"][form][unit_id] = patterns

    for currency in root.findall(".//currencies/currency"):
        code = currency.get("type")
        if code not in CURRENCIES:
            continue
        symbol_element = currency.find("symbol")
        names: dict[str, str] = {}
        generic = None
        for display_name in currency.findall("displayName"):
            count = display_name.get("count")
            text = display_name.text
            if not text:
                continue
            if count is None:
                generic = text
            else:
                names[count] = text
        if generic is not None and "other" not in names:
            names["other"] = generic
        data["currencies"][code] = {
            "symbol": symbol_element.text if symbol_element is not None and symbol_element.text else "",
            "names": names,
        }

    return data


def layer_value(layers, getter):
    for layer in layers:
        value = getter(layer)
        if value:
            return value
    return ""


def resolve_list(locale_data, parent_data, root_data):
    layers = [locale_data, parent_data, root_data]
    result = {}
    for style in LIST_STYLES:
        parts = {}
        for part in LIST_PARTS:
            parts[part] = layer_value(
                layers,
                lambda data, style=style, part=part: (
                    data["list"].get(style, {}).get(part)
                    or next(
                        (
                            data["list"].get(chain_style, {}).get(part)
                            for chain_style in STYLE_CHAINS[style][1:]
                            if data["list"].get(chain_style, {}).get(part)
                        ),
                        "",
                    )
                ),
            ) or "{0}, {1}"
        result[style] = parts
    return result


def resolve_relative(locale_data, parent_data, root_data):
    layers = [locale_data, parent_data, root_data]
    result = {}
    for unit in RELATIVE_UNITS:
        entry = {
            "past_relative": layer_value(
                layers,
                lambda data, unit=unit: data["relative"].get(unit, {}).get("relative", {}).get("-1"),
            ),
            "now_relative": layer_value(
                layers,
                lambda data, unit=unit: data["relative"].get(unit, {}).get("relative", {}).get("0"),
            ),
            "future_relative": layer_value(
                layers,
                lambda data, unit=unit: data["relative"].get(unit, {}).get("relative", {}).get("1"),
            ),
            "past": {},
            "future": {},
        }
        for direction in ("future", "past"):
            for category in CATEGORIES:
                entry[direction][category] = layer_value(
                    layers,
                    lambda data, unit=unit, direction=direction, category=category: (
                        data["relative"].get(unit, {}).get(direction, {}).get(category)
                        or data["relative"].get(unit, {}).get(direction, {}).get("other")
                    ),
                )
        result[unit] = entry
    return result


def unit_pattern(layers, form, unit_id, category):
    for data in layers:
        patterns = data["units"][form].get(unit_id, {})
        value = patterns.get(category) or patterns.get("other")
        if value:
            return value
    return ""


def resolve_units(locale_data, parent_data, root_data):
    layers = [locale_data, parent_data, root_data]
    result = {}
    for _, unit_id in UNITS:
        entry = {"long": {}, "short": {}}
        for category in CATEGORIES:
            long_value = unit_pattern(layers, "long", unit_id, category)
            if not long_value:
                long_value = unit_pattern(layers, "short", unit_id, category)
            short_value = unit_pattern(layers, "short", unit_id, category)
            if not short_value:
                short_value = long_value
            entry["long"][category] = long_value
            entry["short"][category] = short_value
        result[unit_id] = entry
    return result


def parse_currency_fraction_digits(archive: zipfile.ZipFile) -> dict[str, int]:
    text = archive.read("common/supplemental/supplementalData.xml").decode("utf-8")
    root = ET.fromstring(text)
    result: dict[str, int] = {}
    for info in root.findall(".//currencyData/fractions/info"):
        code = info.get("iso4217")
        digits = info.get("digits")
        if code and digits and code not in result:
            result[code] = int(digits)
    return result


def resolve_currencies(locale_data, parent_data, root_data):
    layers = [locale_data, parent_data, root_data]
    result = {}
    for code in CURRENCIES:
        symbol = layer_value(
            layers,
            lambda data, code=code: data["currencies"].get(code, {}).get("symbol"),
        ) or code
        names = {}
        for category in CATEGORIES:
            names[category] = layer_value(
                layers,
                lambda data, code=code, category=category: (
                    data["currencies"].get(code, {}).get("names", {}).get(category)
                    or data["currencies"].get(code, {}).get("names", {}).get("other")
                ),
            ) or code
        result[code] = {"symbol": symbol, "names": names}
    return result


def render_currencies(
    compiled: dict[str, dict],
    fraction_digits: dict[str, int],
) -> str:
    lines = [
        "// Generated by tools/unicode/format/generate_misc.py from CLDR 48.",
        f"// cldr-common-48.zip SHA-256: {CLDR_SHA256}",
        "",
        "pub const Currency = struct {",
        "    symbol: []const u8,",
        "    names: [6][]const u8,",
        "};",
        "",
        "pub const Locale = struct {",
        "    id: []const u8,",
        f"    currencies: [{len(CURRENCIES)}]Currency,",
        "};",
        "",
        "pub const codes = [_][]const u8{",
    ]
    lines.extend(f"    {zig_string(code)}," for code in CURRENCIES)
    lines.extend([
        "};",
        "",
        "pub const fraction_digits = [_]u8{",
    ])
    lines.extend(
        f"    {fraction_digits.get(code, 2)}," for code in CURRENCIES
    )
    lines.extend([
        "};",
        "",
        "pub const locales = [_]Locale{",
    ])
    for locale in sorted(compiled):
        lines.append(f"    .{{ .id = {zig_string(locale)}, .currencies = .{{")
        for code in CURRENCIES:
            entry = compiled[locale]["currencies"][code]
            names = ", ".join(
                zig_string(entry["names"][category]) for category in CATEGORIES
            )
            lines.append(
                f"        .{{ .symbol = {zig_string(entry['symbol'])}, "
                f".names = .{{ {names} }} }},"
            )
        lines.append("    } },")
    lines.extend(["};", ""])
    return "\n".join(lines)


def zig_string(value: str) -> str:
    output = ['"']
    for byte in value.encode("utf-8"):
        if byte == 0x22:
            output.append('\\"')
        elif byte == 0x5C:
            output.append("\\\\")
        elif byte == 0x0A:
            output.append("\\n")
        elif byte == 0x0D:
            output.append("\\r")
        elif byte == 0x09:
            output.append("\\t")
        elif 0x20 <= byte <= 0x7E:
            output.append(chr(byte))
        else:
            output.append(f"\\x{byte:02x}")
    output.append('"')
    return "".join(output)


def render_list(compiled: dict[str, dict]) -> str:
    lines = [
        "// Generated by tools/unicode/format/generate_misc.py from CLDR 48.",
        f"// cldr-common-48.zip SHA-256: {CLDR_SHA256}",
        "",
        "pub const Part = struct {",
        "    start: []const u8,",
        "    middle: []const u8,",
        "    end: []const u8,",
        "    two: []const u8,",
        "};",
        "",
        "pub const Locale = struct {",
        "    id: []const u8,",
        "    patterns: [9]Part,",
        "};",
        "",
        "pub const locales = [_]Locale{",
    ]
    for locale in sorted(compiled):
        lines.append(f"    .{{ .id = {zig_string(locale)}, .patterns = .{{")
        for style in LIST_STYLES:
            parts = compiled[locale]["list"][style]
            lines.append(
                "        .{ "
                f".start = {zig_string(parts['start'])}, "
                f".middle = {zig_string(parts['middle'])}, "
                f".end = {zig_string(parts['end'])}, "
                f".two = {zig_string(parts['2'])} "
                "},"
            )
        lines.append("    } },")
    lines.extend(["};", ""])
    return "\n".join(lines)


def render_relative(compiled: dict[str, dict]) -> str:
    lines = [
        "// Generated by tools/unicode/format/generate_misc.py from CLDR 48.",
        f"// cldr-common-48.zip SHA-256: {CLDR_SHA256}",
        "",
        "pub const Field = struct {",
        "    past_relative: []const u8,",
        "    now_relative: []const u8,",
        "    future_relative: []const u8,",
        "    past: [6][]const u8,",
        "    future: [6][]const u8,",
        "};",
        "",
        "pub const Locale = struct {",
        "    id: []const u8,",
        "    fields: [7]Field,",
        "};",
        "",
        "pub const locales = [_]Locale{",
    ]
    for locale in sorted(compiled):
        lines.append(f"    .{{ .id = {zig_string(locale)}, .fields = .{{")
        for unit in RELATIVE_UNITS:
            entry = compiled[locale]["relative"][unit]
            past = ", ".join(zig_string(entry["past"][c]) for c in CATEGORIES)
            future = ", ".join(zig_string(entry["future"][c]) for c in CATEGORIES)
            lines.append("        .{")
            lines.append(f"            .past_relative = {zig_string(entry['past_relative'])},")
            lines.append(f"            .now_relative = {zig_string(entry['now_relative'])},")
            lines.append(f"            .future_relative = {zig_string(entry['future_relative'])},")
            lines.append(f"            .past = .{{ {past} }},")
            lines.append(f"            .future = .{{ {future} }},")
            lines.append("        },")
        lines.append("    } },")
    lines.extend(["};", ""])
    return "\n".join(lines)


def render_units(compiled: dict[str, dict]) -> str:
    lines = [
        "// Generated by tools/unicode/format/generate_misc.py from CLDR 48.",
        f"// cldr-common-48.zip SHA-256: {CLDR_SHA256}",
        "",
        "pub const Unit = struct {",
        "    long: [6][]const u8,",
        "    short: [6][]const u8,",
        "};",
        "",
        "pub const Locale = struct {",
        "    id: []const u8,",
        f"    units: [{len(UNITS)}]Unit,",
        "};",
        "",
        "pub const locales = [_]Locale{",
    ]
    for locale in sorted(compiled):
        lines.append(f"    .{{ .id = {zig_string(locale)}, .units = .{{")
        for _, unit_id in UNITS:
            entry = compiled[locale]["units"][unit_id]
            long_patterns = ", ".join(
                zig_string(entry["long"][c]) for c in CATEGORIES
            )
            short_patterns = ", ".join(
                zig_string(entry["short"][c]) for c in CATEGORIES
            )
            lines.append(
                f"        .{{ .long = .{{ {long_patterns} }}, "
                f".short = .{{ {short_patterns} }} }},"
            )
        lines.append("    } },")
    lines.extend(["};", ""])
    return "\n".join(lines)


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    archive_path = Path(sys.argv[1])
    out_dir = Path(sys.argv[2])
    out_dir.mkdir(parents=True, exist_ok=True)

    archive = checked_zip(archive_path)
    root_data = parse_locale(archive, "root")
    parsed: dict[str, dict] = {}
    for locale in LOCALES:
        parsed[locale] = parse_locale(archive, locale)
    for locale in PARENT:
        if PARENT[locale] not in parsed:
            parsed[PARENT[locale]] = parse_locale(archive, PARENT[locale])

    compiled: dict[str, dict] = {}
    for locale in LOCALES:
        parent = parsed.get(
            PARENT.get(locale, ""),
            {
                "list": {},
                "relative": {},
                "units": {"long": {}, "short": {}},
                "currencies": {},
            },
        )
        locale_data = parsed[locale]
        compiled[locale] = {
            "list": resolve_list(locale_data, parent, root_data),
            "relative": resolve_relative(locale_data, parent, root_data),
            "units": resolve_units(locale_data, parent, root_data),
            "currencies": resolve_currencies(locale_data, parent, root_data),
        }

    (out_dir / "list_data.zig").write_text(render_list(compiled), encoding="utf-8")
    (out_dir / "relative_data.zig").write_text(render_relative(compiled), encoding="utf-8")
    (out_dir / "units_data.zig").write_text(render_units(compiled), encoding="utf-8")
    (out_dir / "currencies_data.zig").write_text(
        render_currencies(compiled, parse_currency_fraction_digits(archive)),
        encoding="utf-8",
    )
    print(
        f"generated {len(compiled)} locales: "
        f"{len(LIST_STYLES)} list styles, {len(RELATIVE_UNITS)} relative fields, "
        f"{len(UNITS)} units",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
