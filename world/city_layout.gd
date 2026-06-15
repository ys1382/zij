class_name CityLayout
extends RefCounted
# Produces a 2D grid of cell descriptors for the builder. Each cell is a Dictionary:
#   { kind: String, tile: String, rot_steps: int }
# kind ∈ {"road", "building", "empty"}; rot_steps is yaw in 90° increments.
#
# Layout scheme (clean Manhattan grid, snapped to CityKit.MODULE = 9m):
#   - A 1-cell-wide road runs along every row/col whose index is a multiple of
#     (block_size + 1). Roads form a cross-hatch; their crossings are plain road.
#   - Interior block cells hold buildings (a building roughly fills one 9m cell;
#     larger prefabs overhang slightly but plots are spaced by full cells so they
#     never collide with roads).
# Deterministic: same seed -> same city.

# Returns { grid: Array[Array[Dictionary]], cols: int, rows: int, spawn: Vector2i }
# spawn is a guaranteed road cell (kept clear of buildings).
static func generate(cols: int, rows: int, block_size: int, seed_value: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var stride := block_size + 1  # road every `stride` cells

	var grid := []
	var spawn := Vector2i(0, 0)
	var spawn_set := false
	# Pick a road intersection near the centre of the grid for the player spawn.
	var mid_x: int = (cols / 2 / stride) * stride
	var mid_y: int = (rows / 2 / stride) * stride
	for x in range(cols):
		var col := []
		for y in range(rows):
			var is_road := (x % stride == 0) or (y % stride == 0)
			if is_road:
				col.append({"kind": "road", "tile": CityKit.ROAD, "rot_steps": 0})
				if not spawn_set and x == mid_x and y == mid_y:
					spawn = Vector2i(x, y)
					spawn_set = true
			else:
				var b: String = CityKit.BUILDINGS[rng.randi_range(0, CityKit.BUILDINGS.size() - 1)]
				# Face the building toward the nearest road (random of 4 for variety).
				col.append({"kind": "building", "tile": b, "rot_steps": rng.randi_range(0, 3)})
		grid.append(col)

	return {"grid": grid, "cols": cols, "rows": rows, "spawn": spawn}

# Future hook: accept a hand-authored grid (same cell-descriptor shape) so a
# specific neighbourhood can be designed without changing the builder.
static func from_authored(grid: Array, spawn: Vector2i) -> Dictionary:
	return {"grid": grid, "cols": grid.size(), "rows": (grid[0] as Array).size() if grid.size() > 0 else 0, "spawn": spawn}
