"""Strict conversion inputs with deterministic, irregular Unicode runs."""
from pathlib import Path
import random
import runpy


def scalar(rng, width):
    if width == 1:
        return chr(rng.randrange(0x80))
    if width == 2:
        return chr(rng.randrange(0x80, 0x800))
    if width == 3:
        value = rng.randrange(0x800, 0xf800)
        return chr(value if value < 0xd800 else value + 0x800)
    return chr(rng.randrange(0x10000, 0x110000))


def irregular(kind, minimum):
    rng = random.Random({"random": 0x1c0201, "transitions": 0x1c0202,
                         "sparse": 0x1c0203, "surrogate-heavy": 0x1c0204}[kind])
    parts = []
    size = 0
    while size < minimum:
        if kind == "random":
            widths = [rng.choice((1, 1, 1, 1, 1, 2, 2, 3, 3, 4))]
        elif kind == "transitions":
            widths = [rng.choice((1, 2, 3)) for _ in range(rng.randrange(1, 16))]
            widths += [4] * rng.randrange(1, 4)
        elif kind == "sparse":
            widths = [1] * rng.randrange(32, 256)
            widths += [rng.choice((2, 3, 4)) for _ in range(rng.randrange(2, 9))]
        else:
            widths = [rng.choice((1, 2, 3)) for _ in range(rng.randrange(1, 5))]
            widths += [4] * rng.randrange(2, 9)
        for width in widths:
            piece = scalar(rng, width).encode()
            parts.append(piece)
            size += len(piece)
            if size >= minimum:
                break
    return b"".join(parts)


def cases():
    corpus = runpy.run_path(str(Path(__file__).parents[1] / "utf8/compare.py"))["corpora"]
    for name, text, valid in corpus():
        if valid and (name.endswith("-4096") or name.endswith("-128") or
                      name.endswith("-32") or name in ("tiny-emoji-31", "tiny-ascii-31")):
            yield name, text
    for kind in ("random", "transitions", "sparse", "surrogate-heavy"):
        sizes = (128, 4096, 65536) if kind == "random" else (4096, 65536)
        for minimum in sizes:
            yield f"mixed-{kind}-{minimum}", irregular(kind, minimum)
    for minimum in (4096, 65536):
        dense_prefix = irregular("random", 256)
        sparse_prefix = irregular("sparse", 256)
        yield f"mixed-dense-to-sparse-{minimum}", dense_prefix + irregular("sparse", minimum - len(dense_prefix))
        yield f"mixed-sparse-to-dense-{minimum}", sparse_prefix + irregular("random", minimum - len(sparse_prefix))
