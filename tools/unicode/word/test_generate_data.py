#!/usr/bin/env python3
"""Test exact category flags and UnicodeData First/Last parsing."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import generate_data


class UnicodeCategoriesTest(unittest.TestCase):
    def apply(self, text: str, properties: bytearray) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "UnicodeData.txt"
            path.write_text(text, encoding="utf-8")
            generate_data.apply_unicode_categories(properties, str(path))

    def test_letter_categories_are_distinct_from_word_anchors(self) -> None:
        categories = ("Lu", "Ll", "Lt", "Lm", "Lo", "Nd", "Nl", "No", "Mn", "Mc", "Me", "Cf", "Zs", "Pc")
        properties = bytearray([0x25] * len(categories))
        self.apply("\n".join(f"{cp:04X};TEST;{category}" for cp, category in enumerate(categories)), properties)
        for cp, category in enumerate(categories):
            self.assertEqual(properties[cp] & 0x3F, 0x25)
            self.assertEqual(bool(properties[cp] & 0x40), category[0] in "LN")
            self.assertEqual(bool(properties[cp] & 0x80), category in ("Lu", "Ll", "Lt", "Lm", "Lo"))

    def test_first_last_ranges_include_every_scalar(self) -> None:
        properties = bytearray([0x12] * 12)
        self.apply("0002;<TEST LETTER, First>;Lo\n0005;<TEST LETTER, Last>;Lo\n0007;<TEST NUMBER, First>;Nl\n0009;<TEST NUMBER, Last>;Nl\n", properties)
        for cp, value in enumerate(properties):
            self.assertEqual(value & 0x3F, 0x12)
            self.assertEqual(bool(value & 0x40), cp in range(2, 6) or cp in range(7, 10))
            self.assertEqual(bool(value & 0x80), cp in range(2, 6))

    def test_malformed_ranges_fail(self) -> None:
        for text in (
            "0001;<TEST, Last>;Lo\n",
            "0001;<TEST, First>;Lo\n",
            "0001;<TEST, First>;Lo\n0002;<OTHER, First>;Lo\n",
            "0001;<TEST, First>;Lo\n0002;<TEST, Last>;Nl\n",
        ):
            with self.subTest(text=text), self.assertRaises(SystemExit):
                self.apply(text, bytearray(4))

    def test_unpinned_unicode_data_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            word_break = root / "WordBreakProperty.txt"
            emoji = root / "emoji-data.txt"
            categories = root / "UnicodeData.txt"
            output = root / "data.bin"
            word_break.write_text("# WordBreakProperty-17.0.0.txt\n", encoding="utf-8")
            emoji.write_text("# Version: 17.0\n", encoding="utf-8")
            categories.write_text("0000;<control>;Cc;\n", encoding="utf-8")
            arguments = ["generate_data.py", str(word_break), str(emoji), str(categories), str(output)]
            with patch.object(generate_data.sys, "argv", arguments), self.assertRaisesRegex(SystemExit, "pinned Unicode 17.0"):
                generate_data.main()
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
