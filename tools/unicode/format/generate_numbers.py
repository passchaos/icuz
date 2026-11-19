#!/usr/bin/env python3
"""Generate CLDR 48 decimal/percent/currency formatting data.

Usage:
    generate_numbers.py cldr-common-48.zip out_dir

Locale data is read from `common/main/<locale>.xml` and resolved through
the CLDR parent chain (locale -> language -> root).
"""

from __future__ import annotations

import copy
import json
import re
import sys
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

CATEGORIES = ("zero", "one", "two", "few", "many", "other")
COMPACT_MAGNITUDES = tuple(10**power for power in range(3, 15))

LOCALES = (
    "af", "ak", "am", "ar", "az", "be", "bg", "bn", "bs", "ca", "ccp",
    "chr", "cs", "cy", "da", "de", "de-AT", "de-CH", "ee", "el", "en",
    "en-001", "en-AU", "en-CA", "en-GB", "en-IN", "eo", "es", "es-419",
    "es-MX", "et", "eu", "fa", "fa-AF", "ff", "fi", "fil", "fo", "fr",
    "fr-BE", "fr-CA", "fr-CH", "ga", "gl", "gu", "he", "hi", "hr", "hu",
    "hy", "id", "is", "it", "ja", "ka", "kk", "kl", "km", "kn", "ko",
    "ky", "lb", "lo", "lrc", "lt", "lv", "mk", "ml", "mn", "mr", "ms",
    "mt", "my", "nb", "ne", "nl", "nl-BE", "nn", "no", "pa", "pl", "ps",
    "pt", "pt-PT", "qu", "ro", "ru", "se", "si", "sk", "sl", "sq", "sr",
    "sr-Latn", "su", "sv", "sw", "ta", "te", "th", "tr", "uk", "ur",
    "uz", "vec", "vi", "yue", "yue-Hans", "zh", "zh-Hant", "zu",
)

PARENT = {
    "de-AT": "de",
    "de-CH": "de",
    "en-AU": "en-001",
    "en-CA": "en-001",
    "en-GB": "en-001",
    "en-IN": "en-001",
    "es-419": "es",
    "es-MX": "es-419",
    "fr-CA": "fr",
    "nb": "no",
    "nn": "no",
    "nl-BE": "nl",
    "pt-PT": "pt",
    "zh-Hant": "root",
}


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
    )
    if currency_accounting_alpha is None:
        # CLDR derives the accounting alpha pattern from the standard one
        # when the accounting pattern matches the standard pattern.
        currency_accounting_alpha = (
            currency_alpha
            if currency_accounting == currency_standard
            else currency_accounting
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
        "// Source: cldr-common-48 common/main/<locale>.xml (parent-resolved)",
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


def merge_dict(target: dict, source: dict) -> None:
    for key, value in source.items():
        if isinstance(value, dict) and isinstance(target.get(key), dict):
            merge_dict(target[key], value)
        else:
            # Deep-copy so later merges never mutate a cached locale tree.
            target[key] = copy.deepcopy(value)


def numbers_dict(element) -> dict:
    """Convert a CLDR `<numbers>` element into the resolved JSON shape."""
    result: dict = {}
    for child in element:
        tag = child.tag
        if tag == "defaultNumberingSystem":
            if child.text:
                result["defaultNumberingSystem"] = child.text
            continue
        if tag == "minimumGroupingDigits":
            if child.text:
                result["minimumGroupingDigits"] = child.text
            continue
        number_system = child.get("numberSystem", "latn")
        if tag == "symbols":
            symbols = result.setdefault("symbols", {}).setdefault(
                number_system,
                {},
            )
            for item in child:
                if item.text is not None:
                    symbols[item.tag] = item.text
            continue
        formats = result.setdefault(tag, {}).setdefault(number_system, {})
        if tag == "currencyFormats":
            for item in child:
                if item.tag == "unitPattern":
                    count = item.get("count", "other")
                    formats[f"unitPattern-count-{count}"] = item.text or ""
                    continue
                if item.tag != "currencyFormatLength":
                    continue
                for fmt in item:
                    if fmt.tag != "currencyFormat":
                        continue
                    format_type = fmt.get("type", "standard")
                    if format_type not in ("standard", "accounting"):
                        continue
                    for pattern in fmt:
                        if pattern.tag != "pattern":
                            continue
                        if pattern.get("type") is not None or pattern.get("count") is not None:
                            continue
                        alt = pattern.get("alt")
                        if alt is not None and alt != "alphaNextToNumber":
                            continue
                        suffix = (
                            "-alphaNextToNumber"
                            if alt == "alphaNextToNumber"
                            else ""
                        )
                        formats[format_type + suffix] = pattern.text or ""
            continue
        for length in child:
            if not length.tag.endswith("FormatLength"):
                continue
            length_type = length.get("type", "standard")
            for fmt in length:
                for pattern in fmt:
                    if pattern.tag != "pattern":
                        continue
                    pattern_type = pattern.get("type")
                    count = pattern.get("count")
                    if pattern_type is not None and count is not None:
                        formats.setdefault(length_type, {}).setdefault(
                            "decimalFormat",
                            {},
                        )[f"{pattern_type}-count-{count}"] = pattern.text or ""
                    elif length_type == "standard":
                        formats[length_type] = pattern.text or ""
                    elif length_type in ("short", "long"):
                        formats.setdefault(length_type, {}).setdefault(
                            "decimalFormat",
                            {},
                        )["pattern"] = pattern.text or ""
    return result


def parent_chain(locale: str) -> list[str]:
    chain = []
    current = locale
    seen: set[str] = set()
    while current not in seen:
        seen.add(current)
        chain.append(current)
        if current == "root":
            break
        parent = PARENT.get(current)
        if parent is None:
            parent = re.split(r"[-_]", current)[0]
        if parent == current:
            parent = "root"
        current = parent
    if chain[-1] != "root":
        chain.append("root")
    return chain


def load_numbers(archive: zipfile.ZipFile, locale: str, cache: dict) -> dict:
    if locale in cache:
        return cache[locale]
    try:
        filename = locale.replace("-", "_")
        xml = archive.read(f"common/main/{filename}.xml").decode("utf-8")
    except KeyError:
        cache[locale] = {}
        return cache[locale]
    root = ET.fromstring(xml)
    element = root.find(".//numbers")
    cache[locale] = numbers_dict(element) if element is not None else {}
    return cache[locale]


def resolved_numbers(
    archive: zipfile.ZipFile,
    locale: str,
    cache: dict,
    merged_cache: dict,
) -> dict:
    if locale in merged_cache:
        return merged_cache[locale]
    merged: dict = {}
    for name in reversed(parent_chain(locale)):
        merge_dict(merged, load_numbers(archive, name, cache))
    merged_cache[locale] = merged
    return merged


def parse_locale_xml(
    archive: zipfile.ZipFile,
    locale: str,
    cache: dict,
    merged_cache: dict,
) -> tuple[str, dict]:
    numbers = resolved_numbers(archive, locale, cache, merged_cache)
    numbering_system = numbers.get("defaultNumberingSystem", "latn")
    symbols = numbers.get("symbols", {}).get(numbering_system, {})
    decimal_formats = numbers.get("decimalFormats", {}).get(numbering_system, {})
    # Root aliases the compact long format to short (`alias source="locale"`),
    # so a locale without a real long section anywhere in its chain uses its
    # own resolved short patterns.
    has_long = False
    for name in parent_chain(locale):
        if name == "root":
            continue
        data = load_numbers(archive, name, cache)
        if "long" in data.get("decimalFormats", {}).get(numbering_system, {}):
            has_long = True
            break
    if not has_long:
        decimal_formats = dict(decimal_formats)
        decimal_formats["long"] = decimal_formats.get("short", {})
    decimal_pattern = decimal_formats.get("standard", "#,##0.###")
    percent_pattern = (
        numbers.get("percentFormats", {})
        .get(numbering_system, {})
        .get("standard", "#,##0%")
    )
    currency_formats = numbers.get("currencyFormats", {}).get(
        numbering_system,
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
    )
    if currency_accounting_alpha is None:
        # CLDR derives the accounting alpha pattern from the standard one
        # when the accounting pattern matches the standard pattern.
        currency_accounting_alpha = (
            currency_alpha
            if currency_accounting == currency_standard
            else currency_accounting
        )
    currency_unit_patterns = []
    for category in CATEGORIES:
        currency_unit_patterns.append(
            currency_formats.get(f"unitPattern-count-{category}")
            or currency_formats.get("unitPattern-count-other")
            or "{0} {1}"
        )
    scientific_pattern = (
        numbers.get("scientificFormats", {})
        .get(numbering_system, {})
        .get("standard", "#E0")
    )
    digits = DIGITS.get(numbering_system, DIGITS["latn"])
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
        "currency_pattern": currency_standard,
        "currency_alpha_pattern": currency_alpha,
        "currency_accounting_pattern": currency_accounting,
        "currency_accounting_alpha_pattern": currency_accounting_alpha,
        "currency_unit_patterns": currency_unit_patterns,
        "scientific_pattern": scientific_pattern,
        "compact_short": parse_compact(
            decimal_formats.get("short", {}).get("decimalFormat", {})
        ),
        "compact_long": parse_compact(
            decimal_formats.get("long", {}).get("decimalFormat", {})
        ),
        "min_grouping": int(numbers.get("minimumGroupingDigits", "1")),
    }


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    archive_path = Path(sys.argv[1])
    out_dir = Path(sys.argv[2])
    out_dir.mkdir(parents=True, exist_ok=True)

    cache: dict = {}
    merged_cache: dict = {}
    entries: list[tuple[str, dict]] = []
    with zipfile.ZipFile(archive_path) as archive:
        for locale in LOCALES:
            entries.append(
                parse_locale_xml(archive, locale, cache, merged_cache)
            )
    if not entries:
        raise SystemExit("no locale data found")

    (out_dir / "numbers_data.zig").write_text(render(entries), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
