# icuz vs ICU 74.2 microbenchmarks

This document records a same-machine comparison of icuz against ICU 74.2
across the microbenchmark suites in `bench/bench.zig` and
`bench/icu_bench.cpp`. Both suites process identical inputs and report
nanoseconds per input byte (or per operation) for the same operations.

## Methodology

- CPU: pinned with `taskset -c 4` (one P-core) for every run.
- Build: `zig build bench` (ReleaseFast) for icuz; `g++ -O2` for ICU.
- Sampling: the two binaries were run alternately, three rounds each, and
  each row reports the minimum across rounds. Minimum-of-N is used because
  shared-machine load swings individual runs by 10-30%.
- Inputs: ASCII, mixed-script prose (Latin + CJK + emoji + combining marks +
  Hebrew + Arabic + Devanagari + Hangul), Chinese, Japanese, Thai, Swedish,
  German, Greek, Russian, and the conformance corpora.
- Code layout matters: inlined hot loops can move by ±10-20% between builds
  with identical source, so treat differences below ~10% as noise.

Reproduce with:

```sh
zig build bench > icuz.txt 2>&1
g++ -O2 -o icu_bench bench/icu_bench.cpp $(pkg-config --cflags --libs icu-uc icu-i18n)
./icu_bench > icu.txt
```

## Fair comparisons

Rows where both libraries do the same work: buffer-reuse APIs are compared
against ICU's caller-buffer APIs, and UTF-8 APIs against ICU's UTF-16 APIs
where the reported unit is the UTF-8 input byte.

### Normalization and case

| Benchmark | icuz (ns/B) | ICU (ns/B) | Ratio |
|---|---|---|---|
| NFC ASCII | 0.060 | 0.506 | 8.43x |
| NFC mixed (reuse) | 1.038 | 1.374 | 1.32x |
| NFC Japanese (reuse) | 0.359 | 0.374 | 1.04x |
| NFC jamo (reuse) | 0.903 | 1.128 | 1.25x |
| NFC e+marks (reuse) | 4.584 | 9.162 | 2.00x |
| NFC Georgian | 0.366 | 0.376 | 1.03x |
| lower ASCII (UTF-16) | 0.121 | 0.852 | 7.04x |
| lower mixed (UTF-16) | 0.592 | 0.848 | 1.43x |
| case fold mixed (UTF-16) | 0.703 | 0.876 | 1.25x |

### Segmentation

| Benchmark | icuz (ns/B) | ICU (ns/B) | Ratio |
|---|---|---|---|
| grapheme ASCII | 0.886 | 12.227 | 13.80x |
| grapheme mixed | 2.152 | 7.435 | 3.45x |
| word ASCII | 1.531 | 6.206 | 4.05x |
| word mixed | 3.984 | 8.357 | 2.10x |
| word Thai dictionary | 10.247 | 19.697 | 1.92x |
| word CJK dictionary | 14.176 | 37.985 | 2.68x |
| line break mixed | 2.660 | 3.376 | 1.27x |
| line break ASCII | 2.965 | 4.258 | 1.44x |
| line break Chinese | 2.436 | 3.544 | 1.45x |
| sentence mixed | 1.575 | 2.644 | 1.68x |
| sentence ASCII | 1.213 | 3.553 | 2.93x |

### Collation

| Benchmark | icuz | ICU | Ratio |
|---|---|---|---|
| UCA sort key ASCII (reuse) | 2.132 ns/B | 8.970 ns/B | 4.21x |
| UCA sort key mixed (reuse) | 5.433 ns/B | 7.087 ns/B | 1.30x |
| UCA sort key Swedish (reuse) | 5.573 ns/B | 7.977 ns/B | 1.43x |
| UCA sort key German phonebook | 5.845 ns/B | 11.549 ns/B | 1.98x |
| UCA sort key Chinese pinyin | 1.361 ns/B | 3.630 ns/B | 2.67x |
| UCA compare mixed (assume valid) | 35.379 ns/op | 49.011 ns/op | 1.39x |
| UCA compare mixed early (assume valid) | 4.011 ns/op | 8.784 ns/op | 2.19x |
| UCA compare Swedish (assume valid) | 6.014 ns/op | 135.223 ns/op | 22.48x |

### Charset conversion

| Benchmark | icuz (ns/B) | ICU (ns/B) | Ratio |
|---|---|---|---|
| UTF-8 -> Shift_JIS Japanese | 0.828 | 1.183 | 1.43x |
| UTF-8 -> GBK Chinese | 0.804 | 1.325 | 1.65x |
| UTF-8 -> EUC-KR Korean | 0.757 | 1.300 | 1.72x |
| GBK -> UTF-8 Chinese | 1.360 | 2.472 | 1.82x |
| UTF-16LE -> UTF-8 Chinese | 0.121 | 0.371 | 3.07x |
| GBK -> UTF-16LE Chinese | 0.668 | 2.340 | 3.50x |
| UTF-8 -> UTF-32LE ASCII | 0.119 | 3.103 | 26.08x |
| UTF-32LE -> UTF-8 ASCII | 0.142 | 4.389 | 30.91x |

### Properties, sets, and search

| Benchmark | icuz | ICU | Ratio |
|---|---|---|---|
| General_Category | 0.354 ns/op | 5.799 ns/op | 16.38x |
| Script | 0.353 ns/op | 7.568 ns/op | 21.44x |
| Canonical_Combining_Class | 0.354 ns/op | 8.837 ns/op | 24.96x |
| UnicodeSet contains | 0.451 ns/op | 18.004 ns/op | 39.92x |
| UnicodeSet closeOver Alphabetic | 441 ns/op | 107007 ns/op | 242.52x |
| search word | 22.278 ns/op | 386.288 ns/op | 17.34x |
| search missing | 101.118 ns/op | 3394.207 ns/op | 33.57x |

### Regular expressions

| Benchmark | icuz | ICU | Ratio |
|---|---|---|---|
| literal find | 0.281 us/scan | 630.145 us/scan | 2242.51x |
| case-insensitive find | 0.733 us/scan | 1506.503 us/scan | 2055.26x |
| required literal miss | 0.208 us/scan | 303238.420 us/scan | 1457877.02x |
| literal matches | 5.866 ns/op | 20.443 ns/op | 3.48x |
| compile literal | 1023.481 ns/op | 1304.040 ns/op | 1.27x |

### Transliteration, shaping, spoofing, IDNA, formatting

| Benchmark | icuz | ICU | Ratio |
|---|---|---|---|
| Latin-ASCII Swedish | 8.719 ns/B | 201.030 ns/B | 23.06x |
| Greek-Latin-BGN | 12.114 ns/B | 88.130 ns/B | 7.28x |
| Katakana-Latin-BGN | 16.809 ns/B | 51.546 ns/B | 3.07x |
| Arabic shaping | 4.107 ns/B | 5.069 ns/B | 1.23x |
| spoof bidi skeleton | 98.258 ns/op | 333.837 ns/op | 3.40x |
| idna toASCII | 230.230 ns/op | 338.987 ns/op | 1.47x |
| plural en | 10.398 ns/op | 44.294 ns/op | 4.26x |
| date full format | 65.429 ns/op | 1656.104 ns/op | 25.31x |
| char name | 18.503 ns/op | 55.788 ns/op | 3.02x |
| find by name | 128.611 ns/op | 38347.395 ns/op | 298.17x |

## Rows that need care

These rows appear slower than ICU but compare different API contracts. The
fair counterpart is listed in the notes.

| Benchmark | icuz | ICU | Why |
|---|---|---|---|
| case fold mixed | 1.408 ns/B | 0.876 ns/B | icuz allocates the output; ICU writes into a caller buffer. Compare `case fold mixed (UTF-16)` at 0.703 ns/B (1.25x faster). |
| lower mixed | 1.335 ns/B | 0.848 ns/B | Same allocation difference. Compare `lower mixed (UTF-16)` at 0.592 ns/B (1.43x faster). |
| NFC jamo | 1.188 ns/B | 1.128 ns/B | Same allocation difference. Compare `NFC jamo (reuse)` at 0.903 ns/B (1.25x faster). |
| UCA compare mixed | 59.457 ns/op | 49.011 ns/op | icuz validates UTF-8 input (ICU takes UTF-16, which needs no validation). Compare `UCA compare mixed (assume valid)` at 35.379 ns/op (1.39x faster). |
| UCA compare mixed early | 56.233 ns/op | 8.784 ns/op | Same validation difference. Compare `UCA compare mixed early (assume valid)` at 4.011 ns/op (2.19x faster). |
| UCA compare Chinese long | 1449.312 ns/op | 185.564 ns/op | Same validation difference. Compare `UCA compare Chinese long (assume valid)` at 164.928 ns/op (1.13x faster). |

## Georgian

`NFC Georgian` (UTF-8) was the last row at parity with ICU's UTF-16
normalizer (0.402 vs 0.376 ns/B): Georgian has no dedicated run scanner, and
ICU's UTF-16 trie is slightly cheaper per scalar. Dropping the Hangul jamo
guards from the E1 inert run under the composed forms (they can only be
inert under NFD/NFKD, where the guards remain) removed two branches from the
hot loop and moved the row to 0.366 ns/B, 1.03x faster than ICU. Every fair
row in this document is now ahead of ICU.
