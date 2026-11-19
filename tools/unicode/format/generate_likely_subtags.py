#!/usr/bin/env python3
"""Generate the CLDR likely-subtags table.

Usage:
    generate_likely_subtags.py cldr-common-48.zip out_dir
"""

from __future__ import annotations

import struct
import sys
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    archive_path = Path(sys.argv[1])
    out_dir = Path(sys.argv[2])
    out_dir.mkdir(parents=True, exist_ok=True)

    with zipfile.ZipFile(archive_path) as archive:
        document = ET.fromstring(
            archive.read("common/supplemental/likelySubtags.xml")
        )
    entries = []
    for item in document.findall(".//likelySubtag"):
        source = item.get("from")
        target = item.get("to")
        if source and target:
            entries.append((source, target))
    entries.sort(key=lambda item: item[0])

    strings = bytearray(b"\x00")
    offsets: dict[str, int] = {"": 0}

    def intern(value: str) -> int:
        if value in offsets:
            return offsets[value]
        offset = len(strings)
        strings.extend(value.encode("utf-8"))
        strings.append(0)
        offsets[value] = offset
        return offset

    entry_bytes = bytearray()
    for source, target in entries:
        entry_bytes += struct.pack("<II", intern(source), intern(target))
    header = bytearray(b"CJL1")
    header += struct.pack("<B3xII", 1, len(entries), len(strings))
    (out_dir / "likely_subtags_data.bin").write_bytes(
        bytes(header + entry_bytes + strings)
    )
    print(
        f"generated {len(entries)} likely subtags, "
        f"{len(header) + len(entry_bytes) + len(strings)} bytes",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
