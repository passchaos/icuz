#!/usr/bin/env python3
"""Verify committed Unicode generators and generated artifacts.

This check needs no external UCD checkout. It validates binary headers and
layout, pins artifact/generator SHA-256 values, and checks provenance embedded
in the committed generated Zig table. Generator reruns that need upstream UCD
files remain optional build dependencies of `unicode-verify`.
"""

from __future__ import annotations

import hashlib
import re
import struct
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
UNICODE_VERSION = (17, 0, 0)


@dataclass(frozen=True)
class Blob:
    path: str
    magic: bytes
    format_version: int
    sha256: str


@dataclass(frozen=True)
class GeneratedText:
    path: str
    generator: str
    sha256: str


BLOBS = (
    Blob("src/unicode/bidi/conformance.bin", b"CJBT", 1, "40d4b9145779f8aad815e1f5ea5201ccd9cc5daeb73c8bf73b06c6f1c76d9a26"),
    Blob("src/unicode/bidi/data.bin", b"CJB1", 1, "9e9f9937100d6019f7308743916c3606bdb31c9cc4f142eb605becf45a210c3f"),
    Blob("src/unicode/grapheme/conformance.bin", b"CJGT", 1, "07053949345b67792108362e7b5146ae2d5467fef9de7fa5e7aa1dd3ddffbd56"),
    Blob("src/unicode/grapheme/data.bin", b"CJGB", 2, "01f5e5d9197e4b9e779eb3f4540c5f8e4a3ddc9378b9223e81ab8e37cf6f7f5b"),
    Blob("src/unicode/line_break/conformance.bin", b"CJLT", 2, "28e470fb325428ef1cb18b027b8889add6a18f7bf8046e34a986626b687a8ab9"),
    Blob("src/unicode/line_break/data.bin", b"CJL2", 2, "0fef55798282a97581de58698c3617ee0990a52ff40342230fd083f6f881fa92"),
    Blob("src/unicode/normalization/conformance.bin", b"CJNF", 1, "ed9089885715ea3e92f550d0f462e7fa53a681870b95402dc1cae85fd7d17f45"),
    Blob("src/unicode/script/data.bin", b"CJS1", 1, "568090d12531a38659e1e936779464ed05eb3610b443429928fc97eaf119dbdf"),
    Blob("src/unicode/script_extensions/data.bin", b"CJSE", 1, "43135c269af32f24e43b55c94c33205ec715e5f43dddb1ac5b218929e754016b"),
    Blob("src/unicode/sentence/conformance.bin", b"CJST", 1, "ad12cc4dc33a16ffe0da235ac34cb8f0ddfc3c9e85a62c657ee88bb3beeba5cc"),
    Blob("src/unicode/sentence/data.bin", b"CJSB", 1, "c163eb450ba6df51a31fe2ac4a74e3c1d9d154c37ec9124af46dffce6a5844e8"),
    Blob("src/unicode/word/conformance.bin", b"CJWT", 1, "e390fd977570cd63aef4a1c657d4afefa188bfff5e8cc39e60942444feb5b674"),
    Blob("src/unicode/word/data.bin", b"CJWB", 2, "0ed721c08b09aae17c350d1125189b08c912c9fed4610da8704d45a2df4a7000"),
)

GENERATORS = {
    "tools/generate_canonical_combining_class.py": "14e87c3a20a45bfa3dedfd6fb8b50764e4b08e110f0a43f2094d9433330f875e",
    "tools/generate_canonical_decomposition.py": "fd4e57c7fd6e96af04082f591a193371bd97e1e8856152072d3e434ea8c0813d",
    "tools/generate_nonspacing_marks.py": "12d45f34ce2891ccf1b342bc8f44c6fe32e15e019d7a41489d8036dee9f8555c",
    "tools/unicode/normalization/generate_conformance.py": "c3e9f80b8fb410a2d142cfbb228941d01322672b28261c1e0c0de53eb662ee43",
    "tools/unicode/normalization/generate_data.py": "f1358dc6dfc2570947a9e0f2039d4e9e79d7e0fa08ca96c6f805d2cffb58de4f",
    "tools/unicode/case/generate_data.py": "c4b275209f5fa8695b35c22ddd5cb95d2e08f40f35868b901dc22b39726a4dc9",
    "tools/unicode/properties/generate_data.py": "524f61959745f475e0c2f5b61790df95a758ac529d93a5ce26be826375c9b367",
    "tools/unicode/bidi/generate_conformance.py": "1ca3d3fd9fe5962f37192eb77d9aadfab6e5f9c670540a7ae691213682bb0425",
    "tools/unicode/bidi/generate_data.py": "ab6f9359af0f5d198b52d174041e35ffde11b0f8277a4bf5a8981a76c0a1cb05",
    "tools/unicode/grapheme/generate_conformance.py": "93378e8fcf4b0bd91630716a5378902cb3a1a41253b2d4fc4cd4688a036a3018",
    "tools/unicode/grapheme/generate_data.py": "b81dbba706482fa1c2ee562b42ff0a0a02e7dbc92095a8f79be2c01c1e9082c5",
    "tools/unicode/line_break/generate_conformance.py": "44b205d1b640cdb52e4316d649c584c97c2c94644437291fa568fbec1a2cd630",
    "tools/unicode/line_break/generate_data.py": "fa3d55066a98356ffcbf7abc50955a94e0c0f9eeec15758357bd14b8fcf55ac1",
    "tools/unicode/script/generate_data.py": "ce4168570f34cfa6d77b5f33bcf99a3cbc1f745639cda9878cfcc43407e2b6ab",
    "tools/unicode/script_extensions/generate_data.py": "20c00dac98c808300f286634a4d89f5eccd0d45db26aebf15d2d07b3089f17cb",
    "tools/unicode/sentence/generate_conformance.py": "038720b9002dbd73cdfb069dad112e86d64499c4c277c1250c77f9a0b9843dce",
    "tools/unicode/sentence/generate_data.py": "8e681662596e60b808ea36468c54f076c84112dcb8bee6c4c00bf3fe69c17a6e",
    "tools/unicode/vertical/generate_data.py": "be44ad521348fd3614f02f7ad3f58af1fdd3e72f9e27eeb6442bf4fb78a3df5b",
    "tools/unicode/word/generate_conformance.py": "5f86dd6601da9a8a9ca7418c84176eda90f76ea78970986cbc46272ca790c92b",
    "tools/unicode/word/generate_data.py": "a9ca3a51bdd7900c56393f22f6cc9d0730256eb6c43d648908f7b5da03013482",
}

GENERATED_TEXT = (
    GeneratedText(
        "src/unicode/canonical/combining_class.zig",
        "tools/generate_canonical_combining_class.py",
        "c63a40ad8145f3c9c425fa75ff3fb60c086209f86315c9424055728b5cab619b",
    ),
    GeneratedText(
        "src/unicode/canonical/decomposition.zig",
        "tools/generate_canonical_decomposition.py",
        "5489909ff9ef7eaf0ef16a605f336abf1808f5b9338ef1eb6a0c44cda1b83f84",
    ),
    GeneratedText(
        "src/unicode/mark/nonspacing.zig",
        "tools/generate_nonspacing_marks.py",
        "5c347a415ea883455e41e76121b95cd711da5af731144d8257d2bd3ddc9ff013",
    ),
    GeneratedText(
        "src/unicode/normalization/data.zig",
        "tools/unicode/normalization/generate_data.py",
        "dde23924313575481f772e8b00c867bda26efe4c6f1b85e6c7245548b263a7d7",
    ),
    GeneratedText(
        "src/unicode/case/data.zig",
        "tools/unicode/case/generate_data.py",
        "00e78d46e6526c56d39fb374de74a552d4968808273c635a56cffbd134e07ae8",
    ),
    GeneratedText(
        "src/unicode/properties/general_category.zig",
        "tools/unicode/properties/generate_data.py",
        "5db7582fb48cb140df315cda3fe4e3fe160322d7eee025522b07f6405247d366",
    ),
    GeneratedText(
        "src/unicode/properties/aliases.zig",
        "tools/unicode/properties/generate_data.py",
        "106ea30d241ca37a64f6984dc1deb6b5082ffaae4b8ae2d2ca1c61b5153b0dec",
    ),
    GeneratedText(
        "src/unicode/vertical/data.zig",
        "tools/unicode/vertical/generate_data.py",
        "c38118ef695568864af362387684b6333336a082aec5ca4f6814faac7f35ee8d",
    ),
)
SOURCE_SHA = re.compile(r"^// Source SHA-256: ([0-9a-f]{64})$", re.MULTILINE)


def digest(path: Path, *, text: bool = False) -> str:
    data = path.read_bytes()
    if text:
        # Git may materialize text files with CRLF on Windows. Hash canonical
        # LF bytes so checkout policy cannot make verified sources look stale.
        data = data.replace(b"\r\n", b"\n").replace(b"\r", b"\n")
    return hashlib.sha256(data).hexdigest()


def check_page_table(data: bytes, width: int) -> None:
    index_count, page_count = struct.unpack_from("<HH", data, 8)
    assert index_count == 0x1100
    assert 12 + index_count * 2 + page_count * 256 * width == len(data)


def check_layout(blob: Blob, data: bytes) -> None:
    magic = blob.magic
    if magic in (b"CJGB", b"CJWB", b"CJSB"):
        check_page_table(data, 1)
    elif magic == b"CJL2":
        check_page_table(data, 2)
    elif magic == b"CJS1":
        index_count, page_count = struct.unpack_from("<HH", data, 12)
        assert index_count == 0x1100
        assert 16 + index_count * 2 + page_count * 256 == len(data)
    elif magic == b"CJB1":
        index_count, page_count, brackets, mirrors = struct.unpack_from("<HHHH", data, 8)
        assert index_count == 0x1100
        assert 16 + index_count * 2 + page_count * 256 + brackets * 12 + mirrors * 8 == len(data)
    elif magic == b"CJSE":
        set_count, member_count, entry_count = struct.unpack_from("<HHI", data, 12)
        assert 20 + (set_count + 1) * 2 + member_count + entry_count * 8 == len(data)
    else:
        assert len(data) >= (20 if magic == b"CJBT" else 12)


def main() -> None:
    for blob in BLOBS:
        path = ROOT / blob.path
        data = path.read_bytes()
        if len(data) < 8 or data[:4] != blob.magic:
            raise SystemExit(f"{blob.path}: invalid magic")
        if data[4] != blob.format_version or tuple(data[5:8]) != UNICODE_VERSION:
            raise SystemExit(f"{blob.path}: invalid format/Unicode version")
        try:
            check_layout(blob, data)
        except (AssertionError, struct.error):
            raise SystemExit(f"{blob.path}: invalid committed layout") from None
        if digest(path) != blob.sha256:
            raise SystemExit(f"{blob.path}: SHA-256 changed; regenerate and review it")

    for relative, expected in GENERATORS.items():
        if digest(ROOT / relative, text=True) != expected:
            raise SystemExit(f"{relative}: generator changed without reviewed artifacts")

    for generated in GENERATED_TEXT:
        if generated.generator not in GENERATORS:
            raise SystemExit(
                f"{generated.path}: unpinned generator {generated.generator}"
            )
        path = ROOT / generated.path
        if digest(path, text=True) != generated.sha256:
            raise SystemExit(f"{generated.path}: committed generated output changed")
        first_line = path.read_text(encoding="utf-8").splitlines()[0]
        if generated.generator not in first_line:
            raise SystemExit(
                f"{generated.path}: missing {generated.generator} provenance"
            )

    vertical = ROOT / "src/unicode/vertical/data.zig"
    text = vertical.read_text(encoding="utf-8")
    match = SOURCE_SHA.search(text)
    # The digest is provenance for the unavailable UCD input; its presence is
    # required, while reproducibility is covered when that input is supplied.
    if match is None:
        raise SystemExit("vertical/data.zig: missing source SHA-256 provenance")

    print(
        f"verified {len(BLOBS)} Unicode blobs, {len(GENERATED_TEXT)} "
        f"generated sources, and {len(GENERATORS)} generators"
    )


if __name__ == "__main__":
    main()
