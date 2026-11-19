#!/usr/bin/env python3
"""Generate the CLDR locale canonicalization blobs.

Usage:
    generate_aliases.py cldr-common-48.zip out_dir

Reads supplementalMetadata.xml and emits:

* aliases.bin (CJLX version 2): the CLDR language, script, territory, and
  variant alias rules as language-script-region-variant replacement rules,
  sorted in the reference canonicalizer order and indexed by each field.
* canonicalization_conformance.bin (CJLY version 1): the official CLDR
  localeCanonicalization test data, with '-' separators.

The rule set matches CLDR's LsrvCanonicalizer: XML comments are ignored,
ill-formed alias tags are skipped, the first replacement of a multi-value
alias is kept, and the "und" language acts as a wildcard (it is dropped
from rule fields).
"""

from __future__ import annotations

import hashlib
import re
import struct
import sys
import xml.etree.ElementTree as ElementTree
import zipfile
from pathlib import Path

CLDR_SHA256 = "06c7c698d6fd8d67cefac15a0206b0109b00e0ef1636f86f84449fa959561f74"
CLDR_VERSION = 48

ALIAS_MAGIC = b"CJLX"
ALIAS_FORMAT_VERSION = 2
ALIAS_HEADER_LEN = 36
RULE_LEN = 4 + 9 * 3
RULE_SLOTS = (
    "type_language",
    "type_script",
    "type_region",
    "type_variant0",
    "type_variant1",
    "repl_language",
    "repl_script",
    "repl_region",
    "repl_variant0",
)

CONFORMANCE_MAGIC = b"CJLY"
CONFORMANCE_FORMAT_VERSION = 1

ALIAS_TYPES = ("language", "script", "territory", "variant")
FIELD_SEPARATOR = re.compile(r"[-_]")
LANGUAGE_PATTERN = re.compile(r"[A-Za-z]{2,8}")
SCRIPT_PATTERN = re.compile(r"[A-Za-z]{4}")
ALPHA_REGION_PATTERN = re.compile(r"[A-Za-z]{2}")
DIGIT_REGION_PATTERN = re.compile(r"[0-9]{3}")
VARIANT_PATTERN = re.compile(r"[A-Za-z0-9]{5,8}")
DIGIT_VARIANT_PATTERN = re.compile(r"[0-9][A-Za-z0-9]{3}")


def parse_lsrv(tag: str, is_language_type: bool):
    """Parse an alias tag the way CLDR's LanguageTagParser does.

    Non-language alias types are prefixed with "und_" so their single field
    lands in the right slot. Returns (language, script, region, variants) with
    canonical case, dropping the "und" wildcard language, or None when the tag
    is not a well-formed language identifier.
    """
    parts = FIELD_SEPARATOR.split(tag if is_language_type else "und_" + tag)
    if not parts or any(not part for part in parts):
        return None
    language = parts[0]
    if not LANGUAGE_PATTERN.fullmatch(language):
        return None
    script = None
    region = None
    variants: list[str] = []
    for part in parts[1:]:
        if script is None and SCRIPT_PATTERN.fullmatch(part):
            script = part
        elif region is None and (
            ALPHA_REGION_PATTERN.fullmatch(part)
            or DIGIT_REGION_PATTERN.fullmatch(part)
        ):
            region = part
        elif VARIANT_PATTERN.fullmatch(part) or DIGIT_VARIANT_PATTERN.fullmatch(part):
            variants.append(part)
        else:
            return None
    language = language.lower()
    if language == "und":
        language = None
    if script is not None:
        script = script[0].upper() + script[1:].lower()
    if region is not None:
        region = region.upper()
    variants = sorted({variant.lower() for variant in variants})
    return language, script, region, variants


def rule_sort_key(parts) -> tuple[int, str]:
    language, script, region, variants = parts
    fields = []
    if language:
        fields.append("L:" + language)
    if script:
        fields.append("S:" + script)
    if region:
        fields.append("R:" + region)
    if variants:
        fields.append("V:" + "_".join(variants))
    return (-len(fields), ";".join(fields))


def load_rules(xml: bytes):
    root = ElementTree.fromstring(xml)
    rules = []
    seen = set()
    for element in root.iter():
        if element.tag not in tuple(kind + "Alias" for kind in ALIAS_TYPES):
            continue
        kind = element.tag[: -len("Alias")]
        is_language = kind == "language"
        replacement = element.get("replacement")
        if not replacement:
            continue
        type_parts = parse_lsrv(element.get("type"), is_language)
        replacement_parts = parse_lsrv(replacement.split()[0], is_language)
        if type_parts is None or replacement_parts is None:
            continue
        key = rule_sort_key(type_parts)
        if key in seen:
            raise SystemExit(f"duplicate alias rule for {element.get('type')}")
        seen.add(key)
        rules.append((type_parts, replacement_parts))
    rules.sort(key=lambda rule: rule_sort_key(rule[0]))
    return rules


def build_index(rules, slot: int):
    entries: dict[str, list[int]] = {}
    for ordinal, (type_parts, _) in enumerate(rules):
        language, script, region, variants = type_parts
        if slot == 0 and language:
            entries.setdefault(language, []).append(ordinal)
        elif slot == 1 and script:
            entries.setdefault(script, []).append(ordinal)
        elif slot == 2 and region:
            entries.setdefault(region, []).append(ordinal)
        elif slot == 3 and variants:
            entries.setdefault(variants[0], []).append(ordinal)
    return entries


def emit_index(blob: bytearray, entries: dict[str, list[int]], intern) -> None:
    ordered = sorted(entries.items())
    ordinal_count = sum(len(ordinals) for _, ordinals in ordered)
    if len(ordered) > 0xFFFF or ordinal_count > 0xFFFF:
        raise SystemExit("alias index too large")
    blob += struct.pack("<HH", len(ordered), ordinal_count)
    start = 0
    for key, ordinals in ordered:
        key_offset = intern(key)
        blob += struct.pack(
            "<HBBHH", key_offset, len(key), 0, start, len(ordinals)
        )
        start += len(ordinals)
    for _, ordinals in ordered:
        for ordinal in ordinals:
            blob += struct.pack("<H", ordinal)


def emit_aliases(rules, out_dir: Path) -> None:
    pool = bytearray()
    offsets: dict[str, int] = {}

    def intern(value: str) -> int:
        if value in offsets:
            return offsets[value]
        offset = len(pool)
        if offset > 0xFFFF or len(value) > 0xFF:
            raise SystemExit("alias string pool overflow")
        offsets[value] = offset
        pool.extend(value.encode("utf-8"))
        return offset

    rule_records = bytearray()
    for type_parts, replacement_parts in rules:
        language, script, region, variants = type_parts
        repl_language, repl_script, repl_region, repl_variants = replacement_parts
        slots = (
            language,
            script,
            region,
            variants[0] if len(variants) > 0 else None,
            variants[1] if len(variants) > 1 else None,
            repl_language,
            repl_script,
            repl_region,
            repl_variants[0] if repl_variants else None,
        )
        if len(variants) > 2 or len(repl_variants) > 1:
            raise SystemExit("alias rule has too many variants")
        rule_records += struct.pack(
            "<BBH", len(variants), len(repl_variants), 0
        )
        for value in slots:
            if value is None:
                rule_records += struct.pack("<HB", 0, 0)
            else:
                rule_records += struct.pack("<HB", intern(value), len(value))

    indexes = [build_index(rules, slot) for slot in range(4)]
    index_sections = []
    for entries in indexes:
        section = bytearray()
        emit_index(section, entries, intern)
        index_sections.append(section)

    language_offset = ALIAS_HEADER_LEN
    script_offset = language_offset + len(index_sections[0])
    region_offset = script_offset + len(index_sections[1])
    variant_offset = region_offset + len(index_sections[2])
    rules_offset = variant_offset + len(index_sections[3])
    pool_offset = rules_offset + len(rule_records)
    if pool_offset + len(pool) > 0xFFFFFFFF:
        raise SystemExit("alias blob too large")

    blob = bytearray(ALIAS_MAGIC)
    blob += struct.pack("<B3B", ALIAS_FORMAT_VERSION, CLDR_VERSION, 0, 0)
    blob += struct.pack(
        "<HHIIIIII",
        len(rules),
        0,
        language_offset,
        script_offset,
        region_offset,
        variant_offset,
        rules_offset,
        pool_offset,
    )
    for section in index_sections:
        blob += section
    blob += rule_records
    blob += pool
    (out_dir / "aliases.bin").write_bytes(bytes(blob))
    print(
        f"wrote aliases.bin: {len(blob)} bytes, {len(rules)} rules, "
        f"{len(pool)} byte pool",
        file=sys.stderr,
    )


def emit_conformance(archive: zipfile.ZipFile, out_dir: Path) -> None:
    text = archive.read(
        "common/testData/localeIdentifiers/localeCanonicalization.txt"
    ).decode("utf-8")
    cases: list[tuple[str, str]] = []
    for line in text.splitlines():
        if not line or line.startswith("#") or "\t;\t" not in line:
            continue
        source, expected = line.split("\t;\t", 1)
        cases.append((source.replace("_", "-"), expected.replace("_", "-")))
    if not cases:
        raise SystemExit("no canonicalization conformance cases")
    blob = bytearray(CONFORMANCE_MAGIC)
    blob += struct.pack(
        "<B3B", CONFORMANCE_FORMAT_VERSION, CLDR_VERSION, 0, 0
    )
    blob += struct.pack("<I", len(cases))
    for source, expected in cases:
        source_bytes = source.encode("utf-8")
        expected_bytes = expected.encode("utf-8")
        if len(source_bytes) > 0xFF or len(expected_bytes) > 0xFF:
            raise SystemExit("canonicalization case too long")
        blob += struct.pack("<BB", len(source_bytes), len(expected_bytes))
        blob += source_bytes
        blob += expected_bytes
    (out_dir / "canonicalization_conformance.bin").write_bytes(bytes(blob))
    print(
        f"wrote canonicalization_conformance.bin: {len(blob)} bytes, "
        f"{len(cases)} cases",
        file=sys.stderr,
    )


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
        xml = archive.read(
            "common/supplemental/supplementalMetadata.xml"
        )
        rules = load_rules(xml)
        emit_aliases(rules, out_dir)
        emit_conformance(archive, out_dir)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
