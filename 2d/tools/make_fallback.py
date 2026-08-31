#!/usr/bin/env python3
"""Builds backend/fallback_world.json — the hand-authored village the game falls
back to when there is no API key, the network is down, or two generation
attempts both fail validation. It exists so the game ALWAYS boots.

Written as a script rather than typed as JSON so it stays readable, and so it is
checked by the same validate_world() the model's output goes through. If the
catalog changes underneath it, this fails loudly instead of shipping a broken
fallback.

    python3 tools/make_fallback.py
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "backend"))

import worldgen  # noqa: E402

W, H = 40, 30


def obj(oid: str, asset: str, x: int, y: int) -> dict:
    return {"id": oid, "asset": asset, "x": x, "y": y}


def npc(nid, x, y, name, role, persona, secret, could_know, opener, tint,
        movement="idle", wants_item=""):
    """`could_know` is a vantage point, not a list of facts.

    It used to be `knows_beats` — the beat ids this character was allowed to
    reveal — which is precisely what made the mystery a queue. Any villager can
    now supply any undiscovered fact; this only tells the director whether it
    would be in character coming from them."""
    return {"id": nid, "x": x, "y": y, "name": name, "role": role,
            "persona": persona, "secret": secret, "could_know": could_know,
            "opener": opener, "movement": movement, "tint": tint,
            "wants_item": wants_item}


WORLD = {
    "title": "The Quiet Bell",
    "premise": ("Every morning the bell over Hollowbrook rings to wake the village. "
                "This morning it did not, and nobody can find the rope."),
    "hidden_truth": ("A family of jackdaws wove the bell rope into a nest in the old "
                     "oak. Tomas saw them do it and said nothing, because the quiet "
                     "let his sick mother sleep through the night for the first time "
                     "in weeks."),
    "seed": "a bell tower gone silent",

    "goal": {
        "summary": "find out what happened to the bell rope",
        "detail": ("Work out where the rope went and who took it. Four things "
                   "need piecing together, and it does not matter which you "
                   "find first."),
    },

    "items": [
        {"id": "black_feather", "name": "a glossy black feather",
         "text": "It is longer than your hand, and very black. A jackdaw's."},
    ],
    "map": {
        "width": W, "height": H,
        "base_terrain": "grass",
        "regions": [
            {"terrain": "dirt", "x": 12, "y": 12, "w": 16, "h": 9},
            {"terrain": "water", "x": 29, "y": 2, "w": 8, "h": 6},
        ],
        "paths": [
            {"points": [{"x": 3, "y": 27}, {"x": 24, "y": 27},
                        {"x": 24, "y": 17}, {"x": 35, "y": 17}], "width": 2},
        ],
    },
    "player_start": {"x": 5, "y": 27},

    # Scenery: houses along the top, a treeline framing the edges.
    # Every object's x,y is its BOTTOM-LEFT tile, so it occupies
    # x..x+w-1 and y-h+1..y — easy to get wrong, hence validate_world().
    "objects": [
        obj("house_north", "building.house_hay_2", 4, 9),      # 10x7 -> x4..13 y3..9
        obj("house_east", "building.house_hay_1", 22, 9),      # 6x6  -> x22..27 y4..9
        obj("house_west", "building.house_hay_4_purple", 2, 25),  # 8x8 -> x2..9 y18..25
        obj("gate", "building.citywall_gate_1", 34, 28),       # 5x6  -> x34..38 y23..28
        obj("oak", "tree.tree_emerald_3", 16, 9),              # 4x6  -> x16..19 y4..9
        obj("tree_w1", "tree.tree_emerald_1", 0, 16),          # 4x4  -> x0..3  y13..16
        obj("tree_w2", "tree.tree_emerald_2", 0, 6),           # 3x4  -> x0..2  y3..6
        obj("tree_e1", "tree.tree_emerald_4", 37, 14),         # 3x6  -> x37..39 y9..14
        obj("tree_e2", "tree.tree_emerald_1", 30, 29),         # 4x4  -> x30..33 y26..29
        obj("tree_s1", "tree.tree_emerald_2", 25, 29),         # 3x4  -> x25..27 y26..29
        obj("bush_a", "tree.bush_emerald_1", 11, 25),
        obj("bush_b", "tree.bush_emerald_3", 15, 25),
        obj("bush_c", "tree.bush_emerald_4", 21, 25),
        obj("rock_a", "rock.rock_brown_4", 29, 24),
        obj("rock_b", "rock.rock_brown_1", 33, 21),
        obj("hay", "prop.haystack_2", 11, 20),
        obj("plant_a", "prop.plant_2", 31, 13),
    ],

    # Interactables: the world's voice.
    "interactables": [
        {"id": "well", "asset": "building.well_hay_1", "x": 18, "y": 20,
         "text": "The village well. The water is dark and still, and far below "
                 "something pale is caught on the stones.",
         "beat": "rope_in_well"},
        {"id": "notice", "asset": "prop.bulletinboard_1", "x": 13, "y": 19,
         "text": "LOST — one bell rope, three fathoms, good hemp. Ask for Mira "
                 "at the tower. A reward of two honey cakes.",
         "beat": "rope_missing"},
        {"id": "signpost", "asset": "prop.sign_1", "x": 22, "y": 27,
         "text": "HOLLOWBROOK — please walk quietly past the oak, the birds are "
                 "nesting.", "beat": ""},
        {"id": "chest", "asset": "prop.crate_large_empty", "x": 27, "y": 20,
         "text": "Inside: a coil of fresh hemp, still smelling of tar, and a "
                 "single glossy black feather.",
         "beat": "feather_found", "gives_item": "black_feather"},
        {"id": "bench", "asset": "prop.bench_1", "x": 17, "y": 24,
         "text": "A worn bench facing the square. Someone has been sitting here "
                 "a long time.", "beat": ""},
        {"id": "barrel", "asset": "prop.barrel_small_empty", "x": 10, "y": 15,
         "text": "An empty rain barrel. A scrap of hemp twine is snagged on the rim.",
         "beat": "twine_snagged"},
    ],

    "npcs": [
        npc("mira", 20, 15, "Mira", "bell-ringer",
            "Brisk and practical, worried but trying not to show it.",
            "She overslept for the first time in nine years and is embarrassed.",
            "Rings the bell every morning, so she was first to find it gone; she is up and about before anyone else",
            "You're up early! Then again — nothing woke anyone this morning, did it?",
            "#c94f4f"),
        # Tomas is the fallback's item puzzle: he won't admit what he saw until
        # you show him the feather from the crate, which proves you already
        # half-know. Exercises gives_item -> wants_item end to end.
        npc("tomas", 11, 23, "Tomas", "boy",
            "Quiet, kind, changes the subject quickly.",
            "He saw the jackdaws take the rope and said nothing.",
            "Out early with his sick mother's errands, and spends a lot of time looking up at the oak",
            "Oh — hello. It's nice, isn't it? How quiet it is.",
            "#4f7dc9", wants_item="black_feather"),
        npc("harun", 25, 13, "Harun", "rope-maker",
            "Booming, generous, proud of his craft.",
            "He gave Tomas the new coil of hemp for free and won't say why.",
            "Made the rope himself and knows every fibre of it; scraps of his hemp turn up all over the village",
            "Three fathoms of my best hemp, gone! Come, look at this.",
            "#3f8f5a", movement="wander"),
        npc("eda", 15, 26, "Eda", "beekeeper",
            "Slow, observant, speaks in small certainties.",
            "She has watched the oak all week and knows exactly what is in it.",
            "Keeps bees at the foot of the old oak and watches that tree all day long",
            "The birds have been busy. Busier than the bees, this week.",
            "#d8a13a", movement="wander"),
        npc("sefa", 33, 18, "Sefa", "carter",
            "Impatient, always halfway out of the gate, secretly fond of the place.",
            "She'd offered to buy the village a new bell rope and was refused.",
            "Drives the cart in and out past the oak and the well several times a day",
            "If that bell doesn't ring I'll not know when to leave. Suits me fine.",
            "#8a5ac9"),
    ],

    "enemies": [
        {"id": "slime_pond", "x": 29, "y": 11, "behavior": "wander"},
        {"id": "slime_wood", "x": 6, "y": 15, "behavior": "wander"},
    ],

    "beats": [
        {"id": "rope_missing", "desc": "The bell rope has gone missing overnight.", "hint": "Someone mentions the morning felt strange and late."},
        {"id": "twine_snagged", "desc": "Scraps of the same hemp twine are turning up "
                                        "around the village.", "hint": "A neighbour grumbles about bits of string everywhere."},
        {"id": "jackdaws_seen", "desc": "Jackdaws were seen carrying something long "
                                        "and pale up into the old oak.",
         "hint": "Someone glances up at the oak and then quickly away."},
        {"id": "feather_found", "desc": "A glossy black feather was left where the "
                                        "rope should have been.",
         "hint": "There's talk of a feather turning up somewhere odd."},
        {"id": "nest_in_oak", "desc": "There is a new nest high in the old oak, woven "
                                      "through with rope.",
         "hint": "The oak has looked different these last few days."},
        {"id": "rope_in_well", "desc": "The frayed end of the rope hangs down into "
                                       "the well, where a bird dropped it.",
         "hint": "The well rope feels heavier than it used to."},
    ],

    "ending": {
        "condition_beats": ["rope_missing", "jackdaws_seen", "nest_in_oak", "rope_in_well"],
        "finale": ("The village leaves the nest exactly where it is and hangs Harun's "
                   "new rope instead. Mira rings the bell an hour later than usual, "
                   "every morning, until the young jackdaws have flown. Tomas's mother "
                   "sleeps through all of it."),
    },

    "rival": {
        "id": "the_hush",
        "name": "The Hush",
        "nature": "a sulky little fog spirit",
        "motive": "it has loved the quiet mornings since the bell fell silent, and does not want them to end",
        "tint": "#7a4fc9",
        "rumors": [
            "The dogs won't settle at dawn this week, for no reason anyone can name.",
            "Mist has been pooling by the oak at first light, thicker than it should be.",
            "Something in the mist is watching the well now, and it isn't shy about it.",
        ],
        "taunts": [
            "Oh, must you? It was SO peaceful.",
            "Fine, fine — I can be loud too, you know!",
        ],
        "defeat": ("The Hush deflates into a small damp cloud, sniffs, and drifts off "
                   "to go be quiet somewhere it won't be bothered — the bottom of the "
                   "well, probably, once the rope's out of it."),
    },
}


def _add_attachment_field(world: dict) -> None:
    """`on` is required by the schema (structured outputs require every
    property); "" means "place your own art", which is what the fallback does.
    The item fields are the same story."""
    for e in world["interactables"]:
        e.setdefault("on", "")
    worldgen.add_item_fields(world)


def _to_top_left(world: dict) -> None:
    """The layout above is authored with x,y as each object's BOTTOM-left tile,
    because that is how you naturally reason about where a house *sits*. The
    schema uses TOP-left (consistent with terrain regions), so convert here
    rather than re-deriving every coordinate by hand."""
    for group in ("objects", "interactables"):
        for e in world[group]:
            _, h = worldgen.catalog.footprint(e["asset"])
            e["y"] = e["y"] - h + 1


def main() -> int:
    _add_attachment_field(WORLD)
    _to_top_left(WORLD)
    WORLD["version"] = worldgen.WORLD_VERSION
    try:
        worldgen.validate_world(WORLD)
    except worldgen.WorldValidationError as exc:
        print(f"FALLBACK IS INVALID: {exc}", file=sys.stderr)
        return 1
    dest = ROOT / "backend" / "fallback_world.json"
    dest.write_text(json.dumps(WORLD, indent=2) + "\n")
    m = WORLD["map"]
    print(f"ok — wrote {dest.relative_to(ROOT)} "
          f"({m['width']}x{m['height']}, {len(WORLD['objects'])} objects, "
          f"{len(WORLD['interactables'])} interactables, {len(WORLD['npcs'])} npcs, "
          f"{len(WORLD['beats'])} beats)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
