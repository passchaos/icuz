#!/usr/bin/env python3
"""Generate ICU locale data (ulocdata) from CLDR 48.

Usage:
    generate_locale_data.py cldr-common.zip out_file

Stores exemplar character patterns, delimiters, locale display patterns,
measurement systems, and paper sizes.
"""

from __future__ import annotations

import struct
import sys
import xml.etree.ElementTree as ET
import zipfile

MAGIC = b"CJL0"
FORMAT_VERSION = 1
CLDR_VERSION = (48, 0, 0)

REFERENCE_COUNT = 11
LOCALE_RECORD_LEN = REFERENCE_COUNT * 6 + 2

REF_LOCALE = 0
REF_STANDARD = 1
REF_AUXILIARY = 2
REF_INDEX = 3
REF_PUNCTUATION = 4
REF_QUOTATION_START = 5
REF_QUOTATION_END = 6
REF_ALT_QUOTATION_START = 7
REF_ALT_QUOTATION_END = 8
REF_DISPLAY_PATTERN = 9
REF_SEPARATOR = 10

SYSTEM_METRIC = 0
SYSTEM_US = 1
SYSTEM_UK = 2

PAPER_A4 = 0
PAPER_US_LETTER = 1


def child_text(root: ET.Element, path: str) -> str | None:
    element = root.find(path)
    if element is None:
        return None
    return element.text or ""


def parse_locale(root: ET.Element):
    characters = root.find("characters")
    if characters is None:
        return None
    refs = [None] * REFERENCE_COUNT
    flags = 0
    for element in characters.findall("exemplarCharacters"):
        kind = element.get("type")
        text = element.text or ""
        if kind is None:
            refs[REF_STANDARD] = text
        elif kind == "auxiliary":
            refs[REF_AUXILIARY] = text
        elif kind == "index":
            refs[REF_INDEX] = text
        elif kind == "punctuation":
            refs[REF_PUNCTUATION] = text
    delimiters = root.find("delimiters")
    if delimiters is not None:
        flags |= 1
        refs[REF_QUOTATION_START] = child_text(delimiters, "quotationStart")
        refs[REF_QUOTATION_END] = child_text(delimiters, "quotationEnd")
        refs[REF_ALT_QUOTATION_START] = child_text(delimiters, "alternateQuotationStart")
        refs[REF_ALT_QUOTATION_END] = child_text(delimiters, "alternateQuotationEnd")
    display = root.find("localeDisplayNames/localeDisplayPattern")
    if display is not None:
        flags |= 2
        refs[REF_DISPLAY_PATTERN] = child_text(display, "localePattern")
        separator = child_text(display, "localeSeparator")
        if separator is not None:
            separator = separator.replace("{0}", "").replace("{1}", "")
        refs[REF_SEPARATOR] = separator
    if all(value is None for value in refs[1:]):
        return None
    return refs, flags


def parse_measurement(root: ET.Element):
    systems: dict[str, int] = {}
    papers: dict[str, int] = {}
    data = root.find("measurementData")
    if data is None:
        return systems, papers
    for element in data.findall("measurementSystem"):
        if element.get("category") is not None:
            continue
        kind = element.get("type")
        value = {"metric": SYSTEM_METRIC, "US": SYSTEM_US, "UK": SYSTEM_UK}.get(kind)
        if value is None:
            continue
        for territory in (element.get("territories") or "").split():
            systems[territory] = value
    for element in data.findall("paperSize"):
        kind = element.get("type")
        value = {"A4": PAPER_A4, "US-Letter": PAPER_US_LETTER}.get(kind)
        if value is None:
            continue
        for territory in (element.get("territories") or "").split():
            papers[territory] = value
    return systems, papers


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2

    with zipfile.ZipFile(sys.argv[1]) as archive:
        locales: dict[str, tuple[list[str | None], int]] = {}
        for name in archive.namelist():
            if not name.startswith("common/main/") or not name.endswith(".xml"):
                continue
            locale = name[len("common/main/") : -len(".xml")].replace("_", "-")
            root = ET.fromstring(archive.read(name))
            parsed = parse_locale(root)
            if parsed is not None:
                locales[locale] = parsed
        supplemental = ET.fromstring(
            archive.read("common/supplemental/supplementalData.xml")
        )
        systems, papers = parse_measurement(supplemental)

    strings = bytearray()

    def add_string(text: str | None) -> tuple[int, int]:
        if text is None:
            return 0, 0
        offset = len(strings)
        encoded = text.encode("utf-8")
        strings.extend(encoded)
        return offset, len(encoded)

    locale_records = []
    for locale in sorted(locales):
        refs, flags = locales[locale]
        encoded_refs = [add_string(locale)]
        for value in refs[1:]:
            encoded_refs.append(add_string(value))
        record = bytearray()
        for offset, length in encoded_refs:
            record += struct.pack("<IH", offset, length)
        record += struct.pack("<H", flags)
        assert len(record) == LOCALE_RECORD_LEN
        locale_records.append(record)

    measurement_records = []
    for territory in sorted(systems):
        offset, length = add_string(territory)
        measurement_records.append(struct.pack("<IHBB", offset, length, systems[territory], 0))
    paper_records = []
    for territory in sorted(papers):
        offset, length = add_string(territory)
        paper_records.append(struct.pack("<IHBB", offset, length, papers[territory], 0))

    output = bytearray(MAGIC)
    output += bytes([FORMAT_VERSION, *CLDR_VERSION])
    output += struct.pack(
        "<IIHHH",
        len(locale_records),
        len(strings),
        len(measurement_records),
        len(paper_records),
        0,
    )
    for record in locale_records:
        output += record
    for record in measurement_records:
        output += record
    for record in paper_records:
        output += record
    output += strings
    with open(sys.argv[2], "wb") as file:
        file.write(output)
    print(
        f"wrote {len(locale_records)} locales, {len(measurement_records)} "
        f"measurement entries, {len(paper_records)} paper entries, "
        f"{len(output)} bytes"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
