#!/usr/bin/env python3
"""Generate N worlds from different seeds and report what actually happens.

One successful generation proves the pipeline runs; it says nothing about the
first-pass rate, which failure modes are common, or whether the repair passes
are carrying the whole thing. This measures that.

    backend/.venv/bin/python tools/batch_gen.py --count 6 --out test_output/batch
"""
from __future__ import annotations

import argparse
import contextlib
import io
import json
import random
import sys
import time
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "backend"))

import worldgen  # noqa: E402


def classify(stderr: str) -> tuple[list[str], list[str]]:
    """Split the run log into repairs applied and attempts rejected."""
    repairs, rejects = [], []
    for line in stderr.splitlines():
        line = line.strip()
        if "repaired story" in line or "repaired village" in line:
            repairs.append(line.split("— ", 1)[-1])
        elif "attempt" in line and "failed" in line:
            rejects.append(line.split("failed: ", 1)[-1])
        elif "story attempt" in line and "rejected" in line:
            rejects.append(line.split("rejected: ", 1)[-1])
    return repairs, rejects


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--count", type=int, default=6)
    ap.add_argument("--out", default="test_output/batch")
    ap.add_argument("--seed-rng", type=int, default=20260728)
    args = ap.parse_args()

    outdir = ROOT / args.out
    outdir.mkdir(parents=True, exist_ok=True)
    random.seed(args.seed_rng)
    seeds = [worldgen.random_seed() for _ in range(args.count)]

    rows = []
    sources = Counter()
    all_repairs: Counter = Counter()
    all_rejects: list[str] = []

    for i, seed in enumerate(seeds, 1):
        buf = io.StringIO()
        t0 = time.time()
        try:
            with contextlib.redirect_stderr(buf):
                world, source = worldgen.generate_validated(seed)
        except Exception as exc:  # noqa: BLE001
            world, source = worldgen.load_fallback(), f"crash:{exc}"
        dt = time.time() - t0

        repairs, rejects = classify(buf.getvalue())
        sources[source.split(":")[0]] += 1
        for r in repairs:
            # Bucket by the kind of repair, not the specific ids.
            all_repairs[r.split(" (")[0].split(" '")[0][:44]] += 1
        all_rejects += rejects

        if source != "fallback":
            (outdir / f"world_{i:02d}.json").write_text(json.dumps(world, indent=2))

        m = world["map"]
        rows.append((i, seed, source, f"{dt:.0f}s", f"{m['width']}x{m['height']}",
                     len(world["objects"]), len(world["interactables"]),
                     len(world["npcs"]), len(world["beats"]),
                     len(repairs), len(rejects)))
        print(f"[{i}/{len(seeds)}] {source:9s} {dt:5.0f}s  "
              f"repairs={len(repairs):2d} rejected_attempts={len(rejects)}  {seed}",
              flush=True)

    print("\n" + "=" * 78)
    print(f"{'#':>2} {'source':9s} {'time':>5} {'map':>7} {'obj':>4} {'int':>4} "
          f"{'npc':>4} {'beat':>4} {'rep':>4} {'rej':>4}  seed")
    for r in rows:
        print(f"{r[0]:>2} {r[2]:9s} {r[3]:>5} {r[4]:>7} {r[5]:>4} {r[6]:>4} "
              f"{r[7]:>4} {r[8]:>4} {r[9]:>4} {r[10]:>4}  {r[1]}")

    n = len(seeds)
    print(f"\nsources: {dict(sources)}")
    first_pass = sources.get("generated", 0)
    print(f"first-pass success: {first_pass}/{n}  "
          f"any success: {first_pass + sources.get('retry', 0)}/{n}")

    if all_repairs:
        print("\nrepairs applied (the model's systematic near-misses):")
        for kind, c in all_repairs.most_common(12):
            print(f"  {c:3d}x  {kind}")
    if all_rejects:
        print("\nattempts rejected (what repair could NOT fix):")
        for kind, c in Counter(r[:80] for r in all_rejects).most_common(12):
            print(f"  {c:3d}x  {kind}")
    print(f"\nworlds written to {outdir.relative_to(ROOT)}/")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
