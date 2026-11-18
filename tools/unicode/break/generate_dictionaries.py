#!/usr/bin/env python3
"""Generate the dictionary blob for Thai/Lao/Khmer/Burmese/CJK word breaking.

Usage:
    generate_dictionaries.py <icu-dictionaries-dir> <out-dir>

The input files are the ICU break dictionaries from
icu4c/source/data/brkitr/dictionaries:
    thaidict.txt, laodict.txt, khmerdict.txt, burmesedict.txt, cjdict.txt

Words are sorted by UTF-8 byte order and stored in a shared byte pool with an
offset/length/cost table, so the runtime can find exact words by binary search.
CJK entries carry the ICU unigram cost used by the Viterbi segmenter.
"""

from __future__ import annotations

import hashlib
import struct
import sys
from pathlib import Path

LANGUAGES = (
    ("thai", "thaidict.txt", "3166abde40c0f44ab91c28f5ce96d7d1472cb7882e1c0bda0a72f8f69dba4274", False),
    ("lao", "laodict.txt", "3c876934a3fa81031d2333525eafaca6a7c9f842e3b98f18c38880420afb5d36", False),
    ("khmer", "khmerdict.txt", "87bee2d17cd5148aa36957eb05409eefc124de8ad519b81b789298ef3e60b5d9", False),
    ("burmese", "burmesedict.txt", "61d8abc3d9102b2f9bf0c9f44db0d7ab89b18172d8cd26832e4c83174bd8673b", False),
    ("cjk", "cjdict.txt", "e73fd72048981d0cc13e9dc436a7eaba07ffb6eff58c8a59dc75c1df746663a0", True),
)

HEADER_LEN = 4 + 1 + 1 + 2 + len(LANGUAGES) * 12


def parse_dictionary(path: Path, has_cost: bool) -> list[tuple[bytes, int]]:
    data = path.read_bytes()
    expected = next(sha for _, name, sha, _ in LANGUAGES if name == path.name)
    actual = hashlib.sha256(data).hexdigest()
    if actual != expected:
        raise SystemExit(f"{path}: expected SHA-256 {expected}, found {actual}")
    text = data.decode("utf-8-sig")
    entries: dict[bytes, int] = {}
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if has_cost and "\t" in stripped:
            word, _, cost_text = stripped.partition("\t")
            word = word.strip()
            cost_text = cost_text.strip()
            cost = int(cost_text) if cost_text.isdigit() else 0
        else:
            word = stripped
            cost = 0
        if not word:
            continue
        encoded = word.encode("utf-8")
        if not encoded:
            continue
        previous = entries.get(encoded)
        if previous is None or cost < previous:
            entries[encoded] = cost
    return sorted(entries.items())


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    source_dir = Path(sys.argv[1])
    out_dir = Path(sys.argv[2])
    out_dir.mkdir(parents=True, exist_ok=True)

    parsed = []
    for _, name, _, has_cost in LANGUAGES:
        parsed.append(parse_dictionary(source_dir / name, has_cost))

    header = bytearray(b"CJDB")
    header += struct.pack("<BBH", 1, len(LANGUAGES), 0)
    body = bytearray()
    for entries in parsed:
        pool = bytearray()
        records = bytearray()
        max_len = 0
        for word, cost in entries:
            offset = len(pool)
            pool.extend(word)
            max_len = max(max_len, len(word))
            records += struct.pack("<IBHB", offset, len(word), cost, 0)
        header += struct.pack("<IIHH", len(entries), len(pool), max_len, 0)
        body += records
        body += pool

    (out_dir / "dictionaries.bin").write_bytes(bytes(header + body))
    print(
        " ".join(
            f"{name}={len(entries)}" for (name, _, _, _), entries in zip(LANGUAGES, parsed)
        ),
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
