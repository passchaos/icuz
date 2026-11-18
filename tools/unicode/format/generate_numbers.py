#!/usr/bin/env python3
"""Generate CLDR 48 decimal/percent/currency formatting data.

Usage:
    generate_numbers.py locale_json_dir out_dir

The input directory contains one `<locale>.json` file per locale from
`cldr-numbers-full/main/<locale>/numbers.json`.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

CATEGORIES = ("zero", "one", "two", "few", "many", "other")
COMPACT_MAGNITUDES = tuple(10**power for power in range(3, 15))


def unquote_pattern(value: str) -> str:
    output: list[str] = []
    index = 0
    quoted = False
    while index < len(value):
        character = value[index]
        if character == "'":
            if index + 1 < len(value) and value[index + 1] == "'":
                output.append("'")
                index += 2
                continue
            quoted = not quoted
            index += 1
            continue
        output.append(character)
        index += 1
    return "".join(output)


def parse_compact(section: dict) -> list[dict]:
    tables = [dict() for _ in COMPACT_MAGNITUDES]
    exact = ["" for _ in COMPACT_MAGNITUDES]
    for key, pattern in section.items():
        match = re.match(r"^(\d+)-count-(.+)$", key)
        if match is None:
            continue
        magnitude = int(match.group(1))
        if magnitude not in COMPACT_MAGNITUDES:
            continue
        index = COMPACT_MAGNITUDES.index(magnitude)
        category = match.group(2)
        if category == "1":
            exact[index] = unquote_pattern(pattern)
        elif category in CATEGORIES:
            tables[index][category] = unquote_pattern(pattern)
    return [
        {
            "patterns": [tables[index].get(category, "") for category in CATEGORIES],
            "exact_one": exact[index],
        }
        for index in range(len(COMPACT_MAGNITUDES))
    ]

DIGITS = {
    "latn": "0123456789",
    "arab": "\u0660\u0661\u0662\u0663\u0664\u0665\u0666\u0667\u0668\u0669",
    "arabext": "\u06f0\u06f1\u06f2\u06f3\u06f4\u06f5\u06f6\u06f7\u06f8\u06f9",
    "deva": "\u0966\u0967\u0968\u0969\u096a\u096b\u096c\u096d\u096e\u096f",
    "beng": "\u09e6\u09e7\u09e8\u09e9\u09ea\u09eb\u09ec\u09ed\u09ee\u09ef",
}


def zig_string(value: str) -> str:
    result = '"'
    for byte in value.encode("utf-8"):
        if byte == 0x22:
            result += '\\"'
        elif byte == 0x5C:
            result += "\\\\"
        elif 0x20 <= byte < 0x7F:
            result += chr(byte)
        else:
            result += f"\\x{byte:02x}"
    result += '"'
    return result


def parse_locale(path: Path) -> tuple[str, dict]:
    document = json.loads(path.read_text(encoding="utf-8"))
    locale = next(iter(document["main"]))
    numbers = document["main"][locale]["numbers"]
    numbering_system = numbers.get("defaultNumberingSystem", "latn")
    symbols = numbers.get(f"symbols-numberSystem-{numbering_system}", {})
    decimal_pattern = (
        numbers.get(f"decimalFormats-numberSystem-{numbering_system}", {})
        .get("standard", "#,##0.###")
    )
    percent_pattern = (
        numbers.get(f"percentFormats-numberSystem-{numbering_system}", {})
        .get("standard", "#,##0%")
    )
    currency_pattern = (
        numbers.get(f"currencyFormats-numberSystem-{numbering_system}", {})
        .get("standard", "\u00a4#,##0.00")
    )
    digits = DIGITS.get(numbering_system, DIGITS["latn"])
    scientific_pattern = (
        numbers.get(f"scientificFormats-numberSystem-{numbering_system}", {})
        .get("standard", "#E0")
    )
    decimal_formats = numbers.get(
        f"decimalFormats-numberSystem-{numbering_system}",
        {},
    )
    compact_short = parse_compact(
        decimal_formats.get("short", {}).get("decimalFormat", {})
    )
    compact_long = parse_compact(
        decimal_formats.get("long", {}).get("decimalFormat", {})
    )
    currency_formats = numbers.get(
        f"currencyFormats-numberSystem-{numbering_system}",
        {},
    )
    currency_standard = currency_formats.get("standard", "\u00a4#,##0.00")
    currency_alpha = currency_formats.get(
        "standard-alphaNextToNumber",
        currency_standard,
    )
    currency_accounting = currency_formats.get(
        "accounting",
        currency_standard,
    )
    currency_accounting_alpha = currency_formats.get(
        "accounting-alphaNextToNumber",
        currency_accounting,
    )
    currency_unit_patterns = []
    for category in CATEGORIES:
        currency_unit_patterns.append(
            currency_formats.get(f"unitPattern-count-{category}")
            or currency_formats.get("unitPattern-count-other")
            or "{0} {1}"
        )
    return locale, {
        "digits": digits,
        "decimal": symbols.get("decimal", "."),
        "group": symbols.get("group", ","),
        "percent": symbols.get("percentSign", "%"),
        "minus": symbols.get("minusSign", "-"),
        "plus": symbols.get("plusSign", "+"),
        "nan": symbols.get("nan", "NaN"),
        "infinity": symbols.get("infinity", "\u221e"),
        "exponential": symbols.get("exponential", "E"),
        "decimal_pattern": decimal_pattern,
        "percent_pattern": percent_pattern,
        "currency_pattern": currency_pattern,
        "currency_alpha_pattern": currency_alpha,
        "currency_accounting_pattern": currency_accounting,
        "currency_accounting_alpha_pattern": currency_accounting_alpha,
        "currency_unit_patterns": currency_unit_patterns,
        "scientific_pattern": scientific_pattern,
        "compact_short": compact_short,
        "compact_long": compact_long,
        "min_grouping": int(numbers.get("minimumGroupingDigits", "1")),
    }


def render(entries: list[tuple[str, dict]]) -> str:
    lines = [
        "// Generated by tools/unicode/format/generate_numbers.py from CLDR 48.",
        "// Source: cldr-numbers-full/main/<locale>/numbers.json",
        "",
        "pub const Compact = struct {",
        "    patterns: [6][]const u8,",
        "    exact_one: []const u8,",
        "};",
        "",
        "pub const Locale = struct {",
        "    id: []const u8,",
        "    digits: [10]u21,",
        "    decimal: []const u8,",
        "    group: []const u8,",
        "    percent: []const u8,",
        "    minus: []const u8,",
        "    plus: []const u8,",
        "    nan: []const u8,",
        "    infinity: []const u8,",
        "    exponential: []const u8,",
        "    decimal_pattern: []const u8,",
        "    percent_pattern: []const u8,",
        "    currency_pattern: []const u8,",
        "    currency_alpha_pattern: []const u8,",
        "    currency_accounting_pattern: []const u8,",
        "    currency_accounting_alpha_pattern: []const u8,",
        "    currency_unit_patterns: [6][]const u8,",
        "    scientific_pattern: []const u8,",
        "    compact_short: [12]Compact,",
        "    compact_long: [12]Compact,",
        "    min_grouping: u8,",
        "};",
        "",
        "pub const locales = [_]Locale{",
    ]
    for locale, values in sorted(entries):
        digit_values = ", ".join(
            f"0x{ord(character):x}" for character in values["digits"]
        )
        short_values = compact_zig(values["compact_short"])
        long_values = compact_zig(values["compact_long"])
        unit_patterns = ", ".join(
            zig_string(value) for value in values["currency_unit_patterns"]
        )
        lines.append(
            "    .{ "
            f".id = {zig_string(locale)}, "
            f".digits = .{{ {digit_values} }}, "
            f".decimal = {zig_string(values['decimal'])}, "
            f".group = {zig_string(values['group'])}, "
            f".percent = {zig_string(values['percent'])}, "
            f".minus = {zig_string(values['minus'])}, "
            f".plus = {zig_string(values['plus'])}, "
            f".nan = {zig_string(values['nan'])}, "
            f".infinity = {zig_string(values['infinity'])}, "
            f".exponential = {zig_string(values['exponential'])}, "
            f".decimal_pattern = {zig_string(values['decimal_pattern'])}, "
            f".percent_pattern = {zig_string(values['percent_pattern'])}, "
            f".currency_pattern = {zig_string(values['currency_pattern'])}, "
            f".currency_alpha_pattern = {zig_string(values['currency_alpha_pattern'])}, "
            f".currency_accounting_pattern = {zig_string(values['currency_accounting_pattern'])}, "
            f".currency_accounting_alpha_pattern = {zig_string(values['currency_accounting_alpha_pattern'])}, "
            f".currency_unit_patterns = .{{ {unit_patterns} }}, "
            f".scientific_pattern = {zig_string(values['scientific_pattern'])}, "
            f".compact_short = {short_values}, "
            f".compact_long = {long_values}, "
            f".min_grouping = {values['min_grouping']} "
            "},"
        )
    lines.extend(["};", ""])
    return "\n".join(lines)


def compact_zig(table: list[dict]) -> str:
    entries = []
    for entry in table:
        patterns = ", ".join(zig_string(value) for value in entry["patterns"])
        entries.append(
            f".{{ .patterns = .{{ {patterns} }}, "
            f".exact_one = {zig_string(entry['exact_one'])} }}"
        )
    return ".{ " + ", ".join(entries) + " }"


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    input_dir = Path(sys.argv[1])
    out_dir = Path(sys.argv[2])
    out_dir.mkdir(parents=True, exist_ok=True)

    entries: list[tuple[str, dict]] = []
    for path in sorted(input_dir.glob("*.json")):
        entries.append(parse_locale(path))
    if not entries:
        raise SystemExit("no locale numbers.json files found")

    (out_dir / "numbers_data.zig").write_text(render(entries), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
