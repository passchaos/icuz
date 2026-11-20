#!/usr/bin/env python3
"""Generate the charset-detection conformance fixture with PyICU.

Usage:
    generate_detection_conformance.py out_file
"""

from __future__ import annotations

import struct
import sys

import icu

SAMPLES = (
    b"hello world",
    b"The quick brown fox jumps over the lazy dog. " * 4,
    "Grüße aus München. Die Straße ist schön.".encode("latin-1"),
    "Grüße aus München. Die Straße ist schön.".encode("cp1252"),
    "Grüße aus München. Die Straße ist schön.".encode("utf-8"),
    "C'est déjà l'été à Paris, très agréable.".encode("latin-1"),
    "C'est déjà l'été à Paris, très agréable.".encode("cp1252"),
    "Привет, мир! Это проверка русской кодировки.".encode("cp1251"),
    "Привет, мир! Это проверка русской кодировки.".encode("koi8-r"),
    "Привет, мир! Это проверка русской кодировки.".encode("iso8859-5"),
    "Привет, мир! Это проверка русской кодировки.".encode("utf-8"),
    "Γειά σου κόσμε. Αυτή είναι μια δοκιμή.".encode("iso8859-7"),
    "Γειά σου κόσμε. Αυτή είναι μια δοκιμή.".encode("cp1253"),
    "Γειά σου κόσμε. Αυτή είναι μια δοκιμή.".encode("utf-8"),
    "שלום עולם. זו בדיקה של קידוד עברי.".encode("iso8859-8"),
    "שלום עולם. זו בדיקה של קידוד עברי.".encode("cp1255"),
    "שלום עולם. זו בדיקה של קידוד עברי.".encode("utf-8"),
    "مرحبا بالعالم. هذا اختبار للترميز العربي.".encode("iso8859-6"),
    "مرحبا بالعالم. هذا اختبار للترميز العربي.".encode("cp1256"),
    "مرحبا بالعالم. هذا اختبار للترميز العربي.".encode("utf-8"),
    "Türkçe metin. İstanbul'da güzel bir gün.".encode("iso8859-9"),
    "Türkçe metin. İstanbul'da güzel bir gün.".encode("cp1254"),
    "Zażółć gęślą jaźń. To jest test kodowania.".encode("iso8859-2"),
    "Zażółć gęślą jaźń. To jest test kodowania.".encode("cp1250"),
    "日本語のテキストです。これは文字コードのテストです。".encode("shift_jis"),
    "日本語のテキストです。これは文字コードのテストです。".encode("euc_jp"),
    "日本語のテキストです。これは文字コードのテストです。".encode("iso2022_jp"),
    "日本語のテキストです。これは文字コードのテストです。".encode("utf-8"),
    "한국어 텍스트입니다. 이것은 인코딩 테스트입니다.".encode("euc_kr"),
    "한국어 텍스트입니다. 이것은 인코딩 테스트입니다.".encode("utf-8"),
    "这是一个中文测试。我们正在检查字符编码。".encode("gb18030"),
    "這是一個中文測試。我們正在檢查字元編碼。".encode("big5"),
    "这是一个中文测试。我们正在检查字符编码。".encode("utf-8"),
    b"\xff\xfe" + "hello world".encode("utf-16-le"),
    b"\xfe\xff" + "hello world".encode("utf-16-be"),
    b"\xff\xfe\x00\x00" + "hello world".encode("utf-32-le"),
    b"\x00\x00\xfe\xff" + "hello world".encode("utf-32-be"),
)


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    cases = []
    for text in SAMPLES:
        detector = icu.CharsetDetector()
        detector.setText(text)
        matches = tuple(detector.detectAll())
        cases.append((text, matches))
    blob = bytearray(b"CJSD")
    blob += struct.pack("<B3xI", 1, len(cases))
    for text, matches in cases:
        blob += struct.pack("<HBB", len(text), len(matches), 0)
        blob += text
        for match in matches:
            name = match.getName().encode("utf-8")
            language = match.getLanguage().encode("utf-8")
            blob += struct.pack(
                "<BBB",
                len(name),
                match.getConfidence(),
                len(language),
            )
            blob += name
            blob += language
    with open(sys.argv[1], "wb") as handle:
        handle.write(bytes(blob))
    print(f"wrote {len(cases)} detection cases", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
