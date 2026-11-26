# Third-party notices

## Unicode Character Database

Generated property tables and boundary blobs under `src/unicode/` contain
derived Unicode data, including UAX #50 vertical orientation, normalization
and case-mapping tables, and General_Category and property-alias data. Their
conformance fixtures are compact encodings of the official Unicode 17 test
files. The Arabic shaping tables in `src/unicode/shape/tables.zig` are
Unicode-derived positional-form data mirrored from ICU's `u_shapeArabic`
tables; the shaping conformance fixture and the Normalizer2 boundary table were generated with PyICU. The charset-detection statistical tables in `src/unicode/charset/detect_tables.zig` are derived from ICU's recognizer sources.

- Project: <https://www.unicode.org/>
- Copyright: Unicode, Inc.
- License: Unicode License v3; see `licenses/Unicode-3.0.txt`

The generator inputs and pinned SHA-256 values are recorded in
`tools/unicode/verify_committed.py`.

## simdutf

The AVX2 UTF-8 validation nibble tables and lookup4 error classification in
`src/unicode/scalar/validation/avx2.zig` are adapted from simdutf 9.0.0.
The implementation is Zig and does not link against simdutf.

- Project: <https://github.com/simdutf/simdutf>
- Source: `src/generic/utf8_validation/utf8_lookup4_algorithm.h`, tag `v9.0.0`
- Copyright: 2021 The simdutf authors
- License: MIT; see `licenses/simdutf-MIT.txt`
