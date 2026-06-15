extends SceneTree

func _init() -> void:
	var ps := load("res://assets/manhattan_gltf/scene.gltf") as PackedScene
	var root := ps.instantiate() as Node3D
	get_root().add_child(root)   # in-tree so global transforms work

	var agg := AABB()
	var first := true
	var meshes := 0
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		meshes += 1
		var a: AABB = (mi as MeshInstance3D).get_aabb()
		a = (mi as MeshInstance3D).global_transform * a
		if first: agg = a; first = false
		else: agg = agg.merge(a)
	print("MESHES=%d" % meshes)
	print("WORLD AABB pos=%s size=%s" % [agg.position, agg.size])
	print("center=%s  bottom_y=%.3f top_y=%.3f" % [agg.get_center(), agg.position.y, agg.position.y + agg.size.y])
	# report the sketchfab wrapper transforms (rotation/scale quirks)
	for n in root.find_children("*", "Node3D", true, false):
		var t := (n as Node3D).transform
		if t.basis.get_scale() != Vector3.ONE or t.basis.get_euler() != Vector3.ZERO:
			print("  node '", n.name, "' scale=", t.basis.get_scale(), " euler_deg=", t.basis.get_euler() * 180.0 / PI)
	quit()
