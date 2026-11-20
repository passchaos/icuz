#!/usr/bin/env python3
"""Generate CLDR 48 list, relative-time, and unit pattern tables.

Usage:
    generate_misc.py cldr-common-48.zip out_dir
"""

from __future__ import annotations

import hashlib
import struct
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


def all_units(archive: zipfile.ZipFile) -> list[str]:
    text = archive.read("common/main/en.xml").decode("utf-8")
    root = ET.fromstring(text)
    units: set[str] = set()
    for unit in root.findall(".//units/unitLength/unit"):
        unit_id = unit.get("type")
        if unit_id:
            units.add(unit_id)
    return sorted(units)


def unit_enum_name(unit_id: str) -> str:
    # The subtype (after the category prefix) is unique across CLDR units and
    # keeps the familiar `meter`/`kilometer_per_hour` names.
    return unit_id.split("-", 1)[1].replace("-", "_")


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
            "units": {"long": {}, "short": {}, "narrow": {}},
            "currencies": {},
        }
    root = ET.fromstring(text)
    data = {
        "list": {},
        "relative": {},
        "units": {"long": {}, "short": {}, "narrow": {}},
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
        raw_type = field.get("type", "")
        style = "long"
        unit = raw_type
        if raw_type.endswith("-short"):
            unit = raw_type[: -len("-short")]
            style = "short"
        elif raw_type.endswith("-narrow"):
            unit = raw_type[: -len("-narrow")]
            style = "narrow"
        if unit not in RELATIVE_UNITS:
            continue
        if field.find("alias") is not None:
            # CLDR aliases resolve in the current locale's context; the
            # resolver below implements that as a fallback to the locale's
            # long (or short) field.
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
        data["relative"].setdefault(unit, {})[style] = entry

    for unit_length in root.findall(".//units/unitLength"):
        form = unit_length.get("type")
        if form not in ("long", "short", "narrow"):
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
        if not code:
            continue
        # Only the standard symbol is used for currency formatting; CLDR
        # marks narrow/variant symbols with alt attributes and ICU ignores
        # them (falling back to the ISO code) when no standard symbol exists.
        symbol = ""
        for symbol_element in currency.findall("symbol"):
            if symbol_element.get("alt") is not None:
                continue
            if symbol_element.text:
                symbol = symbol_element.text
            break
        names: dict[str, str] = {}
        generic = None
        for display_name in currency.findall("displayName"):
            if display_name.get("alt") is not None:
                continue
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
            "symbol": symbol,
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


def relative_field(entry):
    field = {
        "past_relative": entry.get("relative", {}).get("-1", ""),
        "now_relative": entry.get("relative", {}).get("0", ""),
        "future_relative": entry.get("relative", {}).get("1", ""),
        "past": {},
        "future": {},
    }
    for direction in ("future", "past"):
        for category in CATEGORIES:
            field[direction][category] = (
                entry.get(direction, {}).get(category)
                or entry.get(direction, {}).get("other")
                or ""
            )
    return field


def resolve_relative(locale_data, parent_data, root_data):
    layers = [locale_data, parent_data, root_data]

    def style_entry(unit, style):
        for data in layers:
            entry = data["relative"].get(unit, {}).get(style)
            if entry is not None:
                return entry
        return None

    fields = []
    short_fields = []
    narrow_fields = []
    for unit in RELATIVE_UNITS:
        long_entry = style_entry(unit, "long") or {}
        short_entry = style_entry(unit, "short")
        short_effective = short_entry if short_entry is not None else long_entry
        narrow_entry = style_entry(unit, "narrow")
        narrow_effective = (
            narrow_entry if narrow_entry is not None else short_effective
        )
        long_field = relative_field(long_entry)
        short_field = relative_field(short_effective)
        narrow_field = relative_field(narrow_effective)
        fields.append(long_field)
        short_fields.append(short_field if short_field != long_field else None)
        narrow_fields.append(
            narrow_field if narrow_field != short_field else None
        )
    return {
        "fields": fields,
        "short_fields": short_fields,
        "narrow_fields": narrow_fields,
    }


def unit_pattern(layers, form, unit_id, category):
    for data in layers:
        patterns = data["units"][form].get(unit_id, {})
        value = patterns.get(category) or patterns.get("other")
        if value:
            return value
    return ""


def resolve_units(locale_data, parent_data, root_data, units):
    layers = [locale_data, parent_data, root_data]
    result = {}
    for unit_id in units:
        entry = {"long": {}, "short": {}, "narrow": {}}
        for category in CATEGORIES:
            long_value = unit_pattern(layers, "long", unit_id, category)
            if not long_value:
                long_value = unit_pattern(layers, "short", unit_id, category)
            short_value = unit_pattern(layers, "short", unit_id, category)
            if not short_value:
                short_value = long_value
            narrow_value = unit_pattern(layers, "narrow", unit_id, category)
            if not narrow_value:
                narrow_value = short_value
            entry["long"][category] = long_value
            entry["short"][category] = short_value
            entry["narrow"][category] = narrow_value
        result[unit_id] = entry
    return result


def parse_currency_fractions(
    archive: zipfile.ZipFile,
) -> dict[str, tuple[int, int, int]]:
    """Return code -> (digits, cash_digits, cash_rounding)."""
    text = archive.read("common/supplemental/supplementalData.xml").decode("utf-8")
    root = ET.fromstring(text)
    result: dict[str, tuple[int, int, int]] = {}
    for info in root.findall(".//currencyData/fractions/info"):
        code = info.get("iso4217")
        if not code or code in result:
            continue
        try:
            digits = int(info.get("digits", "2"))
            cash_digits = int(info.get("cashDigits", digits))
            cash_rounding = int(
                info.get("cashRounding", info.get("rounding", "0"))
            )
        except ValueError:
            continue
        result[code] = (digits, cash_digits, cash_rounding)
    return result


def resolve_currencies(locale_data, parent_data, root_data, codes):
    layers = [locale_data, parent_data, root_data]
    result = {}
    for code in codes:
        symbol = layer_value(
            layers,
            lambda data, code=code: data["currencies"].get(code, {}).get("symbol"),
        ) or ""
        names = {}
        for category in CATEGORIES:
            names[category] = layer_value(
                layers,
                lambda data, code=code, category=category: (
                    data["currencies"].get(code, {}).get("names", {}).get(category)
                    or data["currencies"].get(code, {}).get("names", {}).get("other")
                ),
            ) or ""
        result[code] = {"symbol": symbol, "names": names}
    return result


def render_currencies(compiled, fractions, codes) -> bytes:
    strings = bytearray(b"\x00")
    offsets: dict[str, int] = {"": 0}

    def intern(value: str) -> int:
        if not value:
            return 0
        if value in offsets:
            return offsets[value]
        offset = len(strings)
        strings.extend(value.encode("utf-8"))
        strings.append(0)
        offsets[value] = offset
        return offset

    code_bytes = bytearray()
    code_index = {}
    for index, code in enumerate(codes):
        code_index[code] = index
        digits, cash_digits, cash_rounding = fractions.get(code, (2, 2, 0))
        code_bytes += struct.pack(
            "<IBBBx",
            intern(code),
            digits,
            cash_digits,
            cash_rounding,
        )

    entry_bytes = bytearray()
    locale_bytes = bytearray()
    entry_count = 0
    for locale in sorted(compiled):
        start = entry_count
        for code in codes:
            entry = compiled[locale]["currencies"][code]
            names = [entry["names"][category] for category in CATEGORIES]
            if not entry["symbol"] and not any(names):
                continue
            entry_bytes += struct.pack(
                "<H2xIIIIIII",
                code_index[code],
                intern(entry["symbol"]),
                *(intern(name) for name in names),
            )
            entry_count += 1
        id_offset = intern(locale)
        locale_bytes += struct.pack(
            "<IBBHH2x",
            id_offset,
            len(locale.encode("utf-8")),
            0,
            start,
            entry_count - start,
        )
    header = bytearray(b"CJGD")
    header += struct.pack(
        "<B3xHHIII",
        2,
        len(compiled),
        len(codes),
        entry_count,
        len(strings),
        0,
    )
    return bytes(header + code_bytes + locale_bytes + entry_bytes + strings)


def all_currency_codes(archive: zipfile.ZipFile) -> list[str]:
    codes: set[str] = set()
    for name in ("en", "root"):
        text = archive.read(f"common/main/{name}.xml")
        document = ET.fromstring(text)
        for currency in document.findall(".//currencies/currency"):
            code = currency.get("type")
            if code:
                codes.add(code)
    return sorted(codes)



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
        "    short_fields: [7]?Field,",
        "    narrow_fields: [7]?Field,",
        "};",
        "",
        "pub const locales = [_]Locale{",
    ]
    def render_fields(key: str, optional: bool) -> list[str]:
        result = []
        for entry in compiled_current["relative"][key]:
            if entry is None:
                result.append("        null,")
                continue
            past = ", ".join(zig_string(entry["past"][c]) for c in CATEGORIES)
            future = ", ".join(zig_string(entry["future"][c]) for c in CATEGORIES)
            result.append("        .{")
            result.append(f"            .past_relative = {zig_string(entry['past_relative'])},")
            result.append(f"            .now_relative = {zig_string(entry['now_relative'])},")
            result.append(f"            .future_relative = {zig_string(entry['future_relative'])},")
            result.append(f"            .past = .{{ {past} }},")
            result.append(f"            .future = .{{ {future} }},")
            result.append("        },")
        return result

    for locale in sorted(compiled):
        compiled_current = compiled[locale]
        lines.append(f"    .{{ .id = {zig_string(locale)},")
        lines.append("        .fields = .{")
        lines.extend(render_fields("fields", False))
        lines.append("        },")
        lines.append("        .short_fields = .{")
        lines.extend(render_fields("short_fields", True))
        lines.append("        },")
        lines.append("        .narrow_fields = .{")
        lines.extend(render_fields("narrow_fields", True))
        lines.append("        },")
        lines.append("    },")
    lines.extend(["};", ""])
    return "\n".join(lines)


def render_units_zig(units: list[str]) -> str:
    lines = [
        "// Generated by tools/unicode/format/generate_misc.py from CLDR 48.",
        f"// cldr-common-48.zip SHA-256: {CLDR_SHA256}",
        "",
        "pub const Unit = enum {",
    ]
    names = [unit_enum_name(unit_id) for unit_id in units]
    if len(set(names)) != len(names):
        raise SystemExit("unit enum names collide")
    for name in names:
        lines.append(f"    {name},")
    lines.extend(["};", "", "pub const unit_ids = [_][]const u8{"])
    for unit_id in units:
        lines.append(f"    {zig_string(unit_id)},")
    lines.extend(["};", ""])
    return "\n".join(lines)


def render_units_blob(compiled: dict[str, dict], units: list[str]) -> bytes:
    strings = bytearray(b"\x00")
    offsets: dict[str, int] = {"": 0}

    def intern(value: str) -> int:
        if not value:
            return 0
        if value in offsets:
            return offsets[value]
        offset = len(strings)
        strings.extend(value.encode("utf-8"))
        strings.append(0)
        offsets[value] = offset
        return offset

    entry_bytes = bytearray()
    locale_bytes = bytearray()
    entry_count = 0
    for locale in sorted(compiled):
        start = entry_count
        keys: list[tuple[int, str]] = []
        for unit_index, unit_id in enumerate(units):
            entry = compiled[locale]["units"][unit_id]
            for style_index, form in enumerate(("long", "short", "narrow")):
                for category_index, category in enumerate(CATEGORIES):
                    pattern = entry[form][category]
                    if not pattern:
                        continue
                    key = (unit_index * 18) + style_index * 6 + category_index
                    keys.append((key, pattern))
        for key, pattern in sorted(keys):
            entry_bytes += struct.pack("<HIH", key, intern(pattern), 0)
            entry_count += 1
        id_offset = intern(locale)
        locale_bytes += struct.pack(
            "<IB3xIH2x",
            id_offset,
            len(locale.encode("utf-8")),
            start,
            entry_count - start,
        )
    header = bytearray(b"CJUN")
    header += struct.pack(
        "<B3xHHIII",
        2,
        len(compiled),
        len(units),
        entry_count,
        len(strings),
        0,
    )
    return bytes(header + locale_bytes + entry_bytes + strings)


def parse_currency_regions(archive: zipfile.ZipFile) -> dict[str, str]:
    text = archive.read("common/supplemental/supplementalData.xml").decode("utf-8")
    root = ET.fromstring(text)
    result: dict[str, str] = {}
    for region in root.findall(".//currencyData/region"):
        region_code = region.get("iso3166")
        if not region_code:
            continue
        for currency in region.findall("currency"):
            if currency.get("to") is not None:
                continue
            code = currency.get("iso4217")
            if code:
                result[region_code] = code
                break
    return result


def render_currency_regions(regions: dict[str, str]) -> str:
    lines = [
        "// Generated by tools/unicode/format/generate_misc.py from CLDR 48.",
        f"// cldr-common-48.zip SHA-256: {CLDR_SHA256}",
        "",
        "pub const Region = struct {",
        "    id: []const u8,",
        "    code: []const u8,",
        "};",
        "",
        "/// Sorted by region code.",
        "pub const regions = [_]Region{",
    ]
    for region in sorted(regions):
        lines.append(f'    .{{ .id = "{region}", .code = "{regions[region]}" }},')
    lines.append("};")
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    archive_path = Path(sys.argv[1])
    out_dir = Path(sys.argv[2])
    out_dir.mkdir(parents=True, exist_ok=True)

    archive = checked_zip(archive_path)
    currency_codes = all_currency_codes(archive)
    units = all_units(archive)
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
                "units": {"long": {}, "short": {}, "narrow": {}},
                "currencies": {},
            },
        )
        locale_data = parsed[locale]
        compiled[locale] = {
            "list": resolve_list(locale_data, parent, root_data),
            "relative": resolve_relative(locale_data, parent, root_data),
            "units": resolve_units(locale_data, parent, root_data, units),
            "currencies": resolve_currencies(
                locale_data, parent, root_data, currency_codes
            ),
        }

    (out_dir / "list_data.zig").write_text(render_list(compiled), encoding="utf-8")
    (out_dir / "relative_data.zig").write_text(render_relative(compiled), encoding="utf-8")
    (out_dir / "units_data.zig").write_text(render_units_zig(units), encoding="utf-8")
    (out_dir / "units_data.bin").write_bytes(render_units_blob(compiled, units))
    (out_dir / "currencies_data.bin").write_bytes(
        render_currencies(
            compiled,
            parse_currency_fractions(archive),
            currency_codes,
        )
    )
    (out_dir / "currency_regions.zig").write_text(
        render_currency_regions(parse_currency_regions(archive)),
        encoding="utf-8",
    )
    print(
        f"generated {len(compiled)} locales: "
        f"{len(LIST_STYLES)} list styles, {len(RELATIVE_UNITS)} relative fields, "
        f"{len(units)} units",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
