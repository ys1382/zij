extends SceneTree

func _print_tree(n: Node, depth: int) -> void:
	var extra := ""
	if n is MeshInstance3D:
		var aabb = n.get_aabb()
		extra = " AABB size=%s pos=%s" % [aabb.size, aabb.position]
	if n is Node3D:
		extra += " xform_scale=%s" % n.transform.basis.get_scale()
	if n is AnimationPlayer:
		extra = " ANIMS=%s" % str(n.get_animation_list())
	print("  ".repeat(depth), n.name, " [", n.get_class(), "]", extra)
	for c in n.get_children():
		_print_tree(c, depth + 1)

func _init() -> void:
	for path in ["res://assets/Basic Locomotion Pack/Y Bot.fbx",
				 "res://assets/Basic Locomotion Pack/walking.fbx",
				 "res://assets/Basic Locomotion Pack/idle.fbx"]:
		print("\n===== ", path, " =====")
		var ps := load(path) as PackedScene
		if ps == null:
			print("  FAILED to load")
			continue
		var n := ps.instantiate()
		_print_tree(n, 0)
		n.free()
	quit()
