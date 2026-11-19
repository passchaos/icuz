#!/usr/bin/env python3
"""Generate CLDR numeric duration patterns.

Usage:
    generate_durations.py cldr-common-48.zip out_dir

Extracts `units/durationUnit[@type=hm|hms|ms]/durationUnitPattern` for each
locale, resolving the CLDR parent chain, and emits a `CJDU` v1 blob.
"""

from __future__ import annotations

import re
import struct
import sys
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

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
    "de-AT": "de", "de-CH": "de", "en-AU": "en-001", "en-CA": "en-001",
    "en-GB": "en-001", "en-IN": "en-001", "es-419": "es", "es-MX": "es-419",
    "fr-CA": "fr", "nb": "no", "nl-BE": "nl", "pt-PT": "pt", "zh-Hant": "root",
}

DEFAULTS = {"hm": "h:mm", "hms": "h:mm:ss", "ms": "m:ss"}


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

    locale_bytes = bytearray()
    with zipfile.ZipFile(archive_path) as archive:
        for locale in LOCALES:
            patterns = dict(DEFAULTS)
            found: dict[str, str] = {}
            for name in parent_chain(locale):
                filename = name.replace("-", "_")
                try:
                    text = archive.read(f"common/main/{filename}.xml")
                except KeyError:
                    continue
                document = ET.fromstring(text)
                for unit in document.findall(".//units/durationUnit"):
                    unit_type = unit.get("type")
                    pattern = unit.findtext("durationUnitPattern")
                    if unit_type in patterns and pattern and unit_type not in found:
                        found[unit_type] = pattern.strip()
            patterns.update(found)
            id_offset = intern(locale)
            locale_bytes += struct.pack(
                "<IBBHHIII",
                id_offset,
                len(locale.encode("utf-8")),
                0,
                0,
                0,
                intern(patterns["hm"]),
                intern(patterns["hms"]),
                intern(patterns["ms"]),
            )
    header = bytearray(b"CJQ0")
    header += struct.pack(
        "<B3xHHI",
        1,
        len(LOCALES),
        0,
        len(strings),
    )
    blob = bytes(header + locale_bytes + strings)
    (out_dir / "durations_data.bin").write_bytes(blob)
    print(f"generated {len(LOCALES)} locales, {len(blob)} bytes", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
