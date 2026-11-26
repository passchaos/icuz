# Variable-width UTF conversion profile, 2026-11-26

This follow-up compares the allocating and reusable conversion APIs directly
with `7f3939c`. It adds a one/two-byte UTF-8 run decoder, sixteen-unit Latin-1
encoding, and continuous mixed-width BMP encoding. The public native-endian
API contracts and prefix-preserving error behavior are unchanged.

## Method and provenance

- Intel Core i9-13900K, logical CPU 2, Linux x86-64; Zig 0.16.0 ReleaseFast
  native. The external binary uses GCC 13 `-O3 -std=c++17`, simdutf 9.5.0
  (`haswell`), and ICU 78.3.
- Seventeen identical files cover ASCII, accented Latin, Chinese, mixed
  scripts/emoji, pure emoji, and short tails around 31 bytes. The 32/128/4096 labels
  are minimum UTF-8 corpus sizes; exact bytes and native UTF-16 unit counts
  are recorded in the JSON.
- Five rounds, five trials per row, about 8 MiB of original UTF-8 corpus
  bytes per trial, and at least 2,000 calls. Tables show the minimum ns/op
  across the recorded rounds; lower is faster.
- For each corpus, libraries run sequentially on CPU 2: icuz/external/baseline
  in even-numbered rounds, reversed in odd-numbered rounds. Compilation and
  this task's tests finish before sampling. Other workstation activity was
  still present; the JSON retains every round so load variation is visible.
- Allocating rows produce and free exactly sized owned outputs. Reuse rows
  use warmed caller buffers and perform strict validation during conversion.
  simdutf and ICU rows use the same strict caller-buffer contract. Their
  timings are compared only with icuz reuse rows.
- Both icuz binaries check output contents against the independent std
  conversion; the external harness checks conversion contents, status, and
  length. The driver checks all required rows, input lengths, and output sizes.
- The predecessor is a preserved binary whose SHA-256 equals the previous
  profile's current icuz binary. The external SHA-256 also equals that profile.
  simdutf source commit: `9064366fa571fac03bcd28db35af597e97fba842`.
- [Raw profile](utf16-variable-width-2026-11-26.json) records input, binary,
  conversion/validation source, shared corpus driver, and build-file hashes.

## Kernel changes

The UTF-8 fast path decodes eight variable-width ASCII/two-byte scalars with
a 256-entry shuffle table. BMI2 `pext` compacts lead-width bits at scalar
starts; one `vpshufb` pairs each lead with its continuation. Checked conversion
verifies continuation placement and rejects C0/C1. A local run loop consumes
compatible windows and directly widens complete ASCII windows. It requires
LLVM, x86-64 AVX/SSSE3/BMI2 and falls back to the existing portable converter.
Inputs below 32 bytes retain the existing block/tail path.

The UTF-16 path encodes sixteen Latin-1 units in two eight-unit AVX2 lanes,
and consumes a continuous run without repeating the general dispatch. Mixed
BMP conversion finds the first surrogate in each eight-unit span and hands
it back to the surrogate decoder. Two adjacent movemask bits directly encode
each BMP width; the shuffle control also stores its output length. Shared
lane stores use bounded copies at exact output ends. The portable fixed-width
kernels remain available; AVX2 gates the wide packing path.

Thin dispatch wrappers are inline. Small checked conversion stays in the
caller; large general conversion and run consumers retain their local loop
state. Nearby packing tests now live in `src/unicode/utf/convert/packing_tests.zig`,
while buffer/error and validation tests remain in `src/unicode/utf/tests.zig`.

## Allocating API comparison

Speedup is predecessor/current. These rows include validation, sizing,
allocation, conversion, and freeing the owned output.

| Corpus | Direction | Current ns | 7f3939c ns | Speedup |
|---|---|---:|---:|---:|
| ascii-32 | utf8-to-utf16 | 26.669 | 23.909 | 0.90x |
| ascii-32 | utf16-to-utf8 | 25.291 | 22.994 | 0.91x |
| ascii-128 | utf8-to-utf16 | 27.921 | 24.627 | 0.88x |
| ascii-128 | utf16-to-utf8 | 30.984 | 28.974 | 0.94x |
| ascii-4096 | utf8-to-utf16 | 242.569 | 235.523 | 0.97x |
| ascii-4096 | utf16-to-utf8 | 344.700 | 350.215 | 1.02x |
| latin-32 | utf8-to-utf16 | 52.881 | 62.065 | 1.17x |
| latin-32 | utf16-to-utf8 | 32.855 | 36.631 | 1.11x |
| latin-128 | utf8-to-utf16 | 129.329 | 157.006 | 1.21x |
| latin-128 | utf16-to-utf8 | 53.358 | 76.117 | 1.43x |
| latin-4096 | utf8-to-utf16 | 2964.769 | 3438.702 | 1.16x |
| latin-4096 | utf16-to-utf8 | 942.818 | 1650.673 | 1.75x |
| chinese-32 | utf8-to-utf16 | 26.223 | 23.738 | 0.91x |
| chinese-32 | utf16-to-utf8 | 23.862 | 24.202 | 1.01x |
| chinese-128 | utf8-to-utf16 | 34.624 | 31.605 | 0.91x |
| chinese-128 | utf16-to-utf8 | 23.207 | 22.699 | 0.98x |
| chinese-4096 | utf8-to-utf16 | 554.691 | 550.609 | 0.99x |
| chinese-4096 | utf16-to-utf8 | 380.495 | 371.626 | 0.98x |
| mixed-32 | utf8-to-utf16 | 91.314 | 94.609 | 1.04x |
| mixed-32 | utf16-to-utf8 | 66.132 | 83.955 | 1.27x |
| mixed-128 | utf8-to-utf16 | 167.907 | 171.308 | 1.02x |
| mixed-128 | utf16-to-utf8 | 116.439 | 164.311 | 1.41x |
| mixed-4096 | utf8-to-utf16 | 2680.549 | 2964.540 | 1.11x |
| mixed-4096 | utf16-to-utf8 | 1962.650 | 3071.489 | 1.56x |
| emoji-32 | utf8-to-utf16 | 29.879 | 27.419 | 0.92x |
| emoji-32 | utf16-to-utf8 | 23.218 | 22.772 | 0.98x |
| emoji-128 | utf8-to-utf16 | 46.458 | 43.598 | 0.94x |
| emoji-128 | utf16-to-utf8 | 36.622 | 34.548 | 0.94x |
| emoji-4096 | utf8-to-utf16 | 825.477 | 823.628 | 1.00x |
| emoji-4096 | utf16-to-utf8 | 717.008 | 706.198 | 0.98x |
| tiny-ascii-31 | utf8-to-utf16 | 29.136 | 27.161 | 0.93x |
| tiny-ascii-31 | utf16-to-utf8 | 28.033 | 27.330 | 0.97x |
| tiny-emoji-31 | utf8-to-utf16 | 20.897 | 18.684 | 0.89x |
| tiny-emoji-31 | utf16-to-utf8 | 18.087 | 18.050 | 1.00x |

## Reusable caller-buffer comparison

Speedup columns are predecessor/current and simdutf/current respectively.
A speedup below 1 means current icuz takes longer.

| Corpus | Direction | Current ns | 7f3939c ns | simdutf ns | ICU ns | vs previous | vs simdutf |
|---|---|---:|---:|---:|---:|---:|---:|
| ascii-32 | utf8-to-utf16 | 4.761 | 4.510 | 12.474 | 36.905 | 0.95x | 2.62x |
| ascii-32 | utf16-to-utf8 | 8.783 | 5.608 | 10.428 | 35.229 | 0.64x | 1.19x |
| ascii-128 | utf8-to-utf16 | 7.016 | 6.325 | 9.897 | 95.071 | 0.90x | 1.41x |
| ascii-128 | utf16-to-utf8 | 11.776 | 8.779 | 13.806 | 92.625 | 0.75x | 1.17x |
| ascii-4096 | utf8-to-utf16 | 98.023 | 97.215 | 110.741 | 2097.468 | 0.99x | 1.13x |
| ascii-4096 | utf16-to-utf8 | 152.110 | 140.370 | 198.136 | 2087.411 | 0.92x | 1.30x |
| latin-32 | utf8-to-utf16 | 37.104 | 47.115 | 38.470 | 37.967 | 1.27x | 1.04x |
| latin-32 | utf16-to-utf8 | 12.055 | 17.557 | 23.550 | 28.189 | 1.46x | 1.95x |
| latin-128 | utf8-to-utf16 | 110.999 | 126.412 | 87.504 | 91.854 | 1.14x | 0.79x |
| latin-128 | utf16-to-utf8 | 24.655 | 49.618 | 35.196 | 69.761 | 2.01x | 1.43x |
| latin-4096 | utf8-to-utf16 | 2731.875 | 3201.775 | 1897.721 | 2173.634 | 1.17x | 0.69x |
| latin-4096 | utf16-to-utf8 | 527.555 | 1301.139 | 615.877 | 1646.834 | 2.47x | 1.17x |
| chinese-32 | utf8-to-utf16 | 12.136 | 12.898 | 23.349 | 23.760 | 1.06x | 1.92x |
| chinese-32 | utf16-to-utf8 | 10.152 | 9.313 | 18.138 | 18.776 | 0.92x | 1.79x |
| chinese-128 | utf8-to-utf16 | 13.375 | 12.903 | 81.793 | 87.668 | 0.96x | 6.12x |
| chinese-128 | utf16-to-utf8 | 10.615 | 10.185 | 32.475 | 63.357 | 0.96x | 3.06x |
| chinese-4096 | utf8-to-utf16 | 358.568 | 358.331 | 948.565 | 2077.005 | 1.00x | 2.65x |
| chinese-4096 | utf16-to-utf8 | 271.233 | 255.975 | 408.417 | 1388.570 | 0.94x | 1.51x |
| mixed-32 | utf8-to-utf16 | 84.351 | 87.606 | 68.209 | 67.186 | 1.04x | 0.81x |
| mixed-32 | utf16-to-utf8 | 47.631 | 67.572 | 46.796 | 49.853 | 1.42x | 0.98x |
| mixed-128 | utf8-to-utf16 | 161.686 | 160.746 | 121.371 | 124.164 | 0.99x | 0.75x |
| mixed-128 | utf16-to-utf8 | 87.970 | 139.844 | 75.783 | 90.946 | 1.59x | 0.86x |
| mixed-4096 | utf8-to-utf16 | 2372.094 | 2990.303 | 1920.672 | 2262.081 | 1.26x | 0.81x |
| mixed-4096 | utf16-to-utf8 | 1658.759 | 2807.067 | 1029.414 | 1640.537 | 1.69x | 0.62x |
| emoji-32 | utf8-to-utf16 | 12.607 | 12.240 | 31.269 | 54.703 | 0.97x | 2.48x |
| emoji-32 | utf16-to-utf8 | 9.485 | 9.652 | 29.114 | 28.528 | 1.02x | 3.07x |
| emoji-128 | utf8-to-utf16 | 26.227 | 25.745 | 99.321 | 151.662 | 0.98x | 3.79x |
| emoji-128 | utf16-to-utf8 | 18.423 | 17.850 | 73.427 | 82.247 | 0.97x | 3.99x |
| emoji-4096 | utf8-to-utf16 | 585.212 | 584.705 | 2347.319 | 3670.721 | 1.00x | 4.01x |
| emoji-4096 | utf16-to-utf8 | 401.668 | 390.087 | 1963.773 | 1951.793 | 0.97x | 4.89x |
| tiny-ascii-31 | utf8-to-utf16 | 5.271 | 5.269 | 11.873 | 24.047 | 1.00x | 2.25x |
| tiny-ascii-31 | utf16-to-utf8 | 11.374 | 11.873 | 11.057 | 22.350 | 1.04x | 0.97x |
| tiny-emoji-31 | utf8-to-utf16 | 5.505 | 5.136 | 22.023 | 37.675 | 0.93x | 4.00x |
| tiny-emoji-31 | utf16-to-utf8 | 4.768 | 4.518 | 19.520 | 21.234 | 0.95x | 4.09x |

## Remaining work

This profile does not establish universal leadership. Latin UTF-8→UTF-16
and mixed-text conversion still trail simdutf on the large rows. The large
Latin UTF-16→UTF-8 row exceeds simdutf, but short ASCII UTF-16→UTF-8 adds about
3 ns versus the predecessor, and large ASCII/Chinese UTF-16→UTF-8 retain
about 6–8% overhead. The tables include these regressions, allocating rows,
and the actual short tails. Resolving dispatch/tail cost and mixed-width
decoding remains part of the active optimization goal.

## Reproduce

Use the external build from the [preceding profile](utf16-conversion-2026-11-26.md#reproduce).
Reconstruct the predecessor with the same current benchmark source:

```sh
zig build bench-utf16-build
mkdir -p /tmp/icuz-variable-width-baseline
git archive 7f3939c src/unicode/utf16.zig src/unicode/utf src/unicode/scalar | tar -x -C /tmp/icuz-variable-width-baseline
zig build-exe -O ReleaseFast -lc --dep utf16 -Mroot=bench/utf16/bench.zig \
  -O ReleaseFast -Mutf16=/tmp/icuz-variable-width-baseline/src/unicode/utf16.zig \
  -femit-bin=/tmp/icuz-utf16-7f3939c-rebuilt
python3 bench/utf16/compare.py --icuz zig-out/bin/icuz-utf16-bench \
  --baseline /tmp/icuz-utf16-7f3939c-rebuilt --baseline-reuse \
  --external /tmp/icuz-transcode-external --cpu 2 --rounds 5 --interleave-cases \
  --output /tmp/icuz-variable-width-reproduced.json
```

## Validation

- Native ReleaseSafe UTF module: 18/18 tests passed. Coverage includes every
  Unicode scalar, all 65,536 sixteen-unit Latin width masks, all 6,561
  eight-unit BMP width patterns, all 256 variable-width two-byte patterns,
  every two-byte scalar in variable-width windows, malformed sequences,
  surrogate positions, exact output ends, preserved prefixes, and OOM.
- Debug guarded buffers: 4/4 tests passed.
- Baseline x86-64 ReleaseSafe UTF module: 18/18 tests passed.
- AArch64 and big-endian PowerPC64 ReleaseSafe UTF compilation passed;
  these are compilation checks, using `-fno-emit-bin`.
- Full ReleaseSafe library gate: 4/4 build steps succeeded, 528/528 tests passed.
- `unicode-verify`: verified 431 Unicode blobs, 34 generated sources,
  3 generated bitmaps, and 134 generators.
- All source and binary hashes in the profile matched after validation.

```sh
zig test src/unicode/utf16.zig -O ReleaseSafe --test-filter UTF
zig test src/unicode/utf16.zig -O Debug --test-filter guarded
zig test src/unicode/utf16.zig -O ReleaseSafe -target x86_64-linux-gnu -mcpu baseline --test-filter UTF
zig test src/unicode/utf16.zig -O ReleaseSafe -target aarch64-linux-gnu -fno-emit-bin --test-filter UTF
zig test src/unicode/utf16.zig -O ReleaseSafe -target powerpc64-linux-gnu -fno-emit-bin --test-filter UTF
zig build test -Doptimize=ReleaseSafe --summary all
zig build unicode-verify
```
