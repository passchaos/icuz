# Mixed UTF conversion windows, 2026-11-26

This profile compares strict native-endian UTF conversion with the preceding
`1af201c` and `a611885` implementations. General UTF-8 windows replace repeated
scalar dispatch for mixed scripts; UTF-16 conversion keeps BMP and surrogate
processing in one local run. Allocation and warmed caller buffers remain
separate contracts. The complete tables retain the remaining industry gaps.

## Method and provenance

- Intel Core i9-13900K, logical CPU 2, Linux x86-64; Zig 0.16.0 ReleaseFast
  native. External GCC 13 `-O3 -std=c++17`, simdutf 9.5.0 `haswell`, ICU 78.3.
- Seventeen identical files cover ASCII, accented Latin, Chinese, mixed scripts
  and emoji, pure emoji, and short tails around 31 bytes. Names use minimum
  UTF-8 sizes; exact byte and native UTF-16 unit counts are in the JSON.
- Five rounds and five trials per row, about 8 MiB of original corpus bytes
  per trial and at least 2,000 calls. Tables report the minimum ns/op across
  the recorded rounds. Other workstation activity remains visible in samples.
- For each corpus, libraries run sequentially on CPU 2 in
  icuz/external/1af201c/a611885 order, reversed in alternate rounds. This task's
  compilation and tests finish before sampling.
- Owned rows validate, size, allocate an exact output, convert, and free it.
  Reuse rows perform strict conversion into warmed caller buffers. Only reuse
  rows are compared with simdutf and ICU caller-buffer APIs.
- All native binaries check contents against independent std conversion; the
  external harness checks status, length, and content. The driver also checks
  every required row, input length, and output size.
- Preserved predecessor hashes match the
  [previous profile](utf16-ascii-batches-2026-11-26.json): its current binary is
  `1af201c`, its baseline is `a611885`. The external hash also matches.
  simdutf source commit: `9064366fa571fac03bcd28db35af597e97fba842`.
- [Raw profile](utf16-mixed-windows-2026-11-26.json) records all samples and
  input/binary/current-source hashes. `baseline` means `1af201c`; `reference`
  means `a611885`.

## Implementation

The new mixed UTF-8 path validates a bounded 64-byte prefix using a shared
AVX2 lookup4 helper. Register-created lookbehind keeps reads inside the slice.
The final scalar may extend beyond the prefix and is deferred; existing
conversion handles the remaining tail. Public error behavior still preserves
existing output contents. The lookup4 tables and reference design are covered
by `licenses/simdutf-MIT.txt`.

A generated 12-bit endpoint index selects six ASCII/two-byte scalars or
three/four general scalars. A four-byte index entry stores control, consumed
bytes, and output units as separately loadable fields. The endpoint mask
shifts by each decoded group instead of waiting for the cumulative cursor.
Four-byte scalars become surrogate pairs; exact fixed-size stores replace
dynamic memcpy calls. ASCII groups consume twelve or sixteen bytes directly.
Controls occupy 24 KiB and the index occupies 16 KiB. The AVX2 path is selected
only when the prefix contains mixed non-Latin widths; established uniform
ASCII, Latin, Chinese, and supplementary-scalar paths remain available.

UTF-16 processing stays inside the local run across surrogate boundaries.
A proven four-unit BMP prefix reuses packing without repeating the surrogate
check. Consecutive surrogate pairs use the existing two-pair SIMD kernel;
isolated pairs and short BMP prefixes use bounded scalar writes before the
run resumes. This avoids repeatedly returning to the general dispatch.
Portable fallback paths and non-LLVM bounded loads are retained.

## Owned output comparison

Speedup is predecessor/current. This includes allocating and freeing owned output.

| Corpus | Direction | Current ns | 1af201c ns | a611885 ns | vs 1af201c |
|---|---|---:|---:|---:|---:|
| ascii-32 | utf8-to-utf16 | 26.675 | 26.676 | 26.648 | 1.00x |
| ascii-32 | utf16-to-utf8 | 19.177 | 19.149 | 25.233 | 1.00x |
| ascii-128 | utf8-to-utf16 | 27.924 | 27.538 | 27.415 | 0.99x |
| ascii-128 | utf16-to-utf8 | 25.307 | 25.085 | 30.873 | 0.99x |
| ascii-4096 | utf8-to-utf16 | 239.456 | 243.211 | 241.426 | 1.02x |
| ascii-4096 | utf16-to-utf8 | 290.991 | 295.012 | 345.905 | 1.01x |
| latin-32 | utf8-to-utf16 | 52.223 | 52.500 | 52.780 | 1.01x |
| latin-32 | utf16-to-utf8 | 32.760 | 32.553 | 32.924 | 0.99x |
| latin-128 | utf8-to-utf16 | 94.795 | 94.411 | 129.264 | 1.00x |
| latin-128 | utf16-to-utf8 | 53.648 | 53.430 | 53.293 | 1.00x |
| latin-4096 | utf8-to-utf16 | 1756.050 | 1756.400 | 2962.890 | 1.00x |
| latin-4096 | utf16-to-utf8 | 942.058 | 941.821 | 943.850 | 1.00x |
| chinese-32 | utf8-to-utf16 | 26.201 | 26.446 | 26.213 | 1.01x |
| chinese-32 | utf16-to-utf8 | 23.898 | 23.751 | 23.856 | 0.99x |
| chinese-128 | utf8-to-utf16 | 35.012 | 34.506 | 34.596 | 0.99x |
| chinese-128 | utf16-to-utf8 | 23.144 | 23.173 | 22.991 | 1.00x |
| chinese-4096 | utf8-to-utf16 | 547.662 | 550.601 | 553.505 | 1.01x |
| chinese-4096 | utf16-to-utf8 | 370.739 | 381.326 | 380.579 | 1.03x |
| mixed-32 | utf8-to-utf16 | 72.944 | 88.108 | 91.625 | 1.21x |
| mixed-32 | utf16-to-utf8 | 57.388 | 66.088 | 66.136 | 1.15x |
| mixed-128 | utf8-to-utf16 | 126.135 | 162.264 | 163.978 | 1.29x |
| mixed-128 | utf16-to-utf8 | 97.164 | 117.398 | 116.347 | 1.21x |
| mixed-4096 | utf8-to-utf16 | 2077.394 | 2688.827 | 2686.233 | 1.29x |
| mixed-4096 | utf16-to-utf8 | 1520.578 | 1995.040 | 1962.931 | 1.31x |
| emoji-32 | utf8-to-utf16 | 29.878 | 29.876 | 29.880 | 1.00x |
| emoji-32 | utf16-to-utf8 | 23.109 | 22.856 | 23.193 | 0.99x |
| emoji-128 | utf8-to-utf16 | 47.196 | 46.436 | 46.322 | 0.98x |
| emoji-128 | utf16-to-utf8 | 36.094 | 36.106 | 36.474 | 1.00x |
| emoji-4096 | utf8-to-utf16 | 843.521 | 823.105 | 825.099 | 0.98x |
| emoji-4096 | utf16-to-utf8 | 719.081 | 713.424 | 720.804 | 0.99x |
| tiny-ascii-31 | utf8-to-utf16 | 29.090 | 29.347 | 29.107 | 1.01x |
| tiny-ascii-31 | utf16-to-utf8 | 21.139 | 20.963 | 27.993 | 0.99x |
| tiny-emoji-31 | utf8-to-utf16 | 20.908 | 20.847 | 20.893 | 1.00x |
| tiny-emoji-31 | utf16-to-utf8 | 17.920 | 17.759 | 18.069 | 0.99x |

## Warmed caller-buffer comparison

Speedup columns are predecessor/current and simdutf/current. Below 1 means
current icuz takes longer.

| Corpus | Direction | Current ns | 1af201c ns | a611885 ns | simdutf ns | ICU ns | vs 1af201c | vs simdutf |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| ascii-32 | utf8-to-utf16 | 5.011 | 4.761 | 4.760 | 12.385 | 36.967 | 0.95x | 2.47x |
| ascii-32 | utf16-to-utf8 | 3.758 | 4.109 | 8.780 | 10.320 | 36.456 | 1.09x | 2.75x |
| ascii-128 | utf8-to-utf16 | 7.144 | 6.572 | 7.008 | 10.099 | 94.644 | 0.92x | 1.41x |
| ascii-128 | utf16-to-utf8 | 8.126 | 9.045 | 11.776 | 13.780 | 92.546 | 1.11x | 1.70x |
| ascii-4096 | utf8-to-utf16 | 98.503 | 97.225 | 98.014 | 110.784 | 2097.726 | 0.99x | 1.12x |
| ascii-4096 | utf16-to-utf8 | 111.779 | 112.873 | 152.143 | 198.113 | 1998.032 | 1.01x | 1.77x |
| latin-32 | utf8-to-utf16 | 35.913 | 35.493 | 36.984 | 38.217 | 37.975 | 0.99x | 1.06x |
| latin-32 | utf16-to-utf8 | 12.332 | 12.614 | 12.056 | 23.580 | 27.876 | 1.02x | 1.91x |
| latin-128 | utf8-to-utf16 | 68.983 | 68.133 | 111.240 | 86.657 | 91.974 | 0.99x | 1.26x |
| latin-128 | utf16-to-utf8 | 25.254 | 26.066 | 25.203 | 35.420 | 70.459 | 1.03x | 1.40x |
| latin-4096 | utf8-to-utf16 | 1530.433 | 1528.506 | 2729.765 | 1891.360 | 2176.969 | 1.00x | 1.24x |
| latin-4096 | utf16-to-utf8 | 521.517 | 522.611 | 526.438 | 614.749 | 1641.942 | 1.00x | 1.18x |
| chinese-32 | utf8-to-utf16 | 12.720 | 12.248 | 12.134 | 23.161 | 23.759 | 0.96x | 1.82x |
| chinese-32 | utf16-to-utf8 | 8.885 | 9.725 | 10.363 | 18.226 | 18.726 | 1.09x | 2.05x |
| chinese-128 | utf8-to-utf16 | 13.649 | 13.455 | 13.408 | 83.244 | 87.683 | 0.99x | 6.10x |
| chinese-128 | utf16-to-utf8 | 11.323 | 12.230 | 10.772 | 32.448 | 62.930 | 1.08x | 2.87x |
| chinese-4096 | utf8-to-utf16 | 358.833 | 359.042 | 358.373 | 949.909 | 2077.182 | 1.00x | 2.65x |
| chinese-4096 | utf16-to-utf8 | 270.697 | 271.373 | 271.505 | 413.255 | 1388.809 | 1.00x | 1.53x |
| mixed-32 | utf8-to-utf16 | 53.830 | 79.898 | 83.871 | 68.228 | 67.091 | 1.48x | 1.27x |
| mixed-32 | utf16-to-utf8 | 40.028 | 50.913 | 47.606 | 47.041 | 50.472 | 1.27x | 1.18x |
| mixed-128 | utf8-to-utf16 | 99.629 | 155.150 | 162.465 | 121.835 | 122.841 | 1.56x | 1.22x |
| mixed-128 | utf16-to-utf8 | 68.907 | 92.839 | 88.019 | 76.056 | 91.356 | 1.35x | 1.10x |
| mixed-4096 | utf8-to-utf16 | 1835.445 | 2490.077 | 2385.779 | 1918.436 | 2250.907 | 1.36x | 1.05x |
| mixed-4096 | utf16-to-utf8 | 1123.521 | 1671.469 | 1649.196 | 1029.252 | 1639.470 | 1.49x | 0.92x |
| emoji-32 | utf8-to-utf16 | 12.494 | 12.564 | 12.480 | 31.187 | 56.867 | 1.01x | 2.50x |
| emoji-32 | utf16-to-utf8 | 10.327 | 10.952 | 9.484 | 28.526 | 28.505 | 1.06x | 2.76x |
| emoji-128 | utf8-to-utf16 | 26.542 | 26.179 | 26.166 | 99.212 | 153.180 | 0.99x | 3.74x |
| emoji-128 | utf16-to-utf8 | 19.842 | 19.716 | 18.371 | 73.152 | 79.473 | 0.99x | 3.69x |
| emoji-4096 | utf8-to-utf16 | 589.423 | 592.923 | 584.772 | 2345.048 | 3667.367 | 1.01x | 3.98x |
| emoji-4096 | utf16-to-utf8 | 407.361 | 407.660 | 401.761 | 1968.650 | 1950.345 | 1.00x | 4.83x |
| tiny-ascii-31 | utf8-to-utf16 | 5.518 | 5.267 | 5.269 | 11.870 | 23.951 | 0.95x | 2.15x |
| tiny-ascii-31 | utf16-to-utf8 | 3.508 | 3.780 | 11.311 | 11.305 | 22.339 | 1.08x | 3.22x |
| tiny-emoji-31 | utf8-to-utf16 | 5.410 | 5.490 | 5.502 | 21.958 | 37.229 | 1.01x | 4.06x |
| tiny-emoji-31 | utf16-to-utf8 | 5.309 | 5.584 | 4.768 | 19.454 | 21.220 | 1.05x | 3.66x |

## Remaining work

All three mixed UTF-8→UTF-16 rows exceed simdutf in this profile. Mixed
UTF-16→UTF-8 exceeds it for the short and medium rows; the large row still
needs about 9% less time to reach simdutf. This is a remaining optimization
target, along with broader APIs and other hardware profiles. Passing these
gates and selected rows does not complete the active industry-best goal.
All allocating and reuse rows are included rather than limiting the profile
to the winning cases.

## Reproduce

Use the [external build commands](utf16-conversion-2026-11-26.md#reproduce),
and rebuild both predecessors with the same current benchmark source:

```sh
zig build bench-utf16-build
for revision in 1af201c a611885; do
  revision_dir="/tmp/icuz-mixed-$revision"
  mkdir -p "$revision_dir"
  git archive "$revision" src/unicode/utf16.zig src/unicode/utf src/unicode/scalar | tar -x -C "$revision_dir"
  zig build-exe -O ReleaseFast -lc --dep utf16 -Mroot=bench/utf16/bench.zig \
    -O ReleaseFast -Mutf16="$revision_dir/src/unicode/utf16.zig" \
    -femit-bin="/tmp/icuz-mixed-$revision-rebuilt"
done
python3 bench/utf16/compare.py --icuz zig-out/bin/icuz-utf16-bench \
  --baseline /tmp/icuz-mixed-1af201c-rebuilt --baseline-reuse \
  --reference /tmp/icuz-mixed-a611885-rebuilt \
  --external /tmp/icuz-transcode-external --cpu 2 --rounds 5 --interleave-cases \
  --output /tmp/icuz-mixed-windows-reproduced.json
```

## Validation

- Native ReleaseSafe UTF module: 25/25 passed.
- Baseline x86-64 ReleaseSafe UTF module: 25/25 passed.
- Debug guarded input/exact output buffers: 4/4 passed.
- AArch64 and big-endian PowerPC64 ReleaseSafe compilation passed using
  `-fno-emit-bin`; these are compilation checks rather than runtime profiles.
- Full library ReleaseSafe: 4/4 build steps succeeded, 535/535 tests passed.
- Unicode verifier: 431 blobs, 34 generated sources, 3 generated bitmaps,
  and 134 generators verified.
- New oracles cover all 256 four-scalar width tuples at eight offsets,
  direct checked/prevalidated window decoding, all 65,536 eight-scalar
  encoding width tuples, exact and warmed capacities, preserved prefixes,
  and invalid or truncated neighbors at window boundaries. Existing complete
  scalar, surrogate-pair, width-mask, guarded-buffer, and OOM coverage remains.
- Current source and executable hashes matched the formal profile after gates.

```sh
zig test src/unicode/utf16.zig -O ReleaseSafe --test-filter UTF
zig test src/unicode/utf16.zig -O ReleaseSafe -target x86_64-linux-gnu -mcpu baseline --test-filter UTF
zig test src/unicode/utf16.zig -O Debug --test-filter guarded
zig test src/unicode/utf16.zig -O ReleaseSafe -target aarch64-linux-gnu -fno-emit-bin --test-filter UTF
zig test src/unicode/utf16.zig -O ReleaseSafe -target powerpc64-linux-gnu -fno-emit-bin --test-filter UTF
zig build test -Doptimize=ReleaseSafe --summary all
zig build unicode-verify
```
