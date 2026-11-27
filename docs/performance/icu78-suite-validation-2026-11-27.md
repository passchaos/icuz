# Latest-release ICU 78.3 suite validation, 2026-11-27

This profile re-runs the fair-comparison microbenchmarks at commit
`7593916` against the newest ICU release available on the machine,
ICU 78.3, instead of the ICU 74.2 snapshot kept in
[`docs/benchmarks.md`](../benchmarks.md). icuz leads all 81 mapped rows;
the thinnest margin is NFC Arabic (UTF-16 reuse) at 1.06x.

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
- Rows where the two harnesses use different contracts are excluded:
  allocation-versus-caller-buffer rows listed under "Rows that need care",
  and the regular-expression scan rows whose icuz unit is `us/scan` while
  the ICU harness reports `ns/op`.
- Differences below roughly ten percent are treated as parity, matching the
  project's existing methodology. The thinnest row here is 1.06x, so every
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
| NFC ASCII | 0.057 ns/B | 0.490 ns/B | 8.60x |
| NFC mixed (reuse) | 1.029 ns/B | 1.364 ns/B | 1.33x |
| NFC Japanese (reuse) | 0.340 ns/B | 0.378 ns/B | 1.11x |
| NFC jamo (reuse) | 0.904 ns/B | 1.086 ns/B | 1.20x |
| NFC e+marks (reuse) | 4.425 ns/B | 8.941 ns/B | 2.02x |
| NFC Georgian | 0.239 ns/B | 0.395 ns/B | 1.65x |
| NFC Georgian (utf16 reuse) | 0.167 ns/B | 0.395 ns/B | 2.37x |
| NFC Hebrew (utf16 reuse) | 0.531 ns/B | 0.623 ns/B | 1.17x |
| NFC Arabic (utf16 reuse) | 0.513 ns/B | 0.546 ns/B | 1.06x |
| NFC Devanagari (utf16 reuse) | 0.258 ns/B | 0.511 ns/B | 1.98x |
| NFC Thai (utf16 reuse) | 0.288 ns/B | 0.529 ns/B | 1.84x |
| NFC Amharic (utf16 reuse) | 0.230 ns/B | 0.490 ns/B | 2.13x |
| NFC Korean (utf16 reuse) | 0.426 ns/B | 0.488 ns/B | 1.15x |
| isNormalized ASCII | 0.072 ns/B | 0.404 ns/B | 5.61x |
| isNormalized mixed (utf16) | 0.306 ns/B | 0.835 ns/B | 2.73x |
| isNormalized Chinese | 0.242 ns/B | 0.471 ns/B | 1.95x |
| isNormalized Georgian | 0.231 ns/B | 0.350 ns/B | 1.52x |
| lower ASCII (utf16) | 0.119 ns/B | 0.897 ns/B | 7.54x |
| lower mixed (utf16) | 0.606 ns/B | 0.955 ns/B | 1.58x |
| case fold mixed (utf16) | 0.703 ns/B | 1.024 ns/B | 1.46x |

### Segmentation

| Benchmark | icuz | ICU 78.3 | Ratio |
|---|---:|---:|---:|
| grapheme ASCII | 0.887 ns/B | 12.941 ns/B | 14.59x |
| grapheme mixed | 2.217 ns/B | 7.628 ns/B | 3.44x |
| word ASCII | 1.629 ns/B | 6.248 ns/B | 3.84x |
| word mixed | 4.035 ns/B | 8.532 ns/B | 2.11x |
| word Thai dictionary | 7.927 ns/B | 18.330 ns/B | 2.31x |
| word CJK dictionary | 14.346 ns/B | 39.247 ns/B | 2.74x |
| line break mixed | 2.527 ns/B | 3.570 ns/B | 1.41x |
| line break ASCII | 2.750 ns/B | 4.343 ns/B | 1.58x |
| line break Chinese | 2.398 ns/B | 4.768 ns/B | 1.99x |
| sentence mixed | 1.676 ns/B | 2.775 ns/B | 1.66x |
| sentence ASCII | 1.458 ns/B | 3.682 ns/B | 2.53x |

### Collation

| Benchmark | icuz | ICU 78.3 | Ratio |
|---|---:|---:|---:|
| UCA sort key ASCII (reuse) | 2.122 ns/B | 8.118 ns/B | 3.83x |
| UCA sort key mixed (reuse) | 5.593 ns/B | 6.387 ns/B | 1.14x |
| UCA sort key Swedish (reuse) | 5.479 ns/B | 7.234 ns/B | 1.32x |
| UCA sort key German phonebook | 5.860 ns/B | 9.797 ns/B | 1.67x |
| UCA sort key Chinese pinyin | 1.331 ns/B | 3.413 ns/B | 2.56x |
| UCA sort key mixed (utf16) | 5.253 ns/B | 6.387 ns/B | 1.22x |
| UCA sort key Swedish (utf16) | 5.163 ns/B | 7.234 ns/B | 1.40x |
| UCA sort key Chinese pinyin (utf16) | 1.353 ns/B | 3.413 ns/B | 2.52x |
| UCA compare mixed (assume valid) | 10.776 ns/op | 50.275 ns/op | 4.67x |
| UCA compare mixed early (assume valid) | 4.014 ns/op | 9.075 ns/op | 2.26x |
| UCA compare Swedish (assume valid) | 6.014 ns/op | 135.568 ns/op | 22.54x |
| UCA compare mixed (utf16) | 5.012 ns/op | 50.275 ns/op | 10.03x |
| UCA compare mixed early (utf16) | 2.766 ns/op | 9.075 ns/op | 3.28x |

### Charset conversion

| Benchmark | icuz | ICU 78.3 | Ratio |
|---|---:|---:|---:|
| UTF-8 -> Shift_JIS Japanese | 0.816 ns/B | 1.069 ns/B | 1.31x |
| UTF-8 -> GBK Chinese | 0.800 ns/B | 1.220 ns/B | 1.52x |
| UTF-8 -> EUC-KR Korean | 0.767 ns/B | 1.244 ns/B | 1.62x |
| GBK -> UTF-8 Chinese | 1.325 ns/B | 2.441 ns/B | 1.84x |
| UTF-16LE -> UTF-8 Chinese | 0.120 ns/B | 0.371 ns/B | 3.09x |
| GBK -> UTF-16LE Chinese | 0.668 ns/B | 2.283 ns/B | 3.42x |
| UTF-8 -> UTF-32LE ASCII | 0.110 ns/B | 3.069 ns/B | 27.90x |
| UTF-32LE -> UTF-8 ASCII | 0.146 ns/B | 4.352 ns/B | 29.81x |
| UTF-16LE -> UTF-32LE ASCII | 0.167 ns/B | 0.527 ns/B | 3.16x |
| UTF-16LE -> UTF-32LE Chinese | 0.065 ns/B | 0.198 ns/B | 3.05x |
| UTF-32LE -> UTF-16LE ASCII | 0.209 ns/B | 0.588 ns/B | 2.81x |
| UTF-32LE -> UTF-16LE Chinese | 0.076 ns/B | 0.272 ns/B | 3.58x |
| windows-1252 -> UTF-8 accents | 0.658 ns/B | 1.168 ns/B | 1.78x |
| UTF-8 -> windows-1252 accents | 0.767 ns/B | 1.130 ns/B | 1.47x |
| IBM866 -> UTF-8 Russian | 0.479 ns/B | 1.093 ns/B | 2.28x |

### Properties, sets, and search

| Benchmark | icuz | ICU 78.3 | Ratio |
|---|---:|---:|---:|
| General_Category | 0.355 ns/op | 5.994 ns/op | 16.88x |
| Script | 0.355 ns/op | 7.504 ns/op | 21.14x |
| Canonical_Combining_Class | 0.355 ns/op | 8.568 ns/op | 24.14x |
| UnicodeSet contains | 0.451 ns/op | 17.336 ns/op | 38.44x |
| UnicodeSet closeOver Alphabetic | 444.140 ns/op | 109571.795 ns/op | 246.71x |
| search word | 18.683 ns/op | 386.490 ns/op | 20.69x |
| search missing | 87.844 ns/op | 3282.412 ns/op | 37.37x |

### Transliteration, shaping, and formatting

| Benchmark | icuz | ICU 78.3 | Ratio |
|---|---:|---:|---:|
| Latin-ASCII Swedish | 8.595 ns/B | 182.332 ns/B | 21.21x |
| Greek-Latin-BGN | 11.873 ns/B | 78.881 ns/B | 6.64x |
| Katakana-Latin-BGN | 16.081 ns/B | 46.007 ns/B | 2.86x |
| Amharic-Latin-BGN | 9.924 ns/B | 28.630 ns/B | 2.88x |
| Russian-Latin-BGN | 13.841 ns/B | 48.575 ns/B | 3.51x |
| Ukrainian-Latin-BGN | 11.408 ns/B | 44.203 ns/B | 3.87x |
| Arabic shaping | 4.181 ns/B | 4.726 ns/B | 1.13x |
| Arabic shaping (utf16) | 3.711 ns/B | 4.726 ns/B | 1.27x |
| spoof bidi skeleton | 96.755 ns/op | 292.480 ns/op | 3.02x |
| idna toASCII | 206.181 ns/op | 332.938 ns/op | 1.61x |
| idna toUnicode | 126.144 ns/op | 192.101 ns/op | 1.52x |
| plural en | 9.384 ns/op | 42.496 ns/op | 4.53x |
| date full format | 62.352 ns/op | 1137.449 ns/op | 18.24x |
| char name | 18.508 ns/op | 54.907 ns/op | 2.97x |
| find by name | 126.200 ns/op | 37315.241 ns/op | 295.68x |

## Thinnest margins

| Benchmark | icuz | ICU 78.3 | Ratio |
|---|---:|---:|---:|
| NFC Arabic (utf16 reuse) | 0.513 ns/B | 0.546 ns/B | 1.06x |
| NFC Japanese (reuse) | 0.340 ns/B | 0.378 ns/B | 1.11x |
| Arabic shaping | 4.181 ns/B | 4.726 ns/B | 1.13x |
| UCA sort key mixed (reuse) | 5.593 ns/B | 6.387 ns/B | 1.14x |
| NFC Korean (utf16 reuse) | 0.426 ns/B | 0.488 ns/B | 1.15x |
| NFC Hebrew (utf16 reuse) | 0.531 ns/B | 0.623 ns/B | 1.17x |
| NFC jamo (reuse) | 0.904 ns/B | 1.086 ns/B | 1.20x |
| UCA sort key mixed (utf16) | 5.253 ns/B | 6.387 ns/B | 1.22x |
| Arabic shaping (utf16) | 3.711 ns/B | 4.726 ns/B | 1.27x |
| UTF-8 -> Shift_JIS Japanese | 0.816 ns/B | 1.069 ns/B | 1.31x |
| UCA sort key Swedish (reuse) | 5.479 ns/B | 7.234 ns/B | 1.32x |
| NFC mixed (reuse) | 1.029 ns/B | 1.364 ns/B | 1.33x |

Arabic shaping is the largest shift against the older table: ICU 78.3
improves it from 5.163 to 4.726 ns/B while icuz stays at 4.181 ns/B
(UTF-8) and 3.711 ns/B (UTF-16), leaving 1.13x and 1.27x. Several
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
