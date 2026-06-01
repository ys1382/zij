extends SceneTree

func _init() -> void:
	var ps := load("res://assets/Basic Locomotion Pack/walking.fbx") as PackedScene
	var inst := ps.instantiate()
	var ap := inst.get_node("AnimationPlayer") as AnimationPlayer
	var clip := ap.get_animation("mixamo_com")
	print("walk length=%.2f tracks=%d" % [clip.length, clip.get_track_count()])
	for t in clip.get_track_count():
		if clip.track_get_type(t) == Animation.TYPE_POSITION_3D:
			var path := str(clip.track_get_path(t))
			var n := clip.track_get_key_count(t)
			if n > 0:
				var first: Vector3 = clip.track_get_key_value(t, 0)
				var last: Vector3 = clip.track_get_key_value(t, n - 1)
				print("POS track '", path, "' keys=", n, " first=", first, " last=", last,
					" delta=", last - first)
	inst.free()
	quit()
