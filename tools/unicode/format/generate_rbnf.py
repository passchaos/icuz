#!/usr/bin/env python3
"""Generate CLDR 48 RBNF (rule-based number format) tables.

Usage:
    generate_rbnf.py cldr-common-48.zip out_dir

Rule sets are read from `common/rbnf/<locale>.xml` and resolved through the
CLDR parent chain. Identical rule sets are deduplicated across locales; each
locale stores the effective name -> rule set map.

The compiler follows ICU's NFRuleSet parser:
  * a rule body's leading apostrophe is stripped (it only exists to allow a
    leading space);
  * `%%name` private rule set references resolve to the same table as `%name`;
  * when a rule set defines more than one decimal rule (x.x / x,x), the last
    one wins;
  * rule sets referenced from a decimal rule through `>%name>` are marked as
    fraction rule sets so the runtime can format the fraction by denominator.
"""

from __future__ import annotations

import copy
import re
import struct
import sys
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

CLDR_VERSION = 48

LOCALES = (
    "root", "en", "af", "ak", "am", "ar", "az", "be", "bg", "bn", "bs",
    "ca", "ccp", "chr", "cs", "cy", "da", "de", "de-AT", "de-CH", "ee",
    "el", "en-AU", "en-CA", "en-GB", "en-IN", "en-001", "eo", "es",
    "es-419", "es-MX", "et", "eu", "fa", "fa-AF", "ff", "fi", "fil",
    "fo", "fr", "fr-BE", "fr-CA", "fr-CH", "ga", "gl", "gu", "he", "hi",
    "hr", "hu", "hy", "id", "is", "it", "ja", "ka", "kk", "kl", "km",
    "kn", "ko", "ky", "lb", "lo", "lrc", "lt", "lv", "mk", "ml", "mn",
    "mr", "ms", "mt", "my", "nb", "ne", "nl", "nl-BE", "nn", "no", "pa",
    "pl", "ps", "pt", "pt-PT", "qu", "ro", "ru", "se", "si", "sk", "sl",
    "sq", "sr", "sr-Latn", "su", "sv", "sw", "ta", "te", "th", "tr",
    "uk", "ur", "uz", "vec", "vi", "yue", "yue-Hans", "zh", "zh-Hant",
    "zu",
)

PARENT = {
    "de-AT": "de",
    "de-CH": "de",
    "en-AU": "en-001",
    "en-CA": "en-001",
    "en-GB": "en-001",
    "en-IN": "en-001",
    "es-419": "es",
    "es-MX": "es-419",
    "fr-CA": "fr",
    "nb": "no",
    "nn": "no",
    "nl-BE": "nl",
    "pt-PT": "pt",
    "zh-Hant": "root",
}

RULE_NORMAL = 0
RULE_NEGATIVE = 1
RULE_DECIMAL = 2
RULE_INFINITY = 3
RULE_NAN = 4
RULE_PROPER = 5

TOKEN_LITERAL = 0
TOKEN_NUMERATOR = 1
TOKEN_DENOMINATOR = 2
TOKEN_DIGITS = 3
TOKEN_HYPHEN_DENOMINATOR = 4
TOKEN_NUMERATOR_SET = 5
TOKEN_DENOMINATOR_SET = 6
TOKEN_VALUE_SET = 7
TOKEN_PATTERN = 8
TOKEN_OPTIONAL_START = 9
TOKEN_OPTIONAL_END = 10
TOKEN_PLURAL = 11
TOKEN_NUMERATOR_PATTERN = 12
TOKEN_DENOMINATOR_PATTERN = 13
TOKEN_OPTIONAL_ELSE = 14
TOKEN_HYPHEN_DENOMINATOR_SET = 15
TOKEN_HYPHEN_DENOMINATOR_PATTERN = 16

NO_RULESET = 0xFFFFFFFF

PATTERN_CHARS = set("#0,.")

FRACTION_FLAG = 1


def radix_for(base: int) -> int:
    """ICU's default divisor: 10^floor(log10(base)), 1 for single digits."""
    if base < 10:
        return 1
    radix = 1
    while radix * 10 <= base:
        radix *= 10
    return radix


def clean_name(name: str) -> str:
    return name.lstrip("%")


def parse_rule_text(text: str):
    """Split rule text into (kind, value) tokens or None if unsupported."""
    tokens = []
    literal: list[str] = []

    def flush() -> None:
        if literal:
            tokens.append((TOKEN_LITERAL, "".join(literal)))
            literal.clear()

    index = 0
    length = len(text)
    while index < length:
        character = text[index]
        if text.startswith(">>>", index):
            flush()
            tokens.append((TOKEN_DIGITS, None))
            index += 3
            continue
        if text.startswith("->%", index):
            end = text.find(">", index + 3)
            if end < 0:
                return None
            flush()
            tokens.append(
                (TOKEN_HYPHEN_DENOMINATOR_SET, clean_name(text[index + 3 : end]))
            )
            index = end + 1
            continue
        if text.startswith("->#", index) or text.startswith("->0", index):
            end = text.find(">", index + 3)
            if end < 0:
                return None
            pattern = text[index + 2 : end]
            if not set(pattern) <= PATTERN_CHARS:
                return None
            flush()
            tokens.append((TOKEN_HYPHEN_DENOMINATOR_PATTERN, pattern))
            index = end + 1
            continue
        if text.startswith("->>", index):
            flush()
            tokens.append((TOKEN_HYPHEN_DENOMINATOR, None))
            index += 3
            continue
        if text.startswith("<<", index):
            flush()
            tokens.append((TOKEN_NUMERATOR, None))
            index += 2
            continue
        if text.startswith(">>", index):
            flush()
            tokens.append((TOKEN_DENOMINATOR, None))
            index += 2
            continue
        if text.startswith("=%", index):
            end = text.find("=", index + 2)
            if end < 0:
                return None
            flush()
            tokens.append((TOKEN_VALUE_SET, clean_name(text[index + 2 : end])))
            index = end + 1
            continue
        if text.startswith(">%", index):
            end = text.find(">", index + 2)
            if end < 0:
                return None
            flush()
            tokens.append((TOKEN_DENOMINATOR_SET, clean_name(text[index + 2 : end])))
            index = end + 1
            continue
        if text.startswith("<%", index):
            end = text.find("<", index + 2)
            if end < 0:
                return None
            flush()
            tokens.append((TOKEN_NUMERATOR_SET, clean_name(text[index + 2 : end])))
            index = end + 1
            # ICU's `<%name<<` hack consumes the second '<' as part of the
            # substitution token.
            if index < length and text[index] == "<":
                index += 1
            continue
        if text.startswith("=#", index) or text.startswith("=0", index):
            end = text.find("=", index + 2)
            if end < 0:
                return None
            pattern = text[index + 1 : end]
            if not set(pattern) <= PATTERN_CHARS:
                return None
            flush()
            tokens.append((TOKEN_PATTERN, pattern))
            index = end + 1
            continue
        if text.startswith("<#", index) or text.startswith("<0", index):
            end = text.find("<", index + 2)
            if end < 0:
                return None
            pattern = text[index + 1 : end]
            if not set(pattern) <= PATTERN_CHARS:
                return None
            flush()
            tokens.append((TOKEN_NUMERATOR_PATTERN, pattern))
            index = end + 1
            continue
        if text.startswith(">#", index) or text.startswith(">0", index):
            end = text.find(">", index + 2)
            if end < 0:
                return None
            pattern = text[index + 1 : end]
            if not set(pattern) <= PATTERN_CHARS:
                return None
            flush()
            tokens.append((TOKEN_DENOMINATOR_PATTERN, pattern))
            index = end + 1
            continue
        if text.startswith("$(", index):
            end = text.find(")$", index + 2)
            if end < 0:
                return None
            inner = text[index + 2 : end]
            comma = inner.find(",")
            if comma < 0:
                return None
            plural_kind = inner[:comma].strip()
            if plural_kind not in ("cardinal", "ordinal"):
                return None
            pairs = re.findall(r"(\w+)\{([^}]*)\}", inner[comma + 1 :])
            if not pairs:
                return None
            payload = ("o" if plural_kind == "ordinal" else "c") + "".join(
                f"\x1f{key}\x1f{value}" for key, value in pairs
            )
            flush()
            tokens.append((TOKEN_PLURAL, payload))
            index = end + 2
            continue
        if character == "[":
            flush()
            tokens.append((TOKEN_OPTIONAL_START, None))
            index += 1
            continue
        if character == "]":
            flush()
            tokens.append((TOKEN_OPTIONAL_END, None))
            index += 1
            continue
        if character == "|":
            flush()
            tokens.append((TOKEN_OPTIONAL_ELSE, None))
            index += 1
            continue
        literal.append(character)
        index += 1
    flush()
    return tokens


def parse_rulesets(xml_text: str):
    """Return {name: [(kind, base, radix, tokens), ...]} for one locale."""
    document = ET.fromstring(xml_text)
    rulesets: dict[str, list] = {}
    for group in document.findall(".//rulesetGrouping"):
        for rules in group.findall("rbnfRules"):
            body = rules.text or ""
            current = None
            for raw in body.splitlines():
                line = raw.strip()
                if not line or line.startswith("#"):
                    continue
                if line.startswith("%"):
                    current = clean_name(line.rstrip(":").strip())
                    rulesets.setdefault(current, [])
                    continue
                if current is None:
                    continue
                match = re.match(r"^(.*?):(.*);\s*$", line)
                if match is None:
                    continue
                key = match.group(1).strip()
                # ICU strips leading whitespace after the descriptor but
                # keeps trailing spaces (`1: ' ;` is a rule that emits one
                # space).
                text = match.group(2).lstrip()
                # ICU strips a single leading apostrophe from the rule body.
                if text.startswith("'"):
                    text = text[1:]
                tokens = parse_rule_text(text)
                if tokens is None:
                    continue
                kind = RULE_NORMAL
                base = 0
                radix = 10
                if key == "-x":
                    kind = RULE_NEGATIVE
                elif key in ("x.x", "x,x"):
                    kind = RULE_DECIMAL
                elif key in ("0.x", "0,x"):
                    kind = RULE_PROPER
                elif key == "Inf":
                    kind = RULE_INFINITY
                elif key == "NaN":
                    kind = RULE_NAN
                else:
                    try:
                        if "/" in key:
                            base_text, radix_text = key.split("/", 1)
                            base = int(base_text)
                            radix = int(radix_text)
                        else:
                            base = int(key)
                            radix = radix_for(base)
                    except ValueError:
                        continue
                entry = (kind, base, radix, tokens)
                if kind in (RULE_DECIMAL, RULE_PROPER):
                    # ICU keeps the last rule of each special type.
                    rulesets[current] = [
                        rule for rule in rulesets[current] if rule[0] != kind
                    ]
                rulesets[current].append(entry)
    return rulesets


def parent_chain(locale: str) -> list[str]:
    chain = []
    current = locale
    seen: set[str] = set()
    while current not in seen:
        seen.add(current)
        chain.append(current)
        if current == "root":
            break
        parent = PARENT.get(current)
        if parent is None:
            parent = re.split(r"[-_]", current)[0]
        if parent == current:
            parent = "root"
        current = parent
    if chain[-1] != "root":
        chain.append("root")
    return chain


def load_rulesets(archive: zipfile.ZipFile, locale: str, cache: dict) -> dict:
    if locale in cache:
        return cache[locale]
    filename = locale.replace("-", "_")
    try:
        xml = archive.read(f"common/rbnf/{filename}.xml").decode("utf-8")
    except KeyError:
        cache[locale] = {}
        return cache[locale]
    cache[locale] = parse_rulesets(xml)
    return cache[locale]


def has_ruleset_file(archive: zipfile.ZipFile, locale: str) -> bool:
    filename = locale.replace("-", "_")
    return f"common/rbnf/{filename}.xml" in archive.namelist()


def resolved_rulesets(
    archive: zipfile.ZipFile,
    locale: str,
    cache: dict,
    merged_cache: dict,
) -> dict:
    if locale in merged_cache:
        return merged_cache[locale]
    # ICU's root RBNF bundle is the English data, and locales without their
    # own bundle inherit it wholesale rather than the CLDR root fallback.
    if locale != "en" and not has_ruleset_file(archive, locale):
        result = resolved_rulesets(archive, "en", cache, merged_cache)
        merged_cache[locale] = result
        return result
    merged: dict = {}
    for name in reversed(parent_chain(locale)):
        for ruleset_name, rules in load_rulesets(archive, name, cache).items():
            merged[ruleset_name] = copy.deepcopy(rules)
    merged_cache[locale] = merged
    return merged


def fraction_rule_sets(mapping: dict[str, list]) -> set[str]:
    """Rule sets referenced through `>%name>` from a decimal rule."""
    targets: set[str] = set()
    for rules in mapping.values():
        for kind, _base, _radix, tokens in rules:
            if kind not in (RULE_DECIMAL, RULE_PROPER):
                continue
            for token_kind, value in tokens:
                if token_kind == TOKEN_DENOMINATOR_SET:
                    targets.add(value)
    return targets


def render(
    locale_maps: dict[str, dict[str, int]],
    ruleset_list: list[tuple[str, list, bool]],
):
    strings = bytearray()
    string_offsets: dict[str, tuple[int, int]] = {}

    def intern(value: str) -> tuple[int, int]:
        if value in string_offsets:
            return string_offsets[value]
        offset = len(strings)
        encoded = value.encode("utf-8")
        strings.extend(encoded)
        string_offsets[value] = (offset, len(encoded))
        return string_offsets[value]

    rule_bytes = bytearray()
    token_bytes = bytearray()
    ruleset_bytes = bytearray()
    string_token_kinds = (
        TOKEN_NUMERATOR_SET,
        TOKEN_DENOMINATOR_SET,
        TOKEN_VALUE_SET,
        TOKEN_PATTERN,
        TOKEN_PLURAL,
        TOKEN_NUMERATOR_PATTERN,
        TOKEN_DENOMINATOR_PATTERN,
        TOKEN_HYPHEN_DENOMINATOR_SET,
        TOKEN_HYPHEN_DENOMINATOR_PATTERN,
    )
    for name, rules, is_fraction in ruleset_list:
        special: list = []
        normal: list = []
        for rule in rules:
            if rule[0] == RULE_NORMAL:
                normal.append(rule)
            else:
                special.append(rule)
        normal.sort(key=lambda rule: rule[1])
        ordered = special + normal
        first_rule = len(rule_bytes) // 24
        for kind, base, radix, tokens in ordered:
            first_token = len(token_bytes) // 8
            for token_kind, value in tokens:
                if token_kind in (TOKEN_LITERAL,) + string_token_kinds:
                    offset, length = intern(value)
                    token_bytes += struct.pack("<BBHI", token_kind, 0, length, offset)
                else:
                    token_bytes += struct.pack("<BBHI", token_kind, 0, 0, 0)
            rule_bytes += struct.pack(
                "<QQIHBB",
                base,
                radix,
                first_token,
                len(tokens),
                kind,
                0,
            )
        name_offset, name_length = intern(name)
        ruleset_bytes += struct.pack(
            "<IBBHIBBH",
            name_offset,
            name_length,
            0,
            len(ordered),
            first_rule,
            FRACTION_FLAG if is_fraction else 0,
            0,
            0,
        )

    locale_header = bytearray()
    locale_refs = bytearray()
    for locale, mapping in sorted(locale_maps.items()):
        id_offset, id_length = intern(locale)
        first_ref = len(locale_refs) // 10
        for name, index in sorted(mapping.items()):
            ref_offset, ref_length = intern(name)
            locale_refs += struct.pack("<IBIB", ref_offset, ref_length, index, 0)
        locale_header += struct.pack(
            "<IBBIH",
            id_offset,
            id_length,
            len(mapping),
            first_ref,
            0,
        )

    header = bytearray(b"CJRB")
    header += struct.pack(
        "<B3xHIIII",
        1,
        len(locale_maps),
        len(ruleset_list),
        len(rule_bytes) // 24,
        len(token_bytes) // 8,
        len(strings),
    )
    return bytes(
        header
        + locale_header
        + locale_refs
        + ruleset_bytes
        + rule_bytes
        + token_bytes
        + strings
    )


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    archive_path = Path(sys.argv[1])
    out_dir = Path(sys.argv[2])
    out_dir.mkdir(parents=True, exist_ok=True)

    cache: dict = {}
    merged_cache: dict = {}
    locale_maps: dict[str, dict[str, int]] = {}
    ruleset_index: dict[tuple, int] = {}
    ruleset_list: list[tuple[str, list, bool]] = []

    with zipfile.ZipFile(archive_path) as archive:
        for locale in LOCALES:
            mapping = resolved_rulesets(archive, locale, cache, merged_cache)
            fraction = fraction_rule_sets(mapping)
            indices: dict[str, int] = {}
            for name, rules in mapping.items():
                is_fraction = name in fraction
                key = (name, repr(rules), is_fraction)
                index = ruleset_index.get(key)
                if index is None:
                    index = len(ruleset_list)
                    ruleset_index[key] = index
                    ruleset_list.append((name, rules, is_fraction))
                indices[name] = index
            locale_maps[locale] = indices

    (out_dir / "rbnf_data.bin").write_bytes(render(locale_maps, ruleset_list))
    print(
        f"generated {len(locale_maps)} locales, {len(ruleset_list)} rule sets",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
