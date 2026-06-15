extends Node3D
# Loads neighbourhood_city_modular_lowpoly.glb, recenters it, and adds
# instant box collision per mesh (AABB-based — no mesh decomposition).

@export var model_path: String = "res://assets/neighbourhood_city_modular_lowpoly.glb"

func _ready() -> void:
	var ps := load(model_path) as PackedScene
	if ps == null:
		push_error("CitySetup: could not load " + model_path)
		_add_fallback_ground()
		return
	var city := ps.instantiate() as Node3D
	add_child(city)

	# Recenter: horizontal center at origin, bottom at y=0
	var agg: AABB = _aabb_of(city)
	city.global_position -= Vector3(agg.get_center().x, agg.position.y, agg.get_center().z)

	# Box collider per mesh — instant, good enough for walls/buildings
	var count := 0
	for mi in city.find_children("*", "MeshInstance3D", true, false):
		var mi_node := mi as MeshInstance3D
		var local_aabb: AABB = mi_node.get_aabb()
		if local_aabb.size.length() < 0.05:
			continue
		var sb := StaticBody3D.new()
		sb.collision_layer = 1
		sb.collision_mask = 0
		var col := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = local_aabb.size
		col.position = local_aabb.get_center()
		col.shape = shape
		sb.add_child(col)
		mi_node.add_child(sb)
		count += 1
	print("CitySetup: %d box colliders added" % count)

func _add_fallback_ground() -> void:
	var sb := StaticBody3D.new()
	sb.collision_layer = 1
	sb.collision_mask = 0
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(600.0, 0.2, 400.0)
	col.shape = shape
	sb.add_child(col)
	add_child(sb)
	sb.global_position = Vector3(0.0, -0.1, 0.0)

func _aabb_of(root: Node) -> AABB:
	var agg := AABB()
	var first := true
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		var a: AABB = (mi as MeshInstance3D).global_transform * (mi as MeshInstance3D).get_aabb()
		if first:
			agg = a
			first = false
		else:
			agg = agg.merge(a)
	return agg
