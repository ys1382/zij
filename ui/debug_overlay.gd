extends Label
@export var player_path: NodePath
@export var camera_path: NodePath

func _resolve_player() -> Node:
	if not player_path.is_empty():
		var n := get_node_or_null(player_path)
		if n != null:
			return n
	var grp := get_tree().get_nodes_in_group("player")
	return grp[0] if grp.size() > 0 else null

func _resolve_camera() -> Node3D:
	if not camera_path.is_empty():
		var c := get_node_or_null(camera_path)
		if c != null:
			return c
	return get_viewport().get_camera_3d()

func _process(_delta: float) -> void:
	var p := _resolve_player()
	if p == null:
		text = "(no player)"
		return
	var cam := _resolve_camera()
	var cam_pos := str(cam.global_position) if cam != null else "n/a"
	text = "pos %s\nvel %s\ngrounded %s\ncam %s\nfps %d" % [
		p.global_position, p.velocity, p.is_on_floor(),
		cam_pos, Engine.get_frames_per_second()]
