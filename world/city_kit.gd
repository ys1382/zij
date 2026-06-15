class_name CityKit
extends RefCounted
# Catalog of building packs. Each pack exposes a BUILDINGS array (full res:// paths)
# and a ROAD path. The builder picks a pack by name at export time.

const MODULE := 9.0

# --- Pack definitions ---

const MEGAKIT_ROOT := "res://assets/Downtown City MegaKit[Standard]/Exports/glTF (Godot)/"
const CITY4_ROOT   := "res://assets/City_4_glb/Separate_assets_glb/"
const DESERT_ROOT  := "res://assets/Desert_City_Oasis_glb/Separate_assets_glb/"

# Road tile shared across packs (9x9 flat asphalt, zero-height mesh — ground slab
# handles actual collision; tile is purely visual).
const ROAD := MEGAKIT_ROOT + "Street_Asphalt_9x9.gltf"

# City_4: skyscrapers, business centres, banks, hotels, apartments — Manhattan feel.
static var CITY4_BUILDINGS: Array[String] = _list(CITY4_ROOT, [
	"skyscraper", "business_center", "bank", "hotel",
	"appartnemt_1", "appartnemt_2", "house_big_1", "house_big_2",
	"house_purpose", "cafe",
])

# Desert: mosques, towers, houses, stalls — Middle-Eastern feel.
static var DESERT_BUILDINGS: Array[String] = _list(DESERT_ROOT, [
	"mosque", "tower", "house", "stall",
])

static var _scene_cache := {}

# Returns all glb paths under `root` whose stem starts with any prefix in `prefixes`.
static func _list(root: String, prefixes: Array) -> Array[String]:
	var result: Array[String] = []
	var dir := DirAccess.open(ProjectSettings.globalize_path(root))
	if dir == null:
		return result
	dir.list_dir_begin()
	var f := dir.get_next()
	while f != "":
		if f.ends_with(".glb"):
			var stem := f.get_basename()
			for prefix in prefixes:
				if stem.begins_with(prefix):
					result.append(root + f)
					break
		f = dir.get_next()
	dir.list_dir_end()
	result.sort()
	return result

static func buildings_for_pack(pack: String) -> Array[String]:
	match pack:
		"desert": return DESERT_BUILDINGS
		_:        return CITY4_BUILDINGS  # default: city4

static func scene(path: String) -> PackedScene:
	if _scene_cache.has(path):
		return _scene_cache[path]
	var ps := load(path) as PackedScene
	if ps == null:
		push_error("CityKit: could not load " + path)
	_scene_cache[path] = ps
	return ps
