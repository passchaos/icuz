#!/usr/bin/env python3
"""Generate the CLDR alphabetic index label blob.

Usage:
    generate_alphabetic_index.py cldr-common-48.zip out_dir

Reads exemplarCharacters[@type="index"] from every locale and emits
alphabetic_index_data.bin (CJXA version 1): locale records, label
references, and a UTF-8 string pool.
"""

from __future__ import annotations

import hashlib
import re
import struct
import sys
import zipfile
from pathlib import Path

CLDR_SHA256 = "06c7c698d6fd8d67cefac15a0206b0109b00e0ef1636f86f84449fa959561f74"
CLDR_VERSION = 48

MAGIC = b"CJXA"
FORMAT_VERSION = 1
HEADER_LEN = 24
LOCALE_RECORD_LEN = 16
LABEL_REF_LEN = 8

INDEX_PATTERN = re.compile(
    r'<exemplarCharacters type="index">(.*?)</exemplarCharacters>',
    re.S,
)


def parse_set(text: str) -> list[str]:
    text = text.strip()
    if text.startswith("[") and text.endswith("]"):
        text = text[1:-1]
    labels: list[str] = []
    index = 0
    while index < len(text):
        while index < len(text) and text[index].isspace():
            index += 1
        if index >= len(text):
            break
        if text[index] == "{":
            end = text.find("}", index)
            if end < 0:
                raise SystemExit("unterminated index set element")
            labels.append(text[index + 1 : end])
            index = end + 1
        else:
            end = index
            while end < len(text) and not text[end].isspace():
                end += 1
            # Unbraced tokens are lists of individual characters; only a
            # braced element is a single multi-character label.
            labels.extend(text[index:end])
            index = end
    return labels


class Pool:
    def __init__(self):
        self.data = bytearray()
        self.offsets: dict[str, int] = {}

    def intern(self, value: str) -> tuple[int, int]:
        if value in self.offsets:
            return self.offsets[value], len(value.encode("utf-8"))
        offset = len(self.data)
        encoded = value.encode("utf-8")
        if offset > 0xFFFFFFFF or len(encoded) > 0xFFFF:
            raise SystemExit("alphabetic index pool overflow")
        self.offsets[value] = offset
        self.data.extend(encoded)
        return offset, len(encoded)


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    zip_path = Path(sys.argv[1])
    out_dir = Path(sys.argv[2])
    out_dir.mkdir(parents=True, exist_ok=True)

    data = zip_path.read_bytes()
    actual = hashlib.sha256(data).hexdigest()
    if actual != CLDR_SHA256:
        raise SystemExit(
            f"{zip_path}: expected SHA-256 {CLDR_SHA256}, found {actual}"
        )

    with zipfile.ZipFile(zip_path) as archive:
        tables: dict[str, list[str]] = {}
        for name in archive.namelist():
            if not name.startswith("common/main/") or not name.endswith(".xml"):
                continue
            locale = name.rsplit("/", 1)[1][:-4]
            xml = archive.read(name).decode("utf-8")
            match = INDEX_PATTERN.search(xml)
            if not match:
                continue
            labels = parse_set(match.group(1))
            if labels:
                tables[locale] = labels

    pool = Pool()
    locales = sorted(tables)
    label_refs = bytearray()
    locale_records = bytearray()
    label_index = 0
    for locale in locales:
        labels = tables[locale]
        locale_offset, locale_len = pool.intern(locale)
        locale_records += struct.pack(
            "<IHHHHI",
            locale_offset,
            locale_len,
            0,
            len(labels),
            0,
            label_index,
        )
        for label in labels:
            label_offset, label_len = pool.intern(label)
            label_refs += struct.pack("<IHH", label_offset, label_len, 0)
        label_index += len(labels)

    locale_records_offset = HEADER_LEN
    label_refs_offset = locale_records_offset + len(locale_records)
    pool_offset = label_refs_offset + len(label_refs)
    blob = bytearray(MAGIC)
    blob += struct.pack("<B3B", FORMAT_VERSION, CLDR_VERSION, 0, 0)
    blob += struct.pack(
        "<IIII",
        len(locales),
        locale_records_offset,
        label_refs_offset,
        pool_offset,
    )
    blob += locale_records
    blob += label_refs
    blob += pool.data
    (out_dir / "alphabetic_index_data.bin").write_bytes(bytes(blob))
    print(
        f"wrote alphabetic_index_data.bin: {len(blob)} bytes, "
        f"{len(locales)} locales, {label_index} labels, "
        f"{len(pool.data)} byte pool",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
