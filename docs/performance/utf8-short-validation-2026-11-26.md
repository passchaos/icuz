# Short and medium UTF-8 validation against simdutf 9.5.0

This profile measures the public strict UTF-8 validator after `d9d4ecd`,
including early rejection, actual 1–32-byte inputs, and medium strings with
ASCII, Latin, CJK, and emoji prefixes. The API remains allocation-free and
retains its strict UTF-8 validity contract. The comparison uses the latest stable simdutf
release found in the official tags on 2026-11-26: `v9.5.0`, released on
2026-11-24, commit `9064366fa571fac03bcd28db35af597e97fba842`.

## Method

- Intel Core i9-13900K, logical CPU 2 (one P-core), Linux x86-64.
- Zig 0.16.0 ReleaseFast, native target; GCC 13, `-O3 -std=c++17`, compiling
  the complete simdutf 9.5.0 amalgamation and selecting `haswell`.
- Previous icuz is `d9d4ecd`, rebuilt from its archived validator with the
  same updated harness. Each executable receives identical files.
- Both the input pointer and length depend on one volatile read in each
  iteration. The value remains zero. This keeps inlined byte checks inside
  the timed loop as well as preventing whole-call hoisting.
- First-byte rejection rows run at least 2,000,000 operations per trial;
  other rows offer roughly 16 MiB per trial, with at least 2,000 operations.
  Five trials are followed by three rounds, reversing executable order in
  alternate rounds. Reported values are minima. Acceptance counts are
  checked against every input's expected validity.
- Labels denote target sizes; the byte column records actual sizes without
  splitting a Unicode scalar. The machine is shared and differences around
  ten percent are treated as parity. Early-rejection ns/B values are not
  whole-input throughput measurements.
- [Raw samples](utf8-short-validation-2026-11-26.json) include every round,
  input hashes, binary hashes, validator source hashes, harness hashes, and
  the simdutf release source hashes. Evidence covers the listed inputs and
  this CPU profile; other architectures need separate performance profiles.

## Selected measurements

| Input | Bytes | previous icuz ns/op | icuz ns/op | simdutf 9.5 ns/op | previous / icuz | simdutf / icuz |
|---|---:|---:|---:|---:|---:|---:|
| invalid-first | 4240 | 2.510 | 0.669 | 67.603 | 3.75x | 101.03x |
| reject-first-80 | 128 | 2.173 | 0.669 | 6.538 | 3.25x | 9.77x |
| reject-first-f5 | 128 | 2.511 | 0.669 | 6.546 | 3.75x | 9.79x |
| tiny-emoji-31 | 32 | 30.413 | 3.092 | 7.536 | 9.83x | 2.44x |
| tiny-ascii-prefix | 32 | 25.278 | 2.439 | 7.537 | 10.37x | 3.09x |
| tiny-ascii-suffix | 32 | 19.573 | 3.081 | 7.549 | 6.35x | 2.45x |
| tiny-ascii-infix | 32 | 17.817 | 3.080 | 7.544 | 5.78x | 2.45x |
| tiny-ascii-31 | 31 | 3.261 | 1.632 | 10.942 | 2.00x | 6.71x |
| chinese-32 | 36 | 10.505 | 5.062 | 17.238 | 2.08x | 3.41x |
| mixed-32 | 106 | 15.086 | 9.572 | 10.777 | 1.58x | 1.13x |
| mixed-latin-leading | 108 | 15.743 | 9.402 | 10.745 | 1.67x | 1.14x |
| mixed-emoji-leading | 110 | 17.347 | 9.389 | 10.740 | 1.85x | 1.14x |
| chinese-4096 | 4104 | 223.003 | 218.382 | 256.940 | 1.02x | 1.18x |
| emoji-4096 | 4104 | 210.715 | 206.908 | 257.044 | 1.02x | 1.24x |

The first-byte rejection regression from the previous profile is removed.
Complete 32-byte buffers use one register-based lookup window rather than
scalar scanning. The 31-byte ASCII row benefits from one overlapping word
load instead of checking seven trailing bytes individually. Medium inputs
now use lookup windows from 35 bytes onward, closing the mixed-text gap
exposed by simdutf 9.5.0 and improving Latin, CJK, and emoji-leading strings.
Large-input throughput remains at parity with the previous icuz validator;
the recorded 4 KiB rows remain faster than simdutf 9.5.0.

The 24-byte ASCII row is slightly slower than the previous implementation
(about eight percent in this profile). This is within the stated timing
noise range and remains an optimization opportunity. Broader ICU 78.3
operation coverage and runtime measurements on non-AVX2 hardware also remain
open.

## Validating collation

The same-machine public `Collator.compare` rows retain complete UTF-8
validation. ICU 78.3 receives the corresponding UTF-16 inputs, converted
before timing. The mixed input changes the final ASCII `t` to `u`; the long
Chinese input contains 256 copies of `你好世界中国汉字排序拼音` (9,216 UTF-8
bytes / 3,072 UTF-16 units) and changes the final scalar from U+97F3 to
U+97F4. Each library performs the same comparison. Exact row matching avoids
mixing `UCA compare mixed` with the separate `mixed early` row.

| Input | previous icuz ns/op | icuz ns/op | ICU 78.3 ns/op | previous / icuz | ICU / icuz |
|---|---:|---:|---:|---:|---:|
| mixed | 35.322 | 25.757 | 50.979 | 1.37x | 1.98x |
| chinese-long | 697.088 | 697.460 | 1199.231 | 1.00x | 1.72x |

[Raw collation samples](collation-short-validation-2026-11-26.json) record
all rounds and the executable and workload-source hashes. The mixed API row
improves while the long Chinese row retains its previous performance.

## Implementation and validation

- Scalar sequence checking returns length 1–4 or zero for an invalid scalar,
  avoiding optional-length state. Initial malformed scalars are rejected
  before calling the out-of-line lookup scanner, and validated prefix lengths
  are reused.
- Short ASCII prefixes are scanned once. Word scanning reads the final eight
  bytes as an overlapping word when a shorter tail remains; the overlap is
  already proven ASCII and every load stays inside the slice.
- Non-ASCII-leading 24–31-byte inputs use a 35-byte stack buffer with three
  leading ASCII bytes and trailing ASCII that fills the lookup window. A complete 32-byte input is
  loaded directly; a shared half-vector plus three `vpalignr` instructions
  construct lookbehind without reading before the input.
- After lookup checks reject invalid byte pairs, the last three lead-byte
  thresholds establish EOF completeness without decoding the final scalar
  again. The portable path remains available when AVX2 or the LLVM backend
  is unavailable.
- Differential tests check public, portable, and scalar entry points against
  `std.unicode.utf8ValidateSlice`. Every Unicode scalar is placed at the
  beginning of a 32-byte buffer, across the 128-bit lane at offsets 13–15,
  and across normal window boundaries. Invalid scalar encodings cross those
  lanes as well. Linux slices beside unreadable pages cover lengths 0–512,
  including ASCII-prefixed medium inputs and truncated tails.
- The final native validator module passes 12 tests with those exhaustive
  loops. Baseline x86-64 ReleaseSafe tests, Debug guard-page tests, and
  AArch64 ReleaseSafe compilation pass. The final full-library ReleaseSafe
  gate passes all 515 tests, including the additional lane-boundary coverage.

## Reproduce

```sh
zig build bench-utf8-build

git clone --depth 1 --branch v9.5.0 https://github.com/simdutf/simdutf.git /tmp/icuz-simdutf-9.5.0
python3 /tmp/icuz-simdutf-9.5.0/singleheader/amalgamate.py \
  --output-dir /tmp/icuz-simdutf-9.5.0/amalgamation --no-zip --no-readme
g++ -O3 -std=c++17 -I /tmp/icuz-simdutf-9.5.0/amalgamation \
  bench/utf8/simdutf.cpp /tmp/icuz-simdutf-9.5.0/amalgamation/simdutf.cpp \
  -pthread -o /tmp/icuz-simdutf-9.5.0-bench

mkdir -p /tmp/icuz-d9d4ecd
git archive d9d4ecd src/unicode/scalar | tar -x -C /tmp/icuz-d9d4ecd
zig build-exe -O ReleaseFast -lc --dep validate -Mroot=bench/utf8/bench.zig \
  -O ReleaseFast -Mvalidate=/tmp/icuz-d9d4ecd/src/unicode/scalar/validate.zig \
  -femit-bin=/tmp/icuz-utf8-d9d4ecd
python3 bench/utf8/compare.py --icuz zig-out/bin/icuz-utf8-bench \
  --baseline /tmp/icuz-utf8-d9d4ecd --simdutf /tmp/icuz-simdutf-9.5.0-bench \
  --cpu 2 --rounds 3 --output /tmp/icuz-short-validation.json

zig test src/unicode/scalar/validate.zig -O ReleaseSafe
zig test src/unicode/scalar/validate.zig -O ReleaseSafe -target x86_64-linux-gnu -mcpu baseline
zig test src/unicode/scalar/validate.zig -O Debug --test-filter 'guard pages'
zig test src/unicode/scalar/validate.zig -O ReleaseSafe -target aarch64-linux-gnu -fno-emit-bin
zig build test -Doptimize=ReleaseSafe --summary all
zig build unicode-verify
```

The ICU build and pinned collation commands are documented in the
[previous profile](utf8-validation-2026-11-26.md#corrected-long-chinese-comparison).

## All validation rows

| Input | Bytes | previous icuz ns/op | icuz ns/op | simdutf 9.5 ns/op | previous / icuz | simdutf / icuz |
|---|---:|---:|---:|---:|---:|---:|
| ascii-32 | 56 | 3.263 | 3.007 | 10.553 | 1.09x | 3.51x |
| ascii-128 | 168 | 3.758 | 3.257 | 4.760 | 1.15x | 1.46x |
| ascii-4096 | 4144 | 31.489 | 30.825 | 39.232 | 1.02x | 1.27x |
| latin-32 | 52 | 8.664 | 5.411 | 16.998 | 1.60x | 3.14x |
| latin-128 | 156 | 15.238 | 11.251 | 14.522 | 1.35x | 1.29x |
| latin-4096 | 4108 | 230.473 | 225.938 | 257.019 | 1.02x | 1.14x |
| chinese-32 | 36 | 10.505 | 5.062 | 17.238 | 2.08x | 3.41x |
| chinese-128 | 144 | 14.797 | 10.920 | 14.519 | 1.36x | 1.33x |
| chinese-4096 | 4104 | 223.003 | 218.382 | 256.940 | 1.02x | 1.18x |
| mixed-32 | 106 | 15.086 | 9.572 | 10.777 | 1.58x | 1.13x |
| mixed-128 | 212 | 17.293 | 16.548 | 18.381 | 1.04x | 1.11x |
| mixed-4096 | 4134 | 218.839 | 219.601 | 256.990 | 1.00x | 1.17x |
| emoji-32 | 48 | 13.325 | 6.290 | 16.989 | 2.12x | 2.70x |
| emoji-128 | 144 | 15.280 | 11.354 | 14.534 | 1.35x | 1.28x |
| emoji-4096 | 4104 | 210.715 | 206.908 | 257.044 | 1.02x | 1.24x |
| invalid-first | 4240 | 2.510 | 0.669 | 67.603 | 3.75x | 101.03x |
| invalid-last | 4240 | 225.654 | 226.081 | 264.956 | 1.00x | 1.17x |
| truncated-last | 4243 | 225.795 | 225.838 | 264.968 | 1.00x | 1.17x |
| tiny-ascii-1 | 1 | 1.130 | 1.063 | 10.045 | 1.06x | 9.45x |
| tiny-ascii-8 | 8 | 1.004 | 1.004 | 10.086 | 1.00x | 10.05x |
| tiny-ascii-16 | 16 | 1.255 | 1.254 | 10.041 | 1.00x | 8.00x |
| tiny-ascii-24 | 24 | 1.381 | 1.506 | 10.953 | 0.92x | 7.28x |
| tiny-ascii-31 | 31 | 3.261 | 1.632 | 10.942 | 2.00x | 6.71x |
| tiny-latin-1 | 2 | 2.266 | 1.940 | 16.014 | 1.17x | 8.25x |
| tiny-latin-8 | 9 | 5.852 | 4.491 | 15.910 | 1.30x | 3.54x |
| tiny-latin-16 | 16 | 9.930 | 6.649 | 15.951 | 1.49x | 2.40x |
| tiny-latin-24 | 24 | 15.470 | 12.451 | 16.400 | 1.24x | 1.32x |
| tiny-latin-31 | 31 | 19.980 | 12.463 | 16.398 | 1.60x | 1.32x |
| tiny-chinese-1 | 3 | 3.096 | 2.397 | 16.015 | 1.29x | 6.68x |
| tiny-chinese-8 | 9 | 8.486 | 5.536 | 15.912 | 1.53x | 2.87x |
| tiny-chinese-16 | 18 | 19.343 | 9.769 | 16.403 | 1.98x | 1.68x |
| tiny-chinese-24 | 24 | 27.713 | 12.457 | 16.404 | 2.22x | 1.32x |
| tiny-chinese-31 | 33 | 10.428 | 9.479 | 17.240 | 1.10x | 1.82x |
| tiny-mixed-1 | 1 | 1.130 | 1.083 | 10.056 | 1.04x | 9.28x |
| tiny-mixed-8 | 9 | 6.025 | 2.386 | 15.929 | 2.53x | 6.68x |
| tiny-mixed-16 | 16 | 10.639 | 5.005 | 15.957 | 2.13x | 3.19x |
| tiny-mixed-24 | 24 | 16.409 | 7.718 | 16.401 | 2.13x | 2.13x |
| tiny-mixed-31 | 31 | 20.913 | 10.182 | 16.399 | 2.05x | 1.61x |
| tiny-emoji-1 | 4 | 3.294 | 2.760 | 16.056 | 1.19x | 5.82x |
| tiny-emoji-8 | 8 | 6.293 | 5.062 | 15.905 | 1.24x | 3.14x |
| tiny-emoji-16 | 16 | 12.829 | 8.597 | 15.952 | 1.49x | 1.86x |
| tiny-emoji-24 | 24 | 21.311 | 12.438 | 16.405 | 1.71x | 1.32x |
| tiny-emoji-31 | 32 | 30.413 | 3.092 | 7.536 | 9.83x | 2.44x |
| tiny-ascii-prefix | 32 | 25.278 | 2.439 | 7.537 | 10.37x | 3.09x |
| tiny-ascii-suffix | 32 | 19.573 | 3.081 | 7.549 | 6.35x | 2.45x |
| tiny-ascii-infix | 32 | 17.817 | 3.080 | 7.544 | 5.78x | 2.45x |
| latin-ascii-leading | 58 | 7.473 | 5.242 | 17.000 | 1.43x | 3.24x |
| mixed-latin-leading | 108 | 15.743 | 9.402 | 10.745 | 1.67x | 1.14x |
| mixed-emoji-leading | 110 | 17.347 | 9.389 | 10.740 | 1.85x | 1.14x |
| reject-first-80 | 128 | 2.173 | 0.669 | 6.538 | 3.25x | 9.77x |
| reject-first-c0 | 128 | 2.178 | 0.674 | 6.538 | 3.23x | 9.69x |
| reject-first-c1 | 128 | 2.196 | 0.669 | 6.548 | 3.28x | 9.79x |
| reject-first-f5 | 128 | 2.511 | 0.669 | 6.546 | 3.75x | 9.79x |
| reject-short-80 | 32 | 1.632 | 1.019 | 7.555 | 1.60x | 7.41x |
| reject-short-c0 | 32 | 1.631 | 1.019 | 7.559 | 1.60x | 7.42x |
| reject-short-c1 | 32 | 1.631 | 1.019 | 7.563 | 1.60x | 7.42x |
| reject-short-f5 | 32 | 1.883 | 1.018 | 7.545 | 1.85x | 7.41x |
| reject-short-ff | 32 | 1.883 | 1.019 | 7.553 | 1.85x | 7.41x |
