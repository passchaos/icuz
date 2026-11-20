#!/usr/bin/env python3
"""Generate CLDR day-period rules and names.

Usage:
    generate_day_periods.py cldr-common-48.zip out_dir

Reads `common/supplemental/dayPeriods.xml` for the time ranges and the
`common/main/<locale>.xml` day-period names, then emits
`day_periods_data.zig` for the locales used by the date formatter.
"""

from __future__ import annotations

import hashlib
import sys
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from generate_dates import LOCALES, PARENT, zig_string  # noqa: E402

CLDR_SHA256 = "06c7c698d6fd8d67cefac15a0206b0109b00e0ef1636f86f84449fa959561f74"
CLDR_VERSION = 48

PERIODS = (
    "am",
    "pm",
    "midnight",
    "noon",
    "morning1",
    "morning2",
    "afternoon1",
    "afternoon2",
    "evening1",
    "evening2",
    "night1",
    "night2",
)
PERIOD_INDEX = {name: index for index, name in enumerate(PERIODS)}
WIDTHS = ("wide", "abbreviated", "narrow")


def parse_time(value: str) -> int:
    hour, minute = value.split(":")
    return int(hour) * 60 + int(minute)


def parent_chain(locale: str) -> list[str]:
    chain: list[str] = []
    current = locale
    seen: set[str] = set()
    while current not in seen:
        seen.add(current)
        chain.append(current)
        if current == "root":
            break
        parent = PARENT.get(current)
        if parent is None:
            parent = current.split("-")[0].replace("_", "-")
        if parent == current:
            parent = "root"
        current = parent
    if chain[-1] != "root":
        chain.append("root")
    return chain


def load_rules(archive: zipfile.ZipFile) -> dict[str, list[tuple[int, int, str]]]:
    root = ET.fromstring(archive.read("common/supplemental/dayPeriods.xml"))
    rules: dict[str, list[tuple[int, int, str]]] = {}
    for group in root.iter("dayPeriodRules"):
        parsed: list[tuple[int, int, str]] = []
        for element in group.iter("dayPeriodRule"):
            period = element.get("type", "")
            if period not in PERIOD_INDEX:
                continue
            at = element.get("at")
            if at is not None:
                minute = parse_time(at)
                parsed.append((minute, minute, period))
                continue
            start = element.get("from")
            before = element.get("before")
            if start is None or before is None:
                continue
            parsed.append((parse_time(start), parse_time(before), period))
        parsed.sort()
        for locale in group.get("locales", "").split():
            rules.setdefault(locale.replace("-", "_"), parsed)
    rules.setdefault(
        "root",
        [(0, 720, "am"), (720, 1440, "pm")],
    )
    return rules


def load_names(
    archive: zipfile.ZipFile,
) -> dict[str, dict[str, dict[str, str]]]:
    """locale -> width -> period -> name (format context only)."""
    names: dict[str, dict[str, dict[str, str]]] = {}
    for name in archive.namelist():
        if not name.startswith("common/main/") or not name.endswith(".xml"):
            continue
        locale = name[len("common/main/") : -len(".xml")].replace("-", "_")
        try:
            root = ET.fromstring(archive.read(name))
        except ET.ParseError:
            continue
        widths: dict[str, dict[str, str]] = {}
        for context in root.iter("dayPeriodContext"):
            if context.get("type") != "format":
                continue
            for width in context.iter("dayPeriodWidth"):
                width_name = width.get("type", "")
                if width_name not in WIDTHS:
                    continue
                values = widths.setdefault(width_name, {})
                for element in width.iter("dayPeriod"):
                    if element.get("alt") is not None:
                        continue
                    period = element.get("type", "")
                    if period in PERIOD_INDEX and period not in values:
                        values[period] = element.text or ""
        if widths:
            names[locale] = widths
    return names


def resolve_names(
    locale: str,
    names: dict[str, dict[str, dict[str, str]]],
) -> dict[str, dict[str, str]]:
    result: dict[str, dict[str, str]] = {width: {} for width in WIDTHS}
    for candidate in parent_chain(locale):
        key = candidate.replace("-", "_")
        values = names.get(key)
        if values is None:
            continue
        for width in WIDTHS:
            for period, value in values.get(width, {}).items():
                result[width].setdefault(period, value)
    # CLDR uses width aliases (for example root narrow -> abbreviated).
    for period in PERIODS:
        if not result["abbreviated"].get(period):
            result["abbreviated"][period] = (
                result["wide"].get(period, "") or result["narrow"].get(period, "")
            )
        if not result["wide"].get(period):
            result["wide"][period] = result["abbreviated"].get(period, "")
        if not result["narrow"].get(period):
            result["narrow"][period] = result["abbreviated"].get(period, "")
    return result


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    archive_path = Path(sys.argv[1])
    out_dir = Path(sys.argv[2])
    data = archive_path.read_bytes()
    actual = hashlib.sha256(data).hexdigest()
    if actual != CLDR_SHA256:
        raise SystemExit(
            f"{archive_path}: expected CLDR {CLDR_VERSION} SHA-256 "
            f"{CLDR_SHA256}, found {actual}"
        )
    with zipfile.ZipFile(archive_path) as archive:
        rules = load_rules(archive)
        names = load_names(archive)

    lines = [
        f"// Generated by tools/unicode/format/generate_day_periods.py from CLDR {CLDR_VERSION}.",
        f"// cldr-common-48.zip SHA-256: {CLDR_SHA256}",
        "",
        "pub const Period = enum(u8) {",
    ]
    for period in PERIODS:
        lines.append(f"    {period},")
    lines.extend(
        [
            "};",
            "",
            "pub const Rule = struct {",
            "    /// Start minute of day, inclusive.",
            "    start: u16,",
            "    /// End minute of day, exclusive; equal to `start` for an exact time.",
            "    end: u16,",
            "    period: Period,",
            "};",
            "",
            "pub const LocaleRules = struct {",
            "    id: []const u8,",
            "    rules: []const Rule,",
            "};",
            "",
            "pub const LocaleNames = struct {",
            "    id: []const u8,",
            "    wide: [12][]const u8,",
            "    abbreviated: [12][]const u8,",
            "    narrow: [12][]const u8,",
            "};",
            "",
            "/// Sorted by locale.",
            "pub const locale_rules = [_]LocaleRules{",
        ]
    )

    root_rules = rules.get("root", [(0, 720, "am"), (720, 1440, "pm")])
    rule_entries: list[tuple[str, list[tuple[int, int, str]]]] = [
        ("root", root_rules)
    ]
    for locale in LOCALES:
        chain = parent_chain(locale)
        chosen = None
        for candidate in chain:
            key = candidate.replace("-", "_")
            if key in rules:
                chosen = rules[key]
                break
        if chosen is None or chosen == root_rules:
            continue
        rule_entries.append((locale.replace("-", "_"), chosen))
    rule_entries.sort()

    for key, entry_rules in rule_entries:
        lines.append(f'    .{{ .id = "{key}", .rules = &[_]Rule{{')
        for start, end, period in entry_rules:
            lines.append(
                f"        .{{ .start = {start}, .end = {end}, "
                f".period = .{period} }},"
            )
        lines.append("    } },")
    lines.extend(
        [
            "};",
            "",
            "/// Sorted by locale.",
            "pub const locale_names = [_]LocaleNames{",
        ]
    )

    name_entries: list[tuple[str, dict[str, dict[str, str]]]] = [
        ("root", resolve_names("root", names))
    ]
    for locale in LOCALES:
        name_entries.append(
            (locale.replace("-", "_"), resolve_names(locale, names))
        )
    name_entries.sort()
    for key, resolved in name_entries:
        lines.append(f'    .{{ .id = "{key}",')
        for width in WIDTHS:
            values = resolved[width]
            lines.append(f"        .{width} = .{{")
            for period in PERIODS:
                value = values.get(period, "")
                lines.append(f"            {zig_string(value)},")
            lines.append("        },")
        lines.append("    },")

    lines.append("};")
    lines.append("")

    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "day_periods_data.zig").write_text("\n".join(lines))
    print(
        f"wrote {out_dir / 'day_periods_data.zig'}: "
        f"{len(rule_entries)} rule sets, {len(name_entries)} name sets"
    )


if __name__ == "__main__":
    main()
