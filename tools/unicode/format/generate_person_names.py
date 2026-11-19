#!/usr/bin/env python3
"""Generate the CLDR person name data and conformance blobs.

Usage:
    generate_person_names.py cldr-common-48.zip out_dir

Emits:

* person_names_data.bin (CJPU version 1): fully resolved person name data
  for every locale that defines a personNames element, plus the main-data
  parent locale table used for runtime fallback.
* person_names_conformance.bin (CJPQ version 1): the official CLDR
  personNameTest cases.

Resolution follows CLDR's reference resolver: values inherit through the
main parent locale chain, root element aliases rewrite whole personName
subtrees, and a missing namePattern[@alt] falls back to the same path
without the alt attribute. The formatter-level missing-parameter fallbacks
are applied when each locale record is emitted.
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

DATA_MAGIC = b"CJPU"
DATA_FORMAT_VERSION = 1
DATA_HEADER_LEN = 28
LOCALE_RECORD_LEN = 924
PARENT_RECORD_LEN = 16

CONFORMANCE_MAGIC = b"CJPQ"
CONFORMANCE_FORMAT_VERSION = 1

ORDERS = ("givenFirst", "surnameFirst", "sorting")
LENGTHS = ("long", "medium", "short")
USAGES = ("referring", "addressing", "monogram")
FORMALITIES = ("formal", "informal")

FIELD_IDS = {
    "title": 0,
    "given": 1,
    "given2": 2,
    "surname": 3,
    "surname2": 4,
    "generation": 5,
    "credentials": 6,
}
MODIFIER_BITS = {"informal": 1, "prefix": 2, "core": 4}


def split_locale(locale: str):
    parts = re.split(r"[-_]", locale)
    language = parts[0].lower()
    script = region = None
    variants = []
    for part in parts[1:]:
        if script is None and len(part) == 4 and part.isalpha():
            script = part[0].upper() + part[1:].lower()
        elif region is None and (
            (len(part) == 2 and part.isalpha()) or (len(part) == 3 and part.isdigit())
        ):
            region = part.upper()
        else:
            variants.append(part.lower())
    return language, script, region, variants


def join_locale(language, script, region, variants):
    parts = [language]
    if script:
        parts.append(script)
    if region:
        parts.append(region)
    parts.extend(variants)
    return "_".join(parts)


def normalize_locale(locale: str) -> str:
    return join_locale(*split_locale(locale))


def combo_key(order, length, usage, formality):
    return (order, length, usage, formality)


def combo_index(combo) -> int:
    order, length, usage, formality = combo
    return (
        ((ORDERS.index(order) * len(LENGTHS) + LENGTHS.index(length)) * len(USAGES)
         + USAGES.index(usage)) * len(FORMALITIES)
        + FORMALITIES.index(formality)
    )


def param_sort_key(combo):
    return (
        ORDERS.index(combo[0]),
        LENGTHS.index(combo[1]),
        USAGES.index(combo[2]),
        FORMALITIES.index(combo[3]),
    )


def params_match(key, params):
    return all(k is None or p is None or k == p for k, p in zip(key, params))


def fallback_combos(combo):
    order, length, usage, formality = combo
    return (
        (order, length, None, formality),
        (order, length, usage, None),
        (order, length, None, None),
        (order, None, None, None),
        (None, None, None, None),
    )


class Cldr:
    def __init__(self, zip_path: Path):
        archive = zipfile.ZipFile(zip_path)
        self.raw = {}
        for name in archive.namelist():
            if not name.startswith("common/main/") or not name.endswith(".xml"):
                continue
            locale = name.rsplit("/", 1)[1][:-4]
            root = ElementTree.fromstring(archive.read(name))
            person_names = root.find(".//personNames")
            if person_names is None:
                continue
            self.raw[locale] = self.read_person_names(person_names)
        supplemental = ElementTree.fromstring(
            archive.read("common/supplemental/supplementalData.xml")
        )
        self.likely = {}
        for element in supplemental.iter("likelySubtag"):
            self.likely[element.get("from")] = element.get("to")
        self.explicit_parent = {}
        self.skip_non_likely = False
        for section in supplemental.iter("parentLocales"):
            if section.get("component"):
                continue
            if section.get("localeRules") == "nonlikelyScript":
                self.skip_non_likely = True
            for element in section.findall("parentLocale"):
                parent = normalize_locale(element.get("parent"))
                for locale in (element.get("locales") or "").split():
                    self.explicit_parent[normalize_locale(locale)] = parent
        self.records = {}
        self.chain_cache = {}

    @staticmethod
    def read_person_names(person_names):
        data = {
            "orders": {},
            "defaults": {},
            "native": None,
            "foreign": None,
            "initial": None,
            "initial_sequence": None,
            "patterns": {},
            "aliases": {},
        }
        for element in person_names:
            if element.tag == "nameOrderLocales":
                data["orders"][element.get("order")] = element.text or ""
            elif element.tag == "parameterDefault":
                data["defaults"][element.get("parameter")] = element.text
            elif element.tag == "nativeSpaceReplacement":
                data["native"] = element.text or ""
            elif element.tag == "foreignSpaceReplacement":
                data["foreign"] = element.text or ""
            elif element.tag == "initialPattern":
                if element.get("type") == "initial":
                    data["initial"] = element.text
                else:
                    data["initial_sequence"] = element.text
            elif element.tag == "personName":
                combo = combo_key(
                    element.get("order"),
                    element.get("length"),
                    element.get("usage"),
                    element.get("formality"),
                )
                for pattern in element.findall("namePattern"):
                    alt = int(pattern.get("alt") or 0)
                    data["patterns"].setdefault((combo, alt), pattern.text or "")
                alias = element.find("alias")
                if alias is not None:
                    target = alias.get("path") or ""
                    match = re.search(
                        r"personName"
                        r"(?:\[@order='([^']*)'\])?"
                        r"(?:\[@length='([^']*)'\])?"
                        r"(?:\[@usage='([^']*)'\])?"
                        r"(?:\[@formality='([^']*)'\])?",
                        target,
                    )
                    if match:
                        data["aliases"][combo] = combo_key(*match.groups())
        return data

    def parent(self, locale: str):
        if locale == "root":
            return None
        if locale in self.explicit_parent:
            return self.explicit_parent[locale]
        position = locale.rfind("_")
        if position >= 0:
            truncated = locale[:position]
            script_position = locale.find("_")
            script_only = (
                script_position >= 0
                and script_position + 5 == len(locale)
                and "_" not in locale[script_position + 1 :]
            )
            if script_only and self.skip_non_likely:
                script = locale[script_position + 1 :]
                if script != self.likely_script(truncated):
                    return "root"
            return truncated if truncated else "root"
        return "root"

    def chain(self, locale: str):
        if locale in self.chain_cache:
            return self.chain_cache[locale]
        result = []
        current = locale
        while current is not None:
            result.append(current)
            current = self.parent(current)
        result.reverse()
        self.chain_cache[locale] = result
        return result

    def maximize(self, locale: str) -> str:
        language, script, region, variants = split_locale(locale)
        found_language = found_script = found_region = None
        candidates = (
            join_locale(language, script, region, []),
            join_locale(language, None, region, []),
            join_locale(language, script, None, []),
            language,
        )
        for candidate in candidates:
            if candidate in self.likely:
                found_language, found_script, found_region, _ = split_locale(
                    self.likely[candidate]
                )
                break
        if found_language is None:
            found_language, found_script, found_region = "en", "Latn", "US"
        language = language if language != "und" else found_language
        script = script or found_script
        region = region or found_region
        if script is None or region is None:
            key = "und_" + (script or region or "")
            if key in self.likely:
                _, likely_script, likely_region, _ = split_locale(self.likely[key])
                script = script or likely_script
                region = region or likely_region
        return join_locale(language, script, region, variants)

    def likely_script(self, locale: str):
        return split_locale(self.maximize(locale))[1]

    def resolve_all(self):
        for locale in self.raw:
            self.records[locale] = self.resolve(locale)

    def resolve(self, locale: str):
        merged = {
            "orders": {},
            "defaults": {},
            "native": None,
            "foreign": None,
            "initial": None,
            "initial_sequence": None,
            "patterns": {},
        }
        for step in self.chain(locale):
            raw = self.raw.get(step)
            if not raw:
                continue
            for key, value in raw["orders"].items():
                merged["orders"][key] = value
            for key, value in raw["defaults"].items():
                merged["defaults"][key] = value
            for key in ("native", "foreign", "initial", "initial_sequence"):
                if raw[key] is not None:
                    merged[key] = raw[key]
            for key, text in raw["patterns"].items():
                merged["patterns"][key] = text

        aliases = self.raw["root"]["aliases"]
        direct = dict(merged["patterns"])

        def resolve_value(combo, alt, seen):
            key = (combo, alt)
            if key in direct:
                return direct[key]
            if combo in aliases and combo not in seen:
                found = resolve_value(aliases[combo], alt, seen | {combo})
                if found is not None:
                    return found
            if alt is not None:
                return resolve_value(combo, None, seen)
            return None

        resolved = {}
        for combo in set(combo for combo, _ in direct) | set(aliases):
            values = {}
            for alt in (0, 1):
                found = resolve_value(combo, alt, frozenset())
                if found is not None:
                    values[alt] = found
            if values:
                resolved[combo] = values

        # formatter-level fallback for parameter combinations without a pattern
        keys = sorted(resolved, key=param_sort_key)
        for combo in (
            (order, length, usage, formality)
            for order in ORDERS
            for length in LENGTHS
            for usage in USAGES
            for formality in FORMALITIES
        ):
            if combo in resolved:
                continue
            for fallback in fallback_combos(combo):
                found = None
                for key in keys:
                    if params_match(key, fallback):
                        found = resolved[key]
                        break
                if found is not None:
                    resolved[combo] = dict(found)
                    break
            else:
                raise SystemExit(f"no fallback for {locale} {combo}")

        merged["patterns"] = resolved
        return merged


class Pool:
    def __init__(self):
        self.data = bytearray()
        self.offsets = {}

    def intern(self, value: str) -> tuple[int, int]:
        if value in self.offsets:
            return self.offsets[value], len(value.encode("utf-8"))
        offset = len(self.data)
        encoded = value.encode("utf-8")
        if offset > 0xFFFFFFFF or len(encoded) > 0xFFFF:
            raise SystemExit("person name pool overflow")
        self.offsets[value] = offset
        self.data.extend(encoded)
        return offset, len(encoded)


def pack_str(pool: Pool, value: str) -> bytes:
    offset, length = pool.intern(value)
    return struct.pack("<IHH", offset, length, 0)


def emit_data(cldr: Cldr, out_dir: Path) -> None:
    pool = Pool()
    locales = sorted(cldr.records)
    locale_records = bytearray()
    for locale in locales:
        record = cldr.records[locale]
        locale_records += pack_str(pool, locale)
        locale_records += pack_str(pool, record["orders"].get("givenFirst") or "")
        locale_records += pack_str(pool, record["orders"].get("surnameFirst") or "")
        default_length = record["defaults"].get("length") or "medium"
        default_formality = record["defaults"].get("formality") or "formal"
        locale_records += struct.pack(
            "<BBH",
            LENGTHS.index(default_length),
            FORMALITIES.index(default_formality),
            0,
        )
        locale_records += pack_str(pool, record["native"] if record["native"] is not None else " ")
        locale_records += pack_str(pool, record["foreign"] if record["foreign"] is not None else " ")
        locale_records += pack_str(pool, record["initial"] or "{0}.")
        locale_records += pack_str(pool, record["initial_sequence"] or "{0} {1}")
        for combo in (
            (order, length, usage, formality)
            for order in ORDERS
            for length in LENGTHS
            for usage in USAGES
            for formality in FORMALITIES
        ):
            values = record["patterns"][combo]
            locale_records += pack_str(pool, values.get(0, ""))
            locale_records += pack_str(pool, values.get(1, ""))
        if len(locale_records) % LOCALE_RECORD_LEN != 0:
            raise SystemExit("internal locale record size mismatch")

    parents = sorted(cldr.explicit_parent.items())
    parent_records = bytearray()
    for locale, parent in parents:
        parent_records += pack_str(pool, locale)
        parent_records += pack_str(pool, parent)

    header_len = DATA_HEADER_LEN
    locale_records_offset = header_len
    parent_records_offset = locale_records_offset + len(locale_records)
    pool_offset = parent_records_offset + len(parent_records)
    blob = bytearray(DATA_MAGIC)
    blob += struct.pack("<B3B", DATA_FORMAT_VERSION, CLDR_VERSION, 0, 0)
    blob += struct.pack(
        "<HHB3xIII",
        len(locales),
        len(parents),
        1 if cldr.skip_non_likely else 0,
        locale_records_offset,
        parent_records_offset,
        pool_offset,
    )
    blob += locale_records
    blob += parent_records
    blob += pool.data
    (out_dir / "person_names_data.bin").write_bytes(bytes(blob))
    print(
        f"wrote person_names_data.bin: {len(blob)} bytes, {len(locales)} locales, "
        f"{len(parents)} parents, {len(pool.data)} byte pool",
        file=sys.stderr,
    )


def emit_conformance(archive: zipfile.ZipFile, out_dir: Path) -> None:
    names = sorted(
        name
        for name in archive.namelist()
        if name.startswith("common/testData/personNameTest/")
        and name.endswith(".txt")
    )
    blocks = []
    for name in names:
        locale = name.rsplit("/", 1)[1][:-4]
        fields = []
        name_locale = "und"
        groups = []
        expected = None
        params = []
        for line in archive.read(name).decode("utf-8").splitlines():
            if not line or line.startswith("#"):
                continue
            parts = [part.strip() for part in line.split(";")]
            kind = parts[0]
            if kind == "name":
                field = parts[1]
                value = parts[2]
                if field == "locale":
                    name_locale = value
                else:
                    bits = field.split("-")
                    fields.append((bits[0], bits[1:], value))
            elif kind == "expectedResult":
                if expected is not None:
                    groups.append((expected, params))
                expected = parts[1]
                params = []
            elif kind == "parameters":
                order, length, usage, formality = parts[1:5]
                params.append(
                    (
                        ORDERS.index(order),
                        LENGTHS.index(length),
                        USAGES.index(usage),
                        FORMALITIES.index(formality),
                    )
                )
            elif kind == "endName":
                if expected is not None:
                    groups.append((expected, params))
                blocks.append((locale, fields, name_locale, groups))
                fields = []
                groups = []
                expected = None
                params = []
        if fields or groups:
            raise SystemExit(f"unterminated person name block in {name}")

    blob = bytearray(CONFORMANCE_MAGIC)
    blob += struct.pack("<B3B", CONFORMANCE_FORMAT_VERSION, CLDR_VERSION, 0, 0)
    blob += struct.pack("<I", len(blocks))
    for locale, fields, name_locale, groups in blocks:
        locale_bytes = locale.encode("utf-8")
        blob += struct.pack("<B", len(locale_bytes))
        blob += locale_bytes
        blob += struct.pack("<B", len(fields))
        for field, modifiers, value in fields:
            value_bytes = value.encode("utf-8")
            bits = 0
            for modifier in modifiers:
                bits |= MODIFIER_BITS.get(modifier, 0)
            blob += struct.pack("<BBB", FIELD_IDS[field], bits, len(value_bytes))
            blob += value_bytes
        name_locale_bytes = name_locale.encode("utf-8")
        blob += struct.pack("<B", len(name_locale_bytes))
        blob += name_locale_bytes
        blob += struct.pack("<B", len(groups))
        for expected, params in groups:
            expected_bytes = expected.encode("utf-8")
            blob += struct.pack("<HH", len(expected_bytes), len(params))
            blob += expected_bytes
            for order, length, usage, formality in params:
                blob += struct.pack("<BBBB", order, length, usage, formality)
    (out_dir / "person_names_conformance.bin").write_bytes(bytes(blob))
    total = sum(len(group[1]) for block in blocks for group in block[3])
    print(
        f"wrote person_names_conformance.bin: {len(blob)} bytes, "
        f"{len(blocks)} blocks, {total} cases",
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

    cldr = Cldr(zip_path)
    cldr.resolve_all()
    emit_data(cldr, out_dir)
    with zipfile.ZipFile(zip_path) as archive:
        emit_conformance(archive, out_dir)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
