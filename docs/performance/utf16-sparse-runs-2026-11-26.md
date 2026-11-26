# Sparse mixed runs and irregular UTF conversion, 2026-11-26

Strict native-endian UTF-16→UTF-8 conversion now selects a dedicated ASCII
run loop for long buffers whose entry window has high ASCII density, while
dense mixed text keeps a smaller packing loop. Eligible mixed runs consume
their BMP prefix and next surrogate pair in one iteration.

The sparse 4 KiB reuse row falls from 826.542 to 481.019 ns/op
(1.72x), and sparse 64 KiB falls from 19948.632 to
8853.522 ns/op (2.25x). Complete results retain all
allocating and caller-buffer rows, including remaining external gaps.
This profile exceeds both simdutf 9.5.0 and ICU 78.3 in 49/52 reuse rows.
The broader industry-best objective remains active.

## Method and provenance

- Intel Core i9-13900K, logical CPU 2, Linux x86-64. Zig 0.16.0 ReleaseFast
  native; unchanged external GCC 13 `-O3 -std=c++17` harness, simdutf 9.5.0
  `haswell`, ICU 78.3.
- The seventeen established phrase/tail inputs remain. Nine additional
  fixed-seed inputs cover random widths, frequent BMP/surrogate transitions,
  sparse non-ASCII content, and surrogate-heavy text, up to 64 KiB.
- Five rounds, five trials per row, a target of 8 MiB of original UTF-8 bytes
  per trial, and at least 2,000 calls. Thus 64 KiB rows process about 125 MiB
  per trial. Tables report the minimum ns/op across the rounds. All samples
  retain timing variation from other workstation activity.
- Libraries run sequentially for each input on CPU 2 in
  icuz/external/95bb5bc/854fca0 order, reversed in alternate rounds. This
  task's compilation and tests finish before sampling.
- Owned rows validate, size, allocate exact output, convert, and free it.
  Reuse rows convert strictly into warmed caller buffers. Only reuse rows
  are compared with the external caller-buffer APIs.
- Native binaries compare output with independent std conversion; the
  external harness checks status, length, and contents. The driver verifies
  every required row, original UTF-8 byte count, and output size.
- `95bb5bc` and `854fca0` source archives were rebuilt with the same current
  file-driven benchmark. Its four allocating/reuse measurement functions are
  explicitly outlined to prevent unrelated conversion branches from sharing
  one large main-function register allocation. The function call is outside
  the timed interval; conversion loops, contents, trial counts, and contracts
  remain identical. The external harness and its hash remain unchanged from
  the [preceding packing profile](utf16-packing-2026-11-26.json). simdutf source
  commit: `9064366fa571fac03bcd28db35af597e97fba842`.
- [Raw profile](utf16-sparse-runs-2026-11-26.json) records all samples, exact
  input byte/unit counts, input/binary/current-source hashes, and version
  strings. `baseline` means `95bb5bc`; `reference` means `854fca0`.

## Irregular corpus

[corpus.py](../../bench/utf16/corpus.py) keeps generation separate from the
comparison driver. Each family has a fixed seed and scalar values vary across
the full valid width ranges. Three-byte values exclude surrogate code points;
four-byte values cover all supplementary planes. ASCII includes NUL and other
controls, and both native and external APIs receive explicit input lengths.
The minimum names describe UTF-8 sizes; final scalars may exceed the minimum.

| Family | Seed | Sizes | Width/run distribution |
|---|---|---|---|
| random | 0x1c0201 | 128, 4096, 65536 | 50% ASCII, 20% two-byte, 20% three-byte, 10% four-byte |
| transitions | 0x1c0202 | 4096, 65536 | 1–15 BMP scalars followed by 1–3 supplementary scalars |
| sparse | 0x1c0203 | 4096, 65536 | 32–255 ASCII scalars followed by 2–8 non-ASCII scalars |
| surrogate-heavy | 0x1c0204 | 4096, 65536 | 1–4 BMP scalars followed by 2–8 supplementary scalars |

## Implementation and validation

[bmp_encode.zig](../../src/unicode/utf/convert/bmp_encode.zig) owns local
run selection and packing; the general converter remains separate.

For mixed buffers with at least 256 remaining UTF-16 units, a 32-unit entry
sample selects the sparse loop when at least 24 units are ASCII. This is one
selection per local mixed run. The dense specialization removes the ASCII
run logic at compile time, protecting short and dense text from repeated
wide-window checks. Checked buffers shorter than 256 units retain the
preceding scalar-first loop. If a long entry sample contains at least 16
surrogate units, that loop is also kept for checked input and for prevalidated
buffers shorter than 8,192 units. Larger prevalidated pair-dense buffers keep
the merged prefix path. These selections protect both caller-buffer and owned
rows after the first complete profile exposed their different regressions.

The sparse loop proves a complete 32-unit ASCII span before copying it and
resuming the shared ASCII kernel from that known prefix. The larger ASCII
loop stays in a separate function to keep its constants and control flow
out of BMP packing. Its partial-window endpoint body is inlined locally,
removing another call at the end of each ASCII run. Initial-prefix conversion
keeps its existing outlined endpoint path.

In the merged loop, a BMP window containing a surrogate consumes its full proven
BMP prefix: four units use existing packing, and any remaining prefix units
use scalar writes. It then validates and encodes the next surrogate pair in
the same iteration. A two-pair load is made only when four units remain.
Output prefixes, invalid-input behavior, exact owned sizes, native endianness,
and bounded non-LLVM array loads remain covered by the existing oracles.

The guarded-buffer test now directly exercises resumed ASCII conversion for
all lengths 32–257 and every subsequent stop position, including a completely
ASCII tail. Both input and exact output ends are placed before guard pages;
a six-byte existing prefix is checked after every call. This gives 25,651
resumed shapes in Debug and ReleaseSafe. Existing complete scalar/surrogate,
BMP width-pattern, 65,536 mixed width-tuple, OOM, and malformed-input tests also
pass. A new owner-module oracle replaces each of the first 512 units in a
long surrogate-heavy buffer with all four high/low boundary values. It checks
valid checked/prevalidated output against std in exact and spare capacities,
and malformed neighbors preserve the existing prefix. A second long oracle
covers eight consecutive pairs and invalid neighbors at pair/window boundaries.
Their AVX2-only owner paths are skipped by the baseline target; the public
fallback tests still run.
AArch64 and big-endian PowerPC64 checks compile rather than execute.

Diagnostic ASCII-loop variants that checked every dense window regressed the
original large mixed row to roughly 1.43–1.51 µs. They were removed. The entry
selection keeps the dedicated loop's gains without carrying those checks in
the dense specialization. Allocation and reuse measurements are both retained
below, so caller-buffer gains do not stand in for owned-API evidence.

The original pair loop is generated directly with 64-byte entries for
short/smaller buffers and 16-byte entries for large checked pair-dense runs.
Both use one source body, without another error-result wrapper. Mixed
UTF-16 runs use 64-byte entries.

UTF-8 window metadata and entry-layout experiments did not preserve all
short and large rows, so the UTF-8→UTF-16 implementation was restored exactly
to `95bb5bc`. Outlining the four benchmark functions removes cross-direction
main-function coupling from the comparison. All rows remain visible after
rebuilding every native binary with that same harness.

## Owned output comparison

Speedup is `95bb5bc/current`; each row includes allocation and free.

| Corpus | Direction | Current ns | 95bb5bc ns | 854fca0 ns | vs 95bb5bc |
|---|---|---:|---:|---:|---:|
| ascii-32 | utf8-to-utf16 | 26.675 | 26.664 | 26.712 | 1.00x |
| ascii-32 | utf16-to-utf8 | 20.080 | 20.079 | 20.093 | 1.00x |
| ascii-128 | utf8-to-utf16 | 27.594 | 27.282 | 27.769 | 0.99x |
| ascii-128 | utf16-to-utf8 | 24.777 | 24.730 | 24.788 | 1.00x |
| ascii-4096 | utf8-to-utf16 | 242.952 | 241.583 | 239.806 | 0.99x |
| ascii-4096 | utf16-to-utf8 | 289.469 | 295.097 | 295.520 | 1.02x |
| latin-32 | utf8-to-utf16 | 52.620 | 52.453 | 52.354 | 1.00x |
| latin-32 | utf16-to-utf8 | 32.264 | 32.420 | 32.664 | 1.00x |
| latin-128 | utf8-to-utf16 | 94.821 | 94.519 | 94.451 | 1.00x |
| latin-128 | utf16-to-utf8 | 51.433 | 50.584 | 53.111 | 0.98x |
| latin-4096 | utf8-to-utf16 | 1759.092 | 1756.814 | 1760.572 | 1.00x |
| latin-4096 | utf16-to-utf8 | 886.590 | 885.177 | 944.783 | 1.00x |
| chinese-32 | utf8-to-utf16 | 26.155 | 26.137 | 26.187 | 1.00x |
| chinese-32 | utf16-to-utf8 | 23.119 | 23.112 | 23.097 | 1.00x |
| chinese-128 | utf8-to-utf16 | 34.995 | 34.981 | 34.948 | 1.00x |
| chinese-128 | utf16-to-utf8 | 23.059 | 23.066 | 23.106 | 1.00x |
| chinese-4096 | utf8-to-utf16 | 553.213 | 550.585 | 554.572 | 1.00x |
| chinese-4096 | utf16-to-utf8 | 379.654 | 379.875 | 380.303 | 1.00x |
| mixed-32 | utf8-to-utf16 | 74.770 | 72.164 | 75.524 | 0.97x |
| mixed-32 | utf16-to-utf8 | 53.346 | 54.816 | 56.389 | 1.03x |
| mixed-128 | utf8-to-utf16 | 127.195 | 125.285 | 128.079 | 0.98x |
| mixed-128 | utf16-to-utf8 | 90.977 | 93.224 | 96.186 | 1.02x |
| mixed-4096 | utf8-to-utf16 | 2083.762 | 2075.342 | 2079.806 | 1.00x |
| mixed-4096 | utf16-to-utf8 | 1461.968 | 1475.133 | 1519.141 | 1.01x |
| emoji-32 | utf8-to-utf16 | 29.658 | 29.647 | 29.639 | 1.00x |
| emoji-32 | utf16-to-utf8 | 22.124 | 22.115 | 22.642 | 1.00x |
| emoji-128 | utf8-to-utf16 | 47.673 | 47.174 | 47.198 | 0.99x |
| emoji-128 | utf16-to-utf8 | 35.916 | 34.940 | 35.677 | 0.97x |
| emoji-4096 | utf8-to-utf16 | 827.748 | 821.856 | 827.565 | 0.99x |
| emoji-4096 | utf16-to-utf8 | 702.998 | 701.469 | 721.866 | 1.00x |
| tiny-ascii-31 | utf8-to-utf16 | 29.275 | 29.101 | 29.282 | 0.99x |
| tiny-ascii-31 | utf16-to-utf8 | 21.842 | 21.827 | 21.814 | 1.00x |
| tiny-emoji-31 | utf8-to-utf16 | 20.643 | 20.678 | 20.664 | 1.00x |
| tiny-emoji-31 | utf16-to-utf8 | 17.603 | 17.582 | 17.579 | 1.00x |
| mixed-random-128 | utf8-to-utf16 | 88.640 | 83.795 | 88.299 | 0.95x |
| mixed-random-128 | utf16-to-utf8 | 78.477 | 80.616 | 82.848 | 1.03x |
| mixed-random-4096 | utf8-to-utf16 | 2205.281 | 2190.808 | 2202.108 | 0.99x |
| mixed-random-4096 | utf16-to-utf8 | 1852.967 | 1913.067 | 1992.929 | 1.03x |
| mixed-random-65536 | utf8-to-utf16 | 65876.143 | 73396.780 | 65867.258 | 1.11x |
| mixed-random-65536 | utf16-to-utf8 | 79790.905 | 94667.451 | 91197.111 | 1.19x |
| mixed-transitions-4096 | utf8-to-utf16 | 2050.560 | 2048.499 | 2056.055 | 1.00x |
| mixed-transitions-4096 | utf16-to-utf8 | 1743.553 | 1811.536 | 1873.977 | 1.04x |
| mixed-transitions-65536 | utf8-to-utf16 | 54146.884 | 58158.017 | 54248.590 | 1.07x |
| mixed-transitions-65536 | utf16-to-utf8 | 69768.850 | 74380.477 | 77655.371 | 1.07x |
| mixed-sparse-4096 | utf8-to-utf16 | 653.745 | 636.825 | 661.370 | 0.97x |
| mixed-sparse-4096 | utf16-to-utf8 | 726.094 | 1066.068 | 1033.575 | 1.47x |
| mixed-sparse-65536 | utf8-to-utf16 | 39094.003 | 38592.015 | 39309.270 | 0.99x |
| mixed-sparse-65536 | utf16-to-utf8 | 28890.465 | 40595.442 | 40440.007 | 1.41x |
| mixed-surrogate-heavy-4096 | utf8-to-utf16 | 1942.805 | 1941.715 | 1944.192 | 1.00x |
| mixed-surrogate-heavy-4096 | utf16-to-utf8 | 1708.429 | 1719.445 | 1884.070 | 1.01x |
| mixed-surrogate-heavy-65536 | utf8-to-utf16 | 48824.651 | 49917.068 | 48969.580 | 1.02x |
| mixed-surrogate-heavy-65536 | utf16-to-utf8 | 66463.444 | 62448.967 | 72553.883 | 0.94x |

## Warmed caller-buffer comparison

Speedups are `95bb5bc/current` and `simdutf/current`; below one means current
icuz takes longer. Both directions remain visible, including code-layout
variation in UTF-8 conversion.

| Corpus | Direction | Current ns | 95bb5bc ns | 854fca0 ns | simdutf ns | ICU ns | vs 95bb5bc | vs simdutf |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| ascii-32 | utf8-to-utf16 | 4.510 | 4.521 | 4.520 | 12.444 | 36.948 | 1.00x | 2.76x |
| ascii-32 | utf16-to-utf8 | 3.508 | 3.508 | 3.508 | 10.427 | 37.784 | 1.00x | 2.97x |
| ascii-128 | utf8-to-utf16 | 6.517 | 7.016 | 6.518 | 9.942 | 94.712 | 1.08x | 1.53x |
| ascii-128 | utf16-to-utf8 | 6.775 | 6.782 | 6.772 | 13.780 | 92.625 | 1.00x | 2.03x |
| ascii-4096 | utf8-to-utf16 | 97.223 | 97.213 | 99.582 | 110.758 | 2099.058 | 1.00x | 1.14x |
| ascii-4096 | utf16-to-utf8 | 112.148 | 112.032 | 112.149 | 198.227 | 2038.317 | 1.00x | 1.77x |
| latin-32 | utf8-to-utf16 | 35.814 | 36.158 | 35.842 | 38.727 | 38.199 | 1.01x | 1.08x |
| latin-32 | utf16-to-utf8 | 12.552 | 12.555 | 12.809 | 23.497 | 27.903 | 1.00x | 1.87x |
| latin-128 | utf8-to-utf16 | 69.198 | 68.534 | 68.975 | 85.971 | 91.903 | 0.99x | 1.24x |
| latin-128 | utf16-to-utf8 | 23.492 | 23.558 | 25.595 | 35.245 | 70.496 | 1.00x | 1.50x |
| latin-4096 | utf8-to-utf16 | 1530.032 | 1521.647 | 1531.416 | 1896.565 | 2177.619 | 0.99x | 1.24x |
| latin-4096 | utf16-to-utf8 | 468.477 | 468.494 | 526.421 | 613.515 | 1675.075 | 1.00x | 1.31x |
| chinese-32 | utf8-to-utf16 | 13.744 | 12.953 | 12.809 | 23.186 | 23.786 | 0.94x | 1.69x |
| chinese-32 | utf16-to-utf8 | 9.860 | 11.171 | 10.097 | 18.222 | 18.702 | 1.13x | 1.85x |
| chinese-128 | utf8-to-utf16 | 13.654 | 13.677 | 13.641 | 84.271 | 87.329 | 1.00x | 6.17x |
| chinese-128 | utf16-to-utf8 | 10.709 | 11.275 | 10.721 | 32.455 | 63.516 | 1.05x | 3.03x |
| chinese-4096 | utf8-to-utf16 | 359.940 | 362.133 | 359.400 | 948.158 | 2077.279 | 1.01x | 2.63x |
| chinese-4096 | utf16-to-utf8 | 271.288 | 274.367 | 271.181 | 407.357 | 1389.278 | 1.01x | 1.50x |
| mixed-32 | utf8-to-utf16 | 55.915 | 57.455 | 55.314 | 68.315 | 66.437 | 1.03x | 1.22x |
| mixed-32 | utf16-to-utf8 | 39.233 | 39.534 | 39.892 | 47.001 | 50.044 | 1.01x | 1.20x |
| mixed-128 | utf8-to-utf16 | 101.085 | 103.904 | 100.684 | 121.223 | 124.595 | 1.03x | 1.20x |
| mixed-128 | utf16-to-utf8 | 67.409 | 67.504 | 68.408 | 77.108 | 92.492 | 1.00x | 1.14x |
| mixed-4096 | utf8-to-utf16 | 1839.033 | 1842.823 | 1836.004 | 1918.918 | 2266.242 | 1.00x | 1.04x |
| mixed-4096 | utf16-to-utf8 | 1129.133 | 1125.139 | 1146.360 | 1031.346 | 1642.650 | 1.00x | 0.91x |
| emoji-32 | utf8-to-utf16 | 12.983 | 12.554 | 12.466 | 31.201 | 56.294 | 0.97x | 2.40x |
| emoji-32 | utf16-to-utf8 | 9.705 | 10.529 | 10.674 | 28.641 | 28.524 | 1.08x | 2.95x |
| emoji-128 | utf8-to-utf16 | 26.673 | 26.488 | 26.441 | 99.239 | 152.422 | 0.99x | 3.72x |
| emoji-128 | utf16-to-utf8 | 18.044 | 18.813 | 19.685 | 73.264 | 78.185 | 1.04x | 4.06x |
| emoji-4096 | utf8-to-utf16 | 593.927 | 587.814 | 593.135 | 2344.607 | 3669.585 | 0.99x | 3.95x |
| emoji-4096 | utf16-to-utf8 | 396.715 | 398.773 | 407.574 | 1963.391 | 1950.857 | 1.01x | 4.95x |
| tiny-ascii-31 | utf8-to-utf16 | 5.269 | 5.268 | 5.269 | 11.843 | 24.031 | 1.00x | 2.25x |
| tiny-ascii-31 | utf16-to-utf8 | 3.515 | 3.508 | 3.509 | 11.380 | 22.395 | 1.00x | 3.24x |
| tiny-emoji-31 | utf8-to-utf16 | 5.381 | 5.369 | 5.365 | 21.945 | 37.934 | 1.00x | 4.08x |
| tiny-emoji-31 | utf16-to-utf8 | 5.051 | 5.032 | 5.274 | 19.479 | 21.236 | 1.00x | 3.86x |
| mixed-random-128 | utf8-to-utf16 | 70.970 | 74.386 | 70.931 | 84.670 | 89.069 | 1.05x | 1.19x |
| mixed-random-128 | utf16-to-utf8 | 63.353 | 67.515 | 64.759 | 65.601 | 64.183 | 1.07x | 1.04x |
| mixed-random-4096 | utf8-to-utf16 | 2021.152 | 2021.076 | 2027.577 | 2509.885 | 2426.636 | 1.00x | 1.24x |
| mixed-random-4096 | utf16-to-utf8 | 1531.455 | 1589.287 | 1578.942 | 2030.124 | 1819.904 | 1.04x | 1.33x |
| mixed-random-65536 | utf8-to-utf16 | 52514.850 | 43785.725 | 52725.043 | 61901.419 | 221323.622 | 0.83x | 1.18x |
| mixed-random-65536 | utf16-to-utf8 | 57256.933 | 64261.230 | 63723.638 | 154466.076 | 182696.309 | 1.12x | 2.70x |
| mixed-transitions-4096 | utf8-to-utf16 | 1893.251 | 1895.449 | 1902.882 | 2350.284 | 2543.521 | 1.00x | 1.24x |
| mixed-transitions-4096 | utf16-to-utf8 | 1419.051 | 1526.821 | 1495.695 | 2130.356 | 1840.731 | 1.08x | 1.50x |
| mixed-transitions-65536 | utf8-to-utf16 | 46792.147 | 35583.462 | 45734.260 | 49238.920 | 169943.602 | 0.76x | 1.05x |
| mixed-transitions-65536 | utf16-to-utf8 | 41395.424 | 46001.999 | 48830.859 | 140423.381 | 135657.609 | 1.11x | 3.39x |
| mixed-sparse-4096 | utf8-to-utf16 | 421.850 | 424.530 | 414.986 | 622.544 | 2178.444 | 1.01x | 1.48x |
| mixed-sparse-4096 | utf16-to-utf8 | 481.019 | 826.542 | 818.493 | 372.986 | 2062.451 | 1.72x | 0.78x |
| mixed-sparse-65536 | utf8-to-utf16 | 7450.248 | 7482.036 | 7342.711 | 11136.947 | 43487.874 | 1.00x | 1.49x |
| mixed-sparse-65536 | utf16-to-utf8 | 8853.522 | 19948.632 | 19190.255 | 6374.824 | 39761.069 | 2.25x | 0.72x |
| mixed-surrogate-heavy-4096 | utf8-to-utf16 | 1814.728 | 1814.775 | 1814.938 | 2569.629 | 3207.511 | 1.00x | 1.42x |
| mixed-surrogate-heavy-4096 | utf16-to-utf8 | 1304.907 | 1323.939 | 1376.518 | 1836.833 | 1793.699 | 1.01x | 1.41x |
| mixed-surrogate-heavy-65536 | utf8-to-utf16 | 30925.225 | 29879.692 | 30531.009 | 41098.460 | 101282.764 | 0.97x | 1.33x |
| mixed-surrogate-heavy-65536 | utf16-to-utf8 | 24529.859 | 29740.209 | 32813.863 | 66395.489 | 70235.826 | 1.21x | 2.71x |

## Predecessor regressions

Rows more than 5% slower than `95bb5bc` remain unresolved optimization work.
The unchanged UTF-8 implementation still shows a large random caller-buffer
regression in the diagnostic profiles. Restoring its source, changing entry
alignment, and isolating the measurement functions did not remove it. The
current evidence does not identify a single cause; these rows remain explicit
rather than treating the selected improvements as completion.

| Corpus | Direction | Contract | 95bb5bc ns | Current ns | Extra time |
|---|---|---|---:|---:|---:|
| chinese-32 | utf8-to-utf16 | reuse | 12.953 | 13.744 | 6.1% |
| mixed-random-128 | utf8-to-utf16 | alloc | 83.795 | 88.640 | 5.8% |
| mixed-random-65536 | utf8-to-utf16 | reuse | 43785.725 | 52514.850 | 19.9% |
| mixed-transitions-65536 | utf8-to-utf16 | reuse | 35583.462 | 46792.147 | 31.5% |
| mixed-surrogate-heavy-65536 | utf16-to-utf8 | alloc | 62448.967 | 66463.444 | 6.4% |

## Remaining work

These reuse rows still take longer than the fastest external API:

| Corpus | Direction | Current ns | Fastest external ns | Extra time |
|---|---|---:|---:|---:|
| mixed-4096 | utf16-to-utf8 | 1129.133 | 1031.346 | 9.5% |
| mixed-sparse-4096 | utf16-to-utf8 | 481.019 | 372.986 | 29.0% |
| mixed-sparse-65536 | utf16-to-utf8 | 8853.522 | 6374.824 | 38.9% |

Entry-density selection can miss later changes between dense and sparse
paragraphs. Those phase changes need additional corpus coverage and adaptive
selection evidence. The remaining sparse gap, the original large mixed gap,
broader APIs, and other hardware stay in the full optimization objective.

## Reproduce

Use the [external build commands](utf16-conversion-2026-11-26.md#reproduce),
then build the current and preserved source revisions with the same harness:

```sh
zig build bench-utf16-build
for revision in 95bb5bc 854fca0; do
  revision_dir="/tmp/icuz-sparse-$revision"
  mkdir -p "$revision_dir"
  git archive "$revision" src/unicode/utf16.zig src/unicode/utf src/unicode/scalar | tar -x -C "$revision_dir"
  zig build-exe -O ReleaseFast -lc --dep utf16 -Mroot=bench/utf16/bench.zig \
    -O ReleaseFast -Mutf16="$revision_dir/src/unicode/utf16.zig" \
    -femit-bin="/tmp/icuz-sparse-$revision-rebuilt"
done
python3 bench/utf16/compare.py --icuz zig-out/bin/icuz-utf16-bench \
  --baseline /tmp/icuz-sparse-95bb5bc-rebuilt --baseline-reuse \
  --reference /tmp/icuz-sparse-854fca0-rebuilt \
  --external /tmp/icuz-transcode-external --cpu 2 --rounds 5 --interleave-cases \
  --output /tmp/icuz-sparse-reproduced.json
```

The driver defaults to all 26 corpora. For a focused diagnostic, repeat exact
`--case` names, for example `--case mixed-sparse-4096 --case mixed-4096`.

## Final gates

- Native ReleaseSafe UTF module: 28/28 passed.
- Baseline x86-64 ReleaseSafe UTF module: 26 passed, two AVX2 owner tests skipped.
- Debug guarded buffers: 4/4 passed, including all resumed ASCII shapes.
- AArch64 and big-endian PowerPC64 ReleaseSafe compile-only checks passed.
- Full library ReleaseSafe: 4/4 steps succeeded, 538/538 tests passed.
- Unicode verifier: 431 blobs, 34 generated sources, 3 generated bitmaps,
  and 134 generators verified.
- Formatting, patch whitespace, complete profile row/content validation,
  and final source/binary hash audits passed.

```sh
zig test src/unicode/utf16.zig -O ReleaseSafe --test-filter UTF
zig test src/unicode/utf16.zig -O ReleaseSafe -target x86_64-linux-gnu -mcpu baseline --test-filter UTF
zig test src/unicode/utf16.zig -O Debug --test-filter guarded
zig test src/unicode/utf16.zig -O ReleaseSafe -target aarch64-linux-gnu -fno-emit-bin --test-filter UTF
zig test src/unicode/utf16.zig -O ReleaseSafe -target powerpc64-linux-gnu -fno-emit-bin --test-filter UTF
zig build test -Doptimize=ReleaseSafe --summary all
zig build unicode-verify
```
