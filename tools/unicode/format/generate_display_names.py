#!/usr/bin/env python3
"""Generate CLDR locale display names.

Usage:
    generate_display_names.py cldr-common-48.zip out_dir

Reads `localeDisplayNames` (languages, scripts, territories, variants, and
display patterns) for each locale, resolves the parent chain, and emits a
`CJLD` v1 blob.
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

DEFAULT_PATTERN = "{0} ({1})"
DEFAULT_SEPARATOR = "{0}, {1}"
DEFAULT_KEY_TYPE = "{0}: {1}"

MAPS = ("languages/language", "scripts/script", "territories/territory",
        "variants/variant")


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


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    archive_path = Path(sys.argv[1])
    out_dir = Path(sys.argv[2])
    out_dir.mkdir(parents=True, exist_ok=True)

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
    with zipfile.ZipFile(archive_path) as archive:
        for locale in LOCALES:
            merged = {tag: {} for tag in MAPS}
            patterns = {
                "pattern": DEFAULT_PATTERN,
                "separator": DEFAULT_SEPARATOR,
                "keytype": DEFAULT_KEY_TYPE,
            }
            for name in parent_chain(locale):
                filename = name.replace("-", "_")
                try:
                    text = archive.read(f"common/main/{filename}.xml")
                except KeyError:
                    continue
                document = ET.fromstring(text)
                display = document.find(".//localeDisplayNames")
                if display is None:
                    continue
                for tag in MAPS:
                    if name == "root":
                        continue
                    for element in display.findall(tag):
                        if element.get("alt") or element.get("draft") == "unconfirmed":
                            continue
                        code = element.get("type")
                        value = (element.text or "").strip()
                        if code and value:
                            merged[tag].setdefault(code, value)
                element = display.find("localeDisplayPattern")
                if element is not None:
                    for key, tag in (
                        ("pattern", "localePattern"),
                        ("separator", "localeSeparator"),
                        ("keytype", "localeKeyTypePattern"),
                    ):
                        value = element.findtext(tag)
                        if value and patterns[key] == {
                            "pattern": DEFAULT_PATTERN,
                            "separator": DEFAULT_SEPARATOR,
                            "keytype": DEFAULT_KEY_TYPE,
                        }[key]:
                            patterns[key] = value.strip()

            starts = []
            counts = []
            for tag in MAPS:
                items = sorted(merged[tag].items())
                starts.append(entry_count)
                counts.append(len(items))
                for code, value in items:
                    entry_bytes += struct.pack(
                        "<II", intern(code), intern(value)
                    )
                    entry_count += 1
            id_offset = intern(locale)
            locale_bytes += struct.pack(
                "<IBB I H I H I H I H III",
                id_offset,
                len(locale.encode("utf-8")),
                0,
                starts[0], counts[0],
                starts[1], counts[1],
                starts[2], counts[2],
                starts[3], counts[3],
                intern(patterns["pattern"]),
                intern(patterns["separator"]),
                intern(patterns["keytype"]),
            )
    header = bytearray(b"CJLD")
    header += struct.pack(
        "<B3xH H I I I",
        1,
        len(LOCALES),
        0,
        entry_count,
        len(strings),
        0,
    )
    blob = bytes(header + locale_bytes + entry_bytes + strings)
    (out_dir / "display_names_data.bin").write_bytes(blob)
    print(
        f"generated {len(LOCALES)} locales, {entry_count} entries, "
        f"{len(blob)} bytes",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
