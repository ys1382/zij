"""Validator tests. No API key or network needed — these feed deliberately
broken worlds to validate_world() and assert it rejects each one.

validate_world is the only thing standing between a bad generation and an
unplayable map, so a silent regression here is expensive.

    python3 backend/test_worldgen.py
"""
from __future__ import annotations

import copy
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import worldgen
from worldgen import WorldValidationError, validate_world

BASE = worldgen.load_fallback()

_results: list[tuple[bool, str]] = []


def expect_reject(label: str, mutate, needle: str = "") -> None:
    w = copy.deepcopy(BASE)
    mutate(w)
    try:
        validate_world(w)
    except WorldValidationError as exc:
        ok = needle.lower() in str(exc).lower()
        _results.append((ok, f"{label}: {'rejected' if ok else 'wrong reason'} — {exc}"))
    else:
        _results.append((False, f"{label}: ACCEPTED a world that should be invalid"))


def expect_accept(label: str, mutate=None) -> None:
    w = copy.deepcopy(BASE)
    if mutate:
        mutate(w)
    try:
        validate_world(w)
    except WorldValidationError as exc:
        _results.append((False, f"{label}: rejected a valid world — {exc}"))
    else:
        _results.append((True, f"{label}: accepted"))


def _check(label: str, cond: bool, detail: str = "") -> None:
    _results.append((cond, f"{label}: {'ok' if cond else 'FAILED'} {detail}".rstrip()))


expect_accept("the shipped fallback world")

# --- geometry ---------------------------------------------------------------
expect_reject("object off the east edge",
              lambda w: w["objects"][0].update(x=38), "outside")
# x,y is the object's TOP-LEFT tile, so overhanging the top needs a negative y.
expect_reject("object off the top edge",
              lambda w: w["objects"][0].update(y=-1), "outside")
expect_reject("object off the bottom edge",
              lambda w: w["objects"][0].update(y=28), "outside")
expect_reject("two objects on the same tile",
              lambda w: w["objects"][1].update(
                  x=w["objects"][0]["x"], y=w["objects"][0]["y"]), "overlap")
expect_reject("region larger than the map",
              lambda w: w["map"]["regions"].append(
                  {"terrain": "water", "x": 30, "y": 20, "w": 20, "h": 20}), "outside")
expect_reject("unknown asset id",
              lambda w: w["objects"][0].update(asset="prop.dragon_statue"), "unknown asset")

# --- the player -------------------------------------------------------------
expect_reject("player start inside a house",
              lambda w: w["player_start"].update(x=5, y=22), "solid")
expect_reject("player start off the map",
              lambda w: w["player_start"].update(x=99, y=99), "outside")


def _wall_the_player_in(w: dict) -> None:
    """Ring the player start with solid rocks — the classic failure the
    reachability flood-fill exists to catch. Move the start to open ground
    first so the overlap check doesn't fire on a house and mask the real test."""
    w["player_start"].update(x=20, y=12)
    px, py = w["player_start"]["x"], w["player_start"]["y"]
    n = 0
    for dx in (-2, -1, 0, 1, 2):
        for dy in (-2, -1, 0, 1, 2):
            if max(abs(dx), abs(dy)) != 2:
                continue
            n += 1
            w["objects"].append({"id": f"wall_{n}", "asset": "rock.rock_brown_6",
                                 "x": px + dx, "y": py + dy})


expect_reject("player walled in by rocks", _wall_the_player_in, "choked")


def _strand_an_npc(w: dict) -> None:
    """Drop an NPC in the middle of the pond, which is solid water."""
    w["npcs"][0].update(x=32, y=5)


expect_reject("npc stranded in the pond", _strand_an_npc, "water")
expect_reject("a building standing in the pond",
              lambda w: w["interactables"][0].update(x=30, y=6), "in water")
expect_accept("a road bridging the pond",
              lambda w: w["map"]["paths"].append(
                  {"points": [{"x": 28, "y": 5}, {"x": 38, "y": 5}], "width": 1}))

# --- the story -------------------------------------------------------------
# There is no dependency graph any more, so the tests that used to live here —
# unknown `requires`, no root beat, a cycle, a beat owned by nobody — are gone
# along with the thing they protected. Every one of them existed to guarantee an
# order the player would be marched along, which is what made the game feel like
# a queue. What still matters is that each fact stands alone and the goal is
# reachable by collecting them in any order.
expect_reject("duplicate beat ids",
              lambda w: w["beats"][1].update(id=w["beats"][0]["id"]), "duplicate")
expect_reject("a beat with no description",
              lambda w: w["beats"][1].update(desc="   "), "no description")
expect_reject("a villager with no vantage point",
              lambda w: w["npcs"][1].update(could_know=""), "could_know")
expect_reject("interactable reveals an unknown beat",
              lambda w: w["interactables"][0].update(beat="not_a_beat"), "unknown beat")
expect_reject("ending needs a beat that doesn't exist",
              lambda w: w["ending"].update(condition_beats=["nope"]), "condition_beats")
expect_reject("two entities share an id",
              lambda w: w["npcs"][0].update(id=w["objects"][0]["id"]), "duplicate entity")
# The goal replaced the beat ordering as the thing that tells the player what to
# do, and it was dropped on the floor by _merge() the first time round: the
# schema had it, generation produced it, and every generated world arrived with
# goal=None because nothing copied it across.
expect_reject("a world with no goal",
              lambda w: w["goal"].update(summary="  "), "no goal")

# --- the rival ---------------------------------------------------------------
# Unseen all game, so nothing about it touches the map — only its own fields.
expect_reject("rival with no name",
              lambda w: w["rival"].update(name="  "), "rival is missing name")
expect_reject("rival with no motive",
              lambda w: w["rival"].update(motive=""), "rival is missing motive")
expect_reject("rival tint isn't #rrggbb",
              lambda w: w["rival"].update(tint="purple"), "not #rrggbb")
expect_reject("rival has only 2 rumors",
              lambda w: w["rival"].update(rumors=w["rival"]["rumors"][:2]), "3 non-empty rumors")
expect_reject("rival has only 1 taunt",
              lambda w: w["rival"].update(taunts=w["rival"]["taunts"][:1]), "2 non-empty taunts")
expect_accept("a legacy world with no rival at all",
              lambda w: w.pop("rival"))


def _escalation_act_table() -> None:
    """Pure function, mirrored in GameState._escalate() on the Godot side
    because the client always learns of a reveal before the server does (see
    build_system_prompt's docstring) — pinning the table here catches drift
    in the Python half; the bridge's showdown leg exercises the GDScript
    half end to end."""
    cases = [
        (0, 4, 0), (1, 4, 1), (2, 4, 2), (3, 4, 3), (4, 4, 4),
        (1, 3, 1), (2, 3, 2), (2, 5, 2), (4, 5, 3),
    ]
    for n, t, want in cases:
        got = worldgen.escalation_act(n, t)
        _check(f"escalation_act({n},{t}) == {want}", got == want, f"(got {got})")


_escalation_act_table()


def _no_order_is_imposed() -> None:
    """Any fact must be revealable at any time, from anyone.

    The whole point of the change: with a dependency graph, a fact stayed locked
    until its prerequisites were met no matter who the player asked, so the
    village had a reading order. Nothing in a world document should be able to
    express "not yet".
    """
    w = copy.deepcopy(BASE)
    leftover = [k for b in w["beats"] for k in b if k not in ("id", "desc", "hint")]
    _check("beats carry no ordering fields", not leftover, f"(found {sorted(set(leftover))})")
    owners = [k for n in w["npcs"] for k in n if k == "knows_beats"]
    _check("villagers are not pre-assigned facts", not owners)


_no_order_is_imposed()


# --- attachment recovery -----------------------------------------------------
# Not a validator test: resolve_attachments runs BEFORE validation and decides
# whether an interactable survives at all. A real generation emitted six
# interactables with a blank asset and a blank `on`, each named after an object
# it had placed; every one was dropped as "unknown asset ''".

def _attachment_recovery() -> None:
    w = copy.deepcopy(BASE)
    host = w["objects"][0]["id"]
    w["interactables"].append(
        {"id": f"{host}_look", "asset": "", "x": 0, "y": 0, "text": "", "beat": "",
         "on": ""})
    # An interactable whose id matches nothing must NOT be given a host.
    w["interactables"].append(
        {"id": "nowhere_look", "asset": "", "x": 0, "y": 0, "text": "", "beat": "",
         "on": ""})
    worldgen.resolve_attachments(w)
    found = {i["id"]: i for i in w["interactables"]}
    _check("blank interactable named after an object is attached",
           found[f"{host}_look"]["on"] == host,
           f"(on={found[f'{host}_look']['on']!r})")
    _check("blank interactable naming nothing is left alone",
           found["nowhere_look"]["on"] == "")


_attachment_recovery()


# --- items -------------------------------------------------------------------
# A lock-and-key puzzle is the easiest thing for a model to make unsolvable, and
# every one of these worlds passes the geometry checks perfectly.

def _lock(w: dict, target: str, need: str, text: str = "Locked.") -> None:
    it = next(i for i in w["interactables"] if i["id"] == target)
    it["needs_item"] = need
    it["locked_text"] = text


expect_reject("an interactable needs an item that doesn't exist",
              lambda w: _lock(w, "well", "no_such_key"), "unknown item")

expect_reject("an interactable needs a real item nobody has to give",
              lambda w: (w["items"].append(
                  {"id": "ghost_key", "name": "a key", "text": ""}),
                  _lock(w, "well", "ghost_key")),
              "found nowhere")


def _key_inside_its_own_lock(w: dict) -> None:
    """The classic: the feather is in the crate, and the crate needs the feather."""
    _lock(w, "chest", "black_feather")


expect_reject("the key is locked inside the thing it opens",
              _key_inside_its_own_lock, "locked behind themselves")


def _mutual_deadlock(w: dict) -> None:
    w["items"].append({"id": "iron_key", "name": "an iron key", "text": ""})
    next(i for i in w["interactables"] if i["id"] == "barrel")["gives_item"] = "iron_key"
    _lock(w, "chest", "iron_key")        # the feather needs the key
    _lock(w, "barrel", "black_feather")  # the key needs the feather


expect_reject("two items each locked behind the other", _mutual_deadlock,
              "locked behind themselves")

expect_reject("a locked interactable that never says why",
              lambda w: _lock(w, "well", "black_feather", text=""),
              "no locked_text")

expect_reject("an npc wants an item that doesn't exist",
              lambda w: w["npcs"][0].__setitem__("wants_item", "nope"),
              "unknown item")

expect_accept("a solvable chain: the crate gives the feather, the well needs it",
              lambda w: _lock(w, "well", "black_feather"))


def _repair_unlocks_a_deadlock() -> None:
    w = copy.deepcopy(BASE)
    _key_inside_its_own_lock(w)
    notes = worldgen.repair_items(w)
    chest = next(i for i in w["interactables"] if i["id"] == "chest")
    _check("repair unlocks a self-locked item rather than failing the world",
           chest["needs_item"] == "" and any("locked behind itself" in n for n in notes),
           f"(notes={notes})")
    try:
        validate_world(w)
    except WorldValidationError as exc:
        _check("the repaired world then validates", False, f"— {exc}")
    else:
        _check("the repaired world then validates", True)


_repair_unlocks_a_deadlock()


def _trim_keeps_the_load_bearing_items() -> None:
    w = copy.deepcopy(BASE)
    # Five items, close to the model's natural output: one a villager wants, one
    # that locks something, three that do nothing. Only the first two survive.
    for n in range(3):
        w["items"].append({"id": f"filler{n}", "name": f"filler {n}", "text": ""})
    w["items"].append({"id": "iron_key", "name": "an iron key", "text": ""})
    next(i for i in w["interactables"] if i["id"] == "barrel")["gives_item"] = "iron_key"
    _lock(w, "well", "iron_key")

    notes = worldgen.trim_items(w)
    kept = sorted(i["id"] for i in w["items"])
    _check("trim keeps the wanted and the locking item, drops the filler",
           kept == ["black_feather", "iron_key"], f"(kept={kept}, notes={notes})")

    worldgen.repair_items(w)
    try:
        validate_world(w)
    except WorldValidationError as exc:
        _check("the trimmed world still validates", False, f"— {exc}")
    else:
        _check("the trimmed world still validates", True)


def _trim_leaves_one_errand() -> None:
    w = copy.deepcopy(BASE)
    for n in w["npcs"]:
        n["wants_item"] = "black_feather"
    worldgen.trim_items(w)
    wanters = [n["id"] for n in w["npcs"] if n.get("wants_item")]
    _check("trim leaves at most one villager waiting on an item",
           len(wanters) == worldgen.MAX_WANTERS, f"(wanters={wanters})")


_trim_keeps_the_load_bearing_items()
_trim_leaves_one_errand()


def _sealed_off_host_is_rescued() -> None:
    """An interactable attached to an object cut off from the walkable region.

    Repair used to skip attached interactables (they have no position of their
    own) while validate_world still checked them, so a door on a hemmed-in
    building was an unfixable rejection. Over 6 generated worlds that was 7 of
    11 rejected attempts — the largest single cause of a discarded generation.
    """
    w = copy.deepcopy(BASE)
    # Wall off the top-left 5x5 corner with water so it is no longer part of the
    # largest connected region, then put a host + its attachment inside it.
    # 2 tiles thick: the schema rejects thinner regions.
    w["map"]["regions"].append(
        {"terrain": "water", "shape": "rect", "x": 0, "y": 5, "w": 7, "h": 2})
    w["map"]["regions"].append(
        {"terrain": "water", "shape": "rect", "x": 5, "y": 0, "w": 2, "h": 7})
    w["objects"].append(
        {"id": "shed", "asset": "prop.crate_large_empty", "x": 1, "y": 1})
    w["interactables"].append(
        {"id": "shed_open", "asset": "", "x": 0, "y": 0, "text": "A shed.",
         "beat": "", "on": "shed", "gives_item": "", "needs_item": "",
         "locked_text": ""})

    worldgen.resolve_attachments(w)
    before = (w["objects"][-1]["x"], w["objects"][-1]["y"])
    worldgen.repair_village(w)
    shed = next(o for o in w["objects"] if o["id"] == "shed")
    door = next(i for i in w["interactables"] if i["id"] == "shed_open")

    _check("a sealed-off host is moved out of the pocket",
           (shed["x"], shed["y"]) != before, f"(still at {before})")
    _check("its attachment moves with it",
           (door["x"], door["y"]) == (shed["x"], shed["y"]),
           f"(host={(shed['x'], shed['y'])} door={(door['x'], door['y'])})")
    try:
        validate_world(w)
    except WorldValidationError as exc:
        _check("the rescued world validates", False, f"— {exc}")
    else:
        _check("the rescued world validates", True)


_sealed_off_host_is_rescued()


def _attachment_follows_a_nudged_host() -> None:
    """An attached interactable must not be left at its host's old coordinates.

    resolve_attachments() copies the host's position once, at generation time,
    and repair_village() then nudges dozens of objects. Nothing re-synced the
    attachments, so a door pointed at where its house used to be — usually solid
    ground by then — and validation rejected it as unreachable. This was the top
    rejection reason in every measured batch, and it scaled with the repair
    count: the worlds needing the most nudging were exactly the ones discarded.
    """
    w = copy.deepcopy(BASE)
    house = next(o for o in w["objects"] if o["asset"].startswith("building."))
    w["interactables"].append(
        {"id": "front_door", "asset": "", "x": 0, "y": 0, "text": "A door.",
         "beat": "", "on": house["id"], "gives_item": "", "needs_item": "",
         "locked_text": ""})
    worldgen.resolve_attachments(w)
    house["x"] += 3          # what the placement loop does when it nudges
    worldgen.repair_village(w)

    h = next(o for o in w["objects"] if o["id"] == house["id"])
    d = next(i for i in w["interactables"] if i["id"] == "front_door")
    _check("an attachment follows its host after a nudge",
           (d["x"], d["y"]) == (h["x"], h["y"]),
           f"(host={(h['x'], h['y'])} door={(d['x'], d['y'])})")


_attachment_follows_a_nudged_host()


def _repair_never_shuffles_the_same_object_twice() -> None:
    """No object may be relocated more than once by the unblocking pass.

    The first version accepted any move that found a free cell, without
    checking whether it helped. Two hosts sharing a blocker then pushed it back
    and forth between the same two tiles — 22 moves in one village, ending with
    112 of 1408 cells reachable and the whole generation discarded. Aggregate
    batch metrics hid this completely; it only showed up in a boot log.
    """
    w = copy.deepcopy(BASE)
    house = next(o for o in w["objects"] if o["asset"].startswith("building."))
    w["interactables"].append(
        {"id": "door", "asset": "", "x": 0, "y": 0, "text": "t", "beat": "",
         "on": house["id"], "gives_item": "", "needs_item": "", "locked_text": ""})
    # Ring the house in crates so several hosts contend over the same blockers.
    hx, hy = house["x"], house["y"]
    for n in range(8):
        w["objects"].append({"id": f"ring{n}", "asset": "prop.crate_large_empty",
                             "x": hx - 2 + 2 * (n % 4), "y": hy - 2 + 8 * (n // 4)})
    worldgen.resolve_attachments(w)
    notes = worldgen.repair_village(w)

    moved = [n.split()[1] for n in notes if n.startswith("moved ") and " clear " in n]
    dupes = sorted({m for m in moved if moved.count(m) > 1})
    _check("no object is shuffled twice by the unblocking pass",
           not dupes, f"(repeated: {dupes})")


_repair_never_shuffles_the_same_object_twice()


def _dropping_a_giver_does_not_doom_the_world() -> None:
    """Placement may delete the interactable that hands out an item.

    Item repair runs at the top of repair_village, on the world as generated.
    The placement loop afterwards is allowed to drop interactables (unknown
    asset, nowhere legal to stand), and dropping one takes its `gives_item` with
    it — leaving a villager waiting for something that no longer exists, and the
    whole village rejected for it.
    """
    w = copy.deepcopy(BASE)
    # The crate hands out the feather and Tomas wants it (both true in BASE).
    # Make the crate undroppable-by-asset so placement removes it.
    next(i for i in w["interactables"] if i["id"] == "chest")["asset"] = "prop.not_a_real_thing"
    worldgen.resolve_attachments(w)
    worldgen.repair_village(w)

    ids = {i["id"] for i in w["interactables"]}
    _check("the broken giver is dropped", "chest" not in ids, f"(still present)")
    _check("nobody is left waiting for the vanished item",
           all(not n.get("wants_item") for n in w["npcs"]),
           f"({[n['id'] for n in w['npcs'] if n.get('wants_item')]} still waiting)")
    try:
        validate_world(w)
    except WorldValidationError as exc:
        _check("the world still validates", False, f"— {exc}")
    else:
        _check("the world still validates", True)


_dropping_a_giver_does_not_doom_the_world()


def _a_duplicated_building_becomes_a_door() -> None:
    """A door emitted as a second copy of the building must attach, not overlap.

    Real generation: `int_door_ilse` with a house asset, sitting on top of
    another house. `on` was empty and the id matched no `<object>_<verb>`
    pattern, so it stayed a standalone 6x6 interactable and validation rejected
    the village for an overlap — costing a full retry, i.e. another minute on
    the loading screen.
    """
    w = copy.deepcopy(BASE)
    house = next(o for o in w["objects"] if o["asset"].startswith("building."))
    w["interactables"].append(
        {"id": "int_door_somebody", "asset": house["asset"],
         "x": house["x"], "y": house["y"], "text": "A door.", "beat": "",
         "on": "", "gives_item": "", "needs_item": "", "locked_text": ""})
    worldgen.resolve_attachments(w)
    door = next(i for i in w["interactables"] if i["id"] == "int_door_somebody")
    _check("a building-sized interactable on top of a building attaches to it",
           door["on"] == house["id"], f"(on={door['on']!r})")

    worldgen.repair_village(w)
    try:
        validate_world(w)
    except WorldValidationError as exc:
        _check("no overlap rejection results", False, f"— {exc}")
    else:
        _check("no overlap rejection results", True)


def _a_wall_sign_is_not_swallowed() -> None:
    """The overlap rule must not grab small props mounted on buildings."""
    w = copy.deepcopy(BASE)
    house = next(o for o in w["objects"] if o["asset"].startswith("building."))
    w["interactables"].append(
        {"id": "wall_plaque", "asset": "prop.sign_1",
         "x": house["x"], "y": house["y"], "text": "A plaque.", "beat": "",
         "on": "", "gives_item": "", "needs_item": "", "locked_text": ""})
    worldgen.resolve_attachments(w)
    sign = next(i for i in w["interactables"] if i["id"] == "wall_plaque")
    _check("a sign overlapping a building stays its own object",
           sign["on"] == "", f"(on={sign['on']!r})")


def _a_door_naming_a_missing_host_is_rehomed() -> None:
    """`on` pointing at an object that does not exist.

    Real generation: int_mill_door claimed `on: "mill_tower"`, and no mill_tower
    was ever placed. Detaching it left a house-sized interactable standing on
    the dovecote, rejected as an overlap — one wasted attempt, one extra minute
    of loading. It should be re-homed onto what it is actually sitting on.
    """
    w = copy.deepcopy(BASE)
    house = next(o for o in w["objects"] if o["asset"].startswith("building."))
    w["interactables"].append(
        {"id": "int_mill_door", "asset": house["asset"],
         "x": house["x"], "y": house["y"], "text": "A door.", "beat": "",
         "on": "a_tower_that_does_not_exist", "gives_item": "",
         "needs_item": "", "locked_text": ""})
    notes = worldgen.resolve_attachments(w)
    door = next(i for i in w["interactables"] if i["id"] == "int_mill_door")
    _check("a door naming a missing host is re-homed onto what it overlaps",
           door["on"] == house["id"],
           f"(on={door['on']!r}, notes={[n for n in notes if 'int_mill_door' in n]})")

    worldgen.repair_village(w)
    try:
        validate_world(w)
    except WorldValidationError as exc:
        _check("and no overlap rejection results", False, f"— {exc}")
    else:
        _check("and no overlap rejection results", True)


_a_duplicated_building_becomes_a_door()
_a_wall_sign_is_not_swallowed()
_a_door_naming_a_missing_host_is_rehomed()


def main() -> int:
    for ok, msg in _results:
        print(f"  {'PASS' if ok else 'FAIL'}  {msg}")
    failed = sum(1 for ok, _ in _results if not ok)
    print(f"\n{len(_results) - failed}/{len(_results)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
