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
    ("Persian-Latin-BGN", "Persian-Latin-BGN", "context"),
    ("nv-nv_FONIPA", "nv-nv_FONIPA", "context"),
    ("si-si_FONIPA", "si-si_FONIPA", "context"),
    ("es-es_FONIPA", "es-es_FONIPA", "context"),
    ("xh-xh_FONIPA", "xh-xh_FONIPA", "context"),
    ("vec-vec_FONIPA", "vec-vec_FONIPA", "context"),
    ("ro-ro_FONIPA", "ro-ro_FONIPA", "context"),
    ("Arabic-Latin-BGN", "Arabic-Latin-BGN", "context"),
    ("Armenian-Latin-BGN", "Armenian-Latin-BGN", "context"),
    ("Thaana-Latin", "Thaana-Latin", "reverse_simple"),
    ("Syriac-Latin", "Syriac-Latin", "context"),
    ("CanadianAboriginal-Latin", "CanadianAboriginal-Latin", "reverse_simple"),
    ("tr-Lower", "tr-Lower", "context"),
    ("az-Lower", "az-Lower", "context"),
    ("el-Lower", "el-Lower", "context"),
    ("el-Upper", "el-Upper", "context"),
    ("lt-Lower", "lt-Lower", "context"),
    ("lt-Upper", "lt-Upper", "context"),
    ("Korean-Latin-BGN", "Korean-Latin-BGN", "context"),
    ("Kirghiz-Latin-BGN", "Kirghiz-Latin-BGN", "context"),
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


def detect_final_case(rules: str) -> int:
    """Detect a trailing ::Any-Lower; (1) or ::Any-Upper; (2) directive."""
    final_case = 0
    for raw in rules.splitlines():
        line = strip_comment(raw).strip()
        if not line:
            continue
        if line.startswith("::"):
            directive = line[2:].strip().rstrip(";").strip()
            normalized = directive.upper().replace("()", "").strip()
            if normalized in ("ANY-LOWER", "ANY-UPPER"):
                final_case = 1 if normalized == "ANY-LOWER" else 2
                continue
            if normalized.startswith(("NFKD", "NFKC", "NFD", "NFC")):
                continue
            if normalized == "NULL" or directive.startswith("["):
                continue
            return 0
        if VARIABLE_DEF.match(line):
            continue
        if final_case != 0:
            return 0
    return final_case


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


def variable_definition_complete(text: str) -> bool:
    """True when every `[` in a variable definition has its `]`."""
    depth = 0
    quoted = False
    index = 0
    while index < len(text):
        character = text[index]
        if character == "\\":
            index += 2
            continue
        if character == "'":
            quoted = not quoted
        elif not quoted:
            if character == "[":
                depth += 1
            elif character == "]":
                depth = max(depth - 1, 0)
        index += 1
    return depth == 0


def parse_variables(rules: str) -> dict[str, str]:
    variables: dict[str, str] = {}
    lines = rules.splitlines()
    index = 0
    while index < len(lines):
        line = strip_comment(lines[index])
        line = line.replace("\u200e", "").replace("\u200f", "")
        line = line.replace("\u061c", "")
        if not line.startswith("$") or "=" not in line:
            index += 1
            continue
        # Variable definitions may span lines, for example a large
        # multi-line character class.
        statement = line
        while not variable_definition_complete(statement) and index + 1 < len(lines):
            index += 1
            continuation = strip_comment(lines[index])
            continuation = continuation.replace("\u200e", "").replace("\u200f", "")
            continuation = continuation.replace("\u061c", "")
            statement += " " + continuation
        for piece in statement.split(";"):
            piece = piece.strip()
            if not piece.startswith("$") or "=" not in piece:
                continue
            name, value = piece.split("=", 1)
            name = name.strip()
            value = value.strip()
            if not name:
                continue
            # Empty values are meaningful (for example the sixth Ethiopic
            # vowel order has no suffix).
            variables[name] = value
        index += 1
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
    quoted = False
    while index < len(content):
        character = content[index]
        if character == "'":
            if quoted and index + 1 < len(content) and content[index + 1] == "'":
                codepoints.append(0x27)
                index += 2
                continue
            quoted = not quoted
            index += 1
            continue
        if character == "\\":
            codepoint, consumed = read_escape(content, index)
            codepoints.append(codepoint)
            index += consumed
            continue
        # ICU rule syntax ignores unquoted whitespace inside sets.
        if not quoted and character.isspace():
            index += 1
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
COMPLEMENT_CACHE: dict[int, frozenset[int]] = {}
ALL_CODEPOINTS = frozenset(range(0x110000))
CCC_ALIASES = {
    "not_reordered": 0,
    "overlay": 1,
    "nukta": 7,
    "kana_voicing": 8,
    "virama": 9,
    "attached_below": 202,
    "attached_above": 214,
    "attached_above_right": 216,
    "below_left": 218,
    "below": 220,
    "below_right": 222,
    "left": 224,
    "right": 226,
    "above_left": 228,
    "above": 230,
    "above_right": 232,
    "double_below": 233,
    "double_above": 234,
    "iota_subscript": 240,
}


def complement_set(value: frozenset[int]) -> frozenset[int]:
    key = id(value)
    cached = COMPLEMENT_CACHE.get(key)
    if cached is None:
        cached = ALL_CODEPOINTS - value
        COMPLEMENT_CACHE[key] = cached
    return cached


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
    elif key in ("l", "m", "n", "p", "s", "z", "c"):
        prefix = key.upper()
        for codepoint in range(0x110000):
            if unicodedata.category(chr(codepoint)).startswith(prefix):
                result.append(codepoint)
    elif key.startswith("ccc="):
        ccc_name = key[4:].strip().replace("-", "_").replace(" ", "_")
        ccc_value = CCC_ALIASES.get(ccc_name)
        if ccc_value is None:
            return None
        for codepoint in range(0x110000):
            if unicodedata.combining(chr(codepoint)) == ccc_value:
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
    stripped = content.strip()
    if stripped.startswith(":") and stripped.endswith(":"):
        name = stripped[1:-1].strip()
        property_negated = name.startswith("^")
        if property_negated:
            name = name[1:].strip()
        value = property_codepoints(name)
        if value is None:
            return None
        return (value, negated != property_negated)
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
            # Materialize the complement so a negated variable can participate
            # in class unions; -1 keeps ICU's boundary-matching behavior.
            return (complement_set(value) | frozenset((-1,)), end)
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


def split_class_strings(content: str):
    """Split `{...}` string elements out of a UnicodeSet body.

    Returns (remaining body, string tuples) or None when the body is
    malformed. Strings keep longest-first priority.
    """
    strings: list[tuple[int, ...]] = []
    remainder: list[str] = []
    index = 0
    while index < len(content):
        character = content[index]
        if character == "\\":
            remainder.append(content[index : index + 2])
            index += 2
            continue
        if character == "'":
            remainder.append(character)
            index += 1
            while index < len(content):
                remainder.append(content[index])
                if content[index] == "'":
                    index += 1
                    break
                index += 1
            continue
        if character == "{":
            end = content.find("}", index + 1)
            if end < 0:
                return None
            inner = content[index + 1 : end]
            codepoints, syntax = parse_side(inner)
            if syntax:
                return None
            if len(codepoints) >= 2:
                strings.append(tuple(codepoints))
            elif len(codepoints) == 1:
                remainder.append(f"\\u{codepoints[0]:04X}")
            index = end + 1
            continue
        remainder.append(character)
        index += 1
    strings.sort(key=lambda value: (-len(value), value))
    return "".join(remainder), strings


def resolve_context_set(name: str, variables: dict[str, str]):
    """Resolve a context token to (set, negated, string alternatives)."""
    raw = variables.get(name)
    if raw is None:
        return None
    if raw.startswith("[") and raw.endswith("]"):
        split = split_class_strings(raw[1:-1])
        if split is None:
            return None
        content, strings = split
        parsed = parse_class_set("[" + content + "]", variables)
        if parsed is None:
            return None
        base, negated = parsed
        return (base, negated, strings)
    codepoints, syntax = parse_side_with_variables(raw, variables)
    if syntax:
        return None
    return (frozenset(codepoints), False, [])


def parse_context(text: str, variables: dict[str, str]):
    text = text.strip()
    if not text:
        return None
    tokens = split_context_tokens(text)
    if tokens is None:
        return None
    alternatives: list[list[tuple]] = [[]]
    for token in tokens:
        optional = token.endswith("?")
        if optional:
            token = token[:-1]
        parsed = parse_context_token(token, variables)
        if parsed is None:
            return None
        combined: list[list[tuple]] = []
        for prefix in alternatives:
            for elements in parsed:
                combined.append(
                    prefix +
                        [
                            (
                                base,
                                negated,
                                boundary,
                                optional or element_optional,
                                repeat,
                                anchor,
                            )
                            for (
                                base,
                                negated,
                                boundary,
                                repeat,
                                anchor,
                                element_optional,
                            ) in elements
                        ]
                )
        alternatives = combined
        if len(alternatives) > 64:
            return None
    return alternatives if alternatives else None


def set_element_alternatives(base, negated, strings):
    if not strings:
        return [[(base, negated, False, 0, False, False)]]
    if negated:
        return None
    alternatives = []
    for sequence in strings:
        alternatives.append(
            [
                (frozenset((codepoint,)), False, False, 0, False, False)
                for codepoint in sequence
            ]
        )
    if base:
        alternatives.append([(base, False, False, 0, False, False)])
    return alternatives


def parse_context_token(token: str, variables: dict[str, str]):
    token = token.strip()
    if not token:
        return None
    if token == "$":
        return [[(frozenset(), False, True, 0, True, False)]]
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
        return [[(base, True, True, 0, False, False)]]
    alternatives: list[list[tuple]] = [[]]
    index = 0
    while index < len(token):
        character = token[index]
        piece = None
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
            split = split_class_strings(token[index + 1 : end])
            if split is None:
                return None
            content, strings = split
            parsed = parse_class_set("[" + content + "]", variables)
            if parsed is None:
                return None
            base, negated = parsed
            piece = set_element_alternatives(base, negated, strings)
            if piece is None:
                return None
            index = end + 1
        elif character == "(":
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
            piece = [[
                (
                    base,
                    negated,
                    False,
                    1 if quantifier == "*" else 2,
                    False,
                    False,
                )
            ]]
            index = end + 2
        elif character == "$":
            end = index + 1
            while end < len(token) and (
                token[end].isalnum() or token[end] == "_"
            ):
                end += 1
            resolved = resolve_context_set(token[index:end], variables)
            if resolved is None:
                return None
            base, negated, strings = resolved
            piece = set_element_alternatives(base, negated, strings)
            if piece is None:
                return None
            index = end
        elif character in "*+{}|":
            return None
        else:
            if character == "\\":
                codepoint, consumed = read_escape(token, index)
                index += consumed
            else:
                codepoint = ord(character)
                index += 1
            piece = [[(frozenset((codepoint,)), False, False, 0, False, False)]]
        # A `?` directly after a literal or class makes that element optional.
        if index < len(token) and token[index] == "?":
            piece = [
                [
                    (base, negated, boundary, repeat, anchor, True)
                    for (base, negated, boundary, repeat, anchor, _) in elements
                ]
                for elements in piece
            ]
            index += 1
        combined: list[list[tuple]] = []
        for prefix in alternatives:
            for elements in piece:
                combined.append(prefix + elements)
        alternatives = combined
        if len(alternatives) > 64:
            return None
    return alternatives if alternatives else None


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


def expand_embedded_group(source_text: str, variables: dict[str, str]):
    """Expand a single mid-source class capture such as `X ([abc]) Y`.

    Returns (prefix alternatives, class codepoints, suffix alternatives) or
    None. The target's `$1` is replaced with the captured codepoint.
    """
    open_pos = find_unquoted(source_text, "(")
    if open_pos is None:
        return None
    close_pos = find_unquoted(source_text, ")")
    if close_pos is None or close_pos <= open_pos:
        return None
    if find_unquoted(source_text[close_pos + 1 :], "(") is not None:
        return None
    inner = source_text[open_pos + 1 : close_pos].strip()
    if inner.startswith("$"):
        group = resolve_source_variable(inner, variables)
    elif inner.startswith("[") and inner.endswith("]"):
        group = class_alternatives(inner[1:-1], variables)
    else:
        codepoints, syntax = parse_side_with_variables(inner, variables)
        if syntax:
            return None
        group = [tuple(codepoints)]
    if group is None:
        return None
    prefix_text = source_text[:open_pos].strip()
    suffix_text = source_text[close_pos + 1 :].strip()
    prefix_terms = parse_source_terms(prefix_text, variables) if prefix_text else []
    suffix_terms = parse_source_terms(suffix_text, variables) if suffix_text else []
    if prefix_terms is None or suffix_terms is None:
        return None
    prefixes = expand_source_terms(prefix_terms)
    suffixes = expand_source_terms(suffix_terms)
    if prefixes is None or suffixes is None:
        return None
    return prefixes, group, suffixes


def class_alternatives(content: str, variables: dict[str, str]):
    """Expand a class body into source alternatives, including strings."""
    split = split_class_strings(content)
    if split is None:
        return None
    body, strings = split
    parsed = parse_class_set("[" + body + "]", variables)
    if parsed is None:
        return None
    values, negated = parsed
    if negated:
        return None
    alternatives = [tuple(sequence) for sequence in strings]
    alternatives += [(codepoint,) for codepoint in sorted(values) if codepoint >= 0]
    return alternatives if alternatives else None


def resolve_source_variable(name: str, variables: dict[str, str]):
    raw = variables.get(name)
    if raw is None:
        return None
    if raw.startswith("[") and raw.endswith("]"):
        return class_alternatives(raw[1:-1], variables)
    codepoints, syntax = parse_side_with_variables(raw, variables)
    if syntax:
        return None
    return [tuple(codepoints)]


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
            alternatives = class_alternatives(
                text[index + 1 : end],
                variables,
            )
            if alternatives is None:
                return None
            index = end + 1
        elif text[index] == "$":
            end = index + 1
            while end < len(text) and (
                text[end].isalnum() or text[end] == "_"
            ):
                end += 1
            alternatives = resolve_source_variable(text[index:end], variables)
            if alternatives is None:
                return None
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
        # ICU's output cursor `|` controls where scanning resumes after a
        # replacement. A leading `|` means the replacement itself is rescanned.
        reprocess = False
        bar = find_unquoted(right, "|")
        if bar is not None:
            if right[:bar].strip():
                continue
            reprocess = True
            right = right[bar + 1 :].strip()
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
        before_alts = [None]
        if before_text.strip():
            before_alts = parse_context(before_text, variables)
            if before_alts is None:
                continue
        after_alts = [None]
        if after_text.strip():
            after_alts = parse_context(after_text, variables)
            if after_alts is None:
                continue
        source_text = source_text.strip()
        if not source_text:
            if before_alts == [None] and after_alts == [None]:
                continue
            if reprocess:
                continue
            target, target_syntax = parse_side_with_variables(right, variables)
            if target_syntax:
                continue
            for before in before_alts:
                for after in after_alts:
                    entries.append(
                        (
                            pass_index,
                            (),
                            tuple(target),
                            before,
                            after,
                            priority,
                            False,
                        )
                    )
            priority += 1
            continue
        capture = False
        embedded = None
        source_expression = source_text
        if "$1" in right:
            stripped = strip_whole_group(source_text)
            if stripped is not None:
                source_expression = stripped
                capture = True
            else:
                embedded = expand_embedded_group(source_text, variables)
                if embedded is None:
                    continue
        if embedded is not None:
            prefixes, group_values, suffixes = embedded
            for prefix in prefixes:
                for value in group_values:
                    for suffix in suffixes:
                        source = prefix + value + suffix
                        if not source:
                            continue
                        target = parse_target_with_capture(
                            right,
                            variables,
                            value,
                        )
                        if target is None:
                            continue
                        for before in before_alts:
                            for after in after_alts:
                                entries.append(
                                    (
                                        pass_index,
                                        source,
                                        tuple(target),
                                        before,
                                        after,
                                        priority,
                                        reprocess,
                                    )
                                )
            priority += 1
            continue
        terms = parse_source_terms(source_expression, variables)
        if terms is None:
            continue
        repeat_set = None
        repeat_minimum = 0
        if (
            len(terms) == 1
            and terms[0][2] > 1
            and all(len(alternative) == 1 for alternative in terms[0][0])
        ):
            # A repeated single-codepoint class compiles to one repeat entry
            # instead of enumerating every run length.
            repeat_set = frozenset(
                alternative[0] for alternative in terms[0][0]
            )
            repeat_minimum = terms[0][1]
        sources = expand_source_terms(terms) if repeat_set is None else [()]
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
            if not source and repeat_set is None:
                continue
            if capture:
                target = parse_target_with_capture(right, variables, source)
                if target is None:
                    continue
            else:
                target = fixed_target
            repeat = (
                (repeat_set, repeat_minimum)
                if repeat_set is not None
                else None
            )
            for before in before_alts:
                for after in after_alts:
                    entries.append(
                        (
                            pass_index,
                            source,
                            tuple(target),
                            before,
                            after,
                            priority,
                            reprocess,
                            repeat,
                        )
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
    result = []
    for entry in entries:
        pass_index, source, target, before, after, _, reprocess = entry[:7]
        repeat = entry[7] if len(entry) > 7 else None
        result.append(
            (source, target, before, after, pass_index, reprocess, repeat)
        )
    return result


def find_unquoted(text: str, needle: str):
    quoted = False
    depth = 0
    index = 0
    while index < len(text):
        character = text[index]
        if character == "'":
            if quoted and index + 1 < len(text) and text[index + 1] == "'":
                index += 2
                continue
            quoted = not quoted
        elif not quoted:
            # Braces inside a character class are string elements, not the
            # source-context delimiters.
            if character == "[":
                depth += 1
            elif character == "]":
                depth = max(depth - 1, 0)
            elif depth == 0 and character == needle:
                return index
        index += 1
    return None


def parse_filter(rules: str, variables: dict[str, str]):
    """Return the transform's first ICU `:: [set] ;` input filter."""
    for raw in rules.splitlines():
        line = strip_comment(raw).strip()
        if not line.startswith("::"):
            continue
        directive = line[2:].strip().rstrip(";").strip()
        upper = directive.upper()
        if upper.startswith(("NFKD", "NFKC", "NFD", "NFC", "NULL")):
            continue
        if directive.startswith("[") and directive.endswith("]"):
            split = split_class_strings(directive[1:-1])
            if split is None:
                return None
            content, _ = split
            parsed = parse_class_set("[" + content + "]", variables)
            if parsed is None:
                return None
            value, negated = parsed
            if negated:
                return None
            return frozenset(codepoint for codepoint in value if codepoint >= 0)
        return None
    return None


def render_blob(
    specs: list[tuple[str, int, int]],
    tables: list[list[tuple]],
    filters: list[frozenset[int] | None],
) -> bytes:
    names = bytearray()
    name_records: list[tuple[int, int]] = []
    for name, _, _, _ in specs:
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
    for (name, pre_normalization, post_normalization, final_case), table in zip(
        specs, tables
    ):
        pass_count = 1
        for entry in table:
            source = entry[0]
            target = entry[1]
            before = entry[2] if len(entry) > 2 else None
            after = entry[3] if len(entry) > 3 else None
            entry_pass = entry[4] if len(entry) > 4 else 0
            reprocess = entry[5] if len(entry) > 5 else False
            repeat = entry[6] if len(entry) > 6 else None
            pass_count = max(pass_count, entry_pass + 1)
            if repeat is not None:
                repeat_set, repeat_minimum = repeat
                source_offset = add_set(sorted(repeat_set))
                source_len = repeat_minimum
            else:
                source_offset = len(sources) // 4
                for codepoint in source:
                    sources.extend(struct.pack("<I", codepoint))
                source_len = len(source)
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
                    source_len,
                    target_offset,
                    len(target),
                    before_context,
                    after_context,
                    entry_pass,
                    (1 if not source and repeat is None else 0) |
                    (2 if reprocess else 0) |
                    (4 if repeat is not None else 0),
                )
            )
        transform_records.append(
            (
                entry_start,
                len(table),
                pre_normalization,
                pass_count,
                post_normalization,
                final_case,
                add_set(sorted(filters[len(transform_records)]))
                if filters[len(transform_records)] is not None
                else 0,
            )
        )
        entry_start += len(table)

    header = bytearray(b"CJTR")
    header += struct.pack(
        "<B3BBB7IH",
        9,
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
        final_case,
        filter_set,
    ) in enumerate(transform_records):
        name_offset, name_length = name_records[index]
        transform_bytes += struct.pack(
            "<HBBIIBBIBB",
            name_offset,
            name_length,
            pass_count,
            start,
            count,
            pre_normalization,
            post_normalization,
            filter_set,
            final_case,
            0,
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
    specs: list[tuple[str, int, int, int]] = []
    tables: list[list[tuple]] = []
    filters: list[frozenset[int] | None] = []
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
        elif builder == "reverse_simple":
            table = reverse_table(simple_table_entries(rules))
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
        final_case = 0 if builder == "katakana" else detect_final_case(rules)
        specs.append((name, pre_normalization, post_normalization, final_case))
        tables.append(table)
        filters.append(parse_filter(rules, parse_variables(rules)))

    (out_dir / "data.bin").write_bytes(render_blob(specs, tables, filters))
    for _, fixture_path, magic, excluded, filename in CONFORMANCE:
        (out_dir / filename).write_bytes(
            render_conformance(archive, fixture_path, magic, excluded)
        )
    counts = ", ".join(
        f"{name}={len(table)}"
        for (name, _, _, _), table in zip(specs, tables)
    )
    print(counts, file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
