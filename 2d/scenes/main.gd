extends Node2D
# Entry point. Gets a world — freshly invented by the backend, or read from a
# JSON file — hands it to the WorldBuilder, and plays it.
#
# Pressing Play in the editor takes the zero-argument path: start the backend if
# it isn't up, generate a world, review it, play. Every flag below overrides one
# step of that.
#
#   godot --path .                                        # generate and play
#   godot --path . -- --seed "a well gone silent"         # steer the story
#   godot --path . -- --world backend/fallback_world.json # skip generation
#   godot --path . -- --offline                           # no backend at all
#   godot --path . -- --no-critique                       # skip the VLM review
#   godot --path . -- --world <f> --shot out.png          # render it and exit
#
# The --shot path is also the capture the VLM repair loop uses in Phase 6. Note
# it needs a real window: --headless uses a dummy renderer and SubViewport
# textures come back empty.

const FALLBACK := "res://backend/fallback_world.json"
## The repair loop is bounded so a model that keeps finding things to fix can
## never keep the player on the loading screen.
##
## One pass, not two. Measured, a pass costs about 4s (render + vision call +
## rebuild) against ~65s for generation, so this is a minor saving — the long
## loads were caused by failed attempts triggering the 65s retry, not by this.
## One pass is kept because the second reliably returned only cosmetic nits.
const MAX_REPAIR_PASSES := 1
## How long to wait for the backend on boot before giving up and playing the
## fallback village. Generous because LLMClient may have only just autostarted
## it, and the very first run of backend/run.sh builds a venv and installs
## dependencies.
const BACKEND_BOOT_S := 90.0

var builder: WorldBuilder

## Where this session's world came from. "backend" means the server already has
## this exact world and must not be told about it again.
var _source: String = "file"
## True when the player is getting the hand-authored village because generation
## failed, rather than because they asked for it.
var _fell_back: bool = false


func _ready() -> void:
	builder = WorldBuilder.new()
	builder.name = "World"
	add_child(builder)
	WorldManager.world_root = builder

	# A model reply lands while an ellipsis is on screen; swap it in.
	LLMClient.dialogue_received.connect(_on_dialogue)

	# --shot renders and exits with nobody watching, so it skips the screen.
	var shot := _arg_value("--shot")
	var screen: LoadingScreen = null
	if shot == "":
		screen = LoadingScreen.new()
		add_child(screen)
		await screen.status("zij2d", "waking the village")

	var world := await _obtain_world(screen)
	if world.is_empty():
		push_error("no world to build")
		get_tree().quit(1)
		return

	GameState.set_world(world)
	if screen != null:
		await screen.status(world.get("title", "..."), "building the village")
	builder.build(world)
	print("built '%s' [%s] — %d objects, %d interactables, %d npcs, %d enemies"
		% [world["title"], _source, world["objects"].size(),
		   world["interactables"].size(), world["npcs"].size(),
		   world["enemies"].size()])

	# Dialogue is answered against the backend's copy of the world, so it has to
	# be told which one we are playing — unless it generated this one itself, in
	# which case pushing it back would only reset the session it just set up.
	if _source != "backend":
		await _sync_world_to_backend()

	if shot != "":
		await _capture_and_quit(shot)
		return
	if not _has_flag("--no-critique"):
		await _repair_loop(screen)
	screen.queue_free()

	# For scripted runs: render the repaired world and exit, so the whole
	# generate -> build -> review -> rebuild path is testable without a human.
	var after := _arg_value("--shot-after-repair")
	if after != "":
		await capture(after)
		get_tree().quit()
		return

	# The premise, once, before anything else. A player dropped straight into the
	# village has no idea what the problem is. Scripted runs skip it: the bridge
	# drives the player directly and the card would eat its first interact.
	if not _has_flag("--agent-bridge"):
		Journal.show_opening()


# --- getting a world ---------------------------------------------------------

## Order of preference: a file named on the command line, then a fresh
## generation, then the hand-authored fallback village. Every failure falls
## through rather than aborting — there is always something playable at the end.
func _obtain_world(screen: LoadingScreen) -> Dictionary:
	var path := _arg_value("--world")
	if path != "":
		return _load_world(path)

	if not GameState.offline_mode:
		if screen != null:
			await screen.status("zij2d", "starting the storyteller")
		if await _await_backend(BACKEND_BOOT_S):
			if screen != null:
				# The backend pre-generates the next world in the background, so
				# most launches return immediately. Only say "this takes a
				# minute" when it actually will.
				await screen.status("zij2d",
					"waking the village" if LLMClient.world_is_warm
					else "inventing a story, then a village to put it in\n"
						+ "(two model calls, usually about a minute)")
			var reply := await LLMClient.request_world(_arg_value("--seed"))
			var w: Dictionary = reply.get("world", {})
			if not w.is_empty():
				# The server holds this world either way; the reported source
				# says whether the model or the server's own fallback made it.
				var src := str(reply.get("source", "?"))
				print("generated '%s' (source: %s)" % [w.get("title", "?"), src])
				_source = "backend"
				# "fallback" here means both generation attempts failed and the
				# server handed back the hand-authored village. Playing The
				# Quiet Bell every single session and being told nothing is
				# indistinguishable from the game having no generator at all —
				# say it out loud.
				if src == "fallback":
					_fell_back = true
					push_warning("the storyteller failed twice; "
						+ "this is the standard village, not a new one")
					if screen != null:
						await screen.status(str(w.get("title", "...")),
							"the storyteller is having an off day — "
							+ "playing the standard village")
						await _hold(2.5)
				return w
			push_warning("generation failed; playing the fallback village")
		else:
			push_warning("backend never came up; playing the fallback village")

	_fell_back = true
	return _load_world(FALLBACK)


## Lets a message sit on the loading screen long enough to be read.
func _hold(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


# --- the VLM repair loop ----------------------------------------------------


## Screenshot the built world, ask the backend's vision pass what looks wrong,
## rebuild if it returns a patch. The backend re-validates every patch and
## rejects it wholesale if it fails, so each pass can only leave the world at
## least as valid as it found it.
func _repair_loop(screen: LoadingScreen) -> void:
	if GameState.offline_mode:
		return
	# The health check is fired on boot but answers a frame or two later, so
	# without this the loop reads backend_available == false and silently skips
	# every time.
	if not await _await_backend(8.0):
		print("layout review: skipped, no backend")
		return
	for pass_i in MAX_REPAIR_PASSES:
		await screen.status(GameState.world.get("title", "..."),
			"checking the layout (%d/%d)" % [pass_i + 1, MAX_REPAIR_PASSES])
		var img := await capture_image()
		if img == null:
			return
		var reply := await LLMClient.request_critique(
			img.save_png_to_buffer(), GameState.world)
		if reply.is_empty():
			return
		if not bool(reply.get("applied", false)):
			print("layout review: %s" % reply.get("reason", "no change"))
			return
		var patched: Dictionary = reply.get("world", {})
		if patched.is_empty():
			return
		var ops: Array = reply.get("ops", [])
		print("layout review: applying %d op(s)" % ops.size())
		await screen.status(GameState.world.get("title", "..."),
			"tidying up (%d change%s)" % [ops.size(), "" if ops.size() == 1 else "s"])
		GameState.set_world(patched)
		builder.build(patched)


func _sync_world_to_backend() -> void:
	if GameState.offline_mode:
		return
	if await _await_backend(8.0):
		LLMClient.push_world(GameState.world)


## Waits for the backend, polling faster than LLMClient's own retry timer.
## Leaving it to that timer meant a backend that autostarted in two seconds
## still cost the player the full HEALTH_RETRY_S on the loading screen.
## check_health() no-ops while a check is in flight, so this can't pile up.
func _await_backend(timeout_s: float) -> bool:
	if LLMClient.backend_available:
		return true
	var deadline := Time.get_ticks_msec() + int(timeout_s * 1000.0)
	var next_poll := 0
	while not LLMClient.backend_available and Time.get_ticks_msec() < deadline:
		if Time.get_ticks_msec() >= next_poll:
			next_poll = Time.get_ticks_msec() + 1000
			LLMClient.check_health()
		await get_tree().process_frame
	return LLMClient.backend_available


func _on_dialogue(npc_id: String, line: String, _meta: Dictionary) -> void:
	if not DialogueUI.is_open():
		return
	var npc := builder.entities.get(npc_id) as Npc
	if npc == null:
		return
	# An empty line means the request failed. The panel is showing an ellipsis,
	# so put the character's own opener there rather than leaving it hanging.
	DialogueUI.show_line(npc.display_name,
		line if line != "" else str(npc.data.get("opener", "...")))


func _load_world(path: String) -> Dictionary:
	# res:// as-is, an absolute path as-is (worlds generated to /tmp), anything
	# else treated as relative to the project root.
	var p := path
	if p != "" and not p.begins_with("res://") and not p.begins_with("/"):
		p = "res://" + p.trim_prefix("./")
	if p == "":
		p = FALLBACK
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		push_error("cannot open world %s" % p)
		return {}
	var parsed = JSON.parse_string(f.get_as_text())
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}


# --- whole-map capture (also the Phase 6 VLM path) --------------------------

func _capture_and_quit(path: String) -> void:
	await capture(path)
	get_tree().quit()


func capture(path: String) -> Error:
	var img := await capture_image()
	if img == null:
		return FAILED
	var err := img.save_png(path)
	print("capture %s -> %s (%dx%d)"
		% ["ok" if err == OK else "FAILED", path, img.get_width(), img.get_height()])
	return err


## Renders the entire map, regardless of window size, by moving the world into a
## SubViewport sized to its full pixel extent for one frame. Needs a real
## window: --headless uses a dummy renderer and the texture comes back empty.
func capture_image() -> Image:
	var px := builder.pixel_size()
	var sub := SubViewport.new()
	sub.size = px
	sub.transparent_bg = false
	sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(sub)

	var idx := builder.get_index()
	builder.reparent(sub, false)

	var cam := Camera2D.new()
	cam.anchor_mode = Camera2D.ANCHOR_MODE_FIXED_TOP_LEFT
	sub.add_child(cam)
	cam.make_current()  # beat the player's follow camera, now in this viewport

	# Two frames: one to apply the re-parent and camera, one to draw.
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := sub.get_texture().get_image()

	builder.reparent(self, false)
	move_child(builder, idx)
	sub.queue_free()
	return img


func _arg_value(flag: String) -> String:
	var args := OS.get_cmdline_user_args()
	var i := args.find(flag)
	return args[i + 1] if i >= 0 and i + 1 < args.size() else ""


func _has_flag(flag: String) -> bool:
	return OS.get_cmdline_user_args().has(flag)
