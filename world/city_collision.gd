class_name CityCollision
extends RefCounted
# Shared collision/measurement helpers for assembled city scenes.
# Box collider per mesh (AABB-based — no mesh decomposition); instant and
# good enough for walls/buildings/roads.

# Adds a StaticBody3D + BoxShape3D collider under every MeshInstance3D in `root`.
# Returns the number of colliders added. Skips tiny meshes (< 0.05 units).
static func add_box_colliders(root: Node3D, layer: int = 1) -> int:
	var count := 0
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		var mi_node := mi as MeshInstance3D
		var local_aabb: AABB = mi_node.get_aabb()
		if local_aabb.size.length() < 0.05:
			continue
		var sb := StaticBody3D.new()
		sb.collision_layer = layer
		sb.collision_mask = 0
		var col := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = local_aabb.size
		col.position = local_aabb.get_center()
		col.shape = shape
		sb.add_child(col)
		mi_node.add_child(sb)
		count += 1
	return count

# World-space aggregate AABB over all meshes under `root` (must be in-tree
# for global_transform to be valid).
static func aabb_of(root: Node) -> AABB:
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
