#!/usr/bin/env python3
"""Generate the ICU region data blob from CLDR 48.

Usage:
    generate_region.py cldr-common.zip out_file

The output mirrors ICU's `uregion` data model: canonical region codes, UN
M.49 numeric codes, containment parents/children, grouping membership,
deprecated-region preferred replacements, and region types.
"""

from __future__ import annotations

import struct
import sys
import xml.etree.ElementTree as ET
import zipfile

MAGIC = b"CJR0"
FORMAT_VERSION = 1
CLDR_VERSION = (48, 0, 0)

KIND_UNKNOWN = 0
KIND_TERRITORY = 1
KIND_WORLD = 2
KIND_CONTINENT = 3
KIND_SUBCONTINENT = 4
KIND_GROUPING = 5
KIND_DEPRECATED = 6

# Region containment entries that are not part of the normal tree.
PSEUDO_GROUPS = {"containedGroupings", "deprecated"}


def expand_ids(text: str) -> list[str]:
    result = []
    for token in text.split():
        if "~" not in token:
            result.append(token)
            continue
        start, end = token.split("~", 1)
        if len(end) == 1 and len(start) >= 2:
            prefix = start[:-1]
            for code in range(ord(start[-1]), ord(end) + 1):
                result.append(prefix + chr(code))
        else:
            raise SystemExit(f"unsupported range: {token}")
    return result


def parse_validity(root: ET.Element) -> dict[str, list[str]]:
    statuses: dict[str, list[str]] = {}
    for element in root.iter("id"):
        if element.get("type") != "region":
            continue
        status = element.get("idStatus")
        statuses[status] = expand_ids(element.text or "")
    return statuses


def parse_containment(root: ET.Element) -> list[tuple[str, list[str], str | None, bool]]:
    groups = []
    for group in root.iter("group"):
        kind = group.get("status")
        grouping = group.get("grouping") == "true"
        children = expand_ids(group.get("contains") or "")
        groups.append((group.get("type"), children, kind, grouping))
    return groups


def parse_aliases(root: ET.Element) -> list[tuple[str, list[str]]]:
    aliases = []
    for element in root.iter("territoryAlias"):
        source = element.get("type")
        replacement = (element.get("replacement") or "").split()
        aliases.append((source, replacement))
    return aliases


def parse_codes(root: ET.Element) -> list[tuple[str, str | None, str | None]]:
    codes = []
    for element in root.iter("territoryCodes"):
        codes.append((element.get("type"), element.get("numeric"), element.get("alpha3")))
    return codes


class Region:
    __slots__ = ("code", "kind", "numeric", "parent", "children", "preferred")

    def __init__(self, code: str):
        self.code = code
        self.kind = KIND_TERRITORY
        self.numeric = -1
        self.parent: str | None = None
        self.children: list[str] = []
        self.preferred: list[str] = []


def build_regions(zip_path: str):
    with zipfile.ZipFile(zip_path) as archive:
        validity_root = ET.fromstring(archive.read("common/validity/region.xml"))
        supplemental_root = ET.fromstring(
            archive.read("common/supplemental/supplementalData.xml")
        )
        metadata_root = ET.fromstring(
            archive.read("common/supplemental/supplementalMetadata.xml")
        )

    statuses = parse_validity(validity_root)
    known = set(statuses.get("regular", []))
    known.update(statuses.get("macroregion", []))
    known.update(statuses.get("unknown", []))

    regions: dict[str, Region] = {code: Region(code) for code in known}
    for code, region in regions.items():
        if code.isdigit():
            region.numeric = int(code)
    groupings: set[str] = set()
    normal_groups: list[tuple[str, list[str]]] = []

    for parent, children, status, grouping in parse_containment(supplemental_root):
        if parent in PSEUDO_GROUPS:
            continue
        if status == "deprecated":
            continue
        if grouping:
            groupings.add(parent)
            region = regions.get(parent)
            if region is not None:
                region.children = list(children)
            continue
        if status == "grouping":
            # A listing of grouping children under a normal parent; groupings
            # are not part of the normal containment tree.
            continue
        normal_groups.append((parent, children))

    # Territory aliases: single known replacements are aliases; everything
    # else becomes a deprecated region with preferred replacements.
    aliases: dict[str, str] = {}
    for source, replacement in parse_aliases(metadata_root):
        if source is None:
            continue
        if source in regions:
            region = regions[source]
            region.kind = KIND_DEPRECATED
            region.preferred = [code for code in replacement if code in regions]
            continue
        if len(replacement) == 1 and replacement[0] in regions:
            aliases[source] = replacement[0]
            continue
        region = Region(source)
        region.kind = KIND_DEPRECATED
        region.preferred = [code for code in replacement if code in regions]
        if source.isdigit():
            region.numeric = int(source)
        regions[source] = region

    # Code mappings add numeric codes and alpha-3 aliases.
    for code, numeric, alpha3 in parse_codes(supplemental_root):
        region = regions.get(code)
        if region is None:
            continue
        if numeric is not None and numeric.isdigit():
            region.numeric = int(numeric)
        if alpha3 and alpha3 not in regions and alpha3 not in aliases:
            aliases[alpha3] = code

    # Normal containment establishes the tree.
    for parent, children in normal_groups:
        parent_region = regions.get(parent)
        if parent_region is None:
            continue
        for child in children:
            child_region = regions.get(child)
            if child_region is None:
                continue
            if child not in parent_region.children:
                parent_region.children.append(child)
            if parent_region.kind != KIND_GROUPING:
                child_region.parent = parent

    # Types.
    if "001" in regions:
        regions["001"].kind = KIND_WORLD
    if "ZZ" in regions:
        regions["ZZ"].kind = KIND_UNKNOWN
    for code in regions:
        region = regions[code]
        if region.kind in (KIND_WORLD, KIND_UNKNOWN, KIND_DEPRECATED):
            continue
        if code in groupings:
            region.kind = KIND_GROUPING
    for code in regions:
        region = regions[code]
        if region.kind == KIND_TERRITORY and region.parent == "001":
            region.kind = KIND_CONTINENT
    for code in regions:
        region = regions[code]
        if region.kind != KIND_TERRITORY:
            continue
        if code == "QO":
            region.kind = KIND_SUBCONTINENT
            continue
        parent = regions.get(region.parent) if region.parent is not None else None
        if parent is not None and parent.kind == KIND_CONTINENT:
            region.kind = KIND_SUBCONTINENT

    return regions, aliases


def encode(regions: dict[str, Region], aliases: dict[str, str]) -> bytes:
    codes = sorted(regions)
    index = {code: position for position, code in enumerate(codes)}
    strings = bytearray()

    def add_string(text: str) -> tuple[int, int]:
        offset = len(strings)
        encoded = text.encode("ascii")
        strings.extend(encoded)
        return offset, len(encoded)

    region_records = []
    children = []
    preferred = []
    for code in codes:
        region = regions[code]
        code_offset, code_length = add_string(code)
        child_start = len(children)
        children.extend(index[child] for child in region.children if child in index)
        preferred_start = len(preferred)
        preferred.extend(
            index[target] for target in region.preferred if target in index
        )
        parent = index[region.parent] if region.parent in index else 0xFFFF
        region_records.append(
            (
                code_offset,
                code_length,
                region.kind,
                region.numeric,
                parent,
                child_start,
                len(region.children),
                preferred_start,
                len(region.preferred),
            )
        )

    alias_records = []
    for source in sorted(aliases):
        offset, length = add_string(source)
        alias_records.append((offset, length, index[aliases[source]]))

    numeric_records = []
    for code in codes:
        numeric = regions[code].numeric
        if numeric >= 0:
            numeric_records.append((numeric, index[code]))
    numeric_records.sort()

    output = bytearray(MAGIC)
    output += bytes([FORMAT_VERSION, *CLDR_VERSION])
    output += struct.pack(
        "<HHHHII",
        len(region_records),
        len(alias_records),
        len(numeric_records),
        len(strings),
        len(children),
        len(preferred),
    )
    for record in region_records:
        code_offset, code_length, kind, numeric, parent, child_start, child_len, pref_start, pref_len = record
        output += struct.pack(
            "<IBBhHHHHHH",
            code_offset,
            code_length,
            kind,
            numeric,
            parent,
            child_start,
            child_len,
            pref_start,
            pref_len,
            0,
        )
    for offset, length, target in alias_records:
        output += struct.pack("<IBBH", offset, length, 0, target)
    for numeric, target in numeric_records:
        output += struct.pack("<HH", numeric, target)
    for child in children:
        output += struct.pack("<H", child)
    for target in preferred:
        output += struct.pack("<H", target)
    output += strings
    return bytes(output)


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    regions, aliases = build_regions(sys.argv[1])
    data = encode(regions, aliases)
    with open(sys.argv[2], "wb") as file:
        file.write(data)
    print(
        f"wrote {len(regions)} regions, {len(aliases)} aliases, "
        f"{len(data)} bytes"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
