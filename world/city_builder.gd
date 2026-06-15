extends Node3D
# Procedurally assembles a city from Downtown City MegaKit tiles on a MODULE-metre
# grid (see CityKit / CityLayout). Places tiles, scales buildings to fit their
# cell, recenters the whole assembly, and bolts on instant box collision.
#
# Exposes `spawn_position` (a clear road cell, world-space) for the player.

@export var cols: int = 19
@export var rows: int = 19
@export var block_size: int = 3          # building cells between roads
@export var city_seed: int = 1
@export var place_buildings: bool = true
@export var pack: String = "city4"       # "city4" or "desert"

var spawn_position: Vector3 = Vector3(0, 2, 0)

func _ready() -> void:
	var module: float = CityKit.MODULE
	var buildings := CityKit.buildings_for_pack(pack)
	if buildings.is_empty():
		push_error("CityBuilder: no buildings found for pack '%s'" % pack)
		return
	var layout := CityLayout.generate(cols, rows, block_size, city_seed, buildings)
	var grid: Array = layout["grid"]

	var tiles_root := Node3D.new()
	tiles_root.name = "Tiles"
	add_child(tiles_root)

	var placed := 0
	for x in range(cols):
		for y in range(rows):
			var cell: Dictionary = grid[x][y]
			if cell == null:
				push_error("CityBuilder: nil cell at %d,%d" % [x, y])
				continue
			var kind: String = cell["kind"]
			# building_span and empty cells are handled by their plot origin.
			if kind != "road" and kind != "building":
				continue
			if kind == "building" and not place_buildings:
				continue
			var ps := CityKit.scene(cell["tile"])
			if ps == null:
				continue
			var inst := ps.instantiate() as Node3D
			tiles_root.add_child(inst)
			var plot: Vector2i = cell["plot_size"]
			# Plot centre in grid coords (may span multiple cells).
			var cx: float = (x + (plot.x - 1) * 0.5) * module
			var cy: float = (y + (plot.y - 1) * 0.5) * module
			var cell_center := Vector3(cx, 0.0, cy)
			var plot_footprint: float = module * max(plot.x, plot.y)
			_place_tile(inst, cell_center, int(cell["rot_steps"]),
					kind == "building", plot_footprint, float(cell["height_scale"]),
					plot.x, plot.y, module)
			placed += 1

	# Recenter whole assembly: horizontal centre at origin, bottom at y=0.
	var agg: AABB = CityCollision.aabb_of(tiles_root)
	var shift := Vector3(agg.get_center().x, agg.position.y, agg.get_center().z)
	tiles_root.position -= shift

	# Solid ground plane covering the whole city — asphalt tiles have zero
	# mesh thickness so their box colliders are degenerate. One thick slab is
	# simpler and covers every cell (roads and building plots).
	var ground_sb := StaticBody3D.new()
	ground_sb.collision_layer = 1
	ground_sb.collision_mask = 0
	var ground_col := CollisionShape3D.new()
	var ground_shape := BoxShape3D.new()
	ground_shape.size = Vector3(agg.size.x + 4.0, 0.4, agg.size.z + 4.0)
	ground_col.shape = ground_shape
	ground_sb.add_child(ground_col)
	add_child(ground_sb)
	ground_sb.global_position = Vector3(0.0, -0.2, 0.0)

	# Collision over everything.
	var colliders := CityCollision.add_box_colliders(tiles_root)

	# Player spawn: the chosen road cell, after the recenter shift.
	var sp: Vector2i = layout["spawn"]
	spawn_position = Vector3(sp.x * module, 2.0, sp.y * module) - Vector3(shift.x, 0.0, shift.z)

	# Drop the sibling Player onto the spawn cell, if present.
	var player := get_parent().get_node_or_null("Player")
	if player is Node3D:
		(player as Node3D).global_position = spawn_position

	print("CityBuilder: %d tiles, %d colliders, spawn=%s" % [placed, colliders, spawn_position])

# Places a tile: centres footprint on cell_center, applies yaw, scales building
# to fit its plot (plot_w x plot_h cells), then applies height_scale independently.
func _place_tile(inst: Node3D, cell_center: Vector3, rot_steps: int, is_building: bool,
		plot_footprint: float, height_scale: float, plot_w: int, plot_h: int, module: float) -> void:
	inst.rotation = Vector3(0.0, rot_steps * PI * 0.5, 0.0)

	var a: AABB = CityCollision.aabb_of(inst)

	if is_building:
		var margin := 0.88
		var fit_x: float = plot_w * module * margin / max(a.size.x, 0.001)
		var fit_z: float = plot_h * module * margin / max(a.size.z, 0.001)
		var s: float = min(fit_x, fit_z)
		# Apply footprint scale uniformly, then stretch height independently.
		inst.scale = Vector3(s, s * height_scale, s)
		a = CityCollision.aabb_of(inst)

	var center := a.get_center()
	inst.position += Vector3(cell_center.x - center.x, -a.position.y, cell_center.z - center.z)
