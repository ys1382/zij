"""Procedural world generation. One strong-model call at session start invents a
brand-new mystery AND the village it happens in — premise, hidden truth, a goal,
an unordered pool of facts, terrain, buildings, props, NPCs and enemies — as
schema-validated JSON.

Two ideas do most of the work here:

1. The model NEVER emits raw tile ids. It describes terrain as rectangles and
   polylines ("a pond in the northwest, a road from the gate to the well") and
   Godot autotiles the result through the Ground/Water/Road wangsets recovered
   by tools/tsx_convert.py. A 40x30 map is 1200 cells; asking for those directly
   would be slow, expensive and almost always wrong.

2. Every asset id the model can name comes from generated/assets_catalog.json
   via catalog.py, so it cannot invent a prop that doesn't exist.

Any failure (no key, no goal, unreachable layout) retries once on the same
seed and then falls back to fallback_world.json, so the game always boots.

CLI, for iterating on the generator without launching Godot:
    python3 -m worldgen --seed "a well gone silent"
    python3 -m worldgen --fallback --validate-only
"""
from __future__ import annotations

import argparse
import json
import math
import random
import re
import sys
import traceback
from collections import deque
from pathlib import Path

import catalog
import llm

FALLBACK_PATH = Path(__file__).resolve().parent / "fallback_world.json"

# Bumped whenever the merged world shape changes in a way old cached/pushed
# worlds won't have (e.g. adding `rival`). take_warm_world() discards a cache
# stamped with anything else instead of serving it stale.
WORLD_VERSION = 2

MAP_MIN = (32, 24)
MAP_MAX = (56, 44)

# Random-seed word banks. Pairing an object with a problem shape gives the model
# something real to diverge around. zij3d shipped a gibberish letter-string seed
# and watched two consecutive generations both land on "a song lost its ending"
# — literally one of the examples in its own prompt, because the seed offered
# nothing to build on.
_SEED_OBJECTS = [
    "a loom", "a well", "a kiln", "a bridge", "an orchard", "a bell tower",
    "a market stall", "a caravan bell", "a water wheel", "a mosaic floor",
    "a rooftop garden", "a fishing net", "a spice grinder", "a stone archway",
    "a beehive", "a dovecote", "a sundial", "a windmill", "a dye vat",
    "a rope bridge", "a lighthouse lamp", "a puppet theatre", "a millstone",
]
_SEED_PROBLEMS = [
    "gone silent", "cracked overnight", "vanished", "stopped working",
    "was found empty", "changed colour", "started glowing", "was found locked",
    "began moving on its own", "was covered in strange markings",
    "was found full of sand", "stopped keeping time", "was left half-built",
    "was found unlocked with nobody inside", "smells of something unfamiliar",
]


def random_seed() -> str:
    return f"{random.choice(_SEED_OBJECTS)} {random.choice(_SEED_PROBLEMS)}"


# ---------------------------------------------------------------------------
# Schema. Anthropic structured outputs require additionalProperties:false and
# every property listed in `required` on every object — optionals are expressed
# as empty string / empty array, never omitted.
# ---------------------------------------------------------------------------

def _xy(desc: str = "") -> dict:
    return {
        "type": "object", "additionalProperties": False,
        "required": ["x", "y"],
        "properties": {"x": {"type": "integer", "description": desc},
                       "y": {"type": "integer"}},
    }


# Generation is split into TWO calls. One combined schema overflows Anthropic's
# grammar compiler ("The compiled grammar is too large") — measured: dropping any
# single top-level section brings it back under, so it is the total size, not one
# field. Splitting also generates better: the model settles the mystery first,
# then lays out a village *for* that mystery, instead of doing both at once.
#
# There is deliberately no `enum` on the asset fields either; enumerating the 63
# catalog ids inside repeated array items blows the same budget. The closed
# vocabulary is enforced by the prompt plus validate_world(), so a hallucinated
# asset id fails validation and triggers the retry rather than being impossible
# to emit.

def story_schema() -> dict:
    return {
        "type": "object", "additionalProperties": False,
        "required": ["title", "premise", "hidden_truth", "goal", "items", "cast",
                     "beats", "ending", "rival"],
        "properties": {
            "title": {"type": "string"},
            "premise": {"type": "string"},
            "hidden_truth": {"type": "string"},
            # Items live in the STORY call, not the village one. Partly because
            # what exists is a story decision and where it sits is a village
            # decision, but mostly for grammar budget: the combined schema
            # already overflowed Anthropic's compiler once, and the village call
            # is the fuller of the two.
            "items": {
                "type": "array",
                "items": {
                    "type": "object", "additionalProperties": False,
                    "required": ["id", "name", "text"],
                    "properties": {
                        "id": {"type": "string", "description": "short snake_case"},
                        "name": {"type": "string",
                                 "description": "as it reads in the bag, e.g. 'a coil of new rope'"},
                        "text": {"type": "string",
                                 "description": "one line shown when it is picked up"},
                    },
                },
            },
            "cast": {
                "type": "array",
                "items": {
                    "type": "object", "additionalProperties": False,
                    "required": ["id", "name", "role", "persona", "secret",
                                 "could_know", "opener", "tint", "wants_item"],
                    "properties": {
                        "id": {"type": "string", "description": "short snake_case"},
                        "name": {"type": "string"},
                        "role": {"type": "string"},
                        "persona": {"type": "string"},
                        "secret": {"type": "string"},
                        # Deliberately NOT a list of beat ids. Assigning "this
                        # character holds fact 3" up front is what forced the
                        # player through a fixed order; instead this says what
                        # this person is *positioned* to have noticed, and which
                        # fact they actually offer is decided per conversation.
                        "could_know": {
                            "type": "string",
                            "description": "what this character is placed to have "
                                           "seen or overheard, in a sentence — their "
                                           "vantage point, not a list of facts",
                        },
                        "opener": {"type": "string"},
                        "tint": {"type": "string", "description": "#rrggbb clothing tint"},
                        "wants_item": {
                            "type": "string",
                            "description": "an item id this character needs; hand it "
                                           "over and they open up. \"\" for most of "
                                           "the cast",
                        },
                    },
                },
            },
            # A POOL, not a chain. There is no `requires`: any of these can be
            # found at any time, from anyone who plausibly knows it, in any
            # order. The old dependency graph meant the player had to find the
            # character holding fact 1 before fact 2 would unlock from anybody,
            # which turned free exploration into a fixed queue.
            "beats": {
                "type": "array",
                "items": {
                    "type": "object", "additionalProperties": False,
                    "required": ["id", "desc", "hint"],
                    "properties": {
                        "id": {"type": "string"},
                        "desc": {"type": "string",
                                 "description": "the fact itself, one sentence, as "
                                                "the player would write it down"},
                        "hint": {"type": "string",
                                 "description": "how someone alludes to it without "
                                                "saying it outright"},
                    },
                },
            },
            "goal": {
                "type": "object", "additionalProperties": False,
                "required": ["summary", "detail"],
                "properties": {
                    "summary": {"type": "string",
                                "description": "the objective in under ten words, as "
                                               "a child would repeat it — 'find out "
                                               "who took the bell rope'"},
                    "detail": {"type": "string",
                               "description": "one or two sentences on what counts "
                                              "as having done it"},
                },
            },
            "ending": {
                "type": "object", "additionalProperties": False,
                "required": ["condition_beats", "finale"],
                "properties": {
                    # An unordered SET. Every one of these has to be found, but
                    # nothing says in what order or from whom.
                    "condition_beats": {"type": "array", "items": {"type": "string"}},
                    "finale": {"type": "string"},
                },
            },
            # Unseen for the whole game — no sprite, no dialogue lines of its
            # own, never placed in the village. It only ever speaks through
            # rumors (escalating with progress) and, at the very end, a
            # showdown. Deterministic code decides *when* each line fires;
            # the model only supplies what it says.
            "rival": {
                "type": "object", "additionalProperties": False,
                "required": ["id", "name", "nature", "motive", "tint",
                             "rumors", "taunts", "defeat"],
                "properties": {
                    "id": {"type": "string", "description": "short snake_case"},
                    "name": {"type": "string"},
                    "nature": {"type": "string",
                               "description": "what kind of being it is, a few words"},
                    "motive": {"type": "string",
                               "description": "why it wants what the goal is about"},
                    "tint": {"type": "string", "description": "#rrggbb"},
                    # Structured outputs reject minItems/maxItems other than 0
                    # or 1 (same restriction as the `minimum`/`maximum` note
                    # on validate_world()'s numeric ranges) — exactly 3/2 is
                    # asked for in the description and enforced afterward by
                    # validate_rival(), not by the schema.
                    "rumors": {
                        "type": "array", "items": {"type": "string"},
                        "description": "EXACTLY 3 lines, escalating, villagers repeat "
                                       "these as the child gets closer",
                    },
                    "taunts": {
                        "type": "array", "items": {"type": "string"},
                        "description": "EXACTLY 2 lines it says when it finally shows itself",
                    },
                    "defeat": {"type": "string",
                               "description": "gentle, a little funny, said once beaten"},
                },
            },
        },
    }


def village_schema() -> dict:
    return {
        "type": "object", "additionalProperties": False,
        "required": ["map", "player_start", "objects", "interactables",
                     "npc_spots", "enemies"],
        "properties": {
            "map": {
                "type": "object", "additionalProperties": False,
                "required": ["width", "height", "base_terrain", "regions", "paths"],
                "properties": {
                    "width": {"type": "integer",
                              "description": f"Tiles wide, {MAP_MIN[0]}-{MAP_MAX[0]}."},
                    "height": {"type": "integer",
                               "description": f"Tiles tall, {MAP_MIN[1]}-{MAP_MAX[1]}."},
                    "base_terrain": {"type": "string", "enum": ["grass", "dirt"]},
                    "regions": {
                        "type": "array",
                        "description": "Painted in order over the base fill.",
                        "items": {
                            "type": "object", "additionalProperties": False,
                            "required": ["terrain", "x", "y", "w", "h"],
                            "properties": {
                                "terrain": {"type": "string", "enum": catalog.TERRAINS},
                                "x": {"type": "integer"}, "y": {"type": "integer"},
                                "w": {"type": "integer", "description": "at least 2"},
                                "h": {"type": "integer", "description": "at least 2"},
                            },
                        },
                    },
                    "paths": {
                        "type": "array",
                        "description": "Roads as polylines, drawn on top of regions.",
                        "items": {
                            "type": "object", "additionalProperties": False,
                            "required": ["points", "width"],
                            "properties": {
                                "points": {"type": "array", "items": _xy()},
                                "width": {"type": "integer", "description": "1-3"},
                            },
                        },
                    },
                },
            },
            "player_start": _xy(),
            "objects": {
                "type": "array",
                "description": "Scenery: collision and looks, no behaviour.",
                "items": {
                    "type": "object", "additionalProperties": False,
                    "required": ["id", "asset", "x", "y"],
                    "properties": {
                        "id": {"type": "string"},
                        "asset": {"type": "string", "description": "id from the catalogue"},
                        "x": {"type": "integer"}, "y": {"type": "integer"},
                    },
                },
            },
            "interactables": {
                "type": "array",
                "items": {
                    "type": "object", "additionalProperties": False,
                    "required": ["id", "asset", "x", "y", "text", "beat", "on",
                                 "gives_item", "needs_item", "locked_text"],
                    "properties": {
                        "id": {"type": "string"},
                        "gives_item": {
                            "type": "string",
                            "description": "item id the player picks up here, once. "
                                           "\"\" for most interactables",
                        },
                        "needs_item": {
                            "type": "string",
                            "description": "item id required to use this at all. "
                                           "\"\" for most interactables",
                        },
                        "locked_text": {
                            "type": "string",
                            "description": "shown when needs_item is missing, and it "
                                           "must NAME what is missing. \"\" if "
                                           "needs_item is \"\"",
                        },
                        "asset": {"type": "string",
                                  "description": "an INTERACTIVE id from the catalogue. "
                                                 "May only be \"\" if `on` names an "
                                                 "object; one of the two is REQUIRED"},
                        "x": {"type": "integer"}, "y": {"type": "integer"},
                        "text": {"type": "string"},
                        "beat": {"type": "string", "description": "beat id, or empty"},
                        "on": {"type": "string",
                               "description": "id of an object in `objects` to make "
                                              "interactive in place (e.g. a house door). "
                                              "Empty to place your own art instead."},
                    },
                },
            },
            "npc_spots": {
                "type": "array",
                "description": "Where each cast member stands. One per cast id.",
                "items": {
                    "type": "object", "additionalProperties": False,
                    "required": ["id", "x", "y", "movement"],
                    "properties": {
                        "id": {"type": "string", "description": "a cast id"},
                        "x": {"type": "integer"}, "y": {"type": "integer"},
                        "movement": {"type": "string", "enum": ["idle", "wander"]},
                    },
                },
            },
            "enemies": {
                "type": "array",
                "items": {
                    "type": "object", "additionalProperties": False,
                    "required": ["id", "x", "y", "behavior"],
                    "properties": {
                        "id": {"type": "string"},
                        "x": {"type": "integer"}, "y": {"type": "integer"},
                        "behavior": {"type": "string", "enum": ["wander", "guard"]},
                    },
                },
            },
        },
    }


_STORY_SYSTEM = """You invent a mystery for a children's adventure video game set in a
small village.

- TONE: warm and adventurous, for kids. Mild peril is fine (a coming storm, a
  worry about the harvest) but nothing graphic, cruel, or hopeless. Characters
  are kind even when worried. Simple language.
- Invent a NEW mystery built around the inspiration seed — it names an object and
  what is wrong with it. Make THAT the heart of the story, not a generic reskin.
  NEVER reuse: a drying spring, a hidden cistern, a lost brass key.
- `goal` is what the player is trying to do, stated plainly enough for a child
  to repeat it back. It is the ONE thing decided in advance.
- 5 to 8 beats. These are independent FACTS about what happened, not steps in a
  sequence: each must make sense on its own, discovered in any order, without
  assuming the player already knows another one. Do not write "and then...", do
  not number them, and never make one only meaningful after another. `hint` is
  how someone alludes to it without saying it outright.
- 5 to 9 cast members. Do NOT assign facts to characters. `could_know` is that
  person's VANTAGE POINT — where they are, what they watch, who they talk to —
  in one sentence. Who tells the player what is decided during play, from who
  the player actually approaches and what they ask.
- `secret` is something they do not volunteer. `opener` is one friendly greeting.
  `tint` is a clothing colour so they read as different people on screen — keep
  them well separated.
- `ending.condition_beats` is the subset of beat ids (3 or more) that add up to
  the goal. An unordered set: all of them are needed, in ANY order, from anyone.
  `finale` is 2-3 warm sentences resolving it happily.
- `rival` is an unseen troublemaker who wants the same thing the goal is
  about, for a selfish or mischievous reason — never cruel, never scary.
  It never appears in the village; it is only ever talked about. `rumors`
  are 3 lines of village talk about it, each a little more worried than the
  last. `taunts` are 2 lines for when it finally shows itself at the very
  end. `defeat` is warm and a little funny, said once it is beaten.
- All ids are short, snake_case and unique."""
# Deliberately no ITEMS guidance here. The obvious fix for "the model gives
# every villager an errand" was to say so in this prompt; measured on fixed
# seeds it took first-pass generation from 2/2 to 0/2 and repairs from ~20 to
# ~60. The extra prose competes with the geometry rules for the model's
# attention, and geometry is what actually fails. The item budget is enforced
# deterministically instead — see trim_items().


_VILLAGE_SYSTEM = """You lay out the village where a children's adventure takes place,
on a tile grid, using a fixed catalogue of art assets.

GEOMETRY
- (0,0) is the top-left tile; x grows right, y grows down. Keep everything at
  least 2 tiles inside the edge.
- Width 32-56 tiles, height 24-44. About 44x32 is a good size.
- Every object's x,y is its TOP-LEFT tile, so an object of size w x h covers
  x..x+w-1 and y..y+h-1. Sizes are in the catalogue — respect them, keep the
  whole footprint on the map, and never let two objects overlap.
- WORK OUT EACH FOOTPRINT BEFORE YOU PLACE THE NEXT THING. A house listed as
  10x7 at (4,9) fills x4..13, y9..15 — nothing else may touch those tiles.
  Leave at least one clear tile between neighbouring objects so the player can
  walk between them. Fewer objects placed cleanly beats many placed on top of
  each other.
- Put the player_start on open ground, on a road or in the village square, well
  clear of any building footprint.
- Terrain: a base fill, then `regions` rectangles painted over it in order
  (later ones win), then `paths` polylines for roads on top. Regions are at
  least 2x2; road widths are 1-3. Do NOT describe individual tiles.
- Nothing may stand in water. A road may cross water — that reads as a bridge.

COMPOSITION
- Make it feel like a real place: cluster the houses, run a road between them,
  put the well or the notice board where people would gather, edge the map with
  trees so it feels enclosed, and leave open walkable ground to move through.
- The player must be able to WALK to every NPC, interactable and enemy. Never
  ring anything with solid objects or water.
- Place each cast member somewhere they would plausibly be, given their role.
  Emit exactly one `npc_spots` entry per cast id — no more, no fewer.
- Interactables carry the world's voice: signs, notice boards, chests. Give each
  real `text`. Some should reveal a beat (set `beat` to that beat id); others
  just add colour (set `beat` to "").
- `text` is what the player NOTICES, in one or two sentences.
- ITEMS. The story listed some; place them. Exactly one interactable may
  `gives_item` each item id — that is where it is found. An interactable may
  instead `needs_item`, meaning it cannot be used until the player is carrying
  that item, and then `locked_text` must say plainly what is missing ("The lid
  is roped shut. You'd need something to cut it."). Never write ordinary `text`
  that dangles an object the player cannot actually take: if the cabinet holds
  the new rope, give it `gives_item`, or describe it as scenery — a child will
  hunt for a way to take it, and a dead end reads as a bug.
- Keep it solvable: an item must be findable without already holding something
  that is locked behind it.
- To make something you already placed interactive — a house door, the well —
  set `on` to that object's id, leave `asset` as "" and x,y as 0. Do NOT place a
  second copy of the same building on top of the first to act as its door.
- 0 to 3 enemies. They are small slimes — a nuisance, not a threat."""


def _story_prompt(seed: str) -> str:
    return (f"Inspiration seed — build the mystery around this: \"{seed}\".\n"
            f"Invent the story now.")


def _village_prompt(story: dict) -> str:
    cast = "\n".join(f"  {c['id']}: {c['name']}, {c['role']}"
                     + (f" — WANTS ITEM {c['wants_item']}" if c.get("wants_item") else "")
                     for c in story["cast"])
    beats = "\n".join(f"  {b['id']}: {b['desc']}" for b in story["beats"])
    items = "\n".join(f"  {i['id']}: {i['name']}" for i in story.get("items", [])) \
        or "  (none)"
    return (
        f"ASSET CATALOGUE — you may only use these ids:\n"
        f"{catalog.describe_for_prompt()}\n\n"
        f"THE STORY: {story['title']}\n{story['premise']}\n\n"
        f"CAST (place every one of these):\n{cast}\n\n"
        f"BEATS (interactables may reveal these):\n{beats}\n\n"
        f"ITEMS (give each one exactly one interactable to be found in):\n{items}\n\n"
        f"Lay out the village now."
    )


## Verb suffixes the model appends when it names an interactable after the
## object it belongs to — "well_look" for the object "well".
_VERB_SUFFIXES = ("_look", "_open", "_read", "_sit", "_talk", "_use")


def _infer_host_by_overlap(it: dict, objects: list) -> str:
    """Recovers a door the model built as a second copy of the building.

    Nobody places a 6x6 house as an *interactable*; when it happens the model
    means "this building's door" and has re-emitted the building to say so. The
    `on` field exists for exactly that, and _infer_host() catches the common
    spelling (`house_ilse_open`), but not ids like `int_door_ilse`. Left alone
    it becomes two buildings on the same tiles, which validation rejects as an
    overlap — and each rejected attempt costs the player another minute of
    loading while the retry runs.

    Only fires for building-sized interactables that actually overlap something,
    so a sign hung on a wall is unaffected.
    """
    if it.get("on") or not it.get("asset"):
        return ""
    # A hallucinated asset id reaches here too; the placement pass drops those.
    if it["asset"] not in catalog.objects():
        return ""
    if catalog.category(it["asset"]) != "building":
        return ""
    iw, ih = catalog.footprint(it["asset"])
    mine = {(it["x"] + dx, it["y"] + dy)
            for dx in range(iw) for dy in range(ih)}
    best, best_overlap = "", 0
    for o in objects:
        ow, oh = catalog.footprint(o["asset"])
        theirs = {(o["x"] + dx, o["y"] + dy)
                  for dx in range(ow) for dy in range(oh)}
        n = len(mine & theirs)
        if n > best_overlap:
            best, best_overlap = o["id"], n
    return best


def _infer_host(it: dict, by_id: dict) -> str:
    """Recovers the host of an interactable that left BOTH `asset` and `on`
    blank.

    The schema tells the model an empty asset is correct "when `on` is set", and
    it reliably does half of that: one real generation emitted six interactables
    — bulletin_read, haystack_look, crate_open and friends — with a blank asset
    and no `on`, every one of them named `<object_id>_<verb>` after an object it
    HAD placed. They were then dropped as "unknown asset ''", quietly costing
    that village most of its interactivity.

    Only an exact id match counts, so this cannot invent an attachment: an
    interactable that genuinely meant to place its own art names a real asset
    and never reaches here.
    """
    if it.get("asset") or it.get("on"):
        return ""
    ident = it.get("id", "")
    for suffix in _VERB_SUFFIXES:
        if ident.endswith(suffix) and ident[: -len(suffix)] in by_id:
            return ident[: -len(suffix)]
    # No bare-id fallback: ids are unique across objects and interactables, so
    # an interactable named exactly like an object would fail validation anyway.
    return ""


def add_item_fields(world: dict) -> None:
    """Fills in the item fields on a world that predates them.

    Worlds are written to disk (the fallback, batch_gen output, anything the
    user kept from an earlier run) and loaded straight back in, so every reader
    downstream would otherwise need its own `.get(..., "")`. Normalise once, at
    the edge."""
    world.setdefault("items", [])
    for it in world.get("interactables", []):
        it.setdefault("gives_item", "")
        it.setdefault("needs_item", "")
        it.setdefault("locked_text", "")
    for n in world.get("npcs", []):
        n.setdefault("wants_item", "")


def resolve_attachments(world: dict) -> list[str]:
    """Fold `on` interactables onto their host object, so all the geometry code
    downstream needs no special case — an attached interactable simply shares
    the host's asset and position.

    This exists because of a real generation: with no door sprite in the
    catalogue, the model placed a SECOND identical house at the same coordinates
    to serve as the theatre's door, which validation then rejected as an
    overlap. `on` is the supported way to express that."""
    notes: list[str] = []
    by_id = {o["id"]: o for o in world["objects"]}
    for it in world["interactables"]:
        host_id = (it.get("on", "") or _infer_host(it, by_id)
                   or _infer_host_by_overlap(it, world["objects"]))
        if not host_id:
            continue
        it["on"] = host_id
        host = by_id.get(host_id)
        if host is None:
            # The named host doesn't exist — the model invented the id, or the
            # placement pass dropped it. Detaching outright turns a door into a
            # free-floating copy of a house sitting on top of the neighbours,
            # which validation then rejects for an overlap: a full retry, i.e.
            # another minute on the loading screen. Re-home it onto whatever it
            # is actually standing on before giving up.
            probe = dict(it)
            probe["on"] = ""
            alt = _infer_host_by_overlap(probe, world["objects"])
            if alt:
                it["on"] = alt
                host = by_id[alt]
                notes.append(f"{it['id']} named missing host '{host_id}'; "
                             f"re-homed onto '{alt}', which it overlaps")
            else:
                it["on"] = ""
                notes.append(f"{it['id']} attaches to unknown object "
                             f"'{host_id}'; detached")
                continue
        it["asset"] = host["asset"]
        it["x"], it["y"] = host["x"], host["y"]
    return notes


def _merge(story: dict, village: dict) -> dict:
    """Joins the two calls on cast id. The join is its own failure mode, so an
    unplaced or unknown character is an error rather than a silently dropped
    NPC — a missing character can make the mystery unsolvable."""
    spots = {s["id"]: s for s in village["npc_spots"]}
    cast_ids = {c["id"] for c in story["cast"]}
    stray = set(spots) - cast_ids
    if stray:
        raise WorldValidationError(f"npc_spots for unknown cast: {sorted(stray)}")

    npcs = []
    for c in story["cast"]:
        spot = spots.get(c["id"])
        if spot is None:
            # Nobody owns a fact any more, so an unplaced villager costs the
            # player a conversation, not the mystery — any other villager can
            # supply what they would have. Only someone holding an item errand
            # is irreplaceable.
            if not c.get("wants_item"):
                print(f"worldgen: dropping unplaced, story-irrelevant cast "
                      f"member {c['id']}", file=sys.stderr)
                continue
            raise WorldValidationError(f"cast member {c['id']} was never placed")
        npc = dict(c)
        npc["x"], npc["y"] = spot["x"], spot["y"]
        npc["movement"] = spot["movement"]
        npcs.append(npc)

    return {
        "title": story["title"],
        "premise": story["premise"],
        "hidden_truth": story["hidden_truth"],
        "goal": story.get("goal", {}),
        "items": story.get("items", []),
        "beats": story["beats"],
        "ending": story["ending"],
        "rival": story.get("rival", {}),
        "map": village["map"],
        "player_start": village["player_start"],
        "objects": village["objects"],
        "interactables": village["interactables"],
        "npcs": npcs,
        "enemies": village["enemies"],
        "version": WORLD_VERSION,
    }


def repair_story(story: dict) -> list[str]:
    """Deterministic fixes for the story defects that are safely repairable,
    so a whole generation isn't thrown away over a bookkeeping slip. Returns
    what it changed.

    Nothing here re-homes facts any more. The old version's main job was
    "this beat belongs to nobody, give it to whoever holds the fewest" — a
    repair that only made sense while characters owned facts at all."""
    notes: list[str] = []
    beat_ids = {b["id"] for b in story["beats"]}
    cast = story["cast"]
    if not cast:
        return notes

    for c in cast:
        # Older generations (and the model, occasionally) still emit this.
        c.pop("knows_beats", None)
        if not c.get("could_know", "").strip():
            c["could_know"] = f"works as {c.get('role', 'a villager')} and sees who comes and goes"
            notes.append(f"supplied a default could_know for {c['id']}")

    cond = story.get("ending", {}).get("condition_beats", [])
    pruned = [b for b in cond if b in beat_ids]
    if pruned != cond and pruned:
        story["ending"]["condition_beats"] = pruned
        notes.append("pruned unknown beats from the ending condition")

    rival = story.get("rival")
    if isinstance(rival, dict):
        if not rival.get("tint", "").strip():
            rival["tint"] = "#8a3fc9"
            notes.append("supplied a default rival tint")
        for key in ("name", "nature", "motive", "defeat"):
            if isinstance(rival.get(key), str):
                rival[key] = rival[key].strip()
        # The schema can no longer say "exactly 3"/"exactly 2" (structured
        # outputs reject minItems/maxItems above 1 — see the schema comment),
        # so a model that pads the list is common; trim rather than reject a
        # whole generation over an extra line. Too FEW still fails, since
        # there is nothing to safely invent a rumor or taunt from.
        for key, want in (("rumors", 3), ("taunts", 2)):
            if isinstance(rival.get(key), list):
                rival[key] = [s.strip() if isinstance(s, str) else s for s in rival[key]]
                if len(rival[key]) > want:
                    rival[key] = rival[key][:want]
                    notes.append(f"trimmed rival {key} to {want}")
    return notes


def _generate_story(seed: str, attempts: int = 2) -> dict:
    last: Exception | None = None
    for i in range(attempts):
        story = llm.generate_json(llm.WORLD_MODEL, _STORY_SYSTEM, _story_prompt(seed),
                                  story_schema(), max_tokens=8000)
        for note in repair_story(story):
            print(f"worldgen: repaired story — {note}", file=sys.stderr)
        try:
            validate_story(story["beats"], story["cast"])
            validate_rival(story.get("rival") or {})
            return story
        except WorldValidationError as exc:
            last = exc
            print(f"worldgen: story attempt {i + 1} rejected: {exc}", file=sys.stderr)
    raise WorldValidationError(f"story generation failed: {last}")


def generate_world(seed: str = "") -> dict:
    if not seed:
        seed = random_seed()
    story = _generate_story(seed)
    village = llm.generate_json(llm.WORLD_MODEL, _VILLAGE_SYSTEM, _village_prompt(story),
                                village_schema(), max_tokens=16000)
    world = _merge(story, village)
    for note in resolve_attachments(world):
        print(f"worldgen: {note}", file=sys.stderr)
    for note in repair_village(world):
        print(f"worldgen: repaired village — {note}", file=sys.stderr)
    world["seed"] = seed
    return world


# ---------------------------------------------------------------------------
# Semantic validation — everything the JSON schema cannot express.
# ---------------------------------------------------------------------------

class WorldValidationError(ValueError):
    pass


def validate_items(world: dict) -> None:
    """Every item resolves, is findable, and is findable in an order that works.

    The last part is the one that matters. A model asked for a lock-and-key
    puzzle will cheerfully put the key inside the chest it opens, or split a
    pair across two chests that each need the other — worlds that validate
    perfectly on geometry and simply cannot be finished. This walks the
    dependency the way a player would: collect everything reachable with an
    empty bag, then everything that opens up, and repeat until nothing new
    appears. Whatever is left over was never obtainable.
    """
    items = {i["id"]: i for i in world.get("items", [])}
    inters = world["interactables"]

    for it in inters:
        for field in ("gives_item", "needs_item"):
            ref = it.get(field, "")
            if ref and ref not in items:
                raise WorldValidationError(
                    f"interactable {it['id']}: {field} names unknown item {ref!r}")
        if it.get("needs_item") and not it.get("locked_text"):
            raise WorldValidationError(
                f"interactable {it['id']} needs an item but has no locked_text, "
                f"so the player is told nothing about why it won't open")
    for n in world["npcs"]:
        ref = n.get("wants_item", "")
        if ref and ref not in items:
            raise WorldValidationError(
                f"npc {n['id']}: wants_item names unknown item {ref!r}")

    givers: dict[str, list[dict]] = {}
    for it in inters:
        if it.get("gives_item"):
            givers.setdefault(it["gives_item"], []).append(it)

    wanted = {it["needs_item"] for it in inters if it.get("needs_item")}
    wanted |= {n["wants_item"] for n in world["npcs"] if n.get("wants_item")}
    missing = sorted(wanted - set(givers))
    if missing:
        raise WorldValidationError(
            f"items required but found nowhere: {missing}")

    # Fixpoint: what can actually be collected, starting empty-handed.
    held: set[str] = set()
    while True:
        gained = {
            it["gives_item"] for it in inters
            if it.get("gives_item") and it["gives_item"] not in held
            and (not it.get("needs_item") or it["needs_item"] in held)
        }
        if not gained:
            break
        held |= gained

    stuck = sorted(set(givers) - held)
    if stuck:
        raise WorldValidationError(
            f"items locked behind themselves, unobtainable: {stuck}")
    unreachable_needs = sorted(wanted - held)
    if unreachable_needs:
        raise WorldValidationError(
            f"items needed but never obtainable: {unreachable_needs}")


def _cells_for(entry: dict) -> list[tuple[int, int]]:
    """Tiles an object occupies. x,y is its TOP-LEFT cell, matching the
    x/y/w/h convention `regions` already uses — an earlier bottom-left
    convention for objects only had the model placing things off the top of
    the map, because the two disagreed."""
    w, h = catalog.footprint(entry["asset"])
    x0, y0 = entry["x"], entry["y"]
    return [(x0 + dx, y0 + dy) for dx in range(w) for dy in range(h)]


def _water_cells(world: dict) -> set[tuple[int, int]]:
    """Cells that are open water. Regions are painted in order, so a later
    non-water region painted over an earlier pond un-floods those cells; roads
    are drawn last of all and act as bridges."""
    m = world["map"]
    w, h = m["width"], m["height"]
    water: set[tuple[int, int]] = set()
    for r in m["regions"]:
        cells = {(x, y)
                 for y in range(r["y"], r["y"] + r["h"])
                 for x in range(r["x"], r["x"] + r["w"])}
        if r["terrain"] == "water":
            water |= cells
        else:
            water -= cells
    for p in m["paths"]:
        water -= _path_cells(p, w, h)
    return water


def _solid_map(world: dict) -> tuple[set, int, int]:
    """Set of blocked cells, plus map dims. Water blocks; so does any object
    whose Tiled collider survived the conversion."""
    m = world["map"]
    w, h = m["width"], m["height"]
    blocked: set[tuple[int, int]] = set(_water_cells(world))
    for entry in world["objects"] + world["interactables"]:
        if catalog.is_solid(entry["asset"]):
            blocked.update(_cells_for(entry))
    return blocked, w, h


def _path_cells(path: dict, w: int, h: int) -> set[tuple[int, int]]:
    out: set[tuple[int, int]] = set()
    pts = path["points"]
    half = path["width"] // 2
    for a, b in zip(pts, pts[1:]):
        steps = max(abs(b["x"] - a["x"]), abs(b["y"] - a["y"])) or 1
        for i in range(steps + 1):
            cx = round(a["x"] + (b["x"] - a["x"]) * i / steps)
            cy = round(a["y"] + (b["y"] - a["y"]) * i / steps)
            for dy in range(-half, half + 1):
                for dx in range(-half, half + 1):
                    if 0 <= cx + dx < w and 0 <= cy + dy < h:
                        out.add((cx + dx, cy + dy))
    return out


def _reachable(blocked: set, w: int, h: int, start: tuple[int, int]) -> set:
    seen = {start}
    q = deque([start])
    while q:
        x, y = q.popleft()
        for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
            if 0 <= nx < w and 0 <= ny < h and (nx, ny) not in blocked \
                    and (nx, ny) not in seen:
                seen.add((nx, ny))
                q.append((nx, ny))
    return seen


def _may_mount(asset: str) -> bool:
    """Whether an interactable is allowed to share tiles with a building.

    A sign or a plaque on a wall is the point of a sign. A 4x5 well inside a
    cottage is not — an earlier blanket "interactables may overlap buildings"
    rule produced exactly that, twice in one village. So: small, and not itself
    a building."""
    w, h = catalog.footprint(asset)
    return catalog.category(asset) != "building" and w * h <= 6


def _spiral(max_r: int):
    """Offsets ordered by increasing ring, so the first hit is the nearest."""
    yield (0, 0)
    for r in range(1, max_r + 1):
        for dx in range(-r, r + 1):
            for dy in range(-r, r + 1):
                if max(abs(dx), abs(dy)) == r:
                    yield (dx, dy)


def _largest_open_region(blocked: set, W: int, H: int) -> set:
    """The biggest connected blob of walkable tiles. Anything outside it is, by
    definition, somewhere the player can never reach."""
    seen: set[tuple[int, int]] = set()
    best: set[tuple[int, int]] = set()
    for y in range(H):
        for x in range(W):
            if (x, y) in blocked or (x, y) in seen:
                continue
            comp: set[tuple[int, int]] = set()
            q = deque([(x, y)])
            seen.add((x, y))
            while q:
                cx, cy = q.popleft()
                comp.add((cx, cy))
                for nx, ny in ((cx + 1, cy), (cx - 1, cy), (cx, cy + 1), (cx, cy - 1)):
                    if 0 <= nx < W and 0 <= ny < H \
                            and (nx, ny) not in blocked and (nx, ny) not in seen:
                        seen.add((nx, ny))
                        q.append((nx, ny))
            if len(comp) > len(best):
                best = comp
    return best


## How many items a village may end up with, and how many villagers may be
## waiting for one. Left to itself the model hands every character their own
## trinket — five identical fetch-quests in different hats, which a child feels
## as repetition immediately.
MAX_ITEMS = 2
MAX_WANTERS = 1


def trim_items(world: dict) -> list[str]:
    """Cuts the item count down to something that reads as a puzzle.

    Enforced here rather than in the prompt on purpose. Asking for restraint in
    the system prompt worked — the model obeyed — but the extra paragraph
    competed with the geometry rules and measurably wrecked placement: on fixed
    seeds, first-pass generation went 2/2 -> 0/2 and repairs ~20 -> ~60. Prompt
    budget is a scarce resource and geometry is what actually fails, so anything
    expressible as a deterministic pass belongs here.

    Keeps the items that carry the most weight: one a villager is waiting for
    beats one that merely opens a box, which beats one that is only scenery.
    """
    notes: list[str] = []
    items = world.get("items", [])
    if not items:
        return notes

    wanted_by = {n.get("wants_item", "") for n in world["npcs"]}
    locks = {it.get("needs_item", "") for it in world["interactables"]}

    def weight(i: dict) -> int:
        if i["id"] in wanted_by:
            return 0
        if i["id"] in locks:
            return 1
        return 2

    ranked = sorted(items, key=weight)
    keep = {i["id"] for i in ranked[:MAX_ITEMS]}
    dropped = [i["id"] for i in ranked[MAX_ITEMS:]]
    if dropped:
        world["items"] = [i for i in items if i["id"] in keep]
        notes.append(f"trimmed {len(dropped)} item(s) to keep the puzzle sharp: "
                     f"{sorted(dropped)}")

    # Thin the queue of villagers waiting for something, keeping the earliest so
    # the choice is stable for a given generation.
    wanters = [n for n in world["npcs"] if n.get("wants_item")]
    for n in wanters[MAX_WANTERS:]:
        notes.append(f"npc {n['id']}: cleared wants_item {n['wants_item']!r}, "
                     f"one errand is enough")
        n["wants_item"] = ""

    # Anything referring to a trimmed item is cleaned up by repair_items(),
    # which runs straight after and always unlocks rather than blocks.
    return notes


def repair_items(world: dict) -> list[str]:
    """Clears item references that would make the world unfinishable.

    Unlocking is always the safe direction. A lock whose key doesn't exist makes
    content unreachable; dropping the lock only makes something easier, and the
    beat behind it stays reachable. So a dangling reference becomes no reference
    rather than a rejected generation."""
    notes: list[str] = []
    items = {i["id"] for i in world.get("items", [])}
    inters = world["interactables"]

    for it in inters:
        if it.get("gives_item") and it["gives_item"] not in items:
            notes.append(f"{it['id']}: dropped gives_item {it['gives_item']!r}, no such item")
            it["gives_item"] = ""

    # Only one place may hand out a given item; a second copy is duplicate loot.
    seen: set[str] = set()
    for it in inters:
        gid = it.get("gives_item", "")
        if gid and gid in seen:
            notes.append(f"{it['id']}: dropped duplicate gives_item {gid!r}")
            it["gives_item"] = ""
        elif gid:
            seen.add(gid)

    for it in inters:
        need = it.get("needs_item", "")
        if not need:
            it["locked_text"] = ""
            continue
        if need not in items:
            notes.append(f"{it['id']}: unlocked, needs_item {need!r} is not an item")
            it["needs_item"] = it["locked_text"] = ""
        elif need not in seen:
            notes.append(f"{it['id']}: unlocked, {need!r} is found nowhere")
            it["needs_item"] = it["locked_text"] = ""
        elif not it.get("locked_text"):
            it["locked_text"] = "It won't budge. Something is missing."
            notes.append(f"{it['id']}: supplied a default locked_text")

    for n in world["npcs"]:
        want = n.get("wants_item", "")
        if want and (want not in items or want not in seen):
            notes.append(f"npc {n['id']}: dropped wants_item {want!r}, unobtainable")
            n["wants_item"] = ""

    # Anything still locked behind itself. Peel in collection order and unlock
    # whatever never becomes reachable.
    held: set[str] = set()
    while True:
        gained = {
            it["gives_item"] for it in inters
            if it.get("gives_item") and it["gives_item"] not in held
            and (not it.get("needs_item") or it["needs_item"] in held)
        }
        if not gained:
            break
        held |= gained
    for it in inters:
        need = it.get("needs_item", "")
        if need and need not in held:
            notes.append(f"{it['id']}: unlocked, {need!r} was locked behind itself")
            it["needs_item"] = it["locked_text"] = ""
    for n in world["npcs"]:
        want = n.get("wants_item", "")
        if want and want not in held:
            notes.append(f"npc {n['id']}: dropped wants_item {want!r}, unobtainable")
            n["wants_item"] = ""
    return notes


def repair_village(world: dict, search: int = 9) -> list[str]:
    """Deterministic fixes for near-miss placement, run before validation.

    The model composes a village well but misses by a tile — a tree whose
    footprint clips the pond, two crates sharing a corner. Throwing the whole
    generation away for that is wasteful, so nudge each offender to the nearest
    legal spot instead, and only drop it if there is genuinely nowhere to go.

    Anything the story depends on is never dropped: a missing beat-carrying
    interactable would make the mystery unsolvable, so it is left in place for
    validate_world() to reject loudly."""
    notes: list[str] = []
    # Trim first, then repair: trimming leaves dangling references on purpose
    # and repair_items() resolves them by unlocking, which is the safe direction.
    notes += trim_items(world)
    notes += repair_items(world)
    m = world["map"]
    W, H = m["width"], m["height"]
    water = _water_cells(world)
    occupied: dict[tuple[int, int], tuple[str, str]] = {}

    def cells_at(asset: str, x: int, y: int) -> list[tuple[int, int]]:
        fw, fh = catalog.footprint(asset)
        return [(x + dx, y + dy) for dx in range(fw) for dy in range(fh)]

    def free(asset: str, x: int, y: int, mountable: bool = False) -> bool:
        for c in cells_at(asset, x, y):
            if not (0 <= c[0] < W and 0 <= c[1] < H) or c in water:
                return False
            if c in occupied and not (mountable and occupied[c][1] == "building"):
                return False
        return True

    for group in ("objects", "interactables"):
        kept = []
        for e in world[group]:
            if e.get("on"):
                kept.append(e)   # positioned by its host
                continue
            if e["asset"] not in catalog.objects():
                notes.append(f"dropped {e['id']}: unknown asset {e['asset']}")
                continue
            x0, y0 = e["x"], e["y"]
            mount = group == "interactables" and _may_mount(e["asset"])
            if not free(e["asset"], x0, y0, mount):
                for dx, dy in _spiral(search):
                    if free(e["asset"], x0 + dx, y0 + dy, mount):
                        e["x"], e["y"] = x0 + dx, y0 + dy
                        notes.append(
                            f"nudged {e['id']} ({e['asset']}) "
                            f"({x0},{y0}) -> ({e['x']},{e['y']})")
                        break
                else:
                    if group == "interactables" and e.get("beat"):
                        notes.append(f"NO ROOM for beat-carrying {e['id']}; left as-is")
                    else:
                        notes.append(f"dropped {e['id']}: nowhere legal to put it")
                        continue
            for c in cells_at(e["asset"], e["x"], e["y"]):
                occupied.setdefault(c, (e["id"], catalog.category(e["asset"])))
            kept.append(e)
        world[group] = kept

    # An attached interactable copied its coordinates from its host back in
    # resolve_attachments(), and the loop above just moved a pile of hosts. Left
    # unsynced it points at where its host USED to be — usually now solid ground
    # or the inside of another object — and validation rejects it as
    # unreachable. This was the top rejection reason across every batch measured
    # (and it scales with the repair count, which is why the worlds needing the
    # most nudging were the ones that failed).
    resynced = resolve_attachments(world)
    notes += [f"re-synced attachment: {n}" for n in resynced]
    by_host = {o["id"]: o for o in world["objects"]}
    for it in world["interactables"]:
        host = by_host.get(it.get("on", ""))
        if host is not None and (it["x"], it["y"]) != (host["x"], host["y"]):
            it["x"], it["y"] = host["x"], host["y"]
            notes.append(f"followed host: {it['id']} -> ({host['x']},{host['y']})")

    # Actors need a REACHABLE cell, not merely an unoccupied one. Taking the
    # first free tile from a spiral search happily drops the player into a
    # one-tile pocket between two houses, which then fails the reachability
    # check — so snap everyone into the largest connected walkable region.
    def walkable() -> set:
        blocked = set(water)
        for e in world["objects"] + world["interactables"]:
            if catalog.is_solid(e["asset"]):
                blocked.update(cells_at(e["asset"], e["x"], e["y"]))
        return _largest_open_region(blocked, W, H)

    main = walkable()
    if not main:
        notes.append("no walkable space at all")
        return notes

    # An interactable you cannot walk up to is dead content; pull any that ended
    # up sealed off back to the edge of the walkable region. This runs BEFORE
    # actors are placed, because moving a solid interactable changes what is
    # reachable.
    def touches(cells: list, region: set) -> bool:
        return any((cx + dx, cy + dy) in region
                   for cx, cy in cells
                   for dx, dy in ((0, 0), (1, 0), (-1, 0), (0, 1), (0, -1)))

    def touches_main(cells: list) -> bool:
        return touches(cells, main)

    ## Objects this pass has already relocated. Without it two hosts sharing a
    ## blocker shuffled it back and forth between the same two cells.
    moved_out: set[str] = set()

    # An ATTACHED interactable shares its host's cells, so it cannot be nudged
    # on its own — the host has to move and the attachment follows. Repair used
    # to skip these entirely while validation still checked them, which made a
    # door on a hemmed-in house an unfixable rejection. Measured over 6 worlds
    # (12 attempts) that was 7 of 11 rejections: the single largest reason a
    # whole generation was thrown away.
    def clear_a_doorway(cells: list) -> bool:
        """Shift whatever scenery is sealing this footprint in, rather than
        moving the footprint.

        Most sealed-in hosts are buildings, and relocating a 6x6 house needs 36
        contiguous free cells that a dense village does not have — so the move
        below almost always failed for exactly the cases that matter. The thing
        in the way is usually one tree or barrel, and moving that succeeds.
        """
        nonlocal main
        own = set(cells)
        perimeter = []
        for cx, cy in cells:
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                c = (cx + dx, cy + dy)
                if c not in own and 0 <= c[0] < W and 0 <= c[1] < H \
                        and c not in water and c in occupied:
                    perimeter.append(c)
        for c in perimeter:
            # .get, not []: perimeter is snapshotted before any move, and a
            # blocker occupying two of these cells has already been popped by
            # the time the second one comes round. Indexing raised KeyError,
            # which surfaced as a rejected attempt whose only "reason" was a
            # bare coordinate tuple.
            owner = occupied.get(c)
            if owner is None:
                continue
            oid, cat = owner
            if cat == "building" or oid in moved_out:
                continue     # moving a second building solves nothing
            blocker = next((o for o in world["objects"] if o["id"] == oid), None)
            if blocker is None:
                continue     # an interactable; its own pass will handle it
            bx, by = blocker["x"], blocker["y"]
            bcells = cells_at(blocker["asset"], bx, by)
            for c2 in bcells:
                occupied.pop(c2, None)

            placed = False
            for dx, dy in _spiral(search * 2):
                nx, ny = bx + dx, by + dy
                if (nx, ny) == (bx, by) or not free(blocker["asset"], nx, ny):
                    continue
                # Somewhere genuinely clear of this footprint. Sliding it one
                # cell along the same wall leaves it blocking and invites the
                # next host's pass to slide it straight back.
                if touches(cells_at(blocker["asset"], nx, ny), own):
                    continue
                blocker["x"], blocker["y"] = nx, ny
                for c2 in cells_at(blocker["asset"], nx, ny):
                    occupied.setdefault(c2, (oid, cat))
                placed = True
                break
            if not placed:
                for c2 in bcells:      # nowhere to go; put it back
                    occupied.setdefault(c2, (oid, cat))
                continue

            # Only keep the move if it actually opened the way. Accepting it
            # regardless is what turned one village into 112 reachable cells
            # out of 1408: two dozen objects shuffled, none of it helping.
            candidate = walkable()
            if touches(cells, candidate):
                main = candidate
                moved_out.add(oid)
                notes.append(f"moved {oid} clear ({bx},{by}) -> "
                             f"({blocker['x']},{blocker['y']})")
                return True
            for c2 in cells_at(blocker["asset"], blocker["x"], blocker["y"]):
                occupied.pop(c2, None)
            blocker["x"], blocker["y"] = bx, by
            for c2 in bcells:
                occupied.setdefault(c2, (oid, cat))
        return touches_main(cells)

    hosts = {o["id"]: o for o in world["objects"]}
    for host_id, host in hosts.items():
        attached = [i for i in world["interactables"] if i.get("on") == host_id]
        if not attached:
            continue
        cells = cells_at(host["asset"], host["x"], host["y"])
        if touches_main(cells):
            continue
        # Unblock first; only relocate the host if that fails.
        if clear_a_doorway(cells):
            continue
        x0, y0 = host["x"], host["y"]
        for dx, dy in _spiral(search * 2):
            nx, ny = x0 + dx, y0 + dy
            if not free(host["asset"], nx, ny):
                continue
            if not touches_main(cells_at(host["asset"], nx, ny)):
                continue
            for c in cells:
                occupied.pop(c, None)
            host["x"], host["y"] = nx, ny
            for c in cells_at(host["asset"], nx, ny):
                occupied.setdefault(c, (host["id"], catalog.category(host["asset"])))
            # Every attachment on this host, not just the one that flagged it.
            for i in attached:
                i["x"], i["y"] = nx, ny
            notes.append(f"moved sealed-off {host['id']} (host of "
                         f"{', '.join(i['id'] for i in attached)}) "
                         f"({x0},{y0}) -> ({nx},{ny})")
            main = walkable()
            break

    for e in world["interactables"]:
        if e.get("on"):
            continue
        cells = cells_at(e["asset"], e["x"], e["y"])
        if touches_main(cells):
            continue
        # Same trick first: a well boxed in by three trees only needs one of
        # them to step aside, and moving the well may not be possible at all.
        if clear_a_doorway(cells):
            continue
        x0, y0 = e["x"], e["y"]
        for dx, dy in _spiral(search * 2):
            nx, ny = x0 + dx, y0 + dy
            if not free(e["asset"], nx, ny, _may_mount(e["asset"])):
                continue
            if touches_main(cells_at(e["asset"], nx, ny)):
                for c in cells:
                    occupied.pop(c, None)
                e["x"], e["y"] = nx, ny
                for c in cells_at(e["asset"], nx, ny):
                    occupied.setdefault(c, (e["id"], catalog.category(e["asset"])))
                notes.append(f"moved unreachable {e['id']} ({x0},{y0}) -> ({nx},{ny})")
                main = walkable()
                break

    def snap(entry: dict, label: str) -> None:
        c = (entry["x"], entry["y"])
        if c in main:
            return
        best = min(main, key=lambda p: (p[0] - c[0]) ** 2 + (p[1] - c[1]) ** 2)
        entry["x"], entry["y"] = best
        notes.append(f"moved {label} ({c[0]},{c[1]}) -> ({best[0]},{best[1]}) "
                     f"into the walkable area")

    for n in world["npcs"]:
        snap(n, f"npc {n['id']}")
    for e in world["enemies"]:
        snap(e, f"enemy {e['id']}")
    snap(world["player_start"], "player_start")

    # Item repair, AGAIN. It ran at the top on the world as generated, but the
    # placement loop above is allowed to drop interactables — an unknown asset,
    # nowhere legal to stand — and dropping one takes its `gives_item` with it.
    # A villager was then left waiting for a shawl that no longer existed
    # anywhere, and validation rejected the whole village for it. Idempotent and
    # only ever unlocks, so running it twice is free.
    notes += [f"after placement: {n}" for n in repair_items(world)]

    return notes


def validate_story(beats: list[dict], characters: list[dict]) -> None:
    """The half of validation that needs no map. Shared by the story-only
    generation step and by validate_world().

    There is no longer a dependency graph to check — and nothing to check about
    who holds which fact, because nobody is assigned one. The old version
    verified a topological order and that every beat had an owner; both existed
    to guarantee a chain the player would be walked along, which is exactly what
    was wrong with it. What still has to hold is that every fact stands alone and
    that the goal is reachable by collecting facts in any order."""
    beat_ids = [b["id"] for b in beats]
    if not 3 <= len(beats) <= 12:
        raise WorldValidationError(f"bad beat count {len(beats)}")
    if len(set(beat_ids)) != len(beat_ids):
        raise WorldValidationError("duplicate beat ids")
    for b in beats:
        if not b.get("desc", "").strip():
            raise WorldValidationError(f"beat {b['id']} has no description")

    if not 3 <= len(characters) <= 12:
        raise WorldValidationError(f"bad npc count {len(characters)}")
    for c in characters:
        if not c.get("could_know", "").strip():
            raise WorldValidationError(
                f"npc {c['id']} has no could_know, so the director has nothing to "
                f"decide from")


_RIVAL_TINT_RE = re.compile(r"^#[0-9a-fA-F]{6}$")


def validate_rival(rival: dict | None) -> None:
    """`None`/`{}` passes — legacy worlds (old --world files, worlds the critic
    re-validates after a client push) never had a rival and still have to
    load. A present-but-malformed rival is rejected so a generated story
    never ships a mute antagonist."""
    if not rival:
        return
    for key in ("id", "name", "nature", "motive", "defeat"):
        if not str(rival.get(key, "")).strip():
            raise WorldValidationError(f"rival is missing {key}")
    if not _RIVAL_TINT_RE.match(str(rival.get("tint", ""))):
        raise WorldValidationError(f"rival tint {rival.get('tint')!r} is not #rrggbb")
    rumors = rival.get("rumors")
    if not isinstance(rumors, list) or len(rumors) != 3 or not all(
            isinstance(r, str) and r.strip() for r in rumors):
        raise WorldValidationError("rival needs exactly 3 non-empty rumors")
    taunts = rival.get("taunts")
    if not isinstance(taunts, list) or len(taunts) != 2 or not all(
            isinstance(t, str) and t.strip() for t in taunts):
        raise WorldValidationError("rival needs exactly 2 non-empty taunts")


def escalation_act(n_revealed_conditions: int, n_conditions: int) -> int:
    """Which of 4 acts the story is in, purely from how many of the ending's
    condition beats are known. A ratchet, not a rate: callers should fire
    every act crossed since the last check, in order, not just the latest.

    0 = nothing found yet. 1-3 = rising tension (one rumor/spawn wave each).
    4 = every condition beat known — the showdown. Mirrored in GDScript by
    GameState._escalate() since the client learns of a reveal before the
    server ever does (see build_system_prompt's docstring)."""
    if n_conditions <= 0 or n_revealed_conditions <= 0:
        return 0
    if n_revealed_conditions >= n_conditions:
        return 4
    return max(1, min(3, math.ceil(3 * n_revealed_conditions / n_conditions)))


def validate_world(world: dict) -> None:
    """Raises WorldValidationError on any problem. This is the last line of
    defence between the model and an unplayable map."""
    m = world["map"]
    w, h = m["width"], m["height"]

    # Structured outputs reject `minimum`/`maximum` on integers, so every
    # numeric range in this document is advisory in the schema and enforced
    # here instead.
    if not (MAP_MIN[0] <= w <= MAP_MAX[0] and MAP_MIN[1] <= h <= MAP_MAX[1]):
        raise WorldValidationError(
            f"map {w}x{h} outside {MAP_MIN[0]}-{MAP_MAX[0]} by {MAP_MIN[1]}-{MAP_MAX[1]}")
    for r in m["regions"]:
        if r["w"] < 2 or r["h"] < 2:
            raise WorldValidationError(f"region {r} is thinner than 2 tiles")
    for p in m["paths"]:
        if not 1 <= p["width"] <= 3:
            raise WorldValidationError(f"path width {p['width']} not in 1-3")
        if len(p["points"]) < 2:
            raise WorldValidationError("a path needs at least 2 points")

    beats = world["beats"]
    beat_ids = [b["id"] for b in beats]
    npcs = world["npcs"]
    validate_story(beats, npcs)

    for it in world["interactables"]:
        if it["beat"] and it["beat"] not in beat_ids:
            raise WorldValidationError(
                f"interactable {it['id']} reveals unknown beat {it['beat']}")
    cond = world["ending"]["condition_beats"]
    if not cond or set(cond) - set(beat_ids):
        raise WorldValidationError(f"bad ending condition_beats {cond}")

    goal = world.get("goal", {})
    if not str(goal.get("summary", "")).strip():
        raise WorldValidationError(
            "the world has no goal summary — with no beat ordering left, the goal "
            "is the only thing telling the player what they are doing")

    validate_items(world)
    validate_rival(world.get("rival"))

    # --- ids unique across every placed entity ------------------------------
    all_entities = (world["objects"] + world["interactables"]
                    + world["npcs"] + world["enemies"])
    ids = [e["id"] for e in all_entities]
    dupes = {i for i in ids if ids.count(i) > 1}
    if dupes:
        raise WorldValidationError(f"duplicate entity ids: {sorted(dupes)}")

    # --- the map's own geometry, before anything placed on it ---------------
    for r in m["regions"]:
        if not (0 <= r["x"] and 0 <= r["y"]
                and r["x"] + r["w"] <= w and r["y"] + r["h"] <= h):
            raise WorldValidationError(f"region {r} outside the {w}x{h} map")

    # --- bounds + overlap + nothing standing in the pond --------------------
    water = _water_cells(world)
    occupied: dict[tuple[int, int], tuple[str, str]] = {}
    interactable_ids = {e["id"] for e in world["interactables"]}
    for entry in world["objects"] + world["interactables"]:
        if entry["asset"] not in catalog.objects():
            raise WorldValidationError(f"{entry['id']}: unknown asset {entry['asset']}")
        is_interactable = entry["id"] in interactable_ids
        if entry.get("on"):
            continue  # shares its host's footprint; the host was already checked
        for cx, cy in _cells_for(entry):
            if not (0 <= cx < w and 0 <= cy < h):
                raise WorldValidationError(
                    f"{entry['id']} ({entry['asset']}) extends outside the {w}x{h} map")
            if (cx, cy) in occupied:
                other_id, other_cat = occupied[(cx, cy)]
                # A door or sign mounted on a house is the point of a door, not
                # a collision. Everything else that shares a tile is a bug.
                if not (is_interactable and other_cat == "building"
                        and _may_mount(entry["asset"])):
                    raise WorldValidationError(
                        f"{entry['id']} overlaps {other_id} at ({cx},{cy})")
                continue
            if (cx, cy) in water:
                raise WorldValidationError(
                    f"{entry['id']} ({entry['asset']}) is standing in water at ({cx},{cy})")
            occupied[(cx, cy)] = (entry["id"], catalog.category(entry["asset"]))

    for n in npcs:
        if (n["x"], n["y"]) in water:
            raise WorldValidationError(f"npc {n['id']} is standing in water")
    for e in world["enemies"]:
        if (e["x"], e["y"]) in water:
            raise WorldValidationError(f"enemy {e['id']} is standing in water")

    # --- reachability: the check that stops the player being walled in ------
    blocked, _, _ = _solid_map(world)
    start = (world["player_start"]["x"], world["player_start"]["y"])
    if not (0 <= start[0] < w and 0 <= start[1] < h):
        raise WorldValidationError(f"player_start {start} outside the map")
    if start in blocked:
        raise WorldValidationError(f"player_start {start} is inside something solid")
    open_cells = _reachable(blocked, w, h, start)
    if len(open_cells) < (w * h) * 0.15:
        raise WorldValidationError(
            f"only {len(open_cells)} of {w * h} cells reachable — the map is choked")

    def _adjacent_open(x: int, y: int) -> bool:
        return any((x + dx, y + dy) in open_cells
                   for dx, dy in ((0, 0), (1, 0), (-1, 0), (0, 1), (0, -1)))

    for n in npcs:
        if not _adjacent_open(n["x"], n["y"]):
            raise WorldValidationError(f"npc {n['id']} at ({n['x']},{n['y']}) is unreachable")
    for e in world["enemies"]:
        if not _adjacent_open(e["x"], e["y"]):
            raise WorldValidationError(f"enemy {e['id']} is unreachable")
    for it in world["interactables"]:
        # An interactable is reachable if any cell of its footprint touches open
        # ground — you interact from beside it, not on top of it.
        if not any(_adjacent_open(cx, cy) for cx, cy in _cells_for(it)):
            raise WorldValidationError(
                f"interactable {it['id']} ({it['asset']}) cannot be reached")


def coerce_numbers(value):
    """Godot's JSON parser represents every number as a float, so a world that
    has round-tripped through the client comes back with 9.0 where the schema
    says 9 — and range() then raises TypeError deep inside validation. Nothing
    in a world document is legitimately fractional, so integral floats become
    ints at the boundary."""
    if isinstance(value, bool):
        return value
    if isinstance(value, float):
        return int(value) if value.is_integer() else value
    if isinstance(value, dict):
        return {k: coerce_numbers(v) for k, v in value.items()}
    if isinstance(value, list):
        return [coerce_numbers(v) for v in value]
    return value


def load_fallback() -> dict:
    world = json.loads(FALLBACK_PATH.read_text())
    add_item_fields(world)
    return world


def generate_validated(seed: str = "") -> tuple[dict, str]:
    """Generate -> validate -> retry once on the same seed -> fall back.

    zij3d shipped without the retry and a single bad graph dropped it all the
    way to static content; one more attempt recovers most of those.
    Returns (world, source) where source is "generated" | "retry" | "fallback".
    """
    if not seed:
        seed = random_seed()
    if not llm.available():
        print("worldgen: no API key configured — using the fallback world", file=sys.stderr)
        return load_fallback(), "fallback"

    for attempt, label in ((0, "generated"), (1, "retry")):
        try:
            world = generate_world(seed)
            validate_world(world)
            return world, label
        except WorldValidationError as exc:
            print(f"worldgen: attempt {attempt + 1} failed: {exc}", file=sys.stderr)
        except Exception as exc:  # noqa: BLE001 — any failure must stay playable
            # Name the type. A KeyError in the repair pass printed nothing but
            # its key, so a genuine crash of mine sat in the batch report
            # disguised as a rejection reason reading "(14, 21)".
            print(f"worldgen: attempt {attempt + 1} CRASHED: "
                  f"{type(exc).__name__}: {exc}", file=sys.stderr)
            traceback.print_exc(file=sys.stderr)
    return load_fallback(), "fallback"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--seed", default="", help="inspiration seed; random if omitted")
    ap.add_argument("--fallback", action="store_true",
                    help="load fallback_world.json instead of calling the model")
    ap.add_argument("--validate-only", action="store_true",
                    help="validate and report; do not print the world")
    ap.add_argument("--out", default="", help="write the world JSON here")
    args = ap.parse_args(argv)

    if args.fallback:
        world, source = load_fallback(), "fallback"
        validate_world(world)
    else:
        world, source = generate_validated(args.seed)

    print(f"source={source} seed={world.get('seed', '-')!r} title={world['title']!r}",
          file=sys.stderr)
    m = world["map"]
    print(f"map={m['width']}x{m['height']} objects={len(world['objects'])} "
          f"interactables={len(world['interactables'])} npcs={len(world['npcs'])} "
          f"enemies={len(world['enemies'])} beats={len(world['beats'])}", file=sys.stderr)

    if args.out:
        Path(args.out).write_text(json.dumps(world, indent=2))
        print(f"wrote {args.out}", file=sys.stderr)
    elif not args.validate_only:
        print(json.dumps(world, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
