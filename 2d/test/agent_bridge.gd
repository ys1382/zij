extends Node
# Autoload, DORMANT unless the game is launched with `-- --agent-bridge`.
# A TCP JSON-lines control server on 127.0.0.1:8765 that lets an agent (or a
# script) PLAY the real game: read world state, walk the player, talk to NPCs,
# use interactables, screenshot. Ported from zij3d/test/agent_bridge.gd.
#
# This is the only way to test the game as a *game*: the validator proves a
# world is well-formed, but only walking around it shows whether the mystery is
# solvable and the village is pleasant to be in.
#
# Protocol: one JSON object per line in, one JSON reply per line out.
#   {"cmd":"state"}                     -> player, focus, npcs, beats
#   {"cmd":"world"}                     -> the full world document
#   {"cmd":"goto","x":X,"y":Y}          -> walk to a tile (blocks until arrived)
#   {"cmd":"teleport","x":X,"y":Y}      -> instant reposition
#   {"cmd":"use"}                       -> use whatever is in reach
#   {"cmd":"talk","id":"npc_id"}        -> walk to an NPC and greet them
#   {"cmd":"say","text":"..."}          -> send a line, wait for the reply
#   {"cmd":"close"}                     -> dismiss the dialogue panel
#   {"cmd":"wait","secs":N}             -> idle
#   {"cmd":"screenshot","name":"x.png"} -> whole-map PNG into test_output/
#                       ,"ui":true      -> the visible window instead, with UI
#   {"cmd":"reach","id":"..."}          -> an interactable's trigger geometry
#   {"cmd":"journal"}                   -> what the player's journal now says
#   {"cmd":"slay"}                      -> fight the boss/nearest enemy to death
#   {"cmd":"_hang"}                     -> test hook: never replies, to prove
#                                          the watchdog actually fires
#   {"cmd":"quit"}                      -> quit the game

const PORT := 8765
const TILE := 16
const GOTO_TIMEOUT := 30.0
const ARRIVE_DIST := 10.0
const REPLY_TIMEOUT := 25.0
## Total wall time for getting to an NPC, across every candidate standing tile.
## Must leave BUSY_TIMEOUT room for the model round trip that follows.
const APPROACH_BUDGET := 12.0
## No single command may take longer than this. Any path that fails to
## reply (a runtime error mid-coroutine, an await that never resolves)
## would otherwise leave _busy latched true forever: the bridge silently
## ignores every later command while the client blocks on recv with no
## diagnostic. A stall must be loud.
const BUSY_TIMEOUT := 40.0

var _server: TCPServer = null
var _peer: StreamPeerTCP = null
var _buf := ""
var _busy := false
var _busy_since := 0
var _busy_cmd := ""

## Set per screenshot command; see _screenshot().
var _ui_shot := false

var _cached_grid: AStarGrid2D = null
var _cached_for := ""
var _talking_to: Npc = null
var _last_line := ""
var _last_npc := ""


func _ready() -> void:
	if "--agent-bridge" not in OS.get_cmdline_user_args():
		set_process(false)
		return
	# Journal pauses the tree. A paused bridge would stop polling its socket and
	# latch every command silently — exactly the failure the watchdog exists to
	# report — so it stays alive regardless of pause state.
	process_mode = Node.PROCESS_MODE_ALWAYS
	_server = TCPServer.new()
	var err := _server.listen(PORT, "127.0.0.1")
	if err != OK:
		push_warning("AgentBridge: cannot listen on %d (%d)" % [PORT, err])
		set_process(false)
		return
	LLMClient.dialogue_received.connect(_on_dialogue)
	print("AgentBridge: listening on 127.0.0.1:%d" % PORT)


func _on_dialogue(npc_id: String, line: String, _meta: Dictionary) -> void:
	_last_npc = npc_id
	_last_line = line


# --- transport ---------------------------------------------------------------

func _process(_delta: float) -> void:
	if _server == null:
		return
	if _server.is_connection_available():
		var incoming := _server.take_connection()
		if _peer == null or _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			_peer = incoming
			_buf = ""
		else:
			incoming.disconnect_from_host()   # one client at a time
	if _peer == null:
		return
	_peer.poll()
	if _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return
	if _busy and Time.get_ticks_msec() - _busy_since > int(BUSY_TIMEOUT * 1000.0):
		push_warning("AgentBridge: '%s' never replied in %.0fs; unlatching"
			% [_busy_cmd, BUSY_TIMEOUT])
		_reply({"ok": false, "error": "command_timeout", "cmd": _busy_cmd})

	var n := _peer.get_available_bytes()
	if n > 0:
		_buf += _peer.get_utf8_string(n)
	while "\n" in _buf and not _busy:
		var idx := _buf.find("\n")
		var line := _buf.substr(0, idx).strip_edges()
		_buf = _buf.substr(idx + 1)
		if line != "":
			var cmd = JSON.parse_string(line)
			if typeof(cmd) != TYPE_DICTIONARY:
				_reply({"ok": false, "error": "bad_json"})
			else:
				_busy = true
				_busy_since = Time.get_ticks_msec()
				_busy_cmd = str(cmd.get("cmd", "?"))
				_run(cmd)   # async: replies and clears _busy when done


func _reply(data: Dictionary) -> void:
	if not _busy:
		# The watchdog already answered for this command; a second reply
		# would leave the client one message out of step for the rest of
		# the session.
		return
	if _peer != null and _peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		_peer.put_data((JSON.stringify(data) + "\n").to_utf8_buffer())
	_busy = false
	_busy_cmd = ""


# --- helpers -----------------------------------------------------------------

func _player() -> Player:
	return get_tree().get_first_node_in_group("player") as Player


func _main() -> Node:
	return get_tree().current_scene


func _builder() -> WorldBuilder:
	return WorldManager.world_root as WorldBuilder


func _tile_of(pos: Vector2) -> Vector2i:
	return Vector2i(int(pos.x) / TILE, int(pos.y) / TILE)


func _centre_of(tx: int, ty: int) -> Vector2:
	return Vector2(tx * TILE + TILE * 0.5, ty * TILE + TILE * 0.5)


func _describe_focus() -> Dictionary:
	var p := _player()
	if p == null or p.focus == null:
		return {}
	if p.focus is Interactable:
		var it := p.focus as Interactable
		return {"kind": "interactable", "id": str(it.data.get("id", "")),
				"verb": it.verb, "used": it.used_once}
	if p.focus is Npc:
		var npc := p.focus as Npc
		return {"kind": "npc", "id": npc.npc_id, "name": npc.display_name}
	return {}


# --- commands ----------------------------------------------------------------

func _run(cmd: Dictionary) -> void:
	match str(cmd.get("cmd", "")):
		"state":
			_reply(_state())
		"world":
			_reply({"ok": true, "world": GameState.world})
		"teleport":
			var p := _player()
			if p == null:
				_reply({"ok": false, "error": "no_player"})
				return
			p.position = _centre_of(int(cmd.get("x", 0)), int(cmd.get("y", 0)))
			await get_tree().physics_frame
			_reply(_state())
		"enter":
			# Walk to a house door and go in. Interiors are a whole second space
			# the player can be standing in, so a playtest has to be able to get
			# there and back or half the game is untested.
			await _enter(str(cmd.get("id", "")))
		"leave":
			if not Interiors.inside():
				_reply({"ok": false, "error": "not_inside"})
				return
			Interiors.leave()
			await get_tree().physics_frame
			_invalidate_grid()
			_reply(_state())
		"peace":
			# Clears the map of enemies. --auto measures whether the STORY can
			# be uncovered; without this it also measures whether the player
			# survived the walk, and a scripted run that dies mid-goto gets
			# teleported back to spawn and fails for an unrelated reason.
			var n := 0
			for e in get_tree().get_nodes_in_group("enemy"):
				(e as Node).queue_free()
				n += 1
			_reply({"ok": true, "removed": n})
		"attack":
			var pa := _player()
			if pa == null:
				_reply({"ok": false, "error": "no_player"})
				return
			pa.swing()
			_reply({"ok": true, "hp": pa.hp, "enemies": _enemies()})
		"face":
			# Swings are a cone in front of the player, so a test has to be able
			# to aim without walking.
			var pf := _player()
			if pf == null:
				_reply({"ok": false, "error": "no_player"})
				return
			pf.facing = Vector2(float(cmd.get("x", 0)), float(cmd.get("y", 1)))
			_reply({"ok": true})
		"journal":
			# Returns what the player would read, so a run can assert the game
			# is telling them something actionable rather than just not
			# crashing. Pass "open" to show or hide the panel as well.
			if cmd.has("open"):
				if bool(cmd["open"]):
					if not Journal.is_open():
						Journal.toggle()
				else:
					Journal.dismiss()
			_reply({"ok": true, "open": Journal.is_open(),
				"contents": Journal.contents()})
		"dismiss":
			# Acknowledges the ending card (or anything else holding the pause).
			Journal.dismiss()
			_reply({"ok": true, "paused": get_tree().paused})
		"goto":
			await _goto(int(cmd.get("x", 0)), int(cmd.get("y", 0)))
		"use":
			var p2 := _player()
			if p2 == null:
				_reply({"ok": false, "error": "no_player"})
				return
			var focus := _describe_focus()
			if focus.is_empty():
				_reply({"ok": false, "error": "nothing_in_reach"})
				return
			_last_line = ""
			var outcome := p2.use_focus()
			if outcome == "talk":
				await _await_reply()
			var out := _state()
			out["used"] = focus
			out["outcome"] = outcome
			# For anything but a model reply the visible line is whatever the
			# panel is showing — pickup text, locked_text, the gift line.
			out["line"] = _last_line if outcome == "talk" else DialogueUI.body()
			_reply(out)
		"talk":
			await _talk(str(cmd.get("id", "")))
		"say":
			await _say(str(cmd.get("text", "")))
		"close":
			_talking_to = null
			DialogueUI.close()
			_reply({"ok": true})
		"wait":
			await get_tree().create_timer(
				clampf(float(cmd.get("secs", 1.0)), 0.0, 30.0)).timeout
			_reply(_state())
		"_hang":
			# Test hook: deliberately never replies, so the watchdog is exercised
			# rather than assumed. Without it a latched bridge is invisible until a
			# client sits blocked on recv for its full socket timeout.
			await get_tree().create_timer(BUSY_TIMEOUT + 15.0).timeout
		"reach":
			_reply(_reach_of(str(cmd.get("id", ""))))
		"slay":
			# Fights the boss (or, absent one, the nearest enemy) instead of
			# walking a real playtest through a swing-by-swing melee. Bounded
			# at MAX_SWINGS so a tuning mistake that makes something
			# unkillable is a fast, loud failure rather than tripping
			# BUSY_TIMEOUT with no clue why.
			await _slay()
		"screenshot":
			_ui_shot = bool(cmd.get("ui", false))
			await _screenshot(str(cmd.get("name", "shot.png")))
		"quit":
			_reply({"ok": true})
			await get_tree().create_timer(0.1).timeout
			get_tree().quit()
		_:
			_reply({"ok": false, "error": "unknown_cmd"})


func _enemies() -> Array:
	var out := []
	var p := _player()
	for e in get_tree().get_nodes_in_group("enemy"):
		var n := e as Node2D
		if n == null or not is_instance_valid(n):
			continue
		out.append({
			"hp": n.hp if "hp" in n else -1,
			"boss": n.is_in_group("boss"),
			"tile": [_tile_of(n.position).x, _tile_of(n.position).y],
			"dist": -1.0 if p == null else snappedf(
				p.global_position.distance_to(n.global_position), 0.1),
		})
	return out


func _boss_or_nearest_enemy() -> Slime:
	var boss := get_tree().get_first_node_in_group("boss")
	if boss != null and is_instance_valid(boss):
		return boss as Slime
	var p := _player()
	var best: Slime = null
	var best_d := INF
	for e in get_tree().get_nodes_in_group("enemy"):
		var n := e as Slime
		if n == null or not is_instance_valid(n):
			continue
		var d := INF if p == null else p.global_position.distance_to(n.global_position)
		if d < best_d:
			best_d = d
			best = n
	return best


## Stands the player adjacent to the boss (or, absent one, the nearest enemy)
## and swings at it until it dies, teleporting to keep up with knockback —
## this is a combat *outcome* check for the showdown leg of --auto, not a
## test of the melee itself, so there is no reason to walk it in.
func _slay() -> void:
	var p := _player()
	if p == null:
		_reply({"ok": false, "error": "no_player"})
		return
	var target := _boss_or_nearest_enemy()
	var swings := 0
	var max_swings := 40
	while target != null and is_instance_valid(target) and target.hp > 0 \
			and swings < max_swings:
		var dir := p.global_position.direction_to(target.global_position)
		if dir == Vector2.ZERO:
			dir = Vector2.DOWN
		p.global_position = target.global_position - dir * (TILE * 0.6)
		p.facing = dir
		await get_tree().physics_frame
		p.swing()
		swings += 1
		for i in range(3):
			await get_tree().physics_frame
	_reply({"ok": true, "swings": swings, "phase": GameState.phase, "enemies": _enemies()})


func _state() -> Dictionary:
	var p := _player()
	var b := _builder()
	var npcs := []
	if b != null:
		for n in get_tree().get_nodes_in_group("npc"):
			var npc := n as Npc
			npcs.append({
				"id": npc.npc_id, "name": npc.display_name,
				"tile": [_tile_of(npc.position).x, _tile_of(npc.position).y],
				"dist": 0.0 if p == null else snappedf(
					p.position.distance_to(npc.position), 0.1),
			})
	var interactables := []
	for it in GameState.world.get("interactables", []):
		var fp := Catalog.footprint(it["asset"])
		interactables.append({"id": it["id"], "asset": it["asset"],
							  "tile": [it["x"], it["y"]], "tiles": [fp.x, fp.y],
							  "beat": it["beat"]})
	return {
		"ok": true,
		"title": GameState.world.get("title", ""),
		"player_tile": [] if p == null else [_tile_of(p.position).x, _tile_of(p.position).y],
		"focus": _describe_focus(),
		"dialogue_open": DialogueUI.is_open(),
		"revealed_beats": GameState.revealed_beats,
		"total_beats": GameState.world.get("beats", []).size(),
		"phase": GameState.phase,
		# Whether the mystery is actually finishable is the one thing
		# validate_world() cannot see, so a playtest has to be able to ask.
		"solved": GameState.solved(),
		"inside": Interiors.inside(),
		"journal_open": Journal.is_open(),
		"hp": -1 if p == null else p.hp,
		"enemies": _enemies(),
		"inventory": GameState.inventory,
		"npcs": npcs,
		"interactables": interactables,
	}


## Pathfinding over the real colliders. A straight-line walk made the playtest
## report "blocked" for anything behind a house, which measures the walker
## rather than the village — the whole point of this harness is to find out
## what the PLAYER can reach.
func _build_grid() -> AStarGrid2D:
	var m: Dictionary = GameState.world["map"]
	var size := Vector2i(int(m["width"]), int(m["height"]))
	var grid := AStarGrid2D.new()
	grid.region = Rect2i(Vector2i.ZERO, size)
	grid.cell_size = Vector2(TILE, TILE)
	grid.offset = Vector2(TILE, TILE) * 0.5
	grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_NEVER
	grid.update()

	# Probe the physics world instead of re-deriving the backend's blocked-cell
	# maths in GDScript: the colliders are the ground truth, and duplicating
	# that logic is exactly how the two would drift apart.
	var space := get_viewport().world_2d.direct_space_state
	var shape := CircleShape2D.new()
	shape.radius = 5.0
	var q := PhysicsShapeQueryParameters2D.new()
	q.shape = shape
	q.collision_mask = 1          # environment only; npcs and enemies move
	q.collide_with_areas = false
	for y in size.y:
		for x in size.x:
			q.transform = Transform2D(0.0, _centre_of(x, y))
			if not space.intersect_shape(q, 1).is_empty():
				grid.set_point_solid(Vector2i(x, y), true)
	return grid


## Forces the next _grid() call to rebuild. Entering or leaving a building
## replaces the walkable space entirely, and the cache key is the world title,
## which does not change when you step through a door.
func _invalidate_grid() -> void:
	_cached_grid = null
	_cached_for = ""


func _grid() -> AStarGrid2D:
	if _cached_grid == null or _cached_for != GameState.world.get("title", ""):
		_cached_grid = _build_grid()
		_cached_for = GameState.world.get("title", "")
	return _cached_grid


## Nearest walkable cell to `t`, so "go to the sign" means "go beside the sign".
func _nearest_open(grid: AStarGrid2D, t: Vector2i) -> Vector2i:
	if grid.is_in_boundsv(t) and not grid.is_point_solid(t):
		return t
	for r in range(1, 8):
		for dx in range(-r, r + 1):
			for dy in range(-r, r + 1):
				if maxi(absi(dx), absi(dy)) != r:
					continue
				var c := t + Vector2i(dx, dy)
				if grid.is_in_boundsv(c) and not grid.is_point_solid(c):
					return c
	return t


## Returns "" on success, otherwise an error code.
func _walk_to(tx: int, ty: int) -> String:
	var p := _player()
	if p == null:
		return "no_player"
	# A paused tree means the player's _physics_process never runs, so they
	# simply do not move and every goto reports "blocked". The journal and the
	# ending card both pause; the ending card in particular latches, because a
	# scripted run has no reason to dismiss it. Diagnosing that from "blocked"
	# cost an hour, so say it plainly.
	if get_tree().paused:
		return "game_paused"
	var grid := _grid()
	var start := _nearest_open(grid, _tile_of(p.position))
	var goal := _nearest_open(grid, Vector2i(tx, ty))
	if not grid.is_in_boundsv(start) or not grid.is_in_boundsv(goal):
		return "out_of_bounds"
	var path := grid.get_point_path(start, goal)
	if path.is_empty():
		return "no_path"

	var deadline := Time.get_ticks_msec() + int(GOTO_TIMEOUT * 1000.0)
	# Giving up on a waypoint costs 1.2s, and a long path has dozens of them —
	# a player wedged against geometry burned 1.2s on every remaining waypoint
	# in turn, blowing GOTO_TIMEOUT and then the bridge's own BUSY_TIMEOUT. One
	# skipped corner is normal; several in a row means genuinely stuck, so stop.
	var stuck_run := 0
	for point in path:
		var stuck := 0.0
		var last := p.position
		while p.position.distance_to(point) > ARRIVE_DIST:
			if Time.get_ticks_msec() > deadline:
				p.agent_input = Vector2.ZERO
				return "goto_timeout"
			p.agent_input = p.position.direction_to(point)
			await get_tree().physics_frame
			if p.position.distance_to(last) < 0.35:
				stuck += get_physics_process_delta_time()
				if stuck > 1.2:
					stuck_run += 1
					break      # nudge past a corner; the next waypoint may clear it
			else:
				stuck = 0.0
			last = p.position
		if stuck > 1.2:
			if stuck_run >= 3:
				p.agent_input = Vector2.ZERO
				return "stuck"
		else:
			stuck_run = 0
	p.agent_input = Vector2.ZERO
	await get_tree().physics_frame
	if p.position.distance_to(_centre_of(goal.x, goal.y)) > TILE * 2.0:
		return "blocked"
	return ""


func _goto(tx: int, ty: int) -> void:
	var err := await _walk_to(tx, ty)
	var out := _state()
	if err != "":
		out["ok"] = false
		out["error"] = err
	_reply(out)


## Walkable cells touching `tile`, nearest to the player first. Capped, because
## each candidate costs a full walk if it does not pan out.
## Somewhere the player can stand and be in reach of `tile`, best first.
##
## Every candidate is checked for an actual A* path from where the player is
## now, because the expensive failure is walking thirty seconds towards a tile
## on the far side of a wall. Unreachable candidates are dropped for free here
## instead of costing GOTO_TIMEOUT each.
##
## The NPC's OWN tile leads the list: the player collides with the environment
## only (mask 1) and villagers sit on layer 8, so standing on top of someone is
## both legal and the surest way to be in reach of them. Ring 2 is included
## because a villager tucked into a nook can have every immediate neighbour
## walled off, which is what made this fail on a different NPC most runs.
func _stand_tiles_near(tile: Vector2i, limit: int = 8) -> Array[Vector2i]:
	var grid := _grid()
	var p := _player()
	if p == null:
		return []
	var here := p.position
	var start := _nearest_open(grid, _tile_of(here))

	var cands: Array[Vector2i] = []
	for r in range(0, 3):
		var ring: Array[Vector2i] = []
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if maxi(absi(dx), absi(dy)) != r:
					continue
				var c := tile + Vector2i(dx, dy)
				if grid.is_in_boundsv(c) and not grid.is_point_solid(c) \
						and not grid.get_point_path(start, c).is_empty():
					ring.append(c)
		# Within a ring, nearest to the player: least walking, and it keeps the
		# approach on the side they came from.
		ring.sort_custom(func(a, b):
			return here.distance_squared_to(_centre_of(a.x, a.y)) \
				< here.distance_squared_to(_centre_of(b.x, b.y)))
		cands.append_array(ring)
		if cands.size() >= limit:
			break
	return cands.slice(0, limit)


func _enter(building_id: String) -> void:
	var p := _player()
	if p == null:
		_reply({"ok": false, "error": "no_player"})
		return
	if Interiors.inside():
		_reply({"ok": false, "error": "already_inside"})
		return
	var b := _builder()
	if b == null:
		_reply({"ok": false, "error": "no_world"})
		return
	var host: Node2D = b.entities.get(building_id) as Node2D
	if host == null:
		_reply({"ok": false, "error": "no_such_building"})
		return
	var door := host.get_node_or_null("Interact") as Interactable
	if door == null or door.enters == "":
		_reply({"ok": false, "error": "not_enterable"})
		return

	var tile := _tile_of(host.position)
	var werr := "not_in_reach_after_walking"
	var give_up_at := Time.get_ticks_msec() + int(APPROACH_BUDGET * 1000.0)
	for stand in _stand_tiles_near(tile):
		if Time.get_ticks_msec() > give_up_at:
			werr = "approach_budget_spent"
			break
		await _walk_to(stand.x, stand.y)
		await get_tree().physics_frame
		if p.focus == door:
			werr = ""
			break
	if werr != "":
		_reply({"ok": false, "error": werr, "door_tile": [tile.x, tile.y]})
		return

	p.use_focus()
	await get_tree().physics_frame
	_invalidate_grid()
	var out := _state()
	out["entered"] = building_id
	_reply(out)


func _talk(npc_id: String) -> void:
	var target: Npc = null
	for n in get_tree().get_nodes_in_group("npc"):
		if (n as Npc).npc_id == npc_id:
			target = n as Npc
			break
	if target == null:
		_reply({"ok": false, "error": "no_such_npc"})
		return
	# Walk beside them, not onto them — they are solid. Villagers with
	# movement="wander" drift while you are crossing the village, so re-read
	# their position and close the gap once more before giving up.
	var p := _player()
	if p == null:
		_reply({"ok": false, "error": "no_player"})
		return

	# Hold them still first. A villager with movement="wander" drifts while the
	# player crosses the village, so the approach chases a moving target and
	# intermittently fails — which made this a flaky gate rather than a real
	# one. attend() is what happens when someone notices you coming anyway.
	target.attend(p.global_position, 30.0)

	# Try the NPC's actual open neighbours, nearest first, rather than assuming
	# "the tile below". Villagers stand against walls, so that assumed cell is
	# often inside a building; _nearest_open then silently relocates the goal to
	# some other open cell that can be a wall away from them, and the approach
	# "succeeds" three tiles short. That produced a gate that failed on a
	# different NPC almost every run.
	var tile := _tile_of(target.position)
	var werr := "not_in_reach_after_walking"
	# Bound the WHOLE approach, not each attempt. Four candidates that each run
	# out the 30s GOTO_TIMEOUT is two minutes, so the bridge's 40s watchdog
	# answered first and the command reported `command_timeout` — true, but it
	# named the symptom rather than "I couldn't get to this villager".
	var give_up_at := Time.get_ticks_msec() + int(APPROACH_BUDGET * 1000.0)
	var tried := 0
	for stand in _stand_tiles_near(tile):
		if Time.get_ticks_msec() > give_up_at:
			werr = "approach_budget_spent"
			break
		tried += 1
		await _walk_to(stand.x, stand.y)
		p = _player()
		if p != null and p.position.distance_to(target.position) <= TILE * 2.0:
			werr = ""
			break
	if werr != "":
		_reply({"ok": false, "error": werr, "npc_tile": [tile.x, tile.y],
			"stands_tried": tried})
		return

	# Address this NPC directly rather than going through the player's focus:
	# the harness asked for a specific character and should get them.
	_talking_to = target
	_last_line = ""
	target.attend(p.global_position)

	# Handing over what they were waiting for takes precedence over small talk,
	# exactly as it does when the player presses E. Going straight to
	# request_dialogue here meant `talk` could never trigger a gift, so the
	# whole wants_item path looked broken from the harness.
	var gift := target.accept_item()
	target.met = true
	if gift != "":
		DialogueUI.show_thinking(target.display_name)
	else:
		DialogueUI.show_line(target.display_name,
			target.data.get("opener", "") if not target.met else "…")
	LLMClient.request_dialogue(target.npc_id, "", gift)
	await _await_reply()
	var out := _state()
	out["line"] = _last_line if _last_line != "" else target.data.get("opener", "")
	out["outcome"] = "talk"
	out["speaker"] = target.display_name
	_reply(out)


func _say(text: String) -> void:
	var p := _player()
	var npc := _talking_to
	if npc == null and p != null and p.focus is Npc:
		npc = p.focus as Npc
	if p == null or npc == null or not is_instance_valid(npc):
		_reply({"ok": false, "error": "not_talking_to_anyone"})
		return
	npc.attend(p.global_position)
	_last_line = ""
	LLMClient.request_dialogue(npc.npc_id, text)
	await _await_reply()
	if _last_line != "":
		DialogueUI.show_line(npc.display_name, _last_line)
	var out := _state()
	out["line"] = _last_line
	out["speaker"] = npc.display_name
	_reply(out)


func _await_reply() -> void:
	if not LLMClient.backend_available:
		return   # offline: the opener is already on screen, nothing will arrive
	var deadline := Time.get_ticks_msec() + int(REPLY_TIMEOUT * 1000.0)
	while _last_line == "" and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame


## Reports an interactable's trigger volume in world pixels. Focus-based checks
## are non-deterministic here (villagers wander into range), so the regression
## test asserts on this geometry instead — it is what the fix actually changed.
func _reach_of(id: String) -> Dictionary:
	var b := _builder()
	if b == null or not b.entities.has(id):
		return {"ok": false, "error": "no_such_entity"}
	var host := b.entities[id] as Node2D
	var it: Interactable = null
	for child in host.get_children():
		if child is Interactable:
			it = child as Interactable
			break
	if it == null:
		return {"ok": false, "error": "not_interactable"}
	var shape: CollisionShape2D = null
	for child in it.get_children():
		if child is CollisionShape2D:
			shape = child as CollisionShape2D
			break
	if shape == null or not (shape.shape is RectangleShape2D):
		return {"ok": false, "error": "no_rect_shape"}
	var size: Vector2 = (shape.shape as RectangleShape2D).size
	var centre: Vector2 = shape.global_position
	return {
		"ok": true, "id": id,
		"size_px": [size.x, size.y],
		"size_tiles": [size.x / TILE, size.y / TILE],
		"centre_px": [centre.x, centre.y],
		"host_px": [host.global_position.x, host.global_position.y],
		# Host origin is the prop's bottom-centre, so this is how far the box
		# rises above the base and how far it drops below it.
		"top_above_base": host.global_position.y - (centre.y - size.y * 0.5),
		"bottom_below_base": (centre.y + size.y * 0.5) - host.global_position.y,
	}


func _screenshot(name: String) -> void:
	var dir := "res://test_output/"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var path := ProjectSettings.globalize_path(dir + name.get_file())
	var main := _main()
	# Prefer the whole-map capture; fall back to the visible viewport if the
	# scene doesn't provide one (or we're mid-rebuild).
	#
	# "ui" forces the viewport path: the map capture renders the world into its
	# own SubViewport, which by construction contains no CanvasLayer, so it can
	# never show the journal, a dialogue panel or the prompt.
	if main != null and main.has_method("capture") and not _ui_shot:
		var err = await main.capture(path)
		_reply({"ok": err == OK, "path": path})
		return
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	_reply({"ok": img.save_png(path) == OK, "path": path})
