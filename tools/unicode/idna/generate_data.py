#!/usr/bin/env python3
"""Generate UTS #46 IDNA 16.0.0 mapping data and conformance fixtures.

Usage:
    generate_data.py IdnaMappingTable.txt IdnaTestV2.txt out_dir
"""

from __future__ import annotations

import hashlib
import re
import struct
import sys
from pathlib import Path

MAPPING_SHA256 = "6db2ef4ed35f3b3de74ebc2e00404a9607f76d499f576b8d4043cf14f1ed175c"
TEST_SHA256 = "ffcf59f6e97d765caa5ac8315e9511ba3b42955a554cbc431e4c016f20d25ca9"

PAGE_SIZE = 256
PAGE_COUNT = 0x1100
STATUS = {
    "valid": 0,
    "ignored": 1,
    "mapped": 2,
    "deviation": 3,
    "disallowed": 4,
}
MAPPING_RE = re.compile(
    r"^([0-9A-Fa-f]+)(?:\.\.([0-9A-Fa-f]+))?\s*;\s*"
    r"([A-Za-z_]+)\s*(?:;\s*([0-9A-Fa-f ]*))?"
)
ESCAPE_RE = re.compile(r"\\u([0-9A-Fa-f]{4})|\\x\{([0-9A-Fa-f]+)\}")


def checked_text(path: Path, expected_sha256: str) -> str:
    data = path.read_bytes()
    actual = hashlib.sha256(data).hexdigest()
    if actual != expected_sha256:
        raise SystemExit(
            f"{path}: expected source SHA-256 {expected_sha256}, "
            f"found {actual}"
        )
    return data.decode("utf-8")


def parse_mapping_table(
    text: str,
) -> tuple[list[int], list[tuple[int, int, int]]]:
    statuses = [STATUS["disallowed"]] * 0x110000
    mappings: dict[int, tuple[int, ...]] = {}
    for line_number, raw in enumerate(text.splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        match = MAPPING_RE.match(line)
        if match is None:
            raise SystemExit(f"IdnaMappingTable line {line_number}: malformed row")
        first = int(match.group(1), 16)
        last = int(match.group(2) or match.group(1), 16)
        status_name = match.group(3)
        status = STATUS.get(status_name)
        if status is None:
            raise SystemExit(
                f"IdnaMappingTable line {line_number}: unknown status {status_name}"
            )
        mapping_field = (match.group(4) or "").strip()
        mapping = tuple(int(token, 16) for token in mapping_field.split())
        if mapping_field and not mapping:
            raise SystemExit(
                f"IdnaMappingTable line {line_number}: malformed mapping"
            )
        for codepoint in range(first, last + 1):
            statuses[codepoint] = status
            if status == STATUS["deviation"]:
                mappings[codepoint] = mapping
            elif mapping:
                mappings[codepoint] = mapping
    return statuses, sorted(
        (codepoint, mapping) for codepoint, mapping in mappings.items()
    )


def build_page_table(statuses: list[int]) -> tuple[list[int], list[bytes]]:
    pages: list[bytes] = []
    page_index: dict[bytes, int] = {}
    index: list[int] = []
    for page in range(PAGE_COUNT):
        chunk = bytes(statuses[page * PAGE_SIZE : (page + 1) * PAGE_SIZE])
        slot = page_index.get(chunk)
        if slot is None:
            slot = len(pages)
            if slot > 0xFFFF:
                raise SystemExit("IDNA status page table exceeds u16 index space")
            page_index[chunk] = slot
            pages.append(chunk)
        index.append(slot)
    return index, pages


def render_mapping_blob(
    index: list[int],
    pages: list[bytes],
    mappings: list[tuple[int, tuple[int, ...]]],
) -> bytes:
    pool: list[int] = []
    pool_index: dict[tuple[int, ...], tuple[int, int]] = {}

    def intern(mapping: tuple[int, ...]) -> tuple[int, int]:
        existing = pool_index.get(mapping)
        if existing is not None:
            return existing
        offset = len(pool)
        pool.extend(mapping)
        pool_index[mapping] = (offset, len(mapping))
        return offset, len(mapping)

    records: list[tuple[int, int, int]] = []
    for codepoint, mapping in mappings:
        offset, length = intern(mapping)
        records.append((codepoint, offset, length))

    payload = bytearray(
        struct.pack(
            "<4sBBBBHHII",
            b"CJID",
            1,
            16,
            0,
            0,
            PAGE_COUNT,
            len(pages),
            len(records),
            len(pool),
        )
    )
    for slot in index:
        payload += struct.pack("<H", slot)
    for page in pages:
        payload += page
    for codepoint, offset, length in records:
        payload += struct.pack("<IIBB", codepoint, offset, length, 0)
    for codepoint in pool:
        payload += struct.pack("<I", codepoint)
    return bytes(payload)


def unescape(value: str) -> str:
    def replace(match: re.Match[str]) -> str:
        hex_value = match.group(1) or match.group(2)
        return chr(int(hex_value, 16))

    return ESCAPE_RE.sub(replace, value)


def parse_test_value(value: str, fallback: str) -> str:
    value = value.strip()
    if value == "":
        return fallback
    if value == '""':
        return ""
    return unescape(value)


def status_is_error(value: str) -> bool:
    value = value.strip()
    if value in ("", "[]"):
        return False
    # The fixtures are generated for the default options:
    # CheckHyphens=false and UseSTD3ASCIIRules=false. The V2/V3 and U1 codes
    # are only errors when those options are enabled.
    ignored = {"V2", "V3", "U1"}
    tokens = re.findall(r"[A-Za-z0-9_]+", value)
    return any(token not in ignored for token in tokens)


def parse_conformance(text: str) -> list[tuple[str, str, str, str, int]]:
    cases: list[tuple[str, str, str, str, int]] = []
    for line_number, raw in enumerate(text.splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        columns = [column.strip() for column in line.split(";")]
        if len(columns) < 7:
            raise SystemExit(f"IdnaTestV2 line {line_number}: malformed row")
        source = unescape(columns[0])
        if source == '""':
            source = ""
        to_unicode = parse_test_value(columns[1], source)
        unicode_error = status_is_error(columns[2])
        to_ascii = parse_test_value(columns[3], to_unicode)
        ascii_error = (
            status_is_error(columns[4])
            if columns[4] != ""
            else unicode_error
        )
        to_ascii_t = parse_test_value(columns[5], to_ascii)
        ascii_t_error = (
            status_is_error(columns[6])
            if columns[6] != ""
            else ascii_error
        )
        flags = (
            (1 if unicode_error else 0)
            | (2 if ascii_error else 0)
            | (4 if ascii_t_error else 0)
        )
        cases.append((source, to_unicode, to_ascii, to_ascii_t, flags))
    return cases


def render_conformance(cases: list[tuple[str, str, str, str, int]]) -> bytes:
    payload = bytearray(
        struct.pack("<4sBBBB I", b"CJIT", 1, 16, 0, 0, len(cases))
    )
    for source, to_unicode, to_ascii, to_ascii_t, flags in cases:
        source_bytes = source.encode("utf-8", "surrogatepass")
        unicode_bytes = to_unicode.encode("utf-8", "surrogatepass")
        ascii_bytes = to_ascii.encode("utf-8", "surrogatepass")
        ascii_t_bytes = to_ascii_t.encode("utf-8", "surrogatepass")
        if max(
            len(source_bytes),
            len(unicode_bytes),
            len(ascii_bytes),
            len(ascii_t_bytes),
        ) > 0xFFFF:
            raise SystemExit("conformance string exceeds u16 length")
        payload += struct.pack(
            "<HHHHB",
            len(source_bytes),
            len(unicode_bytes),
            len(ascii_bytes),
            len(ascii_t_bytes),
            flags,
        )
        payload += source_bytes
        payload += unicode_bytes
        payload += ascii_bytes
        payload += ascii_t_bytes
    return bytes(payload)


def main() -> int:
    if len(sys.argv) != 4:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    mapping_path = Path(sys.argv[1])
    test_path = Path(sys.argv[2])
    out_dir = Path(sys.argv[3])
    out_dir.mkdir(parents=True, exist_ok=True)

    statuses, mappings = parse_mapping_table(
        checked_text(mapping_path, MAPPING_SHA256)
    )
    index, pages = build_page_table(statuses)
    (out_dir / "data.bin").write_bytes(
        render_mapping_blob(index, pages, mappings)
    )
    (out_dir / "conformance.bin").write_bytes(
        render_conformance(parse_conformance(checked_text(test_path, TEST_SHA256)))
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
