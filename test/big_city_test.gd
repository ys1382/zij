extends Node
# Walkability + assembly test for the procedurally assembled big city.
# Asserts the player lands on a road cell (no fall-through / no spawn inside a
# building) and can walk. Captures a top-down overview + ground-level shot.

func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://test_output"))
	var results := {"checks": [], "pass": true}

	var city := preload("res://scenes/big_city.tscn").instantiate()
	add_child(city)
	var player := city.get_node("Player")
	player.test_mode = true

	# Let collision build + player settle onto the street surface.
	for i in range(60):
		await get_tree().physics_frame

	var p: Vector3 = player.global_position
	var landed: bool = player.is_on_floor() and p.y > -2.0 and p.y < 6.0
	print("BIGCITY landed pos=%s grounded=%s" % [p, player.is_on_floor()])
	_check(results, "player_landed", landed, "pos=%s grounded=%s" % [p, player.is_on_floor()])

	# Top-down overview of the whole grid.
	var builder := city.get_node("CityBuilder")
	var agg: AABB = CityCollision.aabb_of(builder)
	var top := Camera3D.new()
	add_child(top)
	top.current = true
	top.far = 4000.0
	var c := agg.get_center()
	top.global_position = Vector3(c.x, agg.position.y + agg.size.length(), c.z + 0.1)
	top.look_at(c)
	await RenderingServer.frame_post_draw
	await get_tree().create_timer(0.3).timeout
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("res://test_output/bigcity_overview.png")

	# Walk forward ~3s and shoot from a 3/4 ground angle.
	var start: Vector3 = player.global_position
	player.test_input = Vector2(0, -1)
	for i in range(90):
		await get_tree().physics_frame
	var moved: float = start.distance_to(player.global_position)
	var q: Vector3 = player.global_position
	_check(results, "player_walked", moved > 1.0 and player.is_on_floor(), "moved=%.2f grounded=%s" % [moved, player.is_on_floor()])

	var cam := Camera3D.new()
	add_child(cam)
	cam.current = true
	cam.far = 2000.0
	cam.global_position = q + Vector3(15, 10, 15)
	cam.look_at(q)
	await RenderingServer.frame_post_draw
	await get_tree().create_timer(0.3).timeout
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("res://test_output/bigcity_walk.png")
	print("BIGCITY after-walk pos=%s moved=%.2f grounded=%s" % [q, moved, player.is_on_floor()])

	var f := FileAccess.open("res://test_output/results.json", FileAccess.WRITE)
	f.store_string(JSON.stringify(results, "  "))
	f.close()
	print("BIGCITY result pass=%s" % results["pass"])
	get_tree().quit(0 if results["pass"] else 1)

func _check(results: Dictionary, name: String, ok: bool, detail: String) -> void:
	results["checks"].append({"name": name, "pass": ok, "detail": detail})
	if not ok:
		results["pass"] = false
