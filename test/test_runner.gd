extends Node

var results: Array = []

func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://test_output"))
	await run_tests()
	write_results()
	var all_pass := results.all(func(r): return r.pass)
	get_tree().quit(0 if all_pass else 1)

func check(name: String, condition: bool, detail: String = "") -> void:
	results.append({"name": name, "pass": condition, "detail": detail})
	print(("PASS" if condition else "FAIL"), " :: ", name, "  ", detail)

func capture(filename: String) -> void:
	# Must wait for the frame to actually be drawn or the image is blank.
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png("res://test_output/%s" % filename)

func write_results() -> void:
	var f := FileAccess.open("res://test_output/results.json", FileAccess.WRITE)
	f.store_string(JSON.stringify({"checks": results}, "  "))
	f.close()

# ----- M0 + M1: harness proof + movement -----
func run_tests() -> void:
	var game := preload("res://scenes/main.tscn").instantiate()
	add_child(game)
	var player := game.get_node("Player")
	player.test_mode = true

	# M0: let it settle on the floor
	await get_tree().create_timer(1.0).timeout
	await capture("01_spawn.png")
	check("rests_on_floor", player.is_on_floor(), "y=%.2f" % player.global_position.y)
	check("not_sunk", player.global_position.y > -0.2, "y=%.2f" % player.global_position.y)

	# M1: drive forward for 1s, assert it moved and stayed grounded
	var start: Vector3 = player.global_position
	var min_y := start.y
	player.test_input = Vector2(0, -1)   # forward
	for i in range(60):
		await get_tree().physics_frame
		min_y = min(min_y, player.global_position.y)
	player.test_input = Vector2.ZERO
	await capture("02_moved.png")
	var moved: float = start.distance_to(player.global_position)
	check("moved_forward", moved > 1.0, "moved=%.2f" % moved)
	check("still_grounded_after_move", player.is_on_floor(), "y=%.2f" % player.global_position.y)
	check("no_tunneling_through_floor", min_y > -0.2, "min_y=%.2f" % min_y)

	# M2: camera. A wall sits behind the player (+Z) between it and the camera.
	# The SpringArm3D's collision raycast must shorten so the camera doesn't clip.
	var spring: SpringArm3D = player.get_node("SpringArm3D")
	var camera: Camera3D = spring.get_node("Camera3D")
	# Return player to origin so it's in front of the wall again, let camera settle.
	player.test_input = Vector2.ZERO
	player.velocity = Vector3.ZERO
	player.global_position = Vector3(0, 1.2, 0)
	for i in range(30):
		await get_tree().physics_frame
	await capture("03_camera.png")
	var cam_to_pivot: float = spring.global_position.distance_to(camera.global_position)
	check("spring_arm_shortened", cam_to_pivot < spring.spring_length,
		"cam_dist=%.2f spring_length=%.2f" % [cam_to_pivot, spring.spring_length])
	check("camera_not_inside_wall", cam_to_pivot > 0.1,
		"cam_dist=%.2f" % cam_to_pivot)
	# Camera should be in front of the wall (z < wall_z=2.5), not behind it.
	check("camera_in_front_of_wall", camera.global_position.z < 2.5,
		"cam_z=%.2f wall_z=2.50" % camera.global_position.z)

	# M3: walls. FrontWall at z=-6, thickness 0.5 -> front face at z=-5.75.
	# Player radius 0.4 -> should clamp around z=-5.35, never passing the face.
	var wall_face_z := -5.75
	# Normal-speed walk into the wall.
	player.global_position = Vector3(0, 1.2, 0)
	player.velocity = Vector3.ZERO
	player.test_input = Vector2(0, -1)   # forward, toward the wall
	for i in range(120):
		await get_tree().physics_frame
	player.test_input = Vector2.ZERO
	await capture("04_wall.png")
	check("clamped_by_wall", player.global_position.z > wall_face_z,
		"z=%.2f face=%.2f" % [player.global_position.z, wall_face_z])
	check("reached_wall", player.global_position.z < -4.5,
		"z=%.2f" % player.global_position.z)

	# High-speed walk into the wall to check for tunneling.
	var saved_speed: float = player.speed
	player.speed = 80.0
	player.global_position = Vector3(0, 1.2, 0)
	player.velocity = Vector3.ZERO
	var min_z: float = player.global_position.z
	player.test_input = Vector2(0, -1)
	for i in range(120):
		await get_tree().physics_frame
		min_z = min(min_z, player.global_position.z)
	player.test_input = Vector2.ZERO
	player.speed = saved_speed
	check("no_tunneling_at_high_speed", min_z > wall_face_z,
		"min_z=%.2f face=%.2f" % [min_z, wall_face_z])

	# M4: door / interaction. Door trigger (Area3D) sits at z=-3.
	# Reset its state, connect to its signal, walk the player into the trigger.
	var door := game.get_node("Door")
	door.is_open = false
	door.body_entered_count = 0
	door.panel.position.y = 0.0
	var signal_fired := {"v": false}
	door.opened.connect(func(): signal_fired.v = true)
	player.global_position = Vector3(0, 1.2, 0)
	player.velocity = Vector3.ZERO
	player.test_input = Vector2(0, -1)   # forward, into the door trigger
	for i in range(90):
		await get_tree().physics_frame
	player.test_input = Vector2.ZERO
	# let the open tween play so the screenshot shows the raised panel
	await get_tree().create_timer(0.6).timeout
	await capture("05_door.png")
	check("door_trigger_fired", door.body_entered_count > 0,
		"body_entered_count=%d" % door.body_entered_count)
	check("door_opened_signal", signal_fired.v, "opened signal received=%s" % signal_fired.v)
	check("door_is_open", door.is_open, "is_open=%s" % door.is_open)

	# M5: slope. The ramp (z=4) rises in +X from y~0 at x=2 to y~4.4 at x~15.
	# Spawn near the base, settle, walk +X, and verify the player climbs
	# (gains height) while staying grounded and never sinking through.
	var ramp_stats := await climb_test(player, 14.0, "06_ramp.png")
	check("ramp_climbed", ramp_stats.gain > 1.5,
		"base_y=%.2f peak_y=%.2f gain=%.2f x=%.2f" % [ramp_stats.base_y, ramp_stats.peak_y, ramp_stats.gain, ramp_stats.end_x])
	check("ramp_grounded", ramp_stats.grounded_frac > 0.8,
		"grounded_frac=%.2f" % ramp_stats.grounded_frac)
	check("ramp_no_sink", ramp_stats.no_sink, "min gap to surface ok")

	# M5: stairs. Same climb at z=-4, over the stepped collider.
	var stair_stats := await climb_test(player, 6.0, "07_stairs.png")
	check("stairs_climbed", stair_stats.gain > 1.5,
		"base_y=%.2f peak_y=%.2f gain=%.2f x=%.2f" % [stair_stats.base_y, stair_stats.peak_y, stair_stats.gain, stair_stats.end_x])
	check("stairs_grounded", stair_stats.grounded_frac > 0.8,
		"grounded_frac=%.2f" % stair_stats.grounded_frac)
	check("stairs_no_judder", stair_stats.monotonic, "height climbed without dropping back")

	# M6 (humanoid): test the Mixamo Y Bot actor in isolation BEFORE integrating.
	# Reuse the game's floor; spawn far from the ramp/stairs slab (x<-2, z 11..17)
	# in open floor at x=-14 so a walk in any horizontal direction stays clear.
	var hum := preload("res://actors/humanoid.tscn").instantiate()
	game.add_child(hum)
	hum.test_mode = true
	hum.global_position = Vector3(-14.0, 0.3, 14.0)
	# A dedicated camera so the screenshots actually frame the humanoid.
	var hcam := Camera3D.new()
	game.add_child(hcam)
	hcam.current = true
	for i in range(60):
		await get_tree().physics_frame
	_aim(hcam, hum.global_position)
	await capture("08_humanoid_idle.png")
	check("humanoid_anims_loaded",
		hum.anim.has_animation("idle") and hum.anim.has_animation("walk"),
		"anims=%s" % str(hum.anim.get_animation_list()))
	check("humanoid_rests_on_floor", hum.is_on_floor(), "y=%.2f" % hum.global_position.y)
	check("humanoid_not_sunk", hum.global_position.y > -0.2 and hum.global_position.y < 0.6,
		"y=%.2f (feet should be near 0)" % hum.global_position.y)
	check("humanoid_idle_anim", hum.current_animation == "idle",
		"current=%s" % hum.current_animation)

	var h_start: Vector3 = hum.global_position
	hum.test_input = Vector2(0, -1)   # forward (-Z)
	for i in range(60):
		await get_tree().physics_frame
	_aim(hcam, hum.global_position)
	await capture("09_humanoid_walk.png")
	var h_moved: float = h_start.distance_to(hum.global_position)
	check("humanoid_moved", h_moved > 1.0, "moved=%.2f" % h_moved)
	check("humanoid_grounded_after_move", hum.is_on_floor(), "y=%.2f" % hum.global_position.y)
	check("humanoid_walk_anim", hum.current_animation == "walk",
		"current=%s" % hum.current_animation)
	hum.test_input = Vector2.ZERO
	for i in range(20):
		await get_tree().physics_frame
	check("humanoid_returns_to_idle", hum.current_animation == "idle",
		"current=%s" % hum.current_animation)

# Place a camera to frame a target point from a 3/4 angle.
func _aim(cam: Camera3D, target: Vector3) -> void:
	cam.global_position = target + Vector3(3.5, 2.5, 4.5)
	cam.look_at(target + Vector3(0, 1.0, 0))

# Drives the player up a slope/stairs at z=lane and returns climb statistics.
func climb_test(player, lane_z: float, shot: String) -> Dictionary:
	# Drop onto the slope near its base (x=4), settle, then walk +X uphill.
	# The slope surface rises ~2.3 (x=4) -> ~4.3 (x=10); top edge near x=11.
	player.global_position = Vector3(4.0, 4.0, lane_z)
	player.velocity = Vector3.ZERO
	for i in range(35):
		await get_tree().physics_frame
	var base_y: float = player.global_position.y
	var peak_y: float = base_y
	var grounded_count := 0
	var sampled := 0
	var no_sink := true
	var monotonic := true
	# Side camera to see the feet-vs-surface profile mid-climb.
	var sidecam := Camera3D.new()
	add_child(sidecam)
	var mid_done := false
	var mid_shot := shot.replace(".png", "_mid.png")
	player.test_input = Vector2(1, 0)   # +X, uphill
	for i in range(200):
		# stop before the player walks off the top edge (~x=10.5)
		if player.global_position.x > 10.3:
			break
		await get_tree().physics_frame
		sampled += 1
		var y: float = player.global_position.y
		peak_y = max(peak_y, y)
		if player.is_on_floor():
			grounded_count += 1
		# Halfway up (~x=7): stop, let it settle to idle, then measure + shoot.
		if not mid_done and player.global_position.x > 7.0:
			mid_done = true
			player.test_input = Vector2.ZERO
			for j in range(20):
				await get_tree().physics_frame
			var p: Vector3 = player.global_position
			# Raycast straight down from above the feet to find the real surface.
			var space: PhysicsDirectSpaceState3D = player.get_world_3d().direct_space_state
			var rq := PhysicsRayQueryParameters3D.create(
				p + Vector3(0, 2.0, 0), p + Vector3(0, -2.0, 0), 1)  # mask 1 = env
			var hit: Dictionary = space.intersect_ray(rq)
			var surf_y: float = (hit.position.y as float) if not hit.is_empty() else NAN
			var gap: float = p.y - surf_y
			print("CLIMBDBG %s feet_y=%.3f surface_y=%.3f gap=%.3f (>0 feet above surface)"
				% [mid_shot, p.y, surf_y, gap])
			sidecam.current = true
			sidecam.global_position = p + Vector3(0.5, 1.0, 6.0)
			sidecam.look_at(p + Vector3(0, 0.6, 0))
			await capture(mid_shot)
			player.get_node("SpringArm3D").get_node("Camera3D").current = true
			player.test_input = Vector2(1, 0)
		# expected surface y under the player: ~2.3 at x=4 rising 0.333/unit.
		# Player is feet-origin (humanoid), so y should sit ~at the surface.
		var surf: float = 2.3 + (player.global_position.x - 4.0) * 0.333
		if y < surf - 0.4:
			no_sink = false   # sank noticeably below the slope surface
		if y < peak_y - 0.6:
			monotonic = false
	player.test_input = Vector2.ZERO
	for i in range(20):
		await get_tree().physics_frame
	await capture(shot)
	return {
		"base_y": base_y, "peak_y": peak_y, "gain": peak_y - base_y,
		"end_x": player.global_position.x,
		"grounded_frac": float(grounded_count) / float(max(sampled, 1)),
		"no_sink": no_sink, "monotonic": monotonic,
	}
