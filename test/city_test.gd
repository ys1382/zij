extends Node

func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://test_output"))
	var city := preload("res://scenes/city.tscn").instantiate()
	add_child(city)
	var player := city.get_node("Player")
	player.test_mode = true

	# Let collision build + player fall onto the street surface.
	for i in range(60):
		await get_tree().physics_frame

	var p: Vector3 = player.global_position
	print("CITYTEST landed pos=%s grounded=%s" % [p, player.is_on_floor()])

	# External camera framing the player from a 3/4 angle.
	var cam := Camera3D.new()
	add_child(cam)
	cam.current = true
	cam.far = 2000.0
	cam.global_position = p + Vector3(15, 10, 15)
	cam.look_at(p)
	await RenderingServer.frame_post_draw
	await get_tree().create_timer(0.3).timeout
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("res://test_output/city_landed.png")

	# Walk forward for ~3 seconds and re-shoot.
	var start: Vector3 = player.global_position
	player.test_input = Vector2(0, -1)
	for i in range(90):
		await get_tree().physics_frame
	var moved: float = start.distance_to(player.global_position)
	var q: Vector3 = player.global_position
	cam.global_position = q + Vector3(15, 10, 15)
	cam.look_at(q)
	await RenderingServer.frame_post_draw
	await get_tree().create_timer(0.3).timeout
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("res://test_output/city_walk.png")
	print("CITYTEST after-walk pos=%s moved=%.2f grounded=%s" % [q, moved, player.is_on_floor()])
	get_tree().quit()
