#!/usr/bin/env python3
"""Run file-identical UTF-8 validation workloads in alternating order."""
import argparse
import hashlib
import json
import platform
from pathlib import Path
import subprocess
import tempfile


def corpora():
    pieces = {
        "ascii": b"The quick brown fox jumps over the lazy dog. 0123456789\n",
        "latin": "Ångström älskar blåbär och öar. ÅÄÖ åäö ".encode(),
        "chinese": "你好世界中国汉字排序拼音".encode(),
        "mixed": "Hello 世界! café naïve Straße 😀👩‍💻 ẹ́ שלום مرحبا क्षि 각 text.\n".encode(),
        "emoji": "😀👩💻🚀🦀🌍".encode(),
    }
    for name, piece in pieces.items():
        for minimum in (32, 128, 4096):
            text = piece * ((minimum + len(piece) - 1) // len(piece))
            yield f"{name}-{minimum}", text, True
    text = pieces["mixed"] * 40
    yield "invalid-first", b"\xff" + text[1:], False
    yield "invalid-last", text[:-1] + b"\xff", False
    yield "truncated-last", text + b"\xf0\x9f\x98", False
    # The original phrase rows start at 36-106 bytes. Include the actual
    # short-input path and ASCII runs on either side of a multibyte scalar.
    for name, piece in pieces.items():
        scalars = piece.decode()
        for minimum in (1, 8, 16, 24, 31):
            prefix = ""
            for scalar in scalars * 32:
                prefix += scalar
                if len(prefix.encode()) >= minimum:
                    break
            yield f"tiny-{name}-{minimum}", prefix.encode(), True
    yield "tiny-ascii-prefix", b"a" * 29 + "世".encode(), True
    yield "tiny-ascii-suffix", "世".encode() + b"a" * 29, True
    yield "tiny-ascii-infix", "é".encode() + b"a" * 28 + "ö".encode(), True
    yield "latin-ascii-leading", b"hello " + pieces["latin"], True
    yield "mixed-latin-leading", "é".encode() + pieces["mixed"], True
    yield "mixed-emoji-leading", "😀".encode() + pieces["mixed"], True
    for first in (0x80, 0xc0, 0xc1, 0xf5):
        yield f"reject-first-{first:02x}", bytes([first]) + b"a" * 127, False
    for first in (0x80, 0xc0, 0xc1, 0xf5, 0xff):
        yield f"reject-short-{first:02x}", bytes([first]) + b"a" * 31, False


def run(binary, files, cpu):
    result = subprocess.run(["taskset", "-c", str(cpu), binary, *map(str, files)],
                            text=True, capture_output=True, check=True)
    rows = {}
    versions = []
    for line in (result.stdout + result.stderr).splitlines():
        fields = line.split("\t")
        if len(fields) == 5:
            path, length, ns, per_byte, count = fields
            rows[Path(path).stem] = {"bytes": int(length), "ns_op": float(ns),
                                     "ns_byte": float(per_byte), "count": int(count)}
        elif line.startswith("simdutf "):
            versions.append(line)
            print(line)
    if len(rows) != len(files):
        raise RuntimeError(f"incomplete benchmark output from {binary}")
    return rows, versions


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--icuz", required=True)
    parser.add_argument("--baseline")
    parser.add_argument("--simdutf", required=True)
    parser.add_argument("--cpu", type=int, default=4)
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.rounds < 1:
        parser.error("--rounds must be positive")
    binaries = {"icuz": str(Path(args.icuz).resolve()),
                "simdutf": str(Path(args.simdutf).resolve())}
    if args.baseline:
        binaries["baseline"] = str(Path(args.baseline).resolve())
    cases = list(corpora())
    samples = {library: [] for library in binaries}
    versions = []
    with tempfile.TemporaryDirectory(prefix="icuz-utf8-") as directory:
        files = []
        for name, text, valid in cases:
            path = Path(directory) / f"{name}.bin"
            path.write_bytes(text)
            files.append(path)
        for round_number in range(args.rounds):
            order = list(binaries)
            if round_number % 2:
                order.reverse()
            for library in order:
                rows, reported_versions = run(binaries[library], files, args.cpu)
                versions.extend(reported_versions)
                for name, text, valid in cases:
                    expected = 5 * max(2000, 16 * 1024 * 1024 // len(text)) if valid else 0
                    if rows[name]["bytes"] != len(text) or rows[name]["count"] != expected:
                        raise RuntimeError(f"{library}: wrong validation result for {name}")
                samples[library].append(rows)
    source_root = Path(__file__).resolve().parents[2]
    source_paths = [source_root / "src/unicode/scalar/validate.zig",
                    *sorted((source_root / "src/unicode/scalar/validation").glob("*.zig"))]
    evidence = {"cpu": args.cpu, "rounds": args.rounds, "trials": 5,
                "bytes_per_trial": 16 * 1024 * 1024,
                "early_reject_min_rounds": 2_000_000,
                "platform": platform.platform(), "versions": sorted(set(versions)),
                "binaries": binaries,
                "binary_sha256": {name: hashlib.sha256(Path(path).read_bytes()).hexdigest()
                                  for name, path in binaries.items()},
                "source_sha256": {str(path.relative_to(source_root)):
                                  hashlib.sha256(path.read_bytes()).hexdigest()
                                  for path in source_paths},
                "harness_sha256": {str(path.relative_to(source_root)):
                                   hashlib.sha256(path.read_bytes()).hexdigest()
                                   for path in [Path(__file__).resolve(),
                                                Path(__file__).resolve().with_name("bench.zig"),
                                                Path(__file__).resolve().with_name("simdutf.cpp")]},
                "inputs": {name: {"bytes": len(text), "valid": valid,
                                   "sha256": hashlib.sha256(text).hexdigest()}
                           for name, text, valid in cases}, "samples": samples}
    args.output.write_text(json.dumps(evidence, indent=2) + "\n")
    print("| Input | Bytes | icuz ns/op | simdutf ns/op | simdutf / icuz | baseline / icuz |")
    print("|---|---:|---:|---:|---:|---:|")
    for name, text, _ in cases:
        best = {library: min(round_rows[name]["ns_op"] for round_rows in rounds)
                for library, rounds in samples.items()}
        baseline = f'{best["baseline"] / best["icuz"]:.2f}x' if "baseline" in best else "—"
        print(f'| {name} | {len(text)} | {best["icuz"]:.3f} | {best["simdutf"]:.3f} | '
              f'{best["simdutf"] / best["icuz"]:.2f}x | {baseline} |')


if __name__ == "__main__":
    main()
