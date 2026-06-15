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
	var agg: AABB = CityCollision.aabb_of(city)
	city.global_position -= Vector3(agg.get_center().x, agg.position.y, agg.get_center().z)

	# Box collider per mesh — instant, good enough for walls/buildings
	var count := CityCollision.add_box_colliders(city)
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
