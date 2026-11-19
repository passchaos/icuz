#!/usr/bin/env python3
"""Generate the currency formatting conformance fixture with PyICU.

Usage:
    generate_currency_conformance.py out_file
"""

from __future__ import annotations

import struct
import sys

import icu

LOCALES = (
    "en", "fr", "de", "ja", "zh", "ko", "ru", "ar", "hi", "th", "pt", "es",
)
CURRENCIES = (
    "USD", "EUR", "GBP", "JPY", "CNY", "KRW", "INR", "RUB", "BRL", "CAD",
    "AUD", "CHF", "SEK", "NOK", "DKK", "PLN", "TRY", "SAR", "AED", "ILS",
    "THB", "VND", "IDR", "MXN", "ZAR", "AFN", "BHD", "BIF", "BND", "TND",
)
VALUES = (1234.5, 0.5, -1234.5)


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    cases = []
    for locale in LOCALES:
        for code in CURRENCIES:
            formatter = icu.NumberFormat.createCurrencyInstance(
                icu.Locale(locale)
            )
            formatter.setCurrency(code)
            for value in VALUES:
                cases.append((locale, code, value, formatter.format(value)))
    blob = bytearray(b"CJR1")
    blob += struct.pack("<B3xI", 1, len(cases))
    for locale, code, value, expected in cases:
        encoded_locale = locale.encode("utf-8")
        encoded_code = code.encode("utf-8")
        encoded_expected = expected.encode("utf-8")
        blob += struct.pack(
            "<BBBBdHH",
            len(encoded_locale),
            len(encoded_code),
            0,
            0,
            value,
            len(encoded_expected),
            0,
        )
        blob += encoded_locale
        blob += encoded_code
        blob += encoded_expected
    with open(sys.argv[1], "wb") as handle:
        handle.write(bytes(blob))
    print(f"wrote {len(cases)} cases", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
