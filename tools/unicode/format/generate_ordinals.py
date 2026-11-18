#!/usr/bin/env python3
"""Generate CLDR 48 ordinal plural rules and conformance samples.

Usage:
    generate_ordinals.py ordinals.xml out_dir
"""

from __future__ import annotations

import hashlib
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

from generate_plurals import (
    CATEGORY_INDEX,
    build_cases,
    render_conformance,
    render_rules,
    split_rule,
)

INPUT_SHA256 = "129bf4aa6f41d47931bf908ebaa261ec0b73b768f1fe3be90c06ab11fb49880a"


def checked_text(path: Path) -> str:
    data = path.read_bytes()
    actual = hashlib.sha256(data).hexdigest()
    if actual != INPUT_SHA256:
        raise SystemExit(
            f"{path}: expected CLDR 48 SHA-256 {INPUT_SHA256}, "
            f"found {actual}"
        )
    return data.decode("utf-8")


def parse_ordinals(
    text: str,
) -> tuple[dict[str, dict[str, str]], dict[str, dict[str, tuple[str, str]]]]:
    root = ET.fromstring(text)
    plurals = root.find("plurals")
    if plurals is None or plurals.get("type") != "ordinal":
        raise SystemExit("ordinals.xml: missing <plurals type=\"ordinal\">")

    rules: dict[str, dict[str, str]] = {}
    annotations: dict[str, dict[str, tuple[str, str]]] = {}
    for group in plurals.findall("pluralRules"):
        entries: list[tuple[str, str, str]] = []
        for element in group.findall("pluralRule"):
            category = element.get("count", "")
            if category not in CATEGORY_INDEX:
                raise SystemExit(f"ordinals.xml: unknown category {category!r}")
            rule, annotation = split_rule((element.text or "").strip())
            entries.append((category, rule, annotation))
        for locale in group.get("locales", "").split():
            rules[locale] = {}
            annotations[locale] = {}
            for category, rule, annotation in entries:
                rules[locale][category] = rule
                annotations[locale][category] = (rule, annotation)
    if not rules:
        raise SystemExit("ordinals.xml: no pluralRules entries")
    return rules, annotations


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    input_path = Path(sys.argv[1])
    out_dir = Path(sys.argv[2])
    out_dir.mkdir(parents=True, exist_ok=True)

    rules, annotations = parse_ordinals(checked_text(input_path))

    (out_dir / "ordinals_data.zig").write_text(
        render_rules(
            rules,
            generator="tools/unicode/format/generate_ordinals.py",
            source_name="ordinals.xml",
            source_sha=INPUT_SHA256,
        ),
        encoding="utf-8",
    )
    (out_dir / "ordinals_conformance.bin").write_bytes(
        render_conformance(build_cases(rules, annotations))
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
