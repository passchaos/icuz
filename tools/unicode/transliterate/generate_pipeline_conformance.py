#!/usr/bin/env python3
"""Generate conformance fixtures for CLDR `::` pipeline transforms.

Usage:
    generate_pipeline_conformance.py out_dir

CLDR does not ship test data for these composed transforms, so the expected
outputs come from PyICU's Transliterator. Each fixture uses the shared
transform-conformance layout (magic, version, CLDR 48, case count, then
UTF-8 source/target pairs).
"""

from __future__ import annotations

import struct
import sys
from pathlib import Path

import icu

CASE_SETS = {
    "cs-ja": (
        "CJJA",
        "cs_ja_conformance.bin",
        (
            "Dvořák",
            "Škoda",
            "Praha",
            "Brno",
            "Olomouc",
            "Česká republika",
            "Příliš žluťoučký kůň úpěl ďábelské ódy",
            "Václav Havel",
            "DVOŘÁK",
            "č. 42",
            "2,5",
            "1.234,5",
            "100 %",
            "a-b",
            "Praha, Brno; Ostrava",
            "ano/ne",
            "(test)",
            "Kč",
            "žluťoučký",
            "řeka",
            "měsíc",
            "ů",
            "ě",
            "ď",
        ),
    ),
    "es-ja": (
        "CJJB",
        "es_ja_conformance.bin",
        (
            "España",
            "niño",
            "año",
            "¿Qué tal?",
            "¡Hola!",
            "Bogotá",
            "México",
            "mañana",
            "güero",
            "cigüeña",
            "llave",
            "perro",
            "chico",
            "jardín",
            "xilófono",
            "Señor",
            "SEÑOR",
            "pingüino",
            "vergüenza",
            "1.234,5",
            "42",
            "a-b",
            "canción",
            "niñez",
        ),
    ),
    "es_419-am": (
        "CJJC",
        "es_419_am_conformance.bin",
        (
            "España",
            "niño",
            "año",
            "¿Qué tal?",
            "¡Hola!",
            "Bogotá",
            "México",
            "mañana",
            "güero",
            "cigüeña",
            "llave",
            "perro",
            "chico",
            "jardín",
            "xilófono",
            "Señor",
            "SEÑOR",
            "pingüino",
            "vergüenza",
            "1.234,5",
            "42",
            "a-b",
            "canción",
            "niñez",
        ),
    ),
    "es_419-ja": (
        "CJJD",
        "es_419_ja_conformance.bin",
        (
            "España",
            "niño",
            "año",
            "¿Qué tal?",
            "¡Hola!",
            "Bogotá",
            "México",
            "mañana",
            "güero",
            "cigüeña",
            "llave",
            "perro",
            "chico",
            "jardín",
            "xilófono",
            "Señor",
            "SEÑOR",
            "pingüino",
            "vergüenza",
            "1.234,5",
            "42",
            "a-b",
            "canción",
            "niñez",
        ),
    ),
}


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    out_dir = Path(sys.argv[1])
    out_dir.mkdir(parents=True, exist_ok=True)
    for transform, (magic, filename, samples) in CASE_SETS.items():
        transliterator = icu.Transliterator.createInstance(transform)
        blob = bytearray(magic.encode("ascii"))
        blob += struct.pack("<BBBB I", 1, 48, 0, 0, len(samples))
        for sample in samples:
            source = sample.encode("utf-8")
            target = transliterator.transliterate(sample).encode("utf-8")
            blob += struct.pack("<HH", len(source), len(target))
            blob += source
            blob += target
        (out_dir / filename).write_bytes(bytes(blob))
        print(f"{transform}: {len(samples)} cases -> {filename}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
