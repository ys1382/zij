class_name CityLayout
extends RefCounted
# Produces a 2D grid of cell descriptors for the builder. Each cell is a Dictionary:
#   { kind, tile, rot_steps, plot_size: Vector2i, height_scale: float }
# kind ∈ {"road", "building", "building_span", "empty"}
#
# "building"      — plot origin cell; builder places one building here sized to plot_size*MODULE
# "building_span" — cell covered by a multi-cell plot rooted at another cell; builder skips it
# "road"          — asphalt ground tile
# "empty"         — open lot; builder skips (ground slab covers it)
#
# Manhattan variety comes from two sources:
#   1. Variable plot sizes — greedy random partition of each block into 1x1/2x1/1x2/2x2/3x1/1x3
#      plots, so some buildings span multiple cells and look massive next to small ones.
#   2. Independent height scaling — each plot gets a random height multiplier so the skyline
#      is varied (towers, mid-rise, squat) even when the footprint is the same size.
#
# Deterministic: same seed -> same city.

# Returns { grid: Array[Array[Dictionary]], cols: int, rows: int, spawn: Vector2i }
static func generate(cols: int, rows: int, block_size: int, seed_value: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var stride := block_size + 1  # road every `stride` cells

	# Initialise all cells as road or pending.
	var grid := []
	for x in range(cols):
		var col := []
		for y in range(rows):
			col.append(null)
		grid.append(col)

	var spawn := Vector2i(0, 0)
	var spawn_set := false
	var mid_x: int = (cols / 2 / stride) * stride
	var mid_y: int = (rows / 2 / stride) * stride

	# Lay roads first.
	for x in range(cols):
		for y in range(rows):
			if (x % stride == 0) or (y % stride == 0):
				grid[x][y] = {"kind": "road", "tile": CityKit.ROAD, "rot_steps": 0,
						"plot_size": Vector2i(1, 1), "height_scale": 1.0}
				if not spawn_set and x == mid_x and y == mid_y:
					spawn = Vector2i(x, y)
					spawn_set = true

	# Partition each block interior with variable-sized plots.
	# Only process blocks that are fully within the grid.
	for bx in range(cols / stride):
		for by in range(rows / stride):
			var ox: int = bx * stride + 1   # block interior origin x
			var oy: int = by * stride + 1   # block interior origin y
			if ox + block_size > cols or oy + block_size > rows:
				continue
			_partition_block(grid, rng, ox, oy, block_size)

	# Fill any cells left null (partial edge blocks that weren't partitioned).
	for x in range(cols):
		for y in range(rows):
			if grid[x][y] == null:
				grid[x][y] = {"kind": "empty", "tile": "", "rot_steps": 0,
						"plot_size": Vector2i(1, 1), "height_scale": 1.0}

	return {"grid": grid, "cols": cols, "rows": rows, "spawn": spawn}

# Greedy random plot partition for one block interior of size block_size x block_size.
static func _partition_block(grid: Array, rng: RandomNumberGenerator,
		ox: int, oy: int, block_size: int) -> void:
	# Possible plot sizes in priority order (largest first for Manhattan feel).
	# Each entry: [w, h, weight]
	var sizes := [
		[2, 2, 20],  # large corner anchor — common in Manhattan
		[3, 1, 12],  # full-block frontage
		[1, 3, 12],
		[2, 1, 25],
		[1, 2, 25],
		[1, 1, 40],  # small infill
	]
	# Build a weighted pick list once.
	var pick_list := []
	for s in sizes:
		for _i in range(s[2]):
			pick_list.append(Vector2i(s[0], s[1]))

	for lx in range(block_size):
		for ly in range(block_size):
			var x: int = ox + lx
			var y: int = oy + ly
			if grid[x][y] != null:
				continue  # already assigned

			# Try random candidates; fall back to guaranteed 1x1.
			var idx: int = rng.randi_range(0, pick_list.size() - 1)
			var chosen := Vector2i(1, 1)
			for _attempt in range(pick_list.size()):
				var cand: Vector2i = pick_list[(idx + _attempt) % pick_list.size()]
				if _fits(grid, x, y, cand.x, cand.y, block_size, ox, oy):
					chosen = cand
					break
			# 1x1 always fits (cell is unassigned and within block bounds).
			if not _fits(grid, x, y, chosen.x, chosen.y, block_size, ox, oy):
				chosen = Vector2i(1, 1)

			# Occasionally leave small plots empty (open lots, plazas).
			var empty: bool = chosen == Vector2i(1, 1) and rng.randf() < 0.08

			var tile: String = CityKit.BUILDINGS[rng.randi_range(0, CityKit.BUILDINGS.size() - 1)]
			var rot: int = rng.randi_range(0, 3)
			# Height varies by plot size: big plots can be very tall towers;
			# small plots tend to be shorter.
			var h_scale: float = _height_scale(rng, chosen)

			# Mark origin cell.
			if empty:
				grid[x][y] = {"kind": "empty", "tile": "", "rot_steps": 0,
						"plot_size": Vector2i(1, 1), "height_scale": 1.0}
			else:
				grid[x][y] = {"kind": "building", "tile": tile, "rot_steps": rot,
						"plot_size": chosen, "height_scale": h_scale}
				# Mark span cells so the builder skips them.
				for dx in range(chosen.x):
					for dy in range(chosen.y):
						if dx == 0 and dy == 0:
							continue
						grid[x + dx][y + dy] = {"kind": "building_span", "tile": "",
								"rot_steps": 0, "plot_size": Vector2i(1, 1), "height_scale": 1.0}

# Returns true if a w×h plot fits inside the block and all cells are unassigned.
static func _fits(grid: Array, x: int, y: int, w: int, h: int,
		block_size: int, ox: int, oy: int) -> bool:
	if x + w > ox + block_size or y + h > oy + block_size:
		return false
	for dx in range(w):
		for dy in range(h):
			if grid[x + dx][y + dy] != null:
				return false
	return true

# Random height multiplier biased by plot area — big plots can tower.
static func _height_scale(rng: RandomNumberGenerator, plot: Vector2i) -> float:
	var area: int = plot.x * plot.y
	match area:
		4:  # 2x2 — can be a real tower
			return rng.randf_range(1.5, 3.5)
		3:  # 3x1 or 1x3 — mid-rise slab
			return rng.randf_range(1.0, 2.5)
		2:  # 2x1 or 1x2
			return rng.randf_range(0.8, 2.0)
		_:  # 1x1 — small, varied
			return rng.randf_range(0.5, 1.8)

# Future hook: accept a hand-authored grid (same cell-descriptor shape).
static func from_authored(grid: Array, spawn: Vector2i) -> Dictionary:
	return {"grid": grid, "cols": grid.size(),
			"rows": (grid[0] as Array).size() if grid.size() > 0 else 0, "spawn": spawn}
