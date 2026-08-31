class_name Interior
extends Node2D
# A room you step into when you press E on a building.
#
# Procedural, not model-authored, and deliberately so: it costs nothing and
# takes no time, and the point of going inside is to be somewhere else and find
# something, not to read more prose. The layout is seeded off the building id so
# a given house always looks the same when you come back to it.
#
# There is no interior tileset in the art packs. The floor is the Road terrain,
# painted a ring wider than the room so its grassy edge transitions fall UNDER
# the walls instead of fringing the room. The walls themselves are drawn, not
# tiled: Tileset_RockSlope was tried first and renders nothing for a solid fill
# — it only has cliff edges — and a flat band is both reliable and readable.

const TILE := Catalog.TILE
## Wall band thickness in tiles. Wide enough to cover the floor terrain's own
## edge tiles, which are drawn as grass meeting a path.
const WALL := 2
## The floor is painted this far past the room on every side; the surplus sits
## beneath the wall band.
const FLOOR_BLEED := 3
const WALL_COLOUR := Color(0.16, 0.12, 0.10)
const VOID_COLOUR := Color(0.05, 0.045, 0.06)
## Room size, in tiles, clamped from the building's own footprint.
const MIN_ROOM := Vector2i(9, 7)
const MAX_ROOM := Vector2i(16, 11)

## Furniture worth putting in a room, with how many of each at most.
const FURNITURE := [
	"prop.table_medium_1", "prop.fireplace_1", "prop.bench_1", "prop.bench_3",
	"prop.crate_large_empty", "prop.crate_medium_closed", "prop.barrel_small_empty",
	"prop.sack_3", "prop.basket_empty", "prop.plant_2",
]

signal exit_requested

var building_id: String = ""
var room: Vector2i = MIN_ROOM

var _floor: TileMapLayer
var _objects: Node2D
var _rng := RandomNumberGenerator.new()


## `footprint` is the building's tile size; a bigger house gets a bigger room.
func build(id: String, footprint: Vector2i, seed_text: String) -> void:
	building_id = id
	_rng.seed = hash("%s|%s" % [seed_text, id])
	room = Vector2i(
		clampi(footprint.x + 2, MIN_ROOM.x, MAX_ROOM.x),
		clampi(footprint.y + 1, MIN_ROOM.y, MAX_ROOM.y))

	y_sort_enabled = true
	_make_layers()
	_paint()
	_furnish()
	_add_doorway()


func pixel_size() -> Vector2i:
	return room * TILE


## Where the player stands on arrival: just inside the door, bottom-centre.
func entry_point() -> Vector2:
	return Catalog.cell_to_anchor(Vector2i(room.x / 2, room.y - 1))


func _make_layers() -> void:
	# A backdrop far larger than the room, because the camera cannot always be
	# clamped to a space smaller than the viewport — without it the area past
	# the walls is the window's clear colour, which reads as a broken scene.
	var void_rect := ColorRect.new()
	void_rect.name = "Void"
	void_rect.color = VOID_COLOUR
	void_rect.z_index = -100
	var span := (room + Vector2i(40, 40)) * TILE
	void_rect.position = Vector2(-span) * 0.5 + Vector2(room * TILE) * 0.5
	void_rect.size = Vector2(span)
	add_child(void_rect)

	_floor = TileMapLayer.new()
	_floor.name = "Floor"
	_floor.tile_set = Catalog.tileset("Road")
	_floor.z_index = -50
	add_child(_floor)

	_objects = Node2D.new()
	_objects.name = "Objects"
	_objects.y_sort_enabled = true
	add_child(_objects)


func _paint() -> void:
	var cells: Array[Vector2i] = []
	for y in range(-FLOOR_BLEED, room.y + FLOOR_BLEED):
		for x in range(-FLOOR_BLEED, room.x + FLOOR_BLEED):
			cells.append(Vector2i(x, y))
	_floor.set_cells_terrain_connect(
		cells, 0, Catalog.terrain_index("Road", "Road"))

	var w := room.x * TILE
	var h := room.y * TILE
	var t := WALL * TILE
	var body := StaticBody2D.new()
	body.name = "Bounds"
	body.collision_layer = 1
	body.collision_mask = 0
	add_child(body)

	# One drawn slab per side, each doubling as the collider, so what stops the
	# player is exactly what they can see.
	for spec in [
		[Vector2(-t, -t), Vector2(w + t * 2, t)],          # north
		[Vector2(-t, h), Vector2(w + t * 2, t)],           # south
		[Vector2(-t, 0), Vector2(t, h)],                   # west
		[Vector2(w, 0), Vector2(t, h)],                    # east
	]:
		var pos: Vector2 = spec[0]
		var size: Vector2 = spec[1]
		var slab := ColorRect.new()
		slab.color = WALL_COLOUR
		slab.position = pos
		slab.size = size
		slab.z_index = -40
		add_child(slab)

		var shape := CollisionShape2D.new()
		var rect := RectangleShape2D.new()
		rect.size = size
		shape.shape = rect
		shape.position = pos + size * 0.5
		body.add_child(shape)


func _furnish() -> void:
	# Around the edges, leaving the middle and the doorway clear so the room is
	# always crossable — the same reachability worry as outdoors, solved by
	# construction instead of by a flood fill.
	var spots: Array[Vector2i] = []
	for x in range(1, room.x - 1):
		spots.append(Vector2i(x, 1))
	for y in range(2, room.y - 2):
		spots.append(Vector2i(1, y))
		spots.append(Vector2i(room.x - 2, y))
	_shuffle(spots)

	var want := 3 + _rng.randi_range(0, 3)
	var used := {}
	var placed := 0
	for spot in spots:
		if placed >= want:
			break
		var asset: String = FURNITURE[_rng.randi_range(0, FURNITURE.size() - 1)]
		var fp := Catalog.footprint(asset)
		if fp.x > 3 or fp.y > 3:
			continue
		var clash := false
		for dx in range(fp.x):
			for dy in range(fp.y):
				var c := spot + Vector2i(dx, dy)
				if used.has(c) or c.x < 1 or c.y < 1 \
						or c.x >= room.x - 1 or c.y >= room.y - 1:
					clash = true
		if clash:
			continue
		for dx in range(fp.x):
			for dy in range(fp.y):
				used[spot + Vector2i(dx, dy)] = true
		var node: Node2D = load(Catalog.object(asset)["scene"]).instantiate()
		node.name = "%s_%d" % [asset.get_slice(".", 1), placed]
		node.y_sort_enabled = true
		node.position = Catalog.cell_to_anchor(
			Vector2i(spot.x, spot.y + fp.y - 1)) \
			+ Vector2((fp.x - 1) * TILE * 0.5, 0)
		_objects.add_child(node)
		placed += 1


## The way out. An Area2D on the interactable layer so the player's existing
## reach box finds it and the usual "E — Leave" prompt appears; no new input
## path and no invisible trigger the player can stumble through by accident.
func _add_doorway() -> void:
	var door := Interactable.new()
	door.name = "Doorway"
	door.data = {"id": "%s_exit" % building_id}
	door.verb = "leave"
	door.text = ""
	door.collision_layer = 4
	door.collision_mask = 0
	door.monitoring = false
	door.monitorable = true
	door.used.connect(func(_it): exit_requested.emit())

	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(3, 2) * TILE
	shape.shape = rect
	door.add_child(shape)
	door.position = Catalog.cell_to_anchor(Vector2i(room.x / 2, room.y - 1))
	_objects.add_child(door)


func _shuffle(a: Array) -> void:
	for i in range(a.size() - 1, 0, -1):
		var j := _rng.randi_range(0, i)
		var t = a[i]
		a[i] = a[j]
		a[j] = t
