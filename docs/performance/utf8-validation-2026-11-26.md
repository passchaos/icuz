# UTF-8 validation and corrected collation comparison, 2026-11-26

This profile compares the public validating API with simdutf 9.0.0's
`validate_utf8`. It also replaces the mismatched long Chinese ICU comparison
in the historical benchmark document. The original icuz validator was captured
from clean commit `7d3c640`; the before/after binaries use the same file-driven
harness and its volatile length dependency prevents loop hoisting.

## Method

- Intel Core i9-13900K, logical CPU 2 (one P-core), Linux x86-64.
- Zig 0.16.0, ReleaseFast, native target; simdutf 9.0.0's amalgamation built
  with GCC 13, `-O3 -std=c++17`, selecting its `haswell` implementation.
- Each executable processes identical files. Inputs cover ASCII, accented
  Latin, Chinese, mixed scripts and combining marks, and four-byte emoji,
  plus malformed and truncated tails. Labels denote the minimum target
  size; the byte column records the actual size without splitting a scalar.
- Five trials per row, roughly 16 MiB offered per trial, then three rounds
  with executable order reversed in alternate rounds. Tables report the
  minimum of those rounds. Every validation result is checked against the
  corpus's expected acceptance count.
- The machine is shared. Timing and code layout can vary between builds;
  differences around ten percent should be treated as parity. These are
  measured microbenchmarks, not proof of leadership over every workload or
  target architecture. The invalid-first row performs very little work and
  its ns/B value must not be interpreted as full-input throughput.
- [Raw samples and hashes](utf8-validation-2026-11-26.json) record the
  inputs, executable versions, binary SHA-256 values, source SHA-256 values,
  and every round. Ratios above 1 favor the current icuz implementation.

## Measurements

| Input | Bytes | icuz ns/op | simdutf ns/op | simdutf / icuz | previous icuz / icuz |
|---|---:|---:|---:|---:|---:|
| ascii-32 | 56 | 3.261 | 10.137 | 3.11x | 1.31x |
| ascii-128 | 168 | 3.758 | 10.793 | 2.87x | 1.43x |
| ascii-4096 | 4144 | 29.314 | 35.843 | 1.22x | 2.33x |
| latin-32 | 52 | 8.600 | 16.596 | 1.93x | 1.40x |
| latin-128 | 156 | 15.359 | 21.015 | 1.37x | 1.34x |
| latin-4096 | 4108 | 231.385 | 312.860 | 1.35x | 1.61x |
| chinese-32 | 36 | 10.381 | 16.816 | 1.62x | 3.78x |
| chinese-128 | 144 | 14.654 | 20.501 | 1.40x | 2.30x |
| chinese-4096 | 4104 | 221.301 | 312.271 | 1.41x | 2.18x |
| mixed-32 | 106 | 14.634 | 19.038 | 1.30x | 1.37x |
| mixed-128 | 212 | 16.611 | 23.134 | 1.39x | 2.00x |
| mixed-4096 | 4134 | 218.601 | 313.153 | 1.43x | 2.52x |
| emoji-32 | 48 | 12.905 | 16.571 | 1.28x | 2.04x |
| emoji-128 | 144 | 15.020 | 20.499 | 1.36x | 2.63x |
| emoji-4096 | 4104 | 212.510 | 312.787 | 1.47x | 2.89x |
| invalid-first | 4240 | 2.279 | 320.089 | 140.45x | 0.44x |
| invalid-last | 4240 | 224.822 | 321.659 | 1.43x | 2.53x |
| truncated-last | 4243 | 225.736 | 321.785 | 1.43x | 2.52x |

The 4 KiB multibyte rows are 1.61–2.89x faster than the previous validator
and 1.35–1.47x faster than simdutf in this profile. All fifteen valid-input
rows are ahead of simdutf in the recorded measurements. Rejection at the first
byte still takes only a few nanoseconds but is slower than the previous
validator; this remains an optimization opportunity.

## Corrected long Chinese comparison

Both libraries compare the same 256 repetitions of `你好世界中国汉字排序拼音`:
9,216 UTF-8 bytes or 3,072 UTF-16 units. The final scalar changes from
U+97F3 to U+97F4. ICU's UTF-16 conversion is performed before timing; icuz's
public API validates both UTF-8 inputs during the operation. CPU 2 and the
same alternating three-round procedure are used.

| Implementation | ns/op | Relative to current icuz |
|---|---:|---:|
| Previous icuz, validating | 1257.625 | 1.79x |
| Current icuz, validating | 700.985 | 1.00x |
| ICU 78.3, `ucol_strcoll` | 1199.569 | 1.71x |

[Raw collation samples](collation-validation-2026-11-26.json) record the
input and binary hashes. The historical ICU row used only 32 repetitions
(1,152 bytes) and changed a different scalar to ASCII, so its 187.232 ns/op
and the ratios based on it do not describe the same operation.

To reproduce with an ICU 78.3 installation:

```sh
zig build bench-collation-build
ICUZ_ICU_PREFIX=/path/to/icu-78.3
g++ -O2 -std=c++17 -I "$ICUZ_ICU_PREFIX/include" bench/icu_bench.cpp \
  -L "$ICUZ_ICU_PREFIX/lib" -Wl,-rpath,"$ICUZ_ICU_PREFIX/lib" \
  -licuuc -licui18n -licudata -o /tmp/icuz-icu78-bench
taskset -c 2 zig-out/bin/icuz-collation-bench \
  'compare Chinese long validating'
taskset -c 2 /tmp/icuz-icu78-bench 'UCA compare Chinese long'
```

## Implementation and validation

The public API retains its allocation-free, strict UTF-8 contract. Inputs
shorter than 33 bytes use scalar checking with an ASCII scan. The portable
vector path carries the expected continuation bits between windows rather
than rebuilding them from six scalar conditions. On AVX2 with the LLVM
backend, inputs of at least 128 bytes use lookup4 classification adapted from
simdutf under its MIT license. Overlapping loads supply the preceding bytes,
paired windows share checks, and a separate final-scalar check rejects EOF
truncation. ASCII prefixes are scanned once, including text whose first
non-ASCII byte is near EOF. Other targets and the self-hosted Debug backend
use the portable path.

Differential tests compare both paths with `std.unicode.utf8ValidateSlice`:
every one-, two-, and three-byte input, sampled four-byte invalid inputs,
every Unicode scalar encoding across both window boundaries, mixed-script
mutations, and exceptional second-byte ranges. Linux guard-page tests put
slices directly beside unreadable pages at lengths 0–512 to catch lookahead
and lookbehind overreads. The complete ReleaseSafe library suite passes all 514 tests. Native and
baseline x86-64 ReleaseSafe validator tests and
Debug guard-page tests pass; AArch64 ReleaseSafe compilation also passes
(without an AArch64 runtime measurement).

The full-library regression exposed a pre-existing Arabic shaping defect,
reproduced at `7d3c640`: reading `u21` storage as `u32` vector lanes compared
undefined upper padding bits against generated-space markers. Case 1076,
`abc سلام 123` with options `0x8`, leaked `U+FFFF`. Marker compaction now masks
the eleven padding bits, and its focused test injects nonzero padding at every
lane position. The 44,412-case ICU shaping fixture passes for UTF-8 and UTF-16.

## Reproduce

Build the matching simdutf 9.0.0 header and implementation from its
amalgamation directory:

```sh
zig build bench-utf8-build
ICUZ_SIMDUTF_DIR=/path/to/simdutf-9.0.0-amalgamation
g++ -O3 -std=c++17 -I "$ICUZ_SIMDUTF_DIR" bench/utf8/simdutf.cpp \
  "$ICUZ_SIMDUTF_DIR/simdutf.cpp" -pthread -o /tmp/icuz-simdutf-bench
python3 bench/utf8/compare.py --icuz zig-out/bin/icuz-utf8-bench \
  --simdutf /tmp/icuz-simdutf-bench --cpu 2 --rounds 3 \
  --output /tmp/icuz-utf8-current.json
```

To add a before/after comparison without changing the working tree:

```sh
git show 7d3c640:src/unicode/scalar/validate.zig > /tmp/icuz-validator-before.zig
zig build-exe -O ReleaseFast -lc --dep validate -Mroot=bench/utf8/bench.zig \
  -O ReleaseFast -Mvalidate=/tmp/icuz-validator-before.zig \
  -femit-bin=/tmp/icuz-utf8-before
python3 bench/utf8/compare.py --icuz zig-out/bin/icuz-utf8-bench \
  --baseline /tmp/icuz-utf8-before --simdutf /tmp/icuz-simdutf-bench \
  --cpu 2 --rounds 3 --output /tmp/icuz-utf8-comparison.json
```

Validation commands:

```sh
zig test src/unicode/scalar/validate.zig -O ReleaseSafe
zig test src/unicode/scalar/validate.zig -O ReleaseSafe -target x86_64-linux-gnu -mcpu baseline
zig test src/unicode/scalar/validate.zig -O Debug --test-filter 'guard pages'
zig test src/unicode/scalar/validate.zig -O ReleaseSafe -target aarch64-linux-gnu -fno-emit-bin
zig build test -Doptimize=ReleaseSafe
zig build unicode-verify
```
