class_name Catalog
extends RefCounted
# Reader for generated/assets_catalog.json — the single source of truth that
# tools/tsx_convert.py emits. The backend builds the LLM's closed asset enum
# from this same file, so anything the model can name is guaranteed to resolve
# here. Never hand-edit the JSON; change the converter and re-run it.

const PATH := "res://generated/assets_catalog.json"
const TILE := 16

static var _data: Dictionary = {}

static func data() -> Dictionary:
	if _data.is_empty():
		var f := FileAccess.open(PATH, FileAccess.READ)
		assert(f != null, "missing %s — run: python3 tools/tsx_convert.py" % PATH)
		_data = JSON.parse_string(f.get_as_text())
	return _data

static func objects() -> Dictionary:
	return data()["objects"]

static func has_object(id: String) -> bool:
	return objects().has(id)

static func object(id: String) -> Dictionary:
	var objs := objects()
	assert(objs.has(id), "unknown asset id '%s'" % id)
	return objs[id]

## Tile footprint (width, height in cells) — used for overlap and reachability.
static func footprint(id: String) -> Vector2i:
	var t: Array = object(id)["tiles"]
	return Vector2i(t[0], t[1])

## Ids whose semantics table gave them an interaction verb.
static func interactive_ids() -> PackedStringArray:
	var out := PackedStringArray()
	for id in objects():
		if objects()[id]["verb"] != "":
			out.append(id)
	return out

static func tileset(name: String) -> TileSet:
	return load(data()["tilesets"][name]["path"]) as TileSet

## Terrain index within a tileset's terrain set 0, by wangcolor name
## ("Grass", "Dirt", ...). Returns -1 if absent.
static func terrain_index(tileset_name: String, terrain_name: String) -> int:
	var t: Dictionary = data()["tilesets"][tileset_name]["terrains"]
	return int(t.get(terrain_name, -1))

## World position for a tile cell. Objects are anchored bottom-centre (see the
## converter), so this returns the bottom-centre of the cell — which is also
## the correct Y for y-sorting.
static func cell_to_anchor(cell: Vector2i) -> Vector2:
	return Vector2(cell.x * TILE + TILE * 0.5, (cell.y + 1) * TILE)
