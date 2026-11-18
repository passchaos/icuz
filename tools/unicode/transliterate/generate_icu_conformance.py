#!/usr/bin/env python3
"""Generate differential transliteration fixtures with PyICU.

Usage:
    generate_icu_conformance.py <cldr-common.zip> <transform-xml> <icu-id> \
        <magic> <out-file>

The inputs are derived from the transform's own rule sources (classes are
expanded to representatives) and concatenated with a fixed seed. PyICU runs
the ICU implementation, producing an authoritative expected output. This is
used for transforms that CLDR does not ship official test data for.

Requires PyICU (``pip install PyICU``) built against an ICU with transform
data. The fixture format matches the CLDR transform fixtures used by the
runtime conformance test.
"""

from __future__ import annotations

import random
import re
import struct
import sys
import zipfile
from pathlib import Path

import icu


def extract_rule(xml: str) -> str:
    match = re.search(r"<tRule><!\[CDATA\[(.*?)\]\]></tRule>", xml, re.S)
    if match is None:
        match = re.search(r"<tRule>(.*?)</tRule>", xml, re.S)
    if match is None:
        raise SystemExit("transform is missing tRule")
    # Plain-text tRules may contain XML comments that disable rules.
    return re.sub(r"<!--.*?-->", "", match.group(1), flags=re.S)


def read_escape(text: str, index: int):
    if text.startswith("\\u", index) and index + 5 < len(text):
        return int(text[index + 2 : index + 6], 16), 6
    if text.startswith("\\U", index) and index + 9 < len(text):
        return int(text[index + 2 : index + 10], 16), 10
    if text.startswith("\\x", index) and index + 3 < len(text):
        return int(text[index + 2 : index + 4], 16), 4
    return ord(text[index + 1]), 2


def class_representatives(content: str, limit: int = 8):
    values = set()
    index = 0
    while index < len(content):
        character = content[index]
        if character == "\\":
            codepoint, consumed = read_escape(content, index)
            values.add(codepoint)
            index += consumed
            continue
        if (
            index + 2 < len(content)
            and content[index + 1] == "-"
            and content[index + 2] != "]"
        ):
            start = ord(character)
            end = ord(content[index + 2])
            if start <= end:
                step = max(1, (end - start) // limit)
                values.update(range(start, end + 1, step))
            index += 3
            continue
        if character not in "[]^":
            values.add(ord(character))
        index += 1
    ordered = sorted(values)
    if len(ordered) <= limit:
        return ordered
    step = max(1, len(ordered) // limit)
    return ordered[::step][:limit]


def decode_literal(text: str) -> str:
    result = []
    index = 0
    while index < len(text):
        if text[index] == "\\" and index + 1 < len(text):
            codepoint, consumed = read_escape(text, index)
            result.append(chr(codepoint))
            index += consumed
        else:
            result.append(text[index])
            index += 1
    return "".join(result)


def source_strings(rules: str):
    sources = []
    for raw in rules.splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line or line.startswith("::") or line.startswith("$"):
            continue
        if "→" in line:
            left = line.split("→", 1)[0]
        elif "↔" in line:
            left = line.split("↔", 1)[0]
        else:
            continue
        open_pos = left.find("{")
        close_pos = left.find("}")
        if open_pos >= 0:
            if close_pos > open_pos:
                source = left[open_pos + 1 : close_pos]
            else:
                source = left[open_pos + 1 :]
        elif close_pos >= 0:
            source = left[:close_pos]
        else:
            source = left
        source = source.strip()
        if not source:
            continue
        # Keep only literal source text; variables and quantifiers are rule
        # syntax, not input characters.
        if any(character in source for character in "$?*+()[]|"):
            continue
        # Expand the first class in the source; keep other characters as-is.
        match = re.search(r"\[[^\]]*\]", source)
        if match is not None:
            representatives = class_representatives(match.group(0)[1:-1])
            for codepoint in representatives:
                text = source[: match.start()] + chr(codepoint) + source[match.end() :]
                text = re.sub(r"\[[^\]]*\]", "", text)
                text = decode_literal(text)
                if text:
                    sources.append(text)
        else:
            text = decode_literal(source)
            if text:
                sources.append(text)
    return sources


def main() -> int:
    if len(sys.argv) != 6:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    archive_path, transform, icu_id, magic, out_path = sys.argv[1:6]
    with zipfile.ZipFile(archive_path) as archive:
        rules = extract_rule(
            archive.read(f"common/transforms/{transform}.xml").decode("utf-8")
        )
    sources = source_strings(rules)
    if not sources:
        raise SystemExit("no source strings found")
    random.seed(20261118)
    inputs = []
    for source in sources:
        inputs.append(source)
    for _ in range(240):
        count = random.randint(2, 4)
        inputs.append("".join(random.choice(sources) for _ in range(count)))
    inputs.append(" ".join(random.choice(sources) for _ in range(8)))

    transliterator = icu.Transliterator.createInstance(icu_id)
    cases = []
    for source in inputs:
        if not source:
            continue
        target = transliterator.transliterate(source)
        cases.append((source.encode("utf-8"), target.encode("utf-8")))

    output = bytearray(magic.encode("ascii"))
    output += struct.pack("<BBBB I", 1, 48, 0, 0, len(cases))
    for source, target in cases:
        output += struct.pack("<HH", len(source), len(target))
        output += source
        output += target
    Path(out_path).write_bytes(bytes(output))
    print(f"wrote {len(cases)} cases to {out_path}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
