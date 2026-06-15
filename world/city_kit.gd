class_name CityKit
extends RefCounted
# Catalog of Downtown City MegaKit tiles: logical name -> gltf path, with
# cached PackedScene loads and measured footprints. Single source of truth so
# the builder never hardcodes paths or tile dimensions.

const ROOT := "res://assets/Downtown City MegaKit[Standard]/Exports/glTF (Godot)/"

# Logical tile names actually used by the builder. Buildings are the 3 complete
# prefabs; road/ground is the clean flat 9x9 asphalt square (tileable); sidewalk
# is the 3m straight piece (3 divides 9 evenly).
const ROAD := "Street_Asphalt_9x9"
const SIDEWALK := "Sidewalk_Straight_3m"
const BUILDINGS := ["Building_Small_1", "Building_Medium_2_001", "Building_Large_2"]

# Grid module in metres — derived from the flat asphalt tile (9x9). Everything
# snaps to this. Verified empirically via test/inspect_kit.gd.
const MODULE := 9.0
const SIDEWALK_MODULE := 3.0

static var _scene_cache := {}
static var _footprint_cache := {}

static func scene(name: String) -> PackedScene:
	if _scene_cache.has(name):
		return _scene_cache[name]
	var ps := load(ROOT + name + ".gltf") as PackedScene
	if ps == null:
		push_error("CityKit: could not load tile " + name)
	_scene_cache[name] = ps
	return ps

# Local (untransformed) footprint AABB of a tile, measured once and cached.
# Returns AABB so callers can read both size and pivot offset (position).
static func footprint(name: String) -> AABB:
	if _footprint_cache.has(name):
		return _footprint_cache[name]
	var ps := scene(name)
	var agg := AABB()
	if ps != null:
		var inst := ps.instantiate() as Node3D
		var first := true
		for mi in inst.find_children("*", "MeshInstance3D", true, false):
			var a: AABB = (mi as MeshInstance3D).transform * (mi as MeshInstance3D).get_aabb()
			if first:
				agg = a
				first = false
			else:
				agg = agg.merge(a)
		inst.free()
	_footprint_cache[name] = agg
	return agg
