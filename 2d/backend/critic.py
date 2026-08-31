"""The VLM repair pass.

Godot builds the generated world, screenshots the whole map, and posts the PNG
here. A vision call looks at the picture — which catches things no schema can,
like a bench floating in a pond or three houses shoulder to shoulder with no
gap — and returns a small list of edit operations.

The safety property that makes this worth doing at all: the model returns OPS,
never a new world. The ops are applied to a copy, the copy is re-run through
validate_world(), and the patch is thrown away entirely if it fails. So the loop
can only ever move the world towards valid, and it terminates because the caller
runs it a bounded number of times.
"""
from __future__ import annotations

import copy

import catalog
import llm
import worldgen

MAX_OPS = 12

PATCH_SCHEMA = {
    "type": "object", "additionalProperties": False,
    "required": ["verdict", "notes", "ops"],
    "properties": {
        "verdict": {
            "type": "string", "enum": ["good", "needs_repair"],
            "description": "good = leave it alone.",
        },
        "notes": {"type": "string", "description": "One sentence on what is wrong."},
        "ops": {
            # No `maxItems` — structured outputs reject it, same as integer
            # minimum/maximum. The cap is stated in the prompt and enforced for
            # real by apply_ops(), which slices to MAX_OPS.
            "type": "array",
            "description": f"At most {MAX_OPS} operations.",
            "items": {
                "type": "object", "additionalProperties": False,
                "required": ["op", "target_id", "x", "y"],
                "properties": {
                    "op": {"type": "string", "enum": ["move", "remove"]},
                    "target_id": {"type": "string"},
                    "x": {"type": "integer", "description": "New tile x; ignored by remove."},
                    "y": {"type": "integer", "description": "New tile y; ignored by remove."},
                },
            },
        },
    },
}

_SYSTEM = """You are reviewing a screenshot of a procedurally laid-out village in a
top-down 2D children's game, to catch layout mistakes a human would notice
immediately but a rule checker cannot.

Look for, in priority order:
  1. Objects sitting in water, or half-buried in a building.
  2. Things crammed together with no walking room between them.
  3. An NPC or interactable in a silly place — a market stall in the woods, a
     bench facing a wall, a signpost nobody would ever walk past.
  4. Big empty dead zones, or everything huddled in one corner.

Do NOT try to redesign the village. Return the SMALLEST set of moves that fixes
real problems. If it looks fine, return verdict "good" and an empty ops list —
that is a perfectly good answer and the common case.

Coordinates are TILES. (0,0) is the top-left of the image; x grows right, y
grows down. An object's x,y is its TOP-LEFT tile. You are given the current
placement list; only reference target_ids from it."""


def _describe(world: dict) -> str:
    m = world["map"]
    lines = [f"Map is {m['width']}x{m['height']} tiles.",
             f"Player starts at ({world['player_start']['x']},{world['player_start']['y']}).",
             "Water regions: " + (", ".join(
                 f"({r['x']},{r['y']}) {r['w']}x{r['h']}"
                 for r in m["regions"] if r["terrain"] == "water") or "none"),
             "", "PLACEMENTS (id, asset, size in tiles, top-left x,y):"]
    for group in ("objects", "interactables"):
        for e in world[group]:
            w, h = catalog.footprint(e["asset"])
            lines.append(f"  {e['id']}  {e['asset']}  {w}x{h}  at ({e['x']},{e['y']})")
    for n in world["npcs"]:
        lines.append(f"  {n['id']}  npc:{n['name']}  1x1  at ({n['x']},{n['y']})")
    for e in world["enemies"]:
        lines.append(f"  {e['id']}  enemy:slime  1x1  at ({e['x']},{e['y']})")
    return "\n".join(lines)


def apply_ops(world: dict, ops: list[dict]) -> tuple[dict, list[str]]:
    """Applies ops to a COPY. Returns (patched, skipped_reasons)."""
    patched = copy.deepcopy(world)
    index: dict[str, tuple[str, dict]] = {}
    for group in ("objects", "interactables", "npcs", "enemies"):
        for e in patched[group]:
            index[e["id"]] = (group, e)

    skipped: list[str] = []
    for op in ops[:MAX_OPS]:
        tid = op["target_id"]
        if tid not in index:
            skipped.append(f"unknown target {tid}")
            continue
        group, entry = index[tid]
        if op["op"] == "move":
            entry["x"], entry["y"] = int(op["x"]), int(op["y"])
        elif op["op"] == "remove":
            # Never remove something the story depends on.
            if group == "npcs":
                skipped.append(f"refused to remove npc {tid}")
                continue
            if group == "interactables" and entry.get("beat"):
                skipped.append(f"refused to remove beat-carrying {tid}")
                continue
            patched[group] = [e for e in patched[group] if e["id"] != tid]
            del index[tid]
    return patched, skipped


def review_and_patch(world: dict, png: bytes) -> tuple[dict | None, list[dict], str]:
    """Returns (patched_world_or_None, ops, reason)."""
    if not llm.available():
        return None, [], "no api key"
    try:
        result = llm.generate_json(
            llm.CRITIC_MODEL, _SYSTEM,
            _describe(world) + "\n\nReview the screenshot and return your ops.",
            PATCH_SCHEMA, max_tokens=3000, image_png=png)
    except Exception as exc:  # noqa: BLE001
        return None, [], f"critique call failed: {exc}"

    ops = result.get("ops", [])
    if result.get("verdict") == "good" or not ops:
        return None, [], "no changes needed: " + result.get("notes", "")

    patched, skipped = apply_ops(world, ops)

    # Let the deterministic pass settle the exact tiles. The vision model is
    # good at "that bench shouldn't be in the pond" and bad at "and tile (14,9)
    # is free" — left to itself it reliably lands the moved object on top of
    # something else, and the whole patch then gets thrown away. Splitting the
    # job (model decides WHAT moves, repair_village decides exactly WHERE) is
    # what makes the loop actually able to apply anything.
    worldgen.resolve_attachments(patched)
    repairs = worldgen.repair_village(patched)

    try:
        worldgen.validate_world(patched)
    except worldgen.WorldValidationError as exc:
        # The whole patch goes in the bin — never half-apply.
        return None, ops, f"patch rejected, would break the world: {exc}"

    reason = result.get("notes", "")
    if skipped:
        reason += " (skipped: " + "; ".join(skipped) + ")"
    if repairs:
        reason += f" (+{len(repairs)} tile fixups)"
    return patched, ops, reason
