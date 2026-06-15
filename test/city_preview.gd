extends Node

func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://test_output"))

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.5, 0.6, 0.7)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.6, 0.6, 0.6)
	env.environment = e
	add_child(env)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-50, -40, 0)
	add_child(light)

	var city := (load("res://assets/manhattan_gltf/scene.gltf") as PackedScene).instantiate() as Node3D
	add_child(city)
	city.scale = Vector3(0.01, 0.01, 0.01)   # tame the x100 baked scale

	# overall AABB after scaling
	var agg := _aabb_of(city)
	# recenter: put horizontal center at origin and the bottom plane at y=0
	city.global_position -= Vector3(agg.get_center().x, agg.position.y, agg.get_center().z)
	agg = _aabb_of(city)
	var c := agg.get_center()
	var r: float = agg.size.length()

	# Three reference cubes 1.8m tall (human height) at the center & corners to gauge scale.
	for off in [Vector3(0,0,0), Vector3(agg.size.x*0.3,0,0), Vector3(0,0,agg.size.z*0.3)]:
		var ref := MeshInstance3D.new()
		var bm := BoxMesh.new(); bm.size = Vector3(0.6, 1.8, 0.6)
		ref.mesh = bm
		var mat := StandardMaterial3D.new(); mat.albedo_color = Color(1, 0, 0)
		ref.material_override = mat
		add_child(ref)
		ref.global_position = Vector3(c.x + off.x, agg.position.y + 0.9, c.z + off.z)

	var cam := Camera3D.new()
	add_child(cam)
	cam.current = true
	cam.far = 20000.0
	# 3/4 view from outside the bounding sphere
	cam.global_position = c + Vector3(r*0.6, r*0.5, r*0.6)
	cam.look_at(c)

	await RenderingServer.frame_post_draw
	await get_tree().create_timer(0.3).timeout
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png("res://test_output/city_overview.png")
	print("CITY AABB pos=%s size=%s center=%s diag=%.1f" % [agg.position, agg.size, c, r])
	print("Red boxes are 1.8m human-height references at the model's bottom plane.")
	get_tree().quit()

func _aabb_of(root: Node) -> AABB:
	var agg := AABB()
	var first := true
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		var a: AABB = (mi as MeshInstance3D).global_transform * (mi as MeshInstance3D).get_aabb()
		if first: agg = a; first = false
		else: agg = agg.merge(a)
	return agg
