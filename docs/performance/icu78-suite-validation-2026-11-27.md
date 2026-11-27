# Latest-release ICU 78.3 suite validation, 2026-11-27

This profile re-runs the fair-comparison microbenchmarks at commit
`a6d9733` against the newest ICU release available on the machine,
ICU 78.3, instead of the ICU 74.2 snapshot kept in
[`docs/benchmarks.md`](../benchmarks.md). icuz leads all 81 mapped rows;
the thinnest margin is NFC Japanese (reuse) at 1.16x.

The UTF-16→UTF-8 strict conversion rows remain the only measured gaps
against any external library; they are tracked separately in the
[sixteen-unit BMP profile](utf-bmp-16unit-2026-11-27.md) and are not part
of this suite.

## Method

- Intel Core i9-13900K, logical CPU 4, Linux x86-64. icuz built with
  `zig build bench` (ReleaseFast). ICU 78.3 built from the conda-forge
  package `icu-78.3-h33c6efd_0` with GCC 13 `-O2 -std=c++17`.
- Three alternating rounds of each binary; every row reports the minimum
  across rounds for the same row name and unit. Both harnesses generate
  identical inputs, as described in
  [`docs/benchmarks.md`](../benchmarks.md).
- The fused UTF-8 normalization entry is pinned to a 64-byte boundary so
  unrelated code growth cannot re-roll its hot loop layout.
- Rows where the two harnesses use different contracts are excluded:
  allocation-versus-caller-buffer rows listed under "Rows that need care",
  and the regular-expression scan rows whose icuz unit is `us/scan` while
  the ICU harness reports `ns/op`.
- Differences below roughly ten percent are treated as parity, matching the
  project's existing methodology. The thinnest row here is 1.16x, so every
  row is outside that band in icuz's favor, but the smallest margins should
  be re-measured before being quoted as durable rankings.
- [Raw samples](icu78-suite-validation-2026-11-27.json) record all three
  rounds for both binaries, harness hashes, output hashes, and the ICU
  package path.

## Results

Values are the minimum across rounds. Ratio is ICU divided by icuz, so
values above one mean icuz is faster.

### Normalization and case

| Benchmark | icuz | ICU 78.3 | Ratio |
|---|---:|---:|---:|
| NFC ASCII | 0.057 ns/B | 0.506 ns/B | 8.88x |
| NFC mixed (reuse) | 0.966 ns/B | 1.393 ns/B | 1.44x |
| NFC Japanese (reuse) | 0.326 ns/B | 0.378 ns/B | 1.16x |
| NFC jamo (reuse) | 0.929 ns/B | 1.095 ns/B | 1.18x |
| NFC e+marks (reuse) | 4.440 ns/B | 8.920 ns/B | 2.01x |
| NFC Georgian | 0.239 ns/B | 0.384 ns/B | 1.61x |
| NFC Georgian (utf16 reuse) | 0.167 ns/B | 0.384 ns/B | 2.30x |
| NFC Hebrew (utf16 reuse) | 0.378 ns/B | 0.650 ns/B | 1.72x |
| NFC Arabic (utf16 reuse) | 0.215 ns/B | 0.557 ns/B | 2.59x |
| NFC Devanagari (utf16 reuse) | 0.260 ns/B | 0.515 ns/B | 1.98x |
| NFC Thai (utf16 reuse) | 0.293 ns/B | 0.535 ns/B | 1.83x |
| NFC Amharic (utf16 reuse) | 0.245 ns/B | 0.526 ns/B | 2.15x |
| NFC Korean (utf16 reuse) | 0.401 ns/B | 0.497 ns/B | 1.24x |
| isNormalized ASCII | 0.045 ns/B | 0.399 ns/B | 8.87x |
| isNormalized mixed (utf16) | 0.286 ns/B | 0.826 ns/B | 2.89x |
| isNormalized Chinese | 0.187 ns/B | 0.476 ns/B | 2.55x |
| isNormalized Georgian | 0.231 ns/B | 0.344 ns/B | 1.49x |
| lower ASCII (utf16) | 0.115 ns/B | 0.870 ns/B | 7.57x |
| lower mixed (utf16) | 0.597 ns/B | 0.947 ns/B | 1.59x |
| case fold mixed (utf16) | 0.702 ns/B | 1.028 ns/B | 1.46x |

### Segmentation

| Benchmark | icuz | ICU 78.3 | Ratio |
|---|---:|---:|---:|
| grapheme ASCII | 0.887 ns/B | 13.007 ns/B | 14.66x |
| grapheme mixed | 2.107 ns/B | 7.786 ns/B | 3.70x |
| word ASCII | 1.625 ns/B | 6.269 ns/B | 3.86x |
| word mixed | 4.136 ns/B | 8.572 ns/B | 2.07x |
| word Thai dictionary | 8.020 ns/B | 18.289 ns/B | 2.28x |
| word CJK dictionary | 14.481 ns/B | 39.263 ns/B | 2.71x |
| line break mixed | 2.572 ns/B | 3.560 ns/B | 1.38x |
| line break ASCII | 2.706 ns/B | 4.362 ns/B | 1.61x |
| line break Chinese | 2.399 ns/B | 4.776 ns/B | 1.99x |
| sentence mixed | 1.568 ns/B | 2.772 ns/B | 1.77x |
| sentence ASCII | 1.331 ns/B | 3.681 ns/B | 2.77x |

### Collation

| Benchmark | icuz | ICU 78.3 | Ratio |
|---|---:|---:|---:|
| UCA sort key ASCII (reuse) | 2.143 ns/B | 8.107 ns/B | 3.78x |
| UCA sort key mixed (reuse) | 5.510 ns/B | 6.552 ns/B | 1.19x |
| UCA sort key Swedish (reuse) | 5.522 ns/B | 7.200 ns/B | 1.30x |
| UCA sort key German phonebook | 5.772 ns/B | 9.918 ns/B | 1.72x |
| UCA sort key Chinese pinyin | 1.363 ns/B | 3.453 ns/B | 2.53x |
| UCA sort key mixed (utf16) | 5.267 ns/B | 6.552 ns/B | 1.24x |
| UCA sort key Swedish (utf16) | 5.189 ns/B | 7.200 ns/B | 1.39x |
| UCA sort key Chinese pinyin (utf16) | 1.419 ns/B | 3.453 ns/B | 2.43x |
| UCA compare mixed (assume valid) | 11.027 ns/op | 51.363 ns/op | 4.66x |
| UCA compare mixed early (assume valid) | 3.759 ns/op | 10.021 ns/op | 2.67x |
| UCA compare Swedish (assume valid) | 6.014 ns/op | 135.841 ns/op | 22.59x |
| UCA compare mixed (utf16) | 5.263 ns/op | 51.363 ns/op | 9.76x |
| UCA compare mixed early (utf16) | 2.758 ns/op | 10.021 ns/op | 3.63x |

### Charset conversion

| Benchmark | icuz | ICU 78.3 | Ratio |
|---|---:|---:|---:|
| UTF-8 -> Shift_JIS Japanese | 0.817 ns/B | 1.071 ns/B | 1.31x |
| UTF-8 -> GBK Chinese | 0.800 ns/B | 1.225 ns/B | 1.53x |
| UTF-8 -> EUC-KR Korean | 0.780 ns/B | 1.237 ns/B | 1.59x |
| GBK -> UTF-8 Chinese | 1.344 ns/B | 2.441 ns/B | 1.82x |
| UTF-16LE -> UTF-8 Chinese | 0.121 ns/B | 0.371 ns/B | 3.07x |
| GBK -> UTF-16LE Chinese | 0.677 ns/B | 2.281 ns/B | 3.37x |
| UTF-8 -> UTF-32LE ASCII | 0.115 ns/B | 3.064 ns/B | 26.64x |
| UTF-32LE -> UTF-8 ASCII | 0.141 ns/B | 4.351 ns/B | 30.86x |
| UTF-16LE -> UTF-32LE ASCII | 0.184 ns/B | 0.527 ns/B | 2.86x |
| UTF-16LE -> UTF-32LE Chinese | 0.067 ns/B | 0.181 ns/B | 2.70x |
| UTF-32LE -> UTF-16LE ASCII | 0.253 ns/B | 0.590 ns/B | 2.33x |
| UTF-32LE -> UTF-16LE Chinese | 0.090 ns/B | 0.269 ns/B | 2.99x |
| windows-1252 -> UTF-8 accents | 0.660 ns/B | 1.164 ns/B | 1.76x |
| UTF-8 -> windows-1252 accents | 0.763 ns/B | 1.132 ns/B | 1.48x |
| IBM866 -> UTF-8 Russian | 0.487 ns/B | 1.096 ns/B | 2.25x |

### Properties, sets, and search

| Benchmark | icuz | ICU 78.3 | Ratio |
|---|---:|---:|---:|
| General_Category | 0.354 ns/op | 6.007 ns/op | 16.97x |
| Script | 0.355 ns/op | 7.519 ns/op | 21.18x |
| Canonical_Combining_Class | 0.355 ns/op | 8.584 ns/op | 24.18x |
| UnicodeSet contains | 0.451 ns/op | 17.338 ns/op | 38.44x |
| UnicodeSet closeOver Alphabetic | 389.390 ns/op | 108948.917 ns/op | 279.79x |
| search word | 22.464 ns/op | 395.063 ns/op | 17.59x |
| search missing | 105.526 ns/op | 3270.890 ns/op | 31.00x |

### Transliteration, shaping, and formatting

| Benchmark | icuz | ICU 78.3 | Ratio |
|---|---:|---:|---:|
| Latin-ASCII Swedish | 8.612 ns/B | 182.540 ns/B | 21.20x |
| Greek-Latin-BGN | 12.143 ns/B | 78.954 ns/B | 6.50x |
| Katakana-Latin-BGN | 16.469 ns/B | 45.980 ns/B | 2.79x |
| Amharic-Latin-BGN | 10.140 ns/B | 28.617 ns/B | 2.82x |
| Russian-Latin-BGN | 13.843 ns/B | 48.649 ns/B | 3.51x |
| Ukrainian-Latin-BGN | 11.654 ns/B | 43.992 ns/B | 3.77x |
| Arabic shaping | 4.017 ns/B | 4.742 ns/B | 1.18x |
| Arabic shaping (utf16) | 3.587 ns/B | 4.742 ns/B | 1.32x |
| spoof bidi skeleton | 96.962 ns/op | 292.352 ns/op | 3.02x |
| idna toASCII | 207.906 ns/op | 332.888 ns/op | 1.60x |
| idna toUnicode | 126.595 ns/op | 192.487 ns/op | 1.52x |
| plural en | 10.542 ns/op | 44.275 ns/op | 4.20x |
| date full format | 63.001 ns/op | 1138.973 ns/op | 18.08x |
| char name | 18.707 ns/op | 54.726 ns/op | 2.93x |
| find by name | 125.659 ns/op | 37131.316 ns/op | 295.49x |

## Thinnest margins

| Benchmark | icuz | ICU 78.3 | Ratio |
|---|---:|---:|---:|
| NFC Japanese (reuse) | 0.326 ns/B | 0.378 ns/B | 1.16x |
| NFC jamo (reuse) | 0.929 ns/B | 1.095 ns/B | 1.18x |
| Arabic shaping | 4.017 ns/B | 4.742 ns/B | 1.18x |
| UCA sort key mixed (reuse) | 5.510 ns/B | 6.552 ns/B | 1.19x |
| NFC Korean (utf16 reuse) | 0.401 ns/B | 0.497 ns/B | 1.24x |
| UCA sort key mixed (utf16) | 5.267 ns/B | 6.552 ns/B | 1.24x |
| UCA sort key Swedish (reuse) | 5.522 ns/B | 7.200 ns/B | 1.30x |
| UTF-8 -> Shift_JIS Japanese | 0.817 ns/B | 1.071 ns/B | 1.31x |
| Arabic shaping (utf16) | 3.587 ns/B | 4.742 ns/B | 1.32x |
| line break mixed | 2.572 ns/B | 3.560 ns/B | 1.38x |
| UCA sort key Swedish (utf16) | 5.189 ns/B | 7.200 ns/B | 1.39x |
| NFC mixed (reuse) | 0.966 ns/B | 1.393 ns/B | 1.44x |

Arabic shaping is the largest shift against the older table: ICU 78.3
improves it from 5.163 to 4.742 ns/B while icuz stays at 4.017 ns/B
(UTF-8) and 3.587 ns/B (UTF-16), leaving 1.18x and 1.32x. Several
normalization and case rows moved in icuz's favor because ICU 78.3 is
slower there than 74.2 (for example NFC Georgian 0.441 vs 0.379 ns/B,
case fold mixed 1.024 vs 0.897 ns/B, line break Chinese 4.768 vs
3.544 ns/B).

## Reproduce

```sh
zig build bench > icuz.txt 2>&1
ICU=/home/passchaos/.cache/rattler/cache/bld/pkgs/icu-78.3-h33c6efd_0
g++ -O2 -std=c++17 -I$ICU/include -L$ICU/lib -Wl,-rpath,$ICU/lib \
  -o /tmp/icu_bench78 bench/icu_bench.cpp -licuuc -licui18n -licudata
/tmp/icu_bench78 > icu78.txt
```

Run both binaries three times in alternating order on the same CPU and take
the per-row minimum. The suite runs in roughly half a minute for ICU and a
few minutes for icuz.
