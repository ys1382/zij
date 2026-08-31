class_name WorldBuilder
extends Node2D
# Turns one validated world JSON document into a live scene.
#
# The model never names a tile. It describes terrain as a base fill, a list of
# rectangles painted in order, and road polylines; this walks that description
# through Godot's terrain autotiler using the wangsets tools/tsx_convert.py
# recovered from the Tiled files. Objects come from generated/assets_catalog.json,
# so every asset id is guaranteed to resolve.
#
# build() is idempotent: it tears the previous world down first, which is what
# lets the VLM repair pass rebuild a patched world in place.

const TILE := Catalog.TILE
## Terrain is painted this far past the map edge so the autotiler doesn't draw
## an "Empty" border where the grass meets nothing.
const BLEED := 3

signal built(world: Dictionary)

var world: Dictionary = {}
var player: Node2D = null

var _ground: TileMapLayer
var _water: TileMapLayer
var _road: TileMapLayer
var _objects: Node2D

## id -> node, for the repair pass and for story bindings.
var entities: Dictionary = {}

## Counts up as spawn_minions() adds enemies at runtime, so their ids never
## collide with each other or with anything the generator placed.
var _minion_seq := 0


func _ready() -> void:
	y_sort_enabled = true


func build(w: Dictionary) -> void:
	teardown()
	world = w
	_make_layers()
	_paint_terrain()
	_place_objects()
	_spawn_actors()
	built.emit(w)


func teardown() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	entities.clear()
	player = null
	_ground = null
	_water = null
	_road = null
	_objects = null


func map_size() -> Vector2i:
	return Vector2i(world["map"]["width"], world["map"]["height"])


func pixel_size() -> Vector2i:
	return map_size() * TILE


# --- layers -----------------------------------------------------------------

func _make_layers() -> void:
	# Draw order is the child order: ground, then water, then road on top, then
	# everything with a footprint in a Y-sorted layer above that.
	_ground = _add_layer("Ground", Catalog.tileset("Tileset_Ground"))
	_water = _add_layer("Water", Catalog.tileset("Tileset_Water"))
	_road = _add_layer("Road", Catalog.tileset("Road"))
	_objects = Node2D.new()
	_objects.name = "Objects"
	_objects.y_sort_enabled = true
	add_child(_objects)


func _add_layer(layer_name: String, ts: TileSet) -> TileMapLayer:
	var layer := TileMapLayer.new()
	layer.name = layer_name
	layer.tile_set = ts
	add_child(layer)
	return layer


# --- terrain ----------------------------------------------------------------

func _paint_terrain() -> void:
	var m: Dictionary = world["map"]
	var size := map_size()

	var base: int = Catalog.terrain_index("Tileset_Ground",
		"Dirt" if m["base_terrain"] == "dirt" else "Grass")
	_ground.set_cells_terrain_connect(
		_rect_cells(Rect2i(-BLEED, -BLEED, size.x + BLEED * 2, size.y + BLEED * 2)),
		0, base)

	# Regions are painted in declaration order — later ones win, which is what
	# the schema promises the model.
	#
	# The edges are jittered rather than painted as exact rectangles. The
	# autotiler picks the right tiles either way, but along a perfectly straight
	# boundary the same transition tile repeats and the result reads as castle
	# battlements; the pack's own reference map (Beginning Fields) uses organic
	# shapes throughout. Jitter is seeded off the world seed so a given world
	# always looks the same.
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(world.get("seed", world.get("title", "zij2d")))

	for r: Dictionary in m["regions"]:
		var rect := Rect2i(r["x"], r["y"], r["w"], r["h"])
		var cells := _ragged_cells(rect, rng)
		match r["terrain"]:
			"water":
				_water.set_cells_terrain_connect(
					cells, 0, Catalog.terrain_index("Tileset_Water", "Water"))
			"dirt":
				_ground.set_cells_terrain_connect(
					cells, 0, Catalog.terrain_index("Tileset_Ground", "Dirt"))
			"grass":
				_ground.set_cells_terrain_connect(
					cells, 0, Catalog.terrain_index("Tileset_Ground", "Grass"))

	var road_terrain := Catalog.terrain_index("Road", "Road")
	for p: Dictionary in m["paths"]:
		var cells := _path_cells(p, size)
		if not cells.is_empty():
			_road.set_cells_terrain_connect(cells, 0, road_terrain)
			# A road crossing water is a bridge as far as the player is
			# concerned — clear the water under it so it isn't solid.
			for c in cells:
				_water.erase_cell(c)


## A rectangle with its four edges eaten into by 0-1 tiles, so terrain
## boundaries look hand-drawn instead of ruler-straight. Only the outer ring is
## ever removed — the interior is always solid, so this can never disconnect a
## region or invalidate the backend's reachability check (which is computed on
## the un-jittered rectangle, i.e. the pessimistic case for walkability: jitter
## only ever REMOVES blocking water, never adds it).
func _ragged_cells(r: Rect2i, rng: RandomNumberGenerator) -> Array[Vector2i]:
	if r.size.x <= 2 or r.size.y <= 2:
		return _rect_cells(r)
	var drop := {}
	for x in range(r.position.x, r.end.x):
		if rng.randf() < 0.45:
			drop[Vector2i(x, r.position.y)] = true
		if rng.randf() < 0.45:
			drop[Vector2i(x, r.end.y - 1)] = true
	for y in range(r.position.y, r.end.y):
		if rng.randf() < 0.45:
			drop[Vector2i(r.position.x, y)] = true
		if rng.randf() < 0.45:
			drop[Vector2i(r.end.x - 1, y)] = true
	var out: Array[Vector2i] = []
	for c in _rect_cells(r):
		if not drop.has(c):
			out.append(c)
	return out


func _rect_cells(r: Rect2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			out.append(Vector2i(x, y))
	return out


## Rasterises a polyline into cells. Mirrors backend/worldgen.py:_path_cells —
## the two must agree or the reachability check validates a different map than
## the one the player walks around in.
func _path_cells(path: Dictionary, size: Vector2i) -> Array[Vector2i]:
	var seen := {}
	var out: Array[Vector2i] = []
	var pts: Array = path["points"]
	var half: int = int(path["width"]) / 2
	for i in range(pts.size() - 1):
		var a: Dictionary = pts[i]
		var b: Dictionary = pts[i + 1]
		var steps: int = maxi(absi(int(b["x"]) - int(a["x"])),
			absi(int(b["y"]) - int(a["y"])))
		steps = maxi(steps, 1)
		for s in range(steps + 1):
			var t := float(s) / float(steps)
			var cx := int(round(lerpf(a["x"], b["x"], t)))
			var cy := int(round(lerpf(a["y"], b["y"], t)))
			for dy in range(-half, half + 1):
				for dx in range(-half, half + 1):
					var c := Vector2i(cx + dx, cy + dy)
					if c.x >= 0 and c.y >= 0 and c.x < size.x and c.y < size.y \
							and not seen.has(c):
						seen[c] = true
						out.append(c)
	return out


# --- objects and actors ------------------------------------------------------

## Assets whose insides exist. Wells and gates are catalogued as "building" too,
## and walking into a well would be a surprise of the wrong kind.
static func is_enterable(asset: String) -> bool:
	return asset.begins_with("building.house")


func _place_objects() -> void:
	for entry: Dictionary in world["objects"]:
		_instance_asset(entry)
	for entry: Dictionary in world["interactables"]:
		# `on` makes an already-placed object interactive in place — a house
		# door, the well — instead of adding a second sprite on top of it.
		var host_id: String = entry.get("on", "")
		var node: Node2D = entities.get(host_id) as Node2D if host_id != "" \
			else _instance_asset(entry)
		if node == null:
			if host_id != "":
				push_warning("interactable %s attaches to missing object '%s'"
					% [entry["id"], host_id])
			continue
		if Interactable.attach(node, entry) == null:
			continue
		entities[entry["id"]] = node

	_make_houses_enterable()


## Every house gets a door, whether the model thought to give it one or not.
##
## If the world already attached an interactable to a house — a door with its own
## text or beat — that one is promoted to the entrance rather than adding a
## second trigger competing for the same tile.
func _make_houses_enterable() -> void:
	var promoted := {}
	for entry: Dictionary in world["interactables"]:
		var host_id: String = entry.get("on", "")
		if host_id == "" or promoted.has(host_id):
			continue
		if not is_enterable(_asset_of(host_id)):
			continue
		var host_node: Node2D = entities.get(host_id) as Node2D
		if host_node == null:
			continue
		var it := host_node.get_node_or_null("Interact") as Interactable
		if it != null:
			it.enters = host_id
			promoted[host_id] = true

	for entry: Dictionary in world["objects"]:
		if not is_enterable(entry["asset"]) or promoted.has(entry["id"]):
			continue
		var node: Node2D = entities.get(entry["id"]) as Node2D
		if node == null or node.get_node_or_null("Interact") != null:
			continue
		Interactable.attach(node, {
			"id": "%s_door" % entry["id"], "asset": entry["asset"],
			"x": entry["x"], "y": entry["y"], "text": "", "beat": "",
			"on": entry["id"], "enters": entry["id"],
		})


func _asset_of(object_id: String) -> String:
	for o: Dictionary in world["objects"]:
		if o["id"] == object_id:
			return o["asset"]
	return ""


func _instance_asset(entry: Dictionary) -> Node2D:
	var asset: String = entry["asset"]
	if not Catalog.has_object(asset):
		push_warning("world references unknown asset '%s' (%s)" % [asset, entry["id"]])
		return null
	var node: Node2D = load(Catalog.object(asset)["scene"]).instantiate()
	node.name = entry["id"]
	node.y_sort_enabled = true
	# The schema places objects by their TOP-LEFT tile (same convention as
	# terrain regions), but the catalog anchors the art bottom-centre. Walk to
	# the bottom row, then right by half the footprint.
	var fp := Catalog.footprint(asset)
	node.position = Catalog.cell_to_anchor(
		Vector2i(entry["x"], entry["y"] + fp.y - 1)) \
		+ Vector2((fp.x - 1) * TILE * 0.5, 0)
	_objects.add_child(node)
	entities[entry["id"]] = node
	return node


func _spawn_actors() -> void:
	player = preload("res://actors/player.tscn").instantiate()
	player.position = Catalog.cell_to_anchor(
		Vector2i(world["player_start"]["x"], world["player_start"]["y"]))
	player.spawn_point = player.position
	_objects.add_child(player)
	_clamp_camera()

	_spawn_cast()


## Stops the view from sliding off the map when the player walks to its edge.
## Terrain is painted BLEED tiles past the boundary precisely so the autotiler
## has something to blend into; without limits the camera happily shows the
## nothing beyond that, which reads as the game being broken rather than as an
## edge. Set per build, since each world is a different size.
func _clamp_camera() -> void:
	var cam := player.get_node_or_null("Camera") as Camera2D
	if cam == null:
		return
	var px := pixel_size()
	cam.limit_left = 0
	cam.limit_top = 0
	cam.limit_right = px.x
	cam.limit_bottom = px.y


func _spawn_cast() -> void:
	for n: Dictionary in world["npcs"]:
		var npc: Npc = preload("res://actors/npc.tscn").instantiate()
		npc.setup(n)
		npc.name = n["id"]
		npc.position = Catalog.cell_to_anchor(Vector2i(n["x"], n["y"]))
		_objects.add_child(npc)
		entities[n["id"]] = npc

	for e: Dictionary in world["enemies"]:
		var slime: Slime = preload("res://actors/slime.tscn").instantiate()
		slime.name = e["id"]
		slime.position = Catalog.cell_to_anchor(Vector2i(e["x"], e["y"]))
		_objects.add_child(slime)
		entities[e["id"]] = slime


# --- rival escalation: runtime spawns ----------------------------------------
# Minions and the boss are never part of the world document — they are the
# rival's reaction to the player's progress (see GameState._escalate()), so
# they exist only as scene nodes and vanish with the rest of the world on the
# next teardown()/build(). The critic's VLM repair pass never sees them: it
# only ever runs on the loading screen, before any act can fire.

## Where a physics circle-probe finds no collider on the environment layer.
## Reuses the technique test/agent_bridge.gd's pathfinder already relies on
## (probe the real colliders rather than re-deriving the backend's blocked-cell
## maths) so a spawn can never land inside a wall or a pond.
func _probe_open(world_pos: Vector2) -> bool:
	var space := get_viewport().world_2d.direct_space_state
	var shape := CircleShape2D.new()
	shape.radius = 5.0
	var q := PhysicsShapeQueryParameters2D.new()
	q.shape = shape
	q.collision_mask = 1  # environment only
	q.collide_with_areas = false
	q.transform = Transform2D(0.0, world_pos)
	return space.intersect_shape(q, 1).is_empty()


## A random open cell `min_tiles`..`max_tiles` from `center`, optionally kept
## at least `avoid_min_tiles` away from `avoid` (used to stop the boss
## spawning right on top of a just-respawned player). Never fails silently:
## if nothing in the budget satisfies both constraints, it settles for the
## farthest candidate that was at least open; if not even that, it falls back
## to the player's own spawn point rather than leaving a caller with no node
## to place at all.
func _open_cell_near(center: Vector2, min_tiles: float, max_tiles: float,
		avoid: Vector2 = Vector2.INF, avoid_min_tiles: float = 0.0) -> Vector2:
	var px := pixel_size()
	var margin := TILE * 2.0
	var best := Vector2.INF
	var best_dist := -1.0
	for i in range(24):
		var ang := randf() * TAU
		var dist := lerpf(min_tiles, max_tiles, randf()) * TILE
		var candidate := center + Vector2.RIGHT.rotated(ang) * dist
		candidate.x = clampf(candidate.x, margin, float(px.x) - margin)
		candidate.y = clampf(candidate.y, margin, float(px.y) - margin)
		if not _probe_open(candidate):
			continue
		var clear_of_avoid := avoid == Vector2.INF \
			or candidate.distance_to(avoid) >= avoid_min_tiles * TILE
		if clear_of_avoid:
			return candidate
		var d := candidate.distance_to(avoid)
		if d > best_dist:
			best_dist = d
			best = candidate
	if best != Vector2.INF:
		return best
	return player.spawn_point if player != null else center


## Adds up to `count` minions, capped so the village is never swarmed: total
## live enemies (existing + new) never exceeds MAX_LIVE_ENEMIES.
const MAX_LIVE_ENEMIES := 5


func spawn_minions(count: int) -> int:
	if player == null:
		return 0
	var room: int = MAX_LIVE_ENEMIES - get_tree().get_nodes_in_group("enemy").size()
	var to_spawn: int = mini(count, maxi(room, 0))
	for i in to_spawn:
		var slime: Slime = preload("res://actors/slime.tscn").instantiate()
		_minion_seq += 1
		var id := "minion_%d" % _minion_seq
		slime.name = id
		slime.position = _open_cell_near(player.global_position, 6.0, 10.0)
		_objects.add_child(slime)
		entities[id] = slime
	return to_spawn


## The rival "taking monstrous form" for the showdown: the same slime scene,
## scaled and tinted from the story's `rival` block, tuned to take longer and
## chase harder. Spawns clear of the player's respawn point so dying mid-fight
## can never turn into spawn-camping.
func spawn_boss(rival: Dictionary) -> Slime:
	if player == null:
		return null
	var slime: Slime = preload("res://actors/slime.tscn").instantiate()
	slime.max_hp = 8
	slime.chase_speed = 46.0
	slime.chase_range = 140.0
	slime.scale = Vector2(1.7, 1.7)
	slime.modulate = Color(String(rival.get("tint", "#8a3fc9")))
	var avoid := Catalog.cell_to_anchor(Vector2i(
		int(world["player_start"]["x"]), int(world["player_start"]["y"])))
	slime.position = _open_cell_near(player.global_position, 8.0, 12.0, avoid, 8.0)
	var rival_id := String(rival.get("id", ""))
	slime.name = rival_id if rival_id != "" else "boss"
	_objects.add_child(slime)
	slime.add_to_group("boss")
	entities[slime.name] = slime
	slime.died.connect(GameState.notify_boss_defeated)
	return slime
