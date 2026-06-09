extends SceneTree

func walk(n: Node, d: int, stats: Dictionary) -> void:
	var extra := ""
	if n is MeshInstance3D:
		stats.meshes += 1
		var aabb := (n as MeshInstance3D).get_aabb()
		stats.surfaces += (n as MeshInstance3D).mesh.get_surface_count() if (n as MeshInstance3D).mesh else 0
		extra = " AABB pos=%s size=%s" % [aabb.position, aabb.size]
	if n is CollisionShape3D or n is StaticBody3D:
		stats.colliders += 1
	if d <= 2:
		print("  ".repeat(d), n.name, " [", n.get_class(), "]", extra)
	for c in n.get_children():
		walk(c, d + 1, stats)

func _init() -> void:
	var ps := load("res://assets/manhattan_gltf/scene.gltf") as PackedScene
	if ps == null:
		print("FAILED to load"); quit(); return
	var root := ps.instantiate()
	var stats := {"meshes": 0, "surfaces": 0, "colliders": 0}
	walk(root, 0, stats)
	# overall AABB
	var agg := AABB()
	var first := true
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		var a: AABB = (mi as MeshInstance3D).get_aabb()
		a = (mi as MeshInstance3D).global_transform * a
		if first: agg = a; first = false
		else: agg = agg.merge(a)
	print("\nTOTAL meshes=%d surfaces=%d colliders=%d" % [stats.meshes, stats.surfaces, stats.colliders])
	print("WORLD AABB pos=%s size=%s (units)" % [agg.position, agg.size])
	root.free()
	quit()
