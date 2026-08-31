"""Reader for generated/assets_catalog.json — the file tools/tsx_convert.py
emits and Godot's world/catalog.gd also reads.

This is what makes the model's asset vocabulary *closed*: the schema enums are
built from this file at import time, so structured outputs can only ever return
an asset id that provably exists on disk and that Godot can resolve to a scene.

zij3d learned this the hard way with a hand-maintained VERIFIED/BANNED allowlist
in world/interior_layouts.gd that drifted from the real prop set. One generated
file, read by both sides, cannot drift.
"""
from __future__ import annotations

import json
from functools import lru_cache
from pathlib import Path

CATALOG_PATH = Path(__file__).resolve().parent.parent / "generated" / "assets_catalog.json"

TERRAINS = ["grass", "dirt", "water"]
# Verbs the Godot interactable registry knows how to run (see actors/interactable.gd).
VERBS = ["talk", "open", "read", "sit", "look"]


class CatalogMissing(RuntimeError):
    pass


@lru_cache(maxsize=1)
def load() -> dict:
    if not CATALOG_PATH.exists():
        raise CatalogMissing(
            f"{CATALOG_PATH} not found — run: python3 tools/tsx_convert.py")
    return json.loads(CATALOG_PATH.read_text())


def objects() -> dict:
    return load()["objects"]


def scenery_ids() -> list[str]:
    """Everything placeable, interactive or not."""
    return sorted(objects().keys())


def interactive_ids() -> list[str]:
    """Only assets the semantics table gave an interaction verb."""
    return sorted(k for k, v in objects().items() if v["verb"])


def verb_for(asset_id: str) -> str:
    return objects()[asset_id]["verb"]


def footprint(asset_id: str) -> tuple[int, int]:
    w, h = objects()[asset_id]["tiles"]
    return int(w), int(h)


def category(asset_id: str) -> str:
    return objects()[asset_id]["category"]


def is_solid(asset_id: str) -> bool:
    return bool(objects()[asset_id]["solid"])


def describe_for_prompt() -> str:
    """A compact catalogue the world model can actually reason over: id, size in
    tiles, and what it is. Grouped so the model sees buildings as a class."""
    by_cat: dict[str, list[str]] = {}
    for aid, e in sorted(objects().items()):
        w, h = e["tiles"]
        bits = f"{aid} ({w}x{h} tiles"
        if e["verb"]:
            bits += f", interactive: {e['verb']}"
        bits += ")"
        by_cat.setdefault(e["category"], []).append(bits)
    out = []
    for cat in sorted(by_cat):
        out.append(f"{cat.upper()}S:")
        out.append("  " + "\n  ".join(by_cat[cat]))
    return "\n".join(out)
