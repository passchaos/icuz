#!/usr/bin/env python3
"""Pack Node/ICU word-segmentation results into a binary conformance fixture.

Usage:
    generate_word_conformance.py <seg_expected.txt> <out-dir>

The input is a tab-separated file of `language<TAB>text<TAB>segment|segment|...`
lines produced by Node's `Intl.Segmenter` (ICU). The output stores the source
text and the expected segment byte lengths; the language tag is informational
because the runtime detects the dictionary script from the text.

Output layout:
    "CJDW", version u8=1, 3 reserved bytes, case_count u32
    per case: source_len u16, segment_count u16, source bytes,
              segment_len u16 * segment_count
"""

from __future__ import annotations

import struct
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    source = Path(sys.argv[1])
    out_dir = Path(sys.argv[2])
    out_dir.mkdir(parents=True, exist_ok=True)

    cases: list[tuple[bytes, list[int]]] = []
    for line in source.read_text(encoding="utf-8").splitlines():
        if not line:
            continue
        fields = line.split("\t")
        if len(fields) != 3:
            raise SystemExit(f"malformed case: {line!r}")
        _, text, joined = fields
        segments = joined.split("|")
        encoded = text.encode("utf-8")
        lengths = [len(segment.encode("utf-8")) for segment in segments]
        if sum(lengths) != len(encoded):
            raise SystemExit(f"segment lengths do not cover the source: {line!r}")
        cases.append((encoded, lengths))

    output = bytearray(b"CJDW")
    output += struct.pack("<B3xI", 1, len(cases))
    for encoded, lengths in cases:
        output += struct.pack("<HH", len(encoded), len(lengths))
        output += encoded
        for length in lengths:
            output += struct.pack("<H", length)
    (out_dir / "dictionary_conformance.bin").write_bytes(bytes(output))
    print(f"packed {len(cases)} cases", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
