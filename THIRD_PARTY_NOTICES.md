# Third-party notices

## Unicode Character Database

Generated property tables and boundary blobs under `src/unicode/` contain
derived Unicode data, including UAX #50 vertical orientation, normalization
and case-mapping tables, and General_Category and property-alias data. Their
conformance fixtures are compact encodings of the official Unicode 17 test
files.

- Project: <https://www.unicode.org/>
- Copyright: Unicode, Inc.
- License: Unicode License v3; see `licenses/Unicode-3.0.txt`

The generator inputs and pinned SHA-256 values are recorded in
`tools/unicode/verify_committed.py`.
