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
- Snapshot: the numbers below were collected at commit `20d21cc`
  (2026-11-26), with the Georgian row refreshed at `37c0931`, the
  collation contract rows at `0de0c61`, the IDNA row at `48c63a2`, and the
  Chinese compare rows at `cc56631`. Re-run the commands under "Reproduce"
  to refresh them.
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
| NFC ASCII | 0.061 | 0.492 | 8.07x |
| NFC mixed (reuse) | 1.005 | 1.367 | 1.36x |
| NFC Japanese (reuse) | 0.325 | 0.374 | 1.15x |
| NFC jamo (reuse) | 0.975 | 1.158 | 1.19x |
| NFC e+marks (reuse) | 4.454 | 9.133 | 2.05x |
| NFC Georgian | 0.239 | 0.379 | 1.59x |
| lower ASCII (UTF-16) | 0.113 | 0.852 | 7.54x |
| lower mixed (UTF-16) | 0.595 | 0.863 | 1.45x |
| case fold mixed (UTF-16) | 0.709 | 0.893 | 1.26x |

### Segmentation

| Benchmark | icuz (ns/B) | ICU (ns/B) | Ratio |
|---|---|---|---|
| grapheme ASCII | 0.892 | 12.297 | 13.79x |
| grapheme mixed | 2.121 | 7.336 | 3.46x |
| word ASCII | 1.556 | 6.193 | 3.98x |
| word mixed | 4.072 | 8.346 | 2.05x |
| word Thai dictionary | 7.760 | 20.060 | 2.58x |
| word CJK dictionary | 14.076 | 37.783 | 2.68x |
| line break mixed | 2.501 | 3.366 | 1.35x |
| line break ASCII | 2.727 | 4.277 | 1.57x |
| line break Chinese | 2.434 | 3.540 | 1.45x |
| sentence mixed | 1.651 | 2.649 | 1.60x |
| sentence ASCII | 1.454 | 3.575 | 2.46x |

### Collation

| Benchmark | icuz | ICU | Ratio |
|---|---|---|---|
| UCA sort key ASCII (reuse) | 2.159 ns/B | 9.012 ns/B | 4.17x |
| UCA sort key mixed (reuse) | 5.477 ns/B | 7.034 ns/B | 1.28x |
| UCA sort key Swedish (reuse) | 5.602 ns/B | 8.130 ns/B | 1.45x |
| UCA sort key German phonebook | 5.780 ns/B | 11.786 ns/B | 2.04x |
| UCA sort key Chinese pinyin | 1.406 ns/B | 3.685 ns/B | 2.62x |
| UCA compare mixed (assume valid) | 35.379 ns/op | 48.419 ns/op | 1.37x |
| UCA compare mixed early (assume valid) | 4.011 ns/op | 8.812 ns/op | 2.20x |
| UCA compare Chinese long (assume valid) | 123.903 ns/op | 187.232 ns/op | 1.51x |
| UCA compare Swedish (assume valid) | 6.014 ns/op | 135.340 ns/op | 22.50x |

### Charset conversion

| Benchmark | icuz (ns/B) | ICU (ns/B) | Ratio |
|---|---|---|---|
| UTF-8 -> Shift_JIS Japanese | 0.827 | 1.189 | 1.44x |
| UTF-8 -> GBK Chinese | 0.802 | 1.322 | 1.65x |
| UTF-8 -> EUC-KR Korean | 0.757 | 1.321 | 1.75x |
| GBK -> UTF-8 Chinese | 1.346 | 2.474 | 1.84x |
| UTF-16LE -> UTF-8 Chinese | 0.122 | 0.371 | 3.04x |
| GBK -> UTF-16LE Chinese | 0.673 | 2.345 | 3.48x |
| UTF-8 -> UTF-32LE ASCII | 0.121 | 3.103 | 25.64x |
| UTF-32LE -> UTF-8 ASCII | 0.146 | 4.385 | 30.03x |

### Properties, sets, and search

| Benchmark | icuz | ICU | Ratio |
|---|---|---|---|
| General_Category | 0.373 ns/op | 5.770 ns/op | 15.47x |
| Script | 0.354 ns/op | 7.516 ns/op | 21.23x |
| Canonical_Combining_Class | 0.355 ns/op | 8.858 ns/op | 24.95x |
| UnicodeSet contains | 0.451 ns/op | 18.012 ns/op | 39.94x |
| UnicodeSet closeOver Alphabetic | 396.815 ns/op | 107236.455 ns/op | 270.24x |
| search word | 19.380 ns/op | 391.079 ns/op | 20.18x |
| search missing | 140.879 ns/op | 3444.197 ns/op | 24.45x |

### Regular expressions

| Benchmark | icuz | ICU | Ratio |
|---|---|---|---|
| literal find | 0.286 us/scan | 609.817 us/scan | 2132.23x |
| case-insensitive find | 0.732 us/scan | 1487.755 us/scan | 2032.45x |
| required literal miss | 0.206 us/scan | 303023.997 us/scan | 1470990.28x |
| literal matches | 5.801 ns/op | 20.137 ns/op | 3.47x |
| compile literal | 333.221 ns/op | 1298.909 ns/op | 3.90x |
| compile class | 701.649 ns/op | 3103.677 ns/op | 4.42x |
| compile alternation | 492.783 ns/op | 1606.047 ns/op | 3.26x |
| compile lookbehind | 519.542 ns/op | 1783.589 ns/op | 3.43x |
| compile word boundary | 477.192 ns/op | 1471.432 ns/op | 3.08x |
| compile word class | 810.124 ns/op | 4784.516 ns/op | 5.91x |

### Transliteration, shaping, spoofing, IDNA, formatting

| Benchmark | icuz | ICU | Ratio |
|---|---|---|---|
| Latin-ASCII Swedish | 8.985 ns/B | 200.631 ns/B | 22.33x |
| Greek-Latin-BGN | 12.173 ns/B | 88.533 ns/B | 7.27x |
| Katakana-Latin-BGN | 16.652 ns/B | 51.835 ns/B | 3.11x |
| Arabic shaping | 4.044 ns/B | 5.134 ns/B | 1.27x |
| spoof bidi skeleton | 97.078 ns/op | 334.337 ns/op | 3.44x |
| idna toASCII | 205.152 ns/op | 341.113 ns/op | 1.66x |
| plural en | 10.358 ns/op | 44.369 ns/op | 4.28x |
| date full format | 63.415 ns/op | 1658.540 ns/op | 26.15x |
| char name | 18.699 ns/op | 56.300 ns/op | 3.01x |
| find by name | 126.801 ns/op | 38553.622 ns/op | 304.05x |

## Rows that need care

These rows appear slower than ICU but compare different API contracts. The
fair counterpart is listed in the notes.

| Benchmark | icuz | ICU | Why |
|---|---|---|---|
| case fold mixed | 1.406 ns/B | 0.893 ns/B | icuz allocates the output; ICU writes into a caller buffer. Compare `case fold mixed (UTF-16)` at 0.709 ns/B (1.26x faster). |
| lower mixed | 1.338 ns/B | 0.863 ns/B | Same allocation difference. Compare `lower mixed (UTF-16)` at 0.595 ns/B (1.45x faster). |
| NFC jamo | 1.147 ns/B | 1.158 ns/B | Same allocation difference. Compare `NFC jamo (reuse)` at 0.975 ns/B (1.19x faster). |
| UCA compare mixed | 56.643 ns/op | 48.793 ns/op | icuz validates UTF-8 input (ICU takes UTF-16, which needs no validation). Compare `UCA compare mixed (assume valid)` at 35.379 ns/op (1.37x faster). |
| UCA compare mixed early | 50.302 ns/op | 8.780 ns/op | Same validation difference. Compare `UCA compare mixed early (assume valid)` at 4.011 ns/op (2.20x faster). |
| UCA compare Chinese long | 1258.185 ns/op | 187.232 ns/op | Same validation difference. Compare `UCA compare Chinese long (assume valid)` at 123.903 ns/op (1.51x faster). |

## Georgian

`NFC Georgian` (UTF-8) was the last row at parity with ICU's UTF-16
normalizer: Georgian has no dedicated run scanner, and ICU's UTF-16 trie is
slightly cheaper per scalar. Dropping the Hangul jamo guards from the E1
inert run under the composed forms (they can only be inert under NFD/NFKD,
where the guards remain) removed two branches from the hot loop, and the
ASCII accent-starter shortcut trimmed the segment path further. The run now
reads two scalars with one 64-bit load, consumes an odd trailing scalar in
place, and bridges spaces without returning to the main dispatch, so a whole
Georgian or Ethiopic phrase stays in one loop; `isNormalized` uses the same
scan. The row now sits at 0.239 ns/B against ICU's 0.379 (1.59x). Every fair
row in this document is ahead of ICU.
