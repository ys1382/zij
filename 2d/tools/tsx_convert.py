#!/usr/bin/env python3
"""Tiled (.tsx) -> Godot 4.6 asset pipeline for the Fan-tasy tileset.

Godot cannot read .tsx natively, and the Fan-tasy pack has ~560 colliders, 8
wangsets and 83 tile animations already authored in that XML. Redrawing them in
the Godot editor is days of clicking; this recovers all of it in one scripted,
headless, CI-runnable pass.

Output is split by how an asset actually gets *placed*, because that decides
which Godot type can represent it:

  atlas tilesets (columns > 0)  -> generated/tilesets/<Name>.tres
      Grid-locked by nature, so a real TileSet with physics layers, terrain
      sets (from wangsets) and per-tile animation is the right fit.

  collection tilesets (columns = 0)  -> generated/props/<name>.tscn
      One PackedScene per prop. TileSetAtlasSource *and*
      TileSetScenesCollectionSource tiles are both grid-locked, so free-placed
      props must not go through TileSet at all.

  generated/assets_catalog.json
      Single source of truth. Godot resolves id -> scene; the backend builds
      the LLM's closed asset enum from the same file, so the model can never
      name an asset that doesn't exist.

Usage:
    python3 tools/tsx_convert.py            # convert
    python3 tools/tsx_convert.py --verify   # convert + assert recovery counts
"""
from __future__ import annotations

import argparse
import json
import math
import os
import re
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PACK = ROOT / "assets" / "The Fan-tasy Tileset (Free)"
TSX_DIR = PACK / "Tiled" / "Tilesets"
OUT = ROOT / "generated"
TILE = 16

# Tiled wangid is 8 values in this order; Godot names the same neighbours
# differently. For square tiles in MATCH_CORNERS_AND_SIDES these are exactly
# the eight valid peering bits.
WANG_ORDER = [
    "top_side", "top_right_corner", "right_side", "bottom_right_corner",
    "bottom_side", "bottom_left_corner", "left_side", "top_left_corner",
]
# Tiled wangset type -> Godot TileSet.TerrainMode
TERRAIN_MODE = {"mixed": 0, "corner": 1, "edge": 2}

# ---------------------------------------------------------------------------
# Semantics. The .tsx files carry ZERO class/type attributes and ZERO custom
# properties (verified across all 16), so "Sign_1 is readable" exists nowhere in
# the data. This table is the one place hand-authoring is justified: it is the
# semantic layer the XML doesn't have, and it is what the LLM actually reasons
# over. Keys are PNG stems; anything not listed falls back to decor.
# verb: "" means scenery. Anything with a verb becomes an Interactable.
# ---------------------------------------------------------------------------
SEMANTICS: dict[str, tuple[str, str, list[str]]] = {
    # stem: (kind, verb, tags)
    "Sign_1":                ("sign",     "read", ["readable", "signpost"]),
    "Sign_2":                ("sign",     "read", ["readable", "signpost"]),
    "BulletinBoard_1":       ("notice",   "read", ["readable", "notice", "quest"]),
    "Bench_1":               ("bench",    "sit",  ["seat", "furniture"]),
    "Bench_3":               ("bench",    "sit",  ["seat", "furniture"]),
    "Table_Medium_1":        ("table",    "look", ["furniture", "surface"]),
    "Well_Hay_1":            ("well",     "look", ["landmark", "water", "village"]),
    "Fireplace_1":           ("hearth",   "look", ["fire", "warmth", "village"]),
    "LampPost_3":            ("lamp",     "look", ["light", "street"]),
    "Banner_Stick_1_Purple": ("banner",   "read", ["decor", "heraldry"]),
    "Crate_Large_Empty":     ("container", "open", ["container", "storage"]),
    "Crate_Medium_Closed":   ("container", "open", ["container", "storage"]),
    "Barrel_Small_Empty":    ("container", "open", ["container", "storage"]),
    "Basket_Empty":          ("container", "open", ["container", "storage"]),
    "Sack_3":                ("container", "open", ["container", "storage"]),
    "Crate_Water_1":         ("trough",   "look", ["water", "storage"]),
    "HayStack_2":            ("haystack", "look", ["farm", "decor"]),
    "Chopped_Tree_1":        ("stump",    "sit",  ["seat", "woodland"]),
    "Plant_2":               ("plant",    "",     ["decor", "greenery"]),
    "CityWall_Gate_1":       ("gate",     "open", ["door", "entrance", "wall"]),
    "House_Hay_1":           ("house",    "open", ["building", "home"]),
    "House_Hay_2":           ("house",    "open", ["building", "home"]),
    "House_Hay_3":           ("house",    "open", ["building", "home", "large"]),
    "House_Hay_4_Purple":    ("house",    "open", ["building", "home"]),
}
# Keyed on the tileset's `name` ATTRIBUTE, which does not always match the
# filename — Objects_Buildings.tsx calls itself "Buildings".
CATEGORY_BY_SOURCE = {
    "Objects_Props": "prop",
    "Buildings": "building",
    "Objects_Trees": "tree",
    "Objects_Rocks": "rock",
}


def slug(stem: str) -> str:
    """House_Hay_4_Purple -> house_hay_4_purple"""
    return re.sub(r"[^a-z0-9]+", "_", stem.lower()).strip("_")


def res_path(p: Path) -> str:
    return "res://" + p.relative_to(ROOT).as_posix()


def fnum(v: float) -> str:
    """Godot-friendly float: trim to 5dp, drop trailing zeros, kill -0."""
    s = f"{v:.5f}".rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s


# ---------------------------------------------------------------------------
# Collider extraction
# ---------------------------------------------------------------------------

def ellipse_points(x: float, y: float, w: float, h: float, segments: int = 14):
    """Tiled ellipses have no Godot equivalent; polygonise them."""
    cx, cy, rx, ry = x + w / 2, y + h / 2, w / 2, h / 2
    return [(cx + rx * math.cos(2 * math.pi * i / segments),
             cy + ry * math.sin(2 * math.pi * i / segments))
            for i in range(segments)]


def object_polygon(obj: ET.Element) -> list[tuple[float, float]] | None:
    """One Tiled <object> -> a point list in TILE-LOCAL coords (origin at the
    tile's top-left). Handles <polygon>, <ellipse> and the bare rect form."""
    ox, oy = float(obj.get("x", 0)), float(obj.get("y", 0))
    poly = obj.find("polygon")
    if poly is not None:
        pts = []
        for pair in poly.get("points", "").split():
            px, py = pair.split(",")
            pts.append((ox + float(px), oy + float(py)))
        return pts or None
    w, h = float(obj.get("width", 0)), float(obj.get("height", 0))
    if w <= 0 or h <= 0:
        return None  # a point or an unsupported shape
    if obj.find("ellipse") is not None:
        return ellipse_points(ox, oy, w, h)
    return [(ox, oy), (ox + w, oy), (ox + w, oy + h), (ox, oy + h)]


def tile_colliders(tile: ET.Element) -> list[list[tuple[float, float]]]:
    out = []
    for grp in tile.findall("objectgroup"):
        for obj in grp.findall("object"):
            pts = object_polygon(obj)
            if pts:
                out.append(pts)
    return out


# ---------------------------------------------------------------------------
# Atlas tilesets -> TileSet .tres
# ---------------------------------------------------------------------------

@dataclass
class AtlasResult:
    name: str
    path: Path
    tiles: int = 0
    colliders: int = 0
    animations: int = 0
    wangsets: int = 0
    terrains: dict[str, int] = field(default_factory=dict)
    skipped_colliders: int = 0


def convert_atlas(tsx: Path) -> AtlasResult:
    root = ET.parse(tsx).getroot()
    name = root.get("name")
    cols = int(root.get("columns"))
    tw, th = int(root.get("tilewidth")), int(root.get("tileheight"))
    img = root.find("image")
    img_path = (tsx.parent / img.get("source")).resolve()
    iw, ih = int(img.get("width")), int(img.get("height"))
    grid_cols, grid_rows = iw // tw, ih // th

    tiles_by_id = {int(t.get("id")): t for t in root.findall("tile")}

    # --- animations -------------------------------------------------------
    # Godot cannot reference arbitrary frame tileids the way Tiled does. It
    # lays frames out starting at the tile, stepping
    # (size_in_atlas + animation_separation) per frame. Every animation in this
    # pack is a 1x1 tile whose frames march right at a constant stride, so the
    # faithful mapping is separation.x = stride - 1.
    #
    # Those frame cells must NOT also be declared as standalone tiles or Godot
    # rejects the source for overlap. Per row we consume columns [stride,
    # stride*nframes) -- the whole animation period past the base block.
    anims: dict[int, tuple[int, int, list[int]]] = {}   # tileid -> (stride, nframes, durations)
    consumed: set[tuple[int, int]] = set()
    for tid, tile in tiles_by_id.items():
        a = tile.find("animation")
        if a is None:
            continue
        frames = a.findall("frame")
        ids = [int(f.get("tileid")) for f in frames]
        durs = [int(f.get("duration")) for f in frames]
        strides = {ids[i + 1] - ids[i] for i in range(len(ids) - 1)}
        if len(strides) != 1:
            print(f"  ! {name} tile {tid}: non-uniform frame stride {strides}, skipping animation")
            continue
        stride = strides.pop()
        anims[tid] = (stride, len(ids), durs)
        row = tid // cols
        for c in range(stride, stride * len(ids)):
            if c < grid_cols:
                consumed.add((c, row))

    # --- emit -------------------------------------------------------------
    lines_tiles: list[str] = []
    res = AtlasResult(name=name, path=OUT / "tilesets" / f"{name}.tres")

    for row in range(grid_rows):
        for col in range(grid_cols):
            if (col, row) in consumed:
                continue
            tid = row * cols + col
            key = f"{col}:{row}"
            lines_tiles.append(f"{key}/0 = 0")
            res.tiles += 1
            tile = tiles_by_id.get(tid)

            if tid in anims:
                stride, nframes, durs = anims[tid]
                lines_tiles.append(f"{key}/animation_columns = {nframes}")
                if stride > 1:
                    lines_tiles.append(f"{key}/animation_separation = Vector2i({stride - 1}, 0)")
                lines_tiles.append(f"{key}/animation_frames_count = {nframes}")
                for i, d in enumerate(durs):
                    # Godot durations are a multiplier on animation_speed (1/s),
                    # Tiled's are milliseconds.
                    lines_tiles.append(f"{key}/animation_frame_{i}/duration = {fnum(d / 1000.0)}")
                res.animations += 1

            if tile is None:
                continue
            if tile.get("probability"):
                lines_tiles.append(f"{key}/0/probability = {fnum(float(tile.get('probability')))}")

            polys = tile_colliders(tile)
            if polys:
                lines_tiles.append(f"{key}/0/physics_layer_0/polygons_count = {len(polys)}")
                for i, pts in enumerate(polys):
                    # Godot collision polygons are tile-local with (0,0) at the
                    # tile CENTRE; Tiled's are relative to the top-left.
                    flat = ", ".join(
                        f"{fnum(px - tw / 2)}, {fnum(py - th / 2)}" for px, py in pts)
                    lines_tiles.append(
                        f"{key}/0/physics_layer_0/polygon_{i}/points = PackedVector2Array({flat})")
                res.colliders += len(polys)

    declared = {(row * cols + col) for row in range(grid_rows) for col in range(grid_cols)
                if (col, row) not in consumed}
    for tid, tile in tiles_by_id.items():
        if tid not in declared and tile_colliders(tile):
            res.skipped_colliders += len(tile_colliders(tile))

    # --- wangsets -> terrain sets ----------------------------------------
    header: list[str] = []
    peering: dict[str, list[str]] = {}
    for si, ws in enumerate(root.findall("wangsets/wangset")):
        res.wangsets += 1
        mode = TERRAIN_MODE.get(ws.get("type", "mixed"), 0)
        header.append(f"terrain_set_{si}/mode = {mode}")
        colors = ws.findall("wangcolor")
        for ci, wc in enumerate(colors):
            header.append(f'terrain_set_{si}/terrain_{ci}/name = "{wc.get("name")}"')
            r, g, b = (int(wc.get("color", "#ffffff")[i:i + 2], 16) / 255.0 for i in (1, 3, 5))
            header.append(
                f"terrain_set_{si}/terrain_{ci}/color = Color({fnum(r)}, {fnum(g)}, {fnum(b)}, 1)")
            res.terrains[wc.get("name")] = ci
        for wt in ws.findall("wangtile"):
            tid = int(wt.get("tileid"))
            col, row = tid % cols, tid // cols
            if (col, row) in consumed:
                continue
            key = f"{col}:{row}"
            wid = [int(v) for v in wt.get("wangid").split(",")]
            bits = peering.setdefault(key, [])
            # Tiled wang values are 1-based into wangcolor; 0 means unset.
            # Godot terrains are 0-based, -1 means unset.
            present = [v for v in wid if v > 0]
            if not present:
                continue
            # Tiled mixed wangsets carry no explicit centre terrain; Godot needs
            # one. Take the most common neighbour value -- what the tile mostly
            # "is".
            centre = max(set(present), key=present.count) - 1
            bits.append(f"{key}/0/terrain_set = {si}")
            bits.append(f"{key}/0/terrain = {centre}")
            for slot, v in zip(WANG_ORDER, wid):
                if v > 0:
                    bits.append(f"{key}/0/terrains_peering_bit/{slot} = {v - 1}")

    for key, bits in peering.items():
        lines_tiles.extend(bits)

    tex_id = f"tex_{slug(name)}"
    src_id = f"src_{slug(name)}"
    body = [
        "[gd_resource type=\"TileSet\" load_steps=3 format=3]",
        "",
        f'[ext_resource type="Texture2D" path="{res_path(img_path)}" id="{tex_id}"]',
        "",
        f'[sub_resource type="TileSetAtlasSource" id="{src_id}"]',
        f'texture = ExtResource("{tex_id}")',
        f"texture_region_size = Vector2i({tw}, {th})",
        *lines_tiles,
        "",
        "[resource]",
        f"tile_size = Vector2i({tw}, {th})",
        "physics_layer_0/collision_layer = 1",
        *header,
        f'sources/0 = SubResource("{src_id}")',
        "",
    ]
    res.path.parent.mkdir(parents=True, exist_ok=True)
    res.path.write_text("\n".join(body))
    return res


# ---------------------------------------------------------------------------
# Collection tilesets -> one PackedScene per prop
# ---------------------------------------------------------------------------

@dataclass
class PropResult:
    entries: dict = field(default_factory=dict)
    colliders: int = 0


def convert_collection(tsx: Path, out: PropResult) -> None:
    root = ET.parse(tsx).getroot()
    src_name = root.get("name")
    category = CATEGORY_BY_SOURCE.get(src_name, "prop")

    for tile in root.findall("tile"):
        img = tile.find("image")
        if img is None:
            continue
        png = (tsx.parent / img.get("source")).resolve()
        # NB: the tileset header's tilewidth/tileheight is the bounding box of
        # the LARGEST image in the collection, not this tile's size. Always use
        # the per-<image> dimensions.
        w, h = int(img.get("width")), int(img.get("height"))
        stem = png.stem
        sid = slug(stem)
        kind, verb, tags = SEMANTICS.get(stem, (category, "", ["decor"]))
        polys = tile_colliders(tile)
        out.colliders += len(polys)

        # Origin at the prop's bottom-centre (its "foot"): placement on a tile
        # grid is then intuitive, and Y-sorting works off the node position with
        # no extra offset, so the player walks behind a tree correctly.
        ox, oy = -w / 2.0, -float(h)

        parts = [
            "[gd_scene load_steps=2 format=3]",
            "",
            f'[ext_resource type="Texture2D" path="{res_path(png)}" id="tex"]',
            "",
            f'[node name="{stem}" type="StaticBody2D"]',
            "collision_layer = 1",
            "collision_mask = 0",
            "",
            '[node name="Sprite" type="Sprite2D" parent="."]',
            "centered = false",
            f"position = Vector2({fnum(ox)}, {fnum(oy)})",
            'texture = ExtResource("tex")',
        ]
        for i, pts in enumerate(polys):
            # Collider lives inside the scene, not in a TileData, so the
            # tile-centre convention does NOT apply -- offset by the same
            # bottom-centre shift as the sprite and nothing else.
            flat = ", ".join(f"{fnum(px + ox)}, {fnum(py + oy)}" for px, py in pts)
            parts += [
                "",
                f'[node name="Collision{i}" type="CollisionPolygon2D" parent="."]',
                f"polygon = PackedVector2Array({flat})",
            ]
        dest = OUT / "props" / f"{sid}.tscn"
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text("\n".join(parts) + "\n")

        out.entries[f"{category}.{sid}"] = {
            "scene": res_path(dest),
            "source": src_name,
            "category": category,
            "kind": kind,
            "verb": verb,
            "tags": tags,
            "px": [w, h],
            "tiles": [max(1, math.ceil(w / TILE)), max(1, math.ceil(h / TILE))],
            "solid": bool(polys),
            "anchor": "bottom_center",
        }


# ---------------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--verify", action="store_true",
                    help="assert the expected number of colliders/wangsets/animations was recovered")
    args = ap.parse_args()

    if not TSX_DIR.is_dir():
        print(f"error: {TSX_DIR} not found", file=sys.stderr)
        return 2

    atlases: list[AtlasResult] = []
    props = PropResult()

    for tsx in sorted(TSX_DIR.glob("*.tsx")):
        root = ET.parse(tsx).getroot()
        if int(root.get("columns", 0)) > 0:
            r = convert_atlas(tsx)
            atlases.append(r)
            print(f"  atlas  {r.name:28s} tiles={r.tiles:5d} colliders={r.colliders:4d} "
                  f"anims={r.animations:3d} wangsets={r.wangsets}")
        else:
            before = props.colliders
            convert_collection(tsx, props)
            print(f"  props  {root.get('name'):28s} colliders={props.colliders - before:4d}")

    catalog = {
        "version": 1,
        "generated_by": "tools/tsx_convert.py",
        "tile_size": [TILE, TILE],
        "tilesets": {
            a.name: {"path": res_path(a.path), "terrains": a.terrains}
            for a in atlases
        },
        "objects": props.entries,
    }
    (OUT / "assets_catalog.json").write_text(json.dumps(catalog, indent=2, sort_keys=True) + "\n")

    tot_coll = sum(a.colliders for a in atlases) + props.colliders
    tot_anim = sum(a.animations for a in atlases)
    tot_wang = sum(a.wangsets for a in atlases)
    skipped = sum(a.skipped_colliders for a in atlases)
    print(f"\ncolliders={tot_coll} animations={tot_anim} wangsets={tot_wang} "
          f"objects={len(props.entries)} skipped_colliders={skipped}")
    print(f"wrote {OUT.relative_to(ROOT)}/")

    if args.verify:
        ok = True
        tot_terr = sum(len(a.terrains) for a in atlases)
        for label, got, want in (("colliders", tot_coll, 563),
                                 ("animations", tot_anim, 83),
                                 # 4 wangsets (Ground/Water/RockSlope/Road)
                                 # holding 9 wangcolors between them.
                                 ("wangsets", tot_wang, 4),
                                 ("terrains", tot_terr, 9),
                                 ("objects", len(props.entries), 40)):
            if got != want:
                print(f"VERIFY FAIL: {label} {got} != {want}", file=sys.stderr)
                ok = False
        if skipped:
            print(f"VERIFY FAIL: {skipped} colliders landed on animation-frame cells "
                  f"and were dropped", file=sys.stderr)
            ok = False
        if not ok:
            return 1
        print("VERIFY OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
