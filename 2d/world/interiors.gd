extends Node
# Autoload. Owns going inside a building and coming back out.
#
# The outdoor world is hidden and frozen rather than torn down, so the village is
# exactly as you left it when you step back out — villagers mid-wander, slimes
# where they were, nothing re-rolled. Rebuilding would also invalidate every
# node reference anything else is holding, which is the hazard WorldManager
# exists to guard against.

signal entered(building_id: String)
signal left()

var current: Interior = null

var _outside_pos := Vector2.ZERO
var _player: Player = null


func inside() -> bool:
	return current != null


## `flavour` is the door interactable's text, shown once the player is actually
## in the room — over the doorstep it would just be a panel in the way.
func enter(building_id: String, flavour: String = "") -> void:
	if inside():
		return
	var root := WorldManager.world_root
	if root == null:
		return
	var host := root.entities.get(building_id) as Node2D
	var p := root.player as Player
	if host == null or p == null:
		push_warning("cannot enter '%s': no such building" % building_id)
		return

	var asset := ""
	for entry in root.world.get("objects", []):
		if entry["id"] == building_id:
			asset = entry["asset"]
			break
	var footprint := Catalog.footprint(asset) if asset != "" else Vector2i(6, 6)

	_player = p
	_outside_pos = p.global_position

	current = Interior.new()
	current.name = "Interior_%s" % building_id
	add_child(current)
	current.build(building_id, footprint,
		str(root.world.get("seed", root.world.get("title", ""))))
	current.exit_requested.connect(leave)

	root.visible = false
	root.process_mode = Node.PROCESS_MODE_DISABLED

	p.reparent(current.get_node("Objects"), false)
	p.position = current.entry_point()
	p.velocity = Vector2.ZERO
	p.agent_input = Vector2.ZERO
	_clamp_camera(p, current.pixel_size())

	entered.emit(building_id)
	if flavour != "":
		DialogueUI.show_line("", flavour)


func leave() -> void:
	if not inside():
		return
	var root := WorldManager.world_root
	var p := _player
	current.exit_requested.disconnect(leave)

	if root != null and p != null and is_instance_valid(p):
		root.visible = true
		root.process_mode = Node.PROCESS_MODE_INHERIT
		p.reparent(root.get_node("Objects"), false)
		# Back on the doorstep, not inside the wall. The saved position is where
		# they were standing when they pressed E, which is by definition a legal
		# tile they walked to.
		p.global_position = _outside_pos
		p.velocity = Vector2.ZERO
		p.agent_input = Vector2.ZERO
		_clamp_camera(p, root.pixel_size())

	current.queue_free()
	current = null
	_player = null
	DialogueUI.close()
	left.emit()


func _clamp_camera(p: Player, px: Vector2i) -> void:
	var cam := p.get_node_or_null("Camera") as Camera2D
	if cam == null:
		return
	cam.limit_left = 0
	cam.limit_top = 0
	cam.limit_right = px.x
	cam.limit_bottom = px.y
	# The camera smooths towards its target; without this the first frame inside
	# is a pan across the whole room from wherever it was standing outdoors.
	cam.reset_smoothing()
