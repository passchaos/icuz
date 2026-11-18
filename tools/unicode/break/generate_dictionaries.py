#!/usr/bin/env python3
"""Generate the dictionary blob for Thai/Lao/Khmer/Burmese/CJK word breaking.

Usage:
    generate_dictionaries.py <icu-dictionaries-dir> <out-dir>

The input files are the ICU break dictionaries from
icu4c/source/data/brkitr/dictionaries:
    thaidict.txt, laodict.txt, khmerdict.txt, burmesedict.txt, cjdict.txt

Each dictionary is compiled into a compact byte trie. A node stores its edge
range, child count, and word cost. Low-fan-out nodes store sorted (byte, child)
edges; high-fan-out nodes store a 256-bit byte bitmap followed by compact child
indices, so the runtime finds a child with a bitmap test and popcount instead
of several binary-search probes. The runtime walks the trie once per position,
which is much faster than binary-searching the sorted word list for every
prefix length.
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
BITMAP_THRESHOLD = 16


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


def build_trie(entries: list[tuple[bytes, int]]):
    # children maps a byte to a child node (a dict), cost_plus_one marks words.
    root = {"children": {}, "cost": 0}
    for word, cost in entries:
        node = root
        for byte in word:
            children = node["children"]
            child = children.get(byte)
            if child is None:
                child = {"children": {}, "cost": 0}
                children[byte] = child
            node = child
        node["cost"] = cost + 1
    return root


def serialize_trie(root):
    # Assign node indices breadth-first, then build the node/edge arrays.
    nodes = [root]
    index = 0
    while index < len(nodes):
        node = nodes[index]
        index += 1
        for byte in sorted(node["children"]):
            nodes.append(node["children"][byte])
    indices = {id(node): position for position, node in enumerate(nodes)}

    node_records = []
    edge_records = []
    for node in nodes:
        children = sorted(node["children"].items())
        if len(children) > BITMAP_THRESHOLD:
            # Align the bitmap so its eight words share cache lines.
            while len(edge_records) % 8:
                edge_records.append(0)
            edge_start = len(edge_records)
            bitmap = [0] * 8
            for byte, _ in children:
                bitmap[byte >> 5] |= 1 << (byte & 31)
            edge_records.extend(bitmap)
            edge_records.extend(indices[id(child)] for _, child in children)
        else:
            edge_start = len(edge_records)
            for byte, child in children:
                edge_records.append((byte << 24) | indices[id(child)])
        node_records.append((edge_start, len(children), node["cost"]))
    return node_records, edge_records


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    source_dir = Path(sys.argv[1])
    out_dir = Path(sys.argv[2])
    out_dir.mkdir(parents=True, exist_ok=True)

    compiled = []
    for _, name, _, has_cost in LANGUAGES:
        entries = parse_dictionary(source_dir / name, has_cost)
        root = build_trie(entries)
        node_records, edge_records = serialize_trie(root)
        max_word_bytes = max(len(word) for word, _ in entries)
        compiled.append((node_records, edge_records, max_word_bytes, len(entries)))

    header = bytearray(b"CJDB")
    header += struct.pack("<BBH", 3, len(LANGUAGES), 0)
    body = bytearray()
    for node_records, edge_records, max_word_bytes, _ in compiled:
        header += struct.pack(
            "<IIHH",
            len(node_records),
            len(edge_records),
            max_word_bytes,
            0,
        )
    for node_records, edge_records, _, _ in compiled:
        for edge_start, edge_count, cost in node_records:
            body += struct.pack("<IHH", edge_start, edge_count, cost)
        for edge in edge_records:
            body += struct.pack("<I", edge)

    (out_dir / "dictionaries.bin").write_bytes(bytes(header + body))
    print(
        " ".join(
            f"{name}={entries} words/{len(nodes)} nodes"
            for (name, _, _, _), (nodes, _, _, entries) in zip(
                LANGUAGES, compiled
            )
        ),
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
