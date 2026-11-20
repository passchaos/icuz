#!/usr/bin/env python3
"""Generate CLDR date/time interval patterns.

Usage:
    generate_intervals.py cldr-common-48.zip out_dir

Extracts `intervalFormats` for the Gregorian calendar from CLDR, resolves the
parent chain, splits each interval pattern at the locale's fallback separator,
and emits a `CJIV` v1 blob.
"""

from __future__ import annotations

import re
import struct
import sys
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

LOCALES = (
    "af", "ak", "am", "ar", "az", "be", "bg", "bn", "bs", "ca", "ccp",
    "chr", "cs", "cy", "da", "de", "de-AT", "de-CH", "ee", "el", "en",
    "en-001", "en-AU", "en-CA", "en-GB", "en-IN", "eo", "es", "es-419",
    "es-MX", "et", "eu", "fa", "fa-AF", "ff", "fi", "fil", "fo", "fr",
    "fr-BE", "fr-CA", "ga", "gl", "gu", "he", "hi", "hr", "hu",
    "hy", "id", "is", "it", "ja", "ka", "kk", "km", "kn", "ko", "ky",
    "lb", "lo", "lrc", "lt", "lv", "mk", "ml", "mn", "mr", "ms",
    "mt", "my", "nb", "ne", "nl", "nl-BE", "nn", "no", "pa", "pl", "ps",
    "pt", "pt-PT", "qu", "ro", "ru", "se", "si", "sk", "sl", "sq", "sr",
    "su", "sv", "sw", "ta", "te", "th", "tr", "uk", "ur",
    "uz", "vec", "vi", "yue", "yue-Hans", "zh", "zh-Hant", "zu",
)

PARENT = {
    "de-AT": "de", "de-CH": "de", "en-001": "en", "en-AU": "en-001",
    "en-CA": "en-001", "en-GB": "en-001", "en-IN": "en-001",
    "es-419": "es", "es-MX": "es-419", "fa-AF": "fa", "fr-BE": "fr",
    "fr-CA": "fr", "nb": "no", "nn": "no", "nl-BE": "nl", "pt-PT": "pt",
    "yue-Hans": "yue", "zh-Hant": "root",
}

# Skeleton ids match src/unicode/format/intervals.zig.
SKELETONS = (
    ("yMd", 0),
    ("yMMMd", 1),
    ("yMMMMd", 2),
    ("yMMMMEEEEd", 3),
    ("Hm", 4),
    ("hm", 5),
    ("H", 6),
    ("h", 7),
)

KEY_IDS = {"y": 0, "M": 1, "d": 2, "H": 3, "h": 3, "m": 4, "s": 5, "a": 6,
           "B": 6, "G": 7}

DEFAULT_FALLBACK = "{0} \u2013 {1}"

# ICU UDateTimePatternField order: era, year, quarter, month, week-of-year,
# week-of-month, weekday, day-of-year, day-of-week-in-month, day, dayperiod,
# hour, minute, second, fractional second, zone.
SKELETON_ORDER = "GyYuUrUQqMLlwWEecDFdgabBHkhKJjCmsASvzZOVXx"


def canonical_skeleton(skeleton: str) -> str:
    fields: dict[int, tuple[str, int]] = {}
    index = 0
    while index < len(skeleton):
        letter = skeleton[index]
        end = index
        while end < len(skeleton) and skeleton[end] == letter:
            end += 1
        position = SKELETON_ORDER.find(letter)
        # ICU keeps the last letter provided for a field.
        fields[position if position >= 0 else len(SKELETON_ORDER) + index] = (
            letter,
            end - index,
        )
        index = end
    return "".join(
        letter * count for letter, count in (fields[key] for key in sorted(fields))
    )


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


def load(archive: zipfile.ZipFile, locale: str, cache: dict):
    if locale in cache:
        return cache[locale]
    filename = locale.replace("-", "_")
    try:
        text = archive.read(f"common/main/{filename}.xml")
    except KeyError:
        cache[locale] = None
        return None
    document = ET.fromstring(text)
    cache[locale] = document
    return document


def interval_formats(document):
    if document is None:
        return None
    return document.find(
        ".//dates/calendars/calendar[@type='gregorian']/dateTimeFormats/intervalFormats"
    )


def split_pattern_into_two_parts(pattern: str) -> tuple[str, str] | None:
    """Split an interval pattern at the first repeated pattern letter."""
    seen: set[str] = set()
    previous = ""
    count = 0
    in_quote = False
    index = 0
    found = False
    while index < len(pattern):
        character = pattern[index]
        if character != previous and count > 0:
            if previous in seen:
                found = True
                break
            seen.add(previous)
            count = 0
        if character == "'":
            if index + 1 < len(pattern) and pattern[index + 1] == "'":
                index += 1
            else:
                in_quote = not in_quote
        elif not in_quote and character.isalpha():
            previous = character
            count += 1
        index += 1
    if count > 0 and not found:
        if previous not in seen:
            count = 0
    split = index - count
    if split <= 0 or split >= len(pattern):
        return None
    return pattern[:split], pattern[split:]


def render(locale_entries: dict[str, tuple[str, list]], skeleton_ids: list[str]) -> bytes:
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

    skeleton_offsets = [intern(item_id) for item_id in skeleton_ids]
    entry_bytes = bytearray()
    locale_bytes = bytearray()
    for locale in sorted(locale_entries):
        fallback, entries = locale_entries[locale]
        start = len(entry_bytes) // 12
        for skeleton_id, key_id, left, right in entries:
            entry_bytes += struct.pack(
                "<BBHII",
                skeleton_id,
                key_id,
                0,
                intern(left),
                intern(right),
            )
        id_offset = intern(locale)
        locale_bytes += struct.pack(
            "<IBBHHIH",
            id_offset,
            len(locale.encode("utf-8")),
            0,
            start,
            len(entries),
            intern(fallback),
            0,
        )
    header = bytearray(b"CJIV")
    header += struct.pack(
        "<B3xHHIII",
        2,
        len(locale_entries),
        0,
        len(entry_bytes) // 12,
        len(strings),
        len(skeleton_ids),
    )
    skeleton_bytes = b"".join(struct.pack("<I", offset) for offset in skeleton_offsets)
    return bytes(header + skeleton_bytes + locale_bytes + entry_bytes + strings)


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    archive_path = Path(sys.argv[1])
    out_dir = Path(sys.argv[2])
    out_dir.mkdir(parents=True, exist_ok=True)

    cache: dict = {}
    result = {}
    with zipfile.ZipFile(archive_path) as archive:
        discovered: set[str] = set()
        for locale in LOCALES:
            for name in parent_chain(locale):
                element = interval_formats(load(archive, name, cache))
                if element is None:
                    continue
                for item in element.findall("intervalFormatItem"):
                    item_id = item.get("id") or ""
                    if "B" in item_id:
                        continue
                    discovered.add(canonical_skeleton(item_id))
        skeleton_ids = [canonical_skeleton(raw) for raw, _ in SKELETONS]
        for canonical in sorted(discovered):
            if canonical not in skeleton_ids:
                skeleton_ids.append(canonical)
        skeleton_index = {
            canonical: index for index, canonical in enumerate(skeleton_ids)
        }

        for locale in LOCALES:
            fallback = None
            entries: dict[tuple[int, int], tuple[str, str]] = {}
            for name in parent_chain(locale):
                element = interval_formats(load(archive, name, cache))
                if element is None:
                    continue
                value = element.findtext("intervalFormatFallback")
                if value and fallback is None:
                    fallback = value.strip()
                for item in element.findall("intervalFormatItem"):
                    item_id = item.get("id") or ""
                    if "B" in item_id:
                        continue
                    skeleton_id = skeleton_index.get(
                        canonical_skeleton(item_id)
                    )
                    if skeleton_id is None:
                        continue
                    for difference in item.findall("greatestDifference"):
                        key_id = KEY_IDS.get(difference.get("id"))
                        pattern = (difference.text or "").strip()
                        if key_id is None or not pattern:
                            continue
                        entries.setdefault((skeleton_id, key_id), (pattern, ""))
            fallback = fallback or DEFAULT_FALLBACK
            resolved = []
            for (skeleton_id, key_id), (pattern, _unused) in sorted(entries.items()):
                parts = split_pattern_into_two_parts(pattern)
                if parts is None:
                    continue
                left, right = parts
                if not left or not right:
                    continue
                resolved.append((skeleton_id, key_id, left, right))
            result[locale] = (fallback, resolved)

    blob = render(result, skeleton_ids)
    (out_dir / "intervals_data.bin").write_bytes(blob)
    print(
        f"generated {len(result)} locales, {len(blob)} bytes",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
