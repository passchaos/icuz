#!/usr/bin/env python3
"""Same-file strict conversion profiles, with allocation and reuse separate."""
import argparse
import hashlib
import json
from pathlib import Path
import runpy
import subprocess
import tempfile


def cases():
    corpus = runpy.run_path(str(Path(__file__).parents[1] / "utf8/compare.py"))["corpora"]
    for name, text, valid in corpus():
        if valid and (name.endswith("-4096") or name.endswith("-128") or
                      name.endswith("-32") or name in ("tiny-emoji-31", "tiny-ascii-31")):
            yield name, text


def run(binary, paths, cpu):
    r = subprocess.run(["taskset", "-c", str(cpu), binary, *map(str, paths)],
                       text=True, capture_output=True, check=True)
    rows = {}
    versions = []
    for line in (r.stdout + r.stderr).splitlines():
        fields = line.split("\t")
        if len(fields) == 6:
            path, direction, contract, size, ns, output_size = fields
            rows[f"{Path(path).stem}/{direction}/{contract}"] = {
                "input_bytes": int(size), "ns_op": float(ns), "output_size": int(output_size)}
        elif line.startswith("simdutf "):
            versions.append(line)
    if not rows:
        raise RuntimeError(f"no results from {binary}")
    return rows, versions


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--icuz", required=True)
    parser.add_argument("--baseline")
    parser.add_argument("--reference", help="Additional allocating and reusable reference binary")
    parser.add_argument("--baseline-reuse", action="store_true",
                        help="The baseline also provides the reusable-buffer API")
    parser.add_argument("--external", required=True)
    parser.add_argument("--cpu", type=int, default=2)
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--interleave-cases", action="store_true",
                        help="Run libraries sequentially for each input to reduce load drift")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.rounds < 1:
        parser.error("--rounds must be positive")
    binaries = {"icuz": str(Path(args.icuz).resolve()),
                "external": str(Path(args.external).resolve())}
    if args.baseline:
        binaries["baseline"] = str(Path(args.baseline).resolve())
    if args.reference:
        binaries["reference"] = str(Path(args.reference).resolve())
    inputs = list(cases())
    samples = {name: [] for name in binaries}
    versions = []
    with tempfile.TemporaryDirectory(prefix="icuz-utf16-") as directory:
        paths = []
        for name, text in inputs:
            path = Path(directory) / (name + ".bin")
            path.write_bytes(text)
            paths.append(path)
        for number in range(args.rounds):
            order = list(binaries)
            if number % 2:
                order.reverse()
            current = {library: {} for library in order}
            groups = [[path] for path in paths] if args.interleave_cases else [paths]
            for group in groups:
                for library in order:
                    rows, current_versions = run(binaries[library], group, args.cpu)
                    if current[library].keys() & rows.keys():
                        raise RuntimeError(f"duplicate conversion rows from {library}")
                    current[library].update(rows)
                    versions.extend(current_versions)
            for library in order:
                rows = current[library]
                contracts = ("simdutf", "icu") if library == "external" else ("alloc",) if library == "baseline" and not args.baseline_reuse else ("alloc", "reuse")
                required = {f"{name}/{direction}/{contract}" for name, _ in inputs
                            for direction in ("utf8-to-utf16", "utf16-to-utf8") for contract in contracts}
                if set(rows) != required:
                    raise RuntimeError(f"incomplete conversion rows from {library}")
                for key, row in rows.items():
                    name, direction, _ = key.split("/")
                    text = dict(inputs)[name]
                    expected = len(text.decode().encode("utf-16-le")) // 2 if direction == "utf8-to-utf16" else len(text)
                    if row["input_bytes"] != len(text) or row["output_size"] != expected:
                        raise RuntimeError(f"wrong conversion result: {library} {key}")
                samples[library].append(rows)
    root = Path(__file__).resolve().parents[2]
    sources = [root / "build.zig", root / "bench/utf8/compare.py",
               root / "src/unicode/utf16.zig", *sorted((root / "src/unicode/utf").rglob("*.zig")),
               *sorted((root / "src/unicode/scalar").rglob("*.zig")),
               *sorted(Path(__file__).parent.glob("*.*"))]
    data = {"cpu": args.cpu, "rounds": args.rounds, "trials": 5,
            "interleave_cases": args.interleave_cases,
            "versions": sorted(set(versions)), "bytes_per_trial": 8 * 1024 * 1024,
            "binaries": binaries, "samples": samples,
            "binary_sha256": {name: hashlib.sha256(Path(path).read_bytes()).hexdigest()
                              for name, path in binaries.items()},
            "source_sha256": {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
                              for p in sources if p.is_file()},
            "inputs": {name: {"bytes": len(text), "utf16_units": len(text.decode().encode("utf-16-le"))//2,
                              "sha256": hashlib.sha256(text).hexdigest()} for name, text in inputs}}
    args.output.write_text(json.dumps(data, indent=2) + "\n")
    for version in sorted(set(versions)):
        print(version)
    for name, text in inputs:
        for direction in ("utf8-to-utf16", "utf16-to-utf8"):
            prefix = name + "/" + direction + "/"
            values = {f"{library}/{key[len(prefix):]}": min(s[key]["ns_op"] for s in rounds)
                      for library, rounds in samples.items() for key in rounds[0] if key.startswith(prefix)}
            print(name, direction, values)


if __name__ == "__main__":
    main()
