#!/usr/bin/env python3
"""Generate CLDR 48 transliteration tables.

Usage:
    generate_data.py cldr-common-48.zip out_dir

The compiler extracts the simple mapping rules from the CLDR transforms that
are fully table-driven: Latin-ASCII, Fullwidth-Halfwidth, and the inverse
Halfwidth-Fullwidth. Rules that require the full ICU rule engine (contexts,
quantifiers, variables) are handled directly in Zig or skipped.
"""

from __future__ import annotations

import hashlib
import re
import struct
import sys
import unicodedata
import zipfile
from pathlib import Path

CLDR_SHA256 = "06c7c698d6fd8d67cefac15a0206b0109b00e0ef1636f86f84449fa959561f74"
CLDR_VERSION = 48
VARIABLE_DEF = re.compile(r"^\$[A-Za-z0-9_]+\s*=")

TRANSFORMS = (
    # (transform name, CLDR rule source, builder)
    ("Latin-ASCII", "Latin-ASCII", "latin"),
    ("Fullwidth-Halfwidth", "Fullwidth-Halfwidth", "fullwidth"),
    ("Halfwidth-Fullwidth", "Fullwidth-Halfwidth", "halfwidth"),
    ("Georgian-Latin", "Georgian-Latin", "simple"),
    ("Georgian-Latin-BGN_1981", "Georgian-Latin-BGN_1981", "context"),
    ("Latin-Georgian", "Georgian-Latin", "reverse_georgian"),
    ("Lao-Latin", "Lao-Latin", "simple"),
    ("kk-kk_FONIPA", "kk-kk_FONIPA", "simple"),
    ("ug-ug_FONIPA", "ug-ug_FONIPA", "simple"),
    ("Hebrew-Latin-BGN", "Hebrew-Latin-BGN", "variables"),
    ("Russian-Latin-BGN", "Russian-Latin-BGN", "context"),
    ("Greek-Latin-BGN", "Greek-Latin-BGN", "context"),
    ("Katakana-Latin-BGN", "Katakana-Latin-BGN", "katakana"),
    ("Amharic-Latin-BGN", "Amharic-Latin-BGN", "context"),
    ("Kazakh-Latin-BGN", "Kazakh-Latin-BGN", "context"),
    ("Turkmen-Latin-BGN", "Turkmen-Latin-BGN", "context"),
    ("Ukrainian-Latin-BGN", "Ukrainian-Latin-BGN", "context"),
    ("Belarusian-Latin-BGN", "Belarusian-Latin-BGN", "context"),
    ("Mongolian-Latin-BGN", "Mongolian-Latin-BGN", "context"),
    ("Bulgarian-Latin-BGN", "Bulgarian-Latin-BGN", "context"),
    ("Macedonian-Latin-BGN", "Macedonian-Latin-BGN", "context"),
    ("Serbian-Latin-BGN", "Serbian-Latin-BGN", "context"),
    ("InterIndic-ur", "InterIndic-ur", "context"),
    ("sgw-Ethi-t-und-ethi", "sgw-Ethi-t-und-ethi", "context"),
    (
        "am-Ethi-t-am-ethi-m0-geminate",
        "am-Ethi-t-am-ethi-m0-geminate",
        "context",
    ),
    ("und-Ethi-t-und-latn-m0-aethiopi", "und-Ethi-t-und-latn-m0-aethiopi", "context"),
    ("und-Ethi-t-und-latn-m0-beta_metsehaf", "und-Ethi-t-und-latn-m0-beta_metsehaf", "context"),
    ("und-Ethi-t-und-latn-m0-ies-jes-1964", "und-Ethi-t-und-latn-m0-ies-jes-1964", "context"),
    ("byn-Ethi-t-byn-latn-m0-tekie-alibekit", "byn-Ethi-t-byn-latn-m0-tekie-alibekit", "context"),
    ("und-Ethi-t-und-latn-m0-lambdin", "und-Ethi-t-und-latn-m0-lambdin", "context"),
    ("si-si_Latn", "si-si_Latn", "context"),
    ("my-my_FONIPA", "my-my_FONIPA", "context"),
    ("byn-Ethi-t-byn-latn-m0-xaleget", "byn-Ethi-t-byn-latn-m0-xaleget", "context"),
    ("Cyrillic-Latin", "Cyrillic-Latin", "context"),
    ("Arabic-Latin", "Arabic-Latin", "context"),
    ("InterIndic-Arabic", "InterIndic-Arabic", "context"),
    ("InterIndic-Devanagari", "InterIndic-Devanagari", "context"),
    ("InterIndic-Bengali", "InterIndic-Bengali", "context"),
    ("InterIndic-Gurmukhi", "InterIndic-Gurmukhi", "context"),
    ("InterIndic-Gujarati", "InterIndic-Gujarati", "context"),
    ("InterIndic-Oriya", "InterIndic-Oriya", "context"),
    ("InterIndic-Telugu", "InterIndic-Telugu", "context"),
    ("InterIndic-Kannada", "InterIndic-Kannada", "context"),
    ("InterIndic-Malayalam", "InterIndic-Malayalam", "context"),
    ("InterIndic-Latin", "InterIndic-Latin", "context"),
    ("chr-chr_FONIPA", "chr-chr_FONIPA", "context"),
    ("zu-zu_FONIPA", "zu-zu_FONIPA", "context"),
    ("InterIndic-Tamil", "InterIndic-Tamil", "context"),
    ("Hiragana-Katakana", "Hiragana-Katakana", "context"),
)

CONFORMANCE = (
    # (transform name, fixture path, magic, excluded source strings)
    (
        "Georgian-Latin-BGN_1981",
        "common/testData/transforms/ka-Latn-t-ka-m0-bgn-1981.txt",
        b"CJTG",
        frozenset(),
        "georgian_bgn_conformance.bin",
    ),
    (
        "Hebrew-Latin-BGN",
        "common/testData/transforms/he-Latn-t-he-m0-bgn.txt",
        b"CJTH",
        frozenset(),
        "hebrew_bgn_conformance.bin",
    ),
    (
        "Russian-Latin-BGN",
        "common/testData/transforms/ru-Latn-t-ru-m0-bgn.txt",
        b"CJRU",
        frozenset(),
        "russian_bgn_conformance.bin",
    ),
    (
        "Greek-Latin-BGN",
        "common/testData/transforms/el-Latn-t-el-m0-bgn.txt",
        b"CJGR",
        # CLDR 48's Greek BGN test data expects "dh" for the nu-delta-rho
        # cluster, while the transform XML's Rule 4a maps it to "d". Keep the
        # XML behavior and exclude the two conflicting fixture rows.
        frozenset(("\u03ac\u03bd\u03b4\u03c1\u03b1\u03c2", "\u03b1\u03bd\u03b4\u03c1\u03ce\u03bd")),
        "greek_bgn_conformance.bin",
    ),
    (
        "Katakana-Latin-BGN",
        "common/testData/transforms/ja-Latn-t-ja-hrkt-m0-bgn.txt",
        b"CJKA",
        frozenset(),
        "katakana_bgn_conformance.bin",
    ),
    (
        "Amharic-Latin-BGN",
        "common/testData/transforms/am-Latn-t-am-m0-bgn.txt",
        b"CJAM",
        frozenset(),
        "amharic_bgn_conformance.bin",
    ),
    (
        "Kazakh-Latin-BGN",
        "common/testData/transforms/kk-Latn-t-kk-m0-bgn.txt",
        b"CJKZ",
        frozenset(),
        "kazakh_bgn_conformance.bin",
    ),
    (
        "Turkmen-Latin-BGN",
        "common/testData/transforms/tk-t-tk-Cyrl-m0-bgn.txt",
        b"CJTM",
        frozenset(),
        "turkmen_bgn_conformance.bin",
    ),
    (
        "Ukrainian-Latin-BGN",
        "common/testData/transforms/uk-Latn-t-uk-m0-bgn.txt",
        b"CJUA",
        frozenset(),
        "ukrainian_bgn_conformance.bin",
    ),
    (
        "Belarusian-Latin-BGN",
        "common/testData/transforms/be-Latn-t-be-m0-bgn.txt",
        b"CJBY",
        frozenset(),
        "belarusian_bgn_conformance.bin",
    ),
    (
        "Mongolian-Latin-BGN",
        "common/testData/transforms/mn-Latn-t-mn-m0-bgn.txt",
        b"CJMO",
        frozenset(),
        "mongolian_bgn_conformance.bin",
    ),
    (
        "Bulgarian-Latin-BGN",
        "common/testData/transforms/bg-Latn-t-bg-m0-bgn.txt",
        b"CJBU",
        frozenset(),
        "bulgarian_bgn_conformance.bin",
    ),
    (
        "Macedonian-Latin-BGN",
        "common/testData/transforms/mk-Latn-t-mk-m0-bgn.txt",
        b"CJMC",
        frozenset(),
        "macedonian_bgn_conformance.bin",
    ),
    (
        "Serbian-Latin-BGN",
        "common/testData/transforms/sr-Latn-t-sr-m0-bgn.txt",
        b"CJRS",
        frozenset(),
        "serbian_bgn_conformance.bin",
    ),
    (
        "sgw-Ethi-t-und-ethi",
        "common/testData/transforms/und-Ethi-t-sgw-ethi-m0-gurage-2013.txt",
        b"CJSG",
        frozenset(),
        "sgw_ethi_conformance.bin",
    ),
    (
        "am-Ethi-t-am-ethi-m0-geminate",
        "common/testData/transforms/am-Ethi-t-am-ethi-m0-geminate.txt",
        b"CJGE",
        frozenset(),
        "amharic_geminate_conformance.bin",
    ),
    (
        "und-Ethi-t-und-latn-m0-aethiopi",
        "common/testData/transforms/und-Latn-t-und-ethi-m0-aethiopi.txt",
        b"CJE3",
        frozenset(),
        "ethi_aethiopi_conformance.bin",
    ),
    (
        "und-Ethi-t-und-latn-m0-beta_metsehaf",
        "common/testData/transforms/und-Latn-t-und-ethi-m0-beta-metsehaf.txt",
        b"CJE4",
        frozenset(),
        "ethi_beta_conformance.bin",
    ),
    (
        "und-Ethi-t-und-latn-m0-ies-jes-1964",
        "common/testData/transforms/und-Latn-t-und-ethi-m0-ies-jes-1964.txt",
        b"CJE5",
        frozenset(),
        "ethi_ies_conformance.bin",
    ),
    (
        "byn-Ethi-t-byn-latn-m0-tekie-alibekit",
        "common/testData/transforms/byn-Latn-t-byn-ethi-m0-tekie-alibekit.txt",
        b"CJBK",
        frozenset(),
        "byn_tekie_conformance.bin",
    ),
    (
        "und-Ethi-t-und-latn-m0-lambdin",
        "common/testData/transforms/und-Latn-t-und-ethi-m0-lambdin.txt",
        b"CJE7",
        frozenset(),
        "ethi_lambdin_conformance.bin",
    ),
    (
        "si-si_Latn",
        "common/testData/transforms/si-Latn-t-si.txt",
        b"CJSL",
        frozenset(),
        "si_latn_conformance.bin",
    ),
    (
        "my-my_FONIPA",
        "common/testData/transforms/my-fonipa-t-my.txt",
        b"CJMF",
        frozenset(),
        "my_fonipa_conformance.bin",
    ),
    (
        "byn-Ethi-t-byn-latn-m0-xaleget",
        "common/testData/transforms/byn-Latn-t-byn-ethi-m0-xaleget.txt",
        b"CJB2",
        frozenset(),
        "byn_xaleget_conformance.bin",
    ),
)


NORMALIZATION_FORMS = {"NFKD": 3, "NFKC": 4, "NFD": 1, "NFC": 2}


def normalization_directives(rules: str):
    directives = []
    last_rule = -1
    for index, raw in enumerate(rules.splitlines()):
        line = strip_comment(raw).strip()
        if not line:
            continue
        if line.startswith("::"):
            directive = line[2:].strip().rstrip(";").strip().upper()
            form = None
            if directive.startswith("NFKD"):
                form = 3
            elif directive.startswith("NFKC"):
                form = 4
            elif directive.startswith("NFD"):
                form = 1
            elif directive.startswith("NFC"):
                form = 2
            if form is not None:
                post_form = None
                match = re.search(r"\(\s*(NFK?[CD])\s*\)", directive)
                if match:
                    post_form = NORMALIZATION_FORMS.get(match.group(1))
                directives.append((index, form, post_form))
        elif not VARIABLE_DEF.match(line):
            last_rule = index
    return directives, last_rule


def detect_pre_normalization(rules: str) -> int:
    """Map the transform's first normalization directive to the input form."""
    directives, _ = normalization_directives(rules)
    return directives[0][1] if directives else 0


def detect_post_normalization(rules: str) -> int:
    """Map the forward direction's output normalization form."""
    directives, last_rule = normalization_directives(rules)
    if not directives:
        return 0
    # Bidirectional transforms place a second normalization directive between
    # the forward and reverse rule sections; the first parenthetical form
    # describes the forward output.
    if len(directives) >= 2 and directives[0][2] is not None:
        return directives[0][2]
    index, form, post_form = directives[-1]
    if post_form is not None and index > last_rule:
        return post_form
    return form if index > last_rule else 0


def checked_zip(path: Path) -> zipfile.ZipFile:
    actual = hashlib.sha256(path.read_bytes()).hexdigest()
    if actual != CLDR_SHA256:
        raise SystemExit(
            f"{path}: expected CLDR 48 SHA-256 {CLDR_SHA256}, found {actual}"
        )
    return zipfile.ZipFile(path)


def strip_comment(line: str) -> str:
    output: list[str] = []
    quoted = False
    index = 0
    while index < len(line):
        character = line[index]
        if character == "\\" and index + 1 < len(line):
            output.append(line[index : index + 2])
            index += 2
            continue
        if character == "'":
            if quoted and index + 1 < len(line) and line[index + 1] == "'":
                output.append("''")
                index += 2
                continue
            quoted = not quoted
            output.append(character)
            index += 1
            continue
        if not quoted and character == "#":
            break
        output.append(character)
        index += 1
    return "".join(output).strip()


def read_escape(text: str, index: int) -> tuple[int, int]:
    if index + 1 >= len(text):
        return ord("\\"), 1
    kind = text[index + 1]
    if kind == "u" and index + 6 <= len(text):
        return int(text[index + 2 : index + 6], 16), 6
    if kind == "U" and index + 10 <= len(text):
        return int(text[index + 2 : index + 10], 16), 10
    simple = {"t": 9, "n": 10, "r": 13, "\\": 92, "'": 39}
    if kind in simple:
        return simple[kind], 2
    return ord(kind), 2


def parse_side(text: str) -> tuple[list[int], bool]:
    codepoints: list[int] = []
    quoted = False
    syntax = False
    index = 0
    while index < len(text):
        character = text[index]
        if character == "'":
            if index + 1 < len(text) and text[index + 1] == "'":
                codepoints.append(0x27)
                index += 2
                continue
            quoted = not quoted
            index += 1
            continue
        if character == "\\":
            codepoint, consumed = read_escape(text, index)
            codepoints.append(codepoint)
            index += consumed
            continue
        if not quoted and character in "[]{}()+*?|$/":
            syntax = True
        if not quoted and character.isspace():
            index += 1
            continue
        codepoints.append(ord(character))
        index += 1
    return codepoints, syntax


def split_rule(line: str):
    quoted = False
    index = 0
    while index < len(line):
        character = line[index]
        if character == "'":
            if quoted and index + 1 < len(line) and line[index + 1] == "'":
                index += 2
                continue
            quoted = not quoted
        elif not quoted and character in "→←↔":
            return line[:index], character, line[index + 1 :]
        index += 1
    return None


def extract_rule(xml: str) -> str:
    match = re.search(r"<tRule><!\[CDATA\[(.*?)\]\]></tRule>", xml, re.S)
    if match is None:
        match = re.search(r"<tRule>(.*?)</tRule>", xml, re.S)
    if match is None:
        raise SystemExit("transform is missing tRule")
    # Plain-text tRules may contain XML comments that disable rules.
    return re.sub(r"<!--.*?-->", "", match.group(1), flags=re.S)


def simple_rules(rules: str, *, both: bool):
    entries: list[tuple[tuple[int, ...], tuple[int, ...], str]] = []
    for raw in rules.splitlines():
        line = strip_comment(raw)
        line = line.replace("\u200e", "").replace("\u200f", "")
        line = line.replace("\u061c", "")
        if not line or line.startswith("::") or VARIABLE_DEF.match(line):
            continue
        parts = split_rule(line)
        if parts is None:
            continue
        left, arrow, right = parts
        left = left.strip()
        right = right.strip()
        if right.endswith(";"):
            right = right[:-1].strip()
        source, source_syntax = parse_side(left)
        target, target_syntax = parse_side(right)
        if source_syntax or target_syntax:
            continue
        if not source:
            continue
        if arrow == "→" or arrow == "↔":
            entries.append((tuple(source), tuple(target), arrow))
    if both:
        return entries
    return entries


def latin_ascii_entries(rules: str):
    result: dict[tuple[int, ...], tuple[int, ...]] = {}
    for source, target, arrow in simple_rules(rules, both=False):
        if arrow == "←":
            continue
        result[source] = target
    return sorted(result.items(), key=lambda item: (item[0][0], -len(item[0]), item[0]))


def simple_table_entries(rules: str):
    result: dict[tuple[int, ...], tuple[int, ...]] = {}
    for source, target, arrow in simple_rules(rules, both=False):
        if arrow == "←":
            continue
        result[source] = target
    return sorted(result.items(), key=lambda item: (item[0][0], -len(item[0]), item[0]))


def reverse_table(table: list[tuple[tuple[int, ...], tuple[int, ...]]]):
    result: dict[tuple[int, ...], tuple[int, ...]] = {}
    for source, target in table:
        if not target:
            continue
        if target not in result:
            result[target] = source
    return sorted(result.items(), key=lambda item: (item[0][0], -len(item[0]), item[0]))


def parse_variables(rules: str) -> dict[str, str]:
    variables: dict[str, str] = {}
    for raw in rules.splitlines():
        line = strip_comment(raw)
        line = line.replace("\u200e", "").replace("\u200f", "")
        line = line.replace("\u061c", "")
        if not line.startswith("$") or "=" not in line:
            continue
        for statement in line.split(";"):
            statement = statement.strip()
            if not statement.startswith("$") or "=" not in statement:
                continue
            name, value = statement.split("=", 1)
            name = name.strip()
            value = value.strip()
            if not name:
                continue
            # Empty values are meaningful (for example the sixth Ethiopic
            # vowel order has no suffix).
            variables[name] = value
    return variables


def resolve_variable(
    name: str,
    variables: dict[str, str],
    depth: int = 0,
):
    if depth > 8 or name not in variables:
        return None
    value = variables[name]
    if value.startswith("[") and value.endswith("]"):
        codepoints = parse_class(value, variables, depth + 1)
        return None if codepoints is None else ("set", codepoints)
    codepoints, syntax = parse_side_with_variables(value, variables, depth + 1)
    if syntax:
        return None
    return ("literal", codepoints)


def parse_class(
    text: str,
    variables: dict[str, str],
    depth: int = 0,
) -> list[int] | None:
    if not (text.startswith("[") and text.endswith("]")):
        return None
    content = text[1:-1]
    if content.startswith("^"):
        return None
    codepoints: list[int] = []
    index = 0
    while index < len(content):
        character = content[index]
        if character == "\\":
            codepoint, consumed = read_escape(content, index)
            codepoints.append(codepoint)
            index += consumed
            continue
        if character == "$":
            end = index + 1
            while end < len(content) and (
                content[end].isalnum() or content[end] == "_"
            ):
                end += 1
            if end == index + 1:
                codepoints.append(-1)
                index = end
                continue
            resolved = resolve_variable(content[index:end], variables, depth + 1)
            if resolved is None:
                return None
            kind, value = resolved
            if kind == "set":
                codepoints.extend(value)
            else:
                codepoints.extend(value)
            index = end
            continue
        if character == "[":
            end = content.find("]", index + 1)
            if end < 0:
                return None
            nested = parse_class(content[index : end + 1], variables, depth + 1)
            if nested is None:
                return None
            codepoints.extend(nested)
            index = end + 1
            continue
        if (
            index + 2 < len(content)
            and content[index + 1] == "-"
            and content[index + 2] != "]"
        ):
            start = ord(character)
            end_char = content[index + 2]
            end = ord(end_char)
            if end < start:
                return None
            codepoints.extend(range(start, end + 1))
            index += 3
            continue
        codepoints.append(ord(character))
        index += 1
    return sorted(set(codepoints))


def parse_side_with_variables(
    text: str,
    variables: dict[str, str],
    depth: int = 0,
) -> tuple[list[int], bool]:
    codepoints: list[int] = []
    quoted = False
    syntax = False
    index = 0
    while index < len(text):
        character = text[index]
        if character == "'":
            if index + 1 < len(text) and text[index + 1] == "'":
                codepoints.append(0x27)
                index += 2
                continue
            quoted = not quoted
            index += 1
            continue
        if character == "\\":
            codepoint, consumed = read_escape(text, index)
            codepoints.append(codepoint)
            index += consumed
            continue
        if not quoted and character == "$":
            end = index + 1
            while end < len(text) and (text[end].isalnum() or text[end] == "_"):
                end += 1
            resolved = resolve_variable(text[index:end], variables, depth + 1)
            if resolved is None:
                syntax = True
                index = end
                continue
            kind, value = resolved
            if kind == "literal":
                codepoints.extend(value)
            else:
                syntax = True
            index = end
            continue
        if not quoted and character in "[]{}()+*?|":
            syntax = True
        if not quoted and character.isspace():
            index += 1
            continue
        codepoints.append(ord(character))
        index += 1
    return codepoints, syntax


def table_entries_with_variables(rules: str):
    variables = parse_variables(rules)
    result: dict[tuple[int, ...], tuple[int, ...]] = {}
    for raw in rules.splitlines():
        line = strip_comment(raw)
        line = line.replace("\u200e", "").replace("\u200f", "")
        line = line.replace("\u061c", "")
        if not line or line.startswith("::") or VARIABLE_DEF.match(line):
            continue
        parts = split_rule(line)
        if parts is None:
            continue
        left, arrow, right = parts
        left = left.strip()
        right = right.strip()
        if right.endswith(";"):
            right = right[:-1].strip()
        if arrow == "←":
            continue
        target, target_syntax = parse_side_with_variables(right, variables)
        if target_syntax:
            continue
        if left.startswith("[") and left.endswith("]"):
            sources = parse_class(left, variables)
            if sources is None:
                continue
            for codepoint in sources:
                result[(codepoint,)] = tuple(target)
            continue
        source, source_syntax = parse_side_with_variables(left, variables)
        if source_syntax or not source:
            continue
        result[tuple(source)] = tuple(target)
    return sorted(result.items(), key=lambda item: (item[0][0], -len(item[0]), item[0]))


def render_conformance(
    archive: zipfile.ZipFile,
    test_path: str,
    magic: bytes,
    exclude_sources: frozenset[str] = frozenset(),
) -> bytes:
    text = archive.read(test_path).decode("utf-8")
    cases: list[tuple[str, str]] = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "\t" not in line:
            continue
        source, target = line.split("\t", 1)
        if source in exclude_sources:
            continue
        cases.append((source, target))
    payload = bytearray(
        struct.pack("<4sBBBB I", magic, 1, CLDR_VERSION, 0, 0, len(cases))
    )
    for source, target in cases:
        source_bytes = source.encode("utf-8")
        target_bytes = target.encode("utf-8")
        if len(source_bytes) > 0xFFFF or len(target_bytes) > 0xFFFF:
            raise SystemExit("conformance string too long")
        payload += struct.pack("<HH", len(source_bytes), len(target_bytes))
        payload += source_bytes
        payload += target_bytes
    return bytes(payload)


def fullwidth_entries(rules: str):
    forward: dict[tuple[int, ...], tuple[int, ...]] = {}
    reverse: dict[tuple[int, ...], tuple[int, ...]] = {}
    for source, target, arrow in simple_rules(rules, both=True):
        if arrow != "↔":
            continue
        forward[source] = target
        reverse[target] = source
    sort_key = lambda item: (item[0][0], -len(item[0]), item[0])
    return (
        sorted(forward.items(), key=sort_key),
        sorted(reverse.items(), key=sort_key),
    )


PROPERTY_CACHE: dict[str, frozenset[int]] = {}


def property_codepoints(name: str):
    key = name.strip().lower()
    if key in PROPERTY_CACHE:
        return PROPERTY_CACHE[key]
    result: list[int] = []
    if key in ("uppercase", "lowercase"):
        categories = ("Lu", "Lt") if key == "uppercase" else ("Ll", "Lt")
        for codepoint in range(0x110000):
            if unicodedata.category(chr(codepoint)) in categories:
                result.append(codepoint)
    elif key in ("l", "m", "n"):
        prefix = key.upper()
        for codepoint in range(0x110000):
            if unicodedata.category(chr(codepoint)).startswith(prefix):
                result.append(codepoint)
    else:
        return None
    value = frozenset(result)
    PROPERTY_CACHE[key] = value
    return value


def resolve_set_variable(name: str, variables: dict[str, str], depth: int = 0):
    raw = variables.get(name)
    if raw is None:
        return None
    if raw.startswith("[") and raw.endswith("]"):
        return parse_class_set(raw, variables, depth + 1)
    codepoints, syntax = parse_side_with_variables(raw, variables, depth + 1)
    if syntax:
        return None
    return (frozenset(codepoints), False)


def parse_class_set(
    text: str,
    variables: dict[str, str],
    depth: int = 0,
):
    if not (text.startswith("[") and text.endswith("]")):
        return None
    content = text[1:-1]
    negated = content.startswith("^")
    if negated:
        content = content[1:]
    value = parse_class_expression(content, variables, depth + 1)
    if value is None:
        return None
    return (value, negated)


def parse_class_expression(
    content: str,
    variables: dict[str, str],
    depth: int = 0,
):
    stripped = content.strip()
    if stripped.startswith(":") and stripped.endswith(":"):
        return property_codepoints(stripped[1:-1])
    index = 0
    current: set[int] | None = None
    operator = "union"
    while index < len(content):
        character = content[index]
        if character.isspace():
            index += 1
            continue
        if character in "-&":
            operator = "diff" if character == "-" else "intersect"
            index += 1
            continue
        parsed = parse_class_term(content, index, variables, depth + 1)
        if parsed is None:
            return None
        term, index = parsed
        if current is None:
            current = set(term)
        elif operator == "union":
            current |= term
        elif operator == "diff":
            current -= term
        else:
            current &= term
        operator = "union"
    return frozenset(current) if current is not None else frozenset()


def parse_class_term(
    content: str,
    index: int,
    variables: dict[str, str],
    depth: int = 0,
):
    if index >= len(content):
        return None
    character = content[index]
    if character == "[":
        if content.startswith("[:", index):
            end = content.find(":]", index + 2)
            if end < 0:
                return None
            value = property_codepoints(content[index + 2 : end])
            return None if value is None else (value, end + 2)
        depth_count = 0
        end = index
        while end < len(content):
            if content[end] == "[":
                depth_count += 1
            elif content[end] == "]":
                depth_count -= 1
                if depth_count == 0:
                    break
            end += 1
        if depth_count != 0:
            return None
        parsed = parse_class_set(content[index : end + 1], variables, depth + 1)
        if parsed is None:
            return None
        value, negated = parsed
        if negated:
            return None
        return (value, end + 1)
    if character == "$":
        end = index + 1
        while end < len(content) and (content[end].isalnum() or content[end] == "_"):
            end += 1
        if end == index + 1:
            # A bare `$` inside a class is the end-of-text anchor.
            return (frozenset((-1,)), index + 1)
        resolved = resolve_set_variable(content[index:end], variables, depth + 1)
        if resolved is None:
            return None
        value, negated = resolved
        if negated:
            return None
        return (value, end)
    if character == "\\":
        first, consumed = read_escape(content, index)
        index += consumed
    else:
        first = ord(character)
        index += 1
    if (
        index + 1 < len(content)
        and content[index] == "-"
        and not content[index + 1].isspace()
        and content[index + 1] not in "&]"
    ):
        if content[index + 1] == "\\":
            last, consumed = read_escape(content, index + 1)
            index += 1 + consumed
        else:
            last = ord(content[index + 1])
            index += 2
        if last < first:
            return None
        return (frozenset(range(first, last + 1)), index)
    return (frozenset((first,)), index)


def parse_context(text: str, variables: dict[str, str]):
    text = text.strip()
    if not text:
        return None
    tokens = split_context_tokens(text)
    if tokens is None:
        return None
    elements = []
    for token in tokens:
        optional = token.endswith("?")
        if optional:
            token = token[:-1]
        parsed = parse_context_token(token, variables)
        if parsed is None:
            return None
        for base, negated, boundary, repeat, anchor in parsed:
            elements.append(
                (base, negated, boundary, optional, repeat, anchor)
            )
    return elements if elements else None


def parse_context_token(token: str, variables: dict[str, str]):
    token = token.strip()
    if not token:
        return None
    if token == "$":
        return [(frozenset(), False, True, 0, True)]
    if token == "$wordBoundary":
        raw = variables.get("$wordBoundary")
        if raw is None:
            return None
        parsed = parse_class_set(raw, variables)
        if parsed is None:
            return None
        base, negated = parsed
        if not negated:
            return None
        return [(base, True, True, 0, False)]
    elements = []
    index = 0
    while index < len(token):
        character = token[index]
        if character == "[":
            depth = 0
            end = index
            while end < len(token):
                if token[end] == "[":
                    depth += 1
                elif token[end] == "]":
                    depth -= 1
                    if depth == 0:
                        break
                end += 1
            if depth != 0:
                return None
            parsed = parse_class_set(token[index : end + 1], variables)
            if parsed is None:
                return None
            base, negated = parsed
            elements.append((base, negated, False, 0, False))
            index = end + 1
            continue
        if character == "(":
            depth = 0
            end = index
            while end < len(token):
                if token[end] == "(":
                    depth += 1
                elif token[end] == ")":
                    depth -= 1
                    if depth == 0:
                        break
                end += 1
            if depth != 0 or end + 1 >= len(token):
                return None
            quantifier = token[end + 1]
            if quantifier not in "*+":
                return None
            inner = token[index + 1 : end].strip()
            parsed = parse_class_set(inner, variables)
            if parsed is None:
                if inner.startswith("$"):
                    parsed = resolve_set_variable(inner, variables)
                if parsed is None:
                    return None
            base, negated = parsed
            elements.append(
                (
                    base,
                    negated,
                    False,
                    1 if quantifier == "*" else 2,
                    False,
                )
            )
            index = end + 2
            continue
        if character == "$":
            end = index + 1
            while end < len(token) and (
                token[end].isalnum() or token[end] == "_"
            ):
                end += 1
            resolved = resolve_set_variable(token[index:end], variables)
            if resolved is None:
                return None
            base, negated = resolved
            elements.append((base, negated, False, 0, False))
            index = end
            continue
        if character in "*+{}|":
            return None
        if character == "\\":
            codepoint, consumed = read_escape(token, index)
            index += consumed
        else:
            codepoint = ord(character)
            index += 1
        elements.append((frozenset((codepoint,)), False, False, 0, False))
    return elements if elements else None


def split_context_tokens(text: str):
    tokens: list[str] = []
    index = 0
    while index < len(text):
        while index < len(text) and text[index].isspace():
            index += 1
        if index >= len(text):
            break
        start = index
        depth = 0
        while index < len(text):
            character = text[index]
            if character == "[":
                depth += 1
            elif character == "]":
                depth -= 1
            elif character.isspace() and depth == 0:
                break
            index += 1
        tokens.append(text[start:index])
    return tokens if tokens else None


MAX_SOURCE_REPEAT = 3
MAX_SOURCE_ALTERNATIVES = 4096


def strip_whole_group(source_text: str):
    text = source_text.strip()
    if not (text.startswith("(") and text.endswith(")")):
        return None
    depth = 0
    for index, character in enumerate(text):
        if character == "(":
            depth += 1
        elif character == ")":
            depth -= 1
            if depth == 0 and index != len(text) - 1:
                return None
    if depth != 0:
        return None
    return text[1:-1].strip()


def parse_source_terms(text: str, variables: dict[str, str]):
    terms = []
    index = 0
    while index < len(text):
        if text[index].isspace():
            index += 1
            continue
        if text[index] in "|{}/":
            return None
        alternatives = None
        if text[index] == "[":
            depth = 0
            end = index
            while end < len(text):
                if text[end] == "[":
                    depth += 1
                elif text[end] == "]":
                    depth -= 1
                    if depth == 0:
                        break
                end += 1
            if depth != 0:
                return None
            parsed = parse_class_set(text[index : end + 1], variables)
            if parsed is None:
                return None
            values, negated = parsed
            if negated:
                return None
            alternatives = [
                (codepoint,)
                for codepoint in sorted(values)
                if codepoint >= 0
            ]
            if not alternatives:
                return None
            index = end + 1
        elif text[index] == "$":
            end = index + 1
            while end < len(text) and (
                text[end].isalnum() or text[end] == "_"
            ):
                end += 1
            resolved = resolve_variable(text[index:end], variables)
            if resolved is None:
                return None
            kind, value = resolved
            if kind == "set":
                alternatives = [(codepoint,) for codepoint in sorted(value)]
            else:
                alternatives = [tuple(value)]
            index = end
        elif text[index] == "(":
            return None
        else:
            if text[index] == "\\":
                codepoint, consumed = read_escape(text, index)
                index += consumed
            else:
                codepoint = ord(text[index])
                index += 1
            alternatives = [(codepoint,)]
        minimum = 1
        maximum = 1
        if index < len(text) and text[index] in "*+?":
            quantifier = text[index]
            index += 1
            if quantifier == "*":
                minimum, maximum = 0, MAX_SOURCE_REPEAT
            elif quantifier == "+":
                minimum, maximum = 1, MAX_SOURCE_REPEAT
            else:
                minimum, maximum = 0, 1
        terms.append((alternatives, minimum, maximum))
    return terms if terms else None


def expand_source_terms(terms):
    results: list[tuple[int, ...]] = [()]
    for alternatives, minimum, maximum in terms:
        expanded: list[tuple[int, ...]] = []
        for base in results:
            for repetitions in range(minimum, maximum + 1):
                combinations: list[tuple[int, ...]] = [()]
                for _ in range(repetitions):
                    combinations = [
                        prefix + alternative
                        for prefix in combinations
                        for alternative in alternatives
                    ]
                    if len(combinations) > MAX_SOURCE_ALTERNATIVES:
                        return None
                for combination in combinations:
                    expanded.append(base + combination)
                    if len(expanded) > MAX_SOURCE_ALTERNATIVES:
                        return None
        results = expanded
    seen = set()
    unique: list[tuple[int, ...]] = []
    for source in results:
        if source in seen:
            continue
        seen.add(source)
        unique.append(source)
    return unique


def parse_target_with_capture(text: str, variables: dict[str, str], source):
    segments = text.split("$1")
    result: list[int] = []
    for index, segment in enumerate(segments):
        if index > 0:
            result.extend(source)
        codepoints, syntax = parse_side_with_variables(segment, variables)
        if syntax:
            return None
        result.extend(codepoints)
    return result


def table_entries_with_contexts(rules: str):
    variables = parse_variables(rules)
    entries = []
    priority = 0
    pass_index = 0
    for raw in rules.splitlines():
        line = strip_comment(raw)
        line = line.replace("\u200e", "").replace("\u200f", "")
        line = line.replace("\u061c", "")
        if not line:
            continue
        if line.startswith("::"):
            # CLDR's ::Null; directive closes the current pass: rules that
            # follow see the output of the rules before it.
            directive = line[2:].strip().rstrip(";").strip().lower()
            if directive == "null":
                pass_index += 1
            continue
        if VARIABLE_DEF.match(line):
            continue
        parts = split_rule(line)
        if parts is None:
            continue
        left, arrow, right = parts
        if arrow == "←":
            continue
        left = left.strip()
        right = right.strip()
        if right.endswith(";"):
            right = right[:-1].strip()
        open_pos = find_unquoted(left, "{")
        close_pos = find_unquoted(left, "}")
        if open_pos is not None:
            before_text = left[:open_pos]
            if close_pos is not None and close_pos > open_pos:
                source_text = left[open_pos + 1 : close_pos]
                after_text = left[close_pos + 1 :]
            else:
                source_text = left[open_pos + 1 :]
                after_text = ""
        elif close_pos is not None:
            source_text = left[:close_pos]
            after_text = left[close_pos + 1 :]
            before_text = ""
        else:
            source_text = left
            before_text = ""
            after_text = ""
        before = None
        if before_text.strip():
            before = parse_context(before_text, variables)
            if before is None:
                continue
        after = None
        if after_text.strip():
            after = parse_context(after_text, variables)
            if after is None:
                continue
        source_text = source_text.strip()
        if not source_text:
            if before is None and after is None:
                continue
            target, target_syntax = parse_side_with_variables(right, variables)
            if target_syntax:
                continue
            entries.append((pass_index, (), tuple(target), before, after, priority))
            priority += 1
            continue
        capture = False
        source_expression = source_text
        if "$1" in right:
            stripped = strip_whole_group(source_text)
            if stripped is None:
                continue
            source_expression = stripped
            capture = True
        terms = parse_source_terms(source_expression, variables)
        if terms is None:
            continue
        sources = expand_source_terms(terms)
        if sources is None:
            continue
        fixed_target = None
        if not capture:
            fixed_target, target_syntax = parse_side_with_variables(
                right,
                variables,
            )
            if target_syntax:
                continue
        for source in sources:
            if not source:
                continue
            if capture:
                target = parse_target_with_capture(right, variables, source)
                if target is None:
                    continue
            else:
                target = fixed_target
            entries.append(
                (pass_index, source, tuple(target), before, after, priority)
            )
        priority += 1
    entries.sort(
        key=lambda item: (
            item[0],
            0 if not item[1] else 1,
            item[1][0] if item[1] else 0,
            item[5],
        )
    )
    return [
        (source, target, before, after, pass_index)
        for pass_index, source, target, before, after, _ in entries
    ]


def find_unquoted(text: str, needle: str):
    quoted = False
    index = 0
    while index < len(text):
        character = text[index]
        if character == "'":
            if quoted and index + 1 < len(text) and text[index + 1] == "'":
                index += 2
                continue
            quoted = not quoted
        elif not quoted and character == needle:
            return index
        index += 1
    return None


def render_blob(
    specs: list[tuple[str, int, int]],
    tables: list[list[tuple]],
) -> bytes:
    names = bytearray()
    name_records: list[tuple[int, int]] = []
    for name, _, _ in specs:
        name_records.append((len(names), len(name)))
        names.extend(name.encode("utf-8"))

    set_map: dict[frozenset[int], int] = {frozenset(): 0}
    set_records: list[tuple[int, int]] = [(0, 0)]
    range_pool: list[tuple[int, int]] = []

    def add_set(codepoints) -> int:
        key = frozenset(codepoints)
        if key in set_map:
            return set_map[key]
        offset = len(range_pool)
        start: int | None = None
        previous = 0
        for codepoint in sorted(key):
            if start is None:
                start = codepoint
                previous = codepoint
                continue
            if codepoint == previous + 1:
                previous = codepoint
                continue
            range_pool.append((start, previous))
            start = codepoint
            previous = codepoint
        if start is not None:
            range_pool.append((start, previous))
        index = len(set_records)
        set_map[key] = index
        set_records.append((offset, len(range_pool) - offset))
        return index

    context_map: dict[tuple, int] = {(): 0}
    context_records: list[tuple[int, int]] = [(0, 0)]
    context_elements: list[tuple[int, int]] = []

    def add_context(elements) -> int:
        key = tuple(
            (
                add_set(
                    [codepoint for codepoint in codepoints if codepoint >= 0]
                ),
                (1 if negated else 0) |
                (2 if optional else 0) |
                (4 if boundary else 0) |
                (8 if repeat >= 1 else 0) |
                (16 if repeat >= 2 else 0) |
                (32 if (-1 in codepoints) or anchor else 0),
            )
            for (
                codepoints,
                negated,
                boundary,
                optional,
                repeat,
                anchor,
            ) in elements
        )
        if key in context_map:
            return context_map[key]
        offset = len(context_elements)
        context_elements.extend(key)
        index = len(context_records)
        context_map[key] = index
        context_records.append((offset, len(key)))
        return index

    sources = bytearray()
    targets = bytearray()
    entries: list[tuple[int, int, int, int, int, int, int]] = []
    transform_records: list[tuple[int, int, int, int]] = []
    entry_start = 0
    for (name, pre_normalization, post_normalization), table in zip(
        specs, tables
    ):
        pass_count = 1
        for entry in table:
            source = entry[0]
            target = entry[1]
            before = entry[2] if len(entry) > 2 else None
            after = entry[3] if len(entry) > 3 else None
            entry_pass = entry[4] if len(entry) > 4 else 0
            pass_count = max(pass_count, entry_pass + 1)
            source_offset = len(sources) // 4
            for codepoint in source:
                sources.extend(struct.pack("<I", codepoint))
            target_offset = len(targets) // 4
            for codepoint in target:
                targets.extend(struct.pack("<I", codepoint))
            before_context = 0
            after_context = 0
            if before is not None:
                before_context = add_context(before)
            if after is not None:
                after_context = add_context(after)
            entries.append(
                (
                    source_offset,
                    len(source),
                    target_offset,
                    len(target),
                    before_context,
                    after_context,
                    entry_pass,
                    1 if not source else 0,
                )
            )
        transform_records.append(
            (
                entry_start,
                len(table),
                pre_normalization,
                pass_count,
                post_normalization,
            )
        )
        entry_start += len(table)

    header = bytearray(b"CJTR")
    header += struct.pack(
        "<B3BBB7IH",
        7,
        CLDR_VERSION,
        0,
        0,
        len(TRANSFORMS),
        0,
        len(entries),
        len(sources) // 4,
        len(targets) // 4,
        len(set_records),
        len(range_pool),
        len(context_records),
        len(context_elements),
        0,
    )
    transform_bytes = bytearray()
    for index, (
        start,
        count,
        pre_normalization,
        pass_count,
        post_normalization,
    ) in enumerate(transform_records):
        name_offset, name_length = name_records[index]
        transform_bytes += struct.pack(
            "<HBBIIBB",
            name_offset,
            name_length,
            pass_count,
            start,
            count,
            pre_normalization,
            post_normalization,
        )
    entry_bytes = bytearray()
    for entry in entries:
        entry_bytes += struct.pack("<IBIBIIBB", *entry)
    set_bytes = bytearray()
    for offset, count in set_records:
        set_bytes += struct.pack("<II", offset, count)
    range_bytes = bytearray()
    for start, end in range_pool:
        range_bytes += struct.pack("<II", start, end)
    context_bytes = bytearray()
    for offset, count in context_records:
        context_bytes += struct.pack("<II", offset, count)
    context_element_bytes = bytearray()
    for set_index, flags in context_elements:
        context_element_bytes += struct.pack("<II", set_index, flags)
    return bytes(
        header
        + transform_bytes
        + entry_bytes
        + set_bytes
        + range_bytes
        + context_bytes
        + context_element_bytes
        + names
        + sources
        + targets
    )


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    archive_path = Path(sys.argv[1])
    out_dir = Path(sys.argv[2])
    out_dir.mkdir(parents=True, exist_ok=True)

    archive = checked_zip(archive_path)
    rule_cache: dict[str, str] = {}

    def rules_for(source: str) -> str:
        if source not in rule_cache:
            rule_cache[source] = extract_rule(
                archive.read(f"common/transforms/{source}.xml").decode("utf-8")
            )
        return rule_cache[source]

    georgian_rules = rules_for("Georgian-Latin")
    width_forward, width_reverse = fullwidth_entries(
        rules_for("Fullwidth-Halfwidth")
    )
    specs: list[tuple[str, int]] = []
    tables: list[list[tuple]] = []
    for name, source, builder in TRANSFORMS:
        rules = rules_for(source)
        if builder == "latin":
            table = latin_ascii_entries(rules)
        elif builder == "fullwidth":
            table = width_forward
        elif builder == "halfwidth":
            table = width_reverse
        elif builder == "simple":
            table = simple_table_entries(rules)
        elif builder == "reverse_georgian":
            table = reverse_table(simple_table_entries(georgian_rules))
        elif builder == "variables":
            table = table_entries_with_variables(rules)
        elif builder == "context":
            table = table_entries_with_contexts(rules)
        elif builder == "katakana":
            table = table_entries_with_contexts(rules)
        else:
            raise SystemExit(f"unknown transform builder {builder!r}")
        pre_normalization = (
            5 if builder == "katakana" else detect_pre_normalization(rules)
        )
        post_normalization = 0 if builder == "katakana" else (
            detect_post_normalization(rules)
        )
        specs.append((name, pre_normalization, post_normalization))
        tables.append(table)

    (out_dir / "data.bin").write_bytes(render_blob(specs, tables))
    for _, fixture_path, magic, excluded, filename in CONFORMANCE:
        (out_dir / filename).write_bytes(
            render_conformance(archive, fixture_path, magic, excluded)
        )
    counts = ", ".join(
        f"{name}={len(table)}" for (name, _, _), table in zip(specs, tables)
    )
    print(counts, file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
