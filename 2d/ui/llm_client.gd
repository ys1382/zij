extends Node
# Autoload. The ONLY thing the Godot client talks to for dialogue is the local
# backend proxy on 127.0.0.1 — the Anthropic key lives server-side, never here.
#
# Ported from zij3d/ui/llm_client.gd. Two HTTPRequest nodes so a health check
# can never collide with an in-flight dialogue request, a retry timer so
# starting the backend mid-game wakes the village up, and a one-shot autostart
# of backend/run.sh if nothing is listening.

const BACKEND := "http://127.0.0.1:8000"
const HEALTH_RETRY_S := 10.0

signal dialogue_received(npc_id: String, line: String, meta: Dictionary)
signal backend_became_available()

var backend_available: bool = false
## True when the backend already has a world pre-generated, so /session/new will
## answer straight away. Read from /health; only used to word the loading screen
## honestly rather than promising a minute's wait that isn't coming.
var world_is_warm: bool = false

var _http: HTTPRequest       # dialogue
var _http_meta: HTTPRequest  # health
var _pending_npc: String = ""
var _health_inflight := false
var _timer: Timer
var _autostart_attempted := false


func _ready() -> void:
	# HTTPRequest polls in _process, so an in-flight dialogue call would stall
	# for as long as the player left the journal open.
	process_mode = Node.PROCESS_MODE_ALWAYS

	_http = HTTPRequest.new()
	_http.timeout = 20.0
	add_child(_http)
	_http.request_completed.connect(_on_dialogue_done)

	_http_meta = HTTPRequest.new()
	_http_meta.timeout = 3.0
	add_child(_http_meta)
	_http_meta.request_completed.connect(_on_health_done)

	_timer = Timer.new()
	_timer.wait_time = HEALTH_RETRY_S
	add_child(_timer)
	_timer.timeout.connect(check_health)

	if not GameState.offline_mode:
		call_deferred("check_health")
		_timer.start()


## Public so the boot path can poll faster than HEALTH_RETRY_S while it holds
## the loading screen — otherwise a backend that autostarts in two seconds still
## costs the player a ten-second wait. Cheap to over-call: it no-ops while a
## check is in flight.
func check_health() -> void:
	if GameState.offline_mode or _health_inflight:
		return
	_health_inflight = true
	if _http_meta.request(BACKEND + "/health") != OK:
		_health_inflight = false
		_on_backend_down()


func _on_health_done(result: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
	_health_inflight = false
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		_on_backend_down()
		return
	var data = JSON.parse_string(body.get_string_from_utf8())
	if typeof(data) == TYPE_DICTIONARY:
		world_is_warm = bool(data.get("warm", false))
	if not backend_available:
		backend_available = true
		var title := "?"
		if typeof(data) == TYPE_DICTIONARY:
			title = str(data.get("title", "?"))
		print("LLMClient: backend up (world: %s)" % title)
		backend_became_available.emit()
	_timer.stop()


func _on_backend_down() -> void:
	backend_available = false
	if _timer.is_stopped():
		_timer.start()
	if not _autostart_attempted:
		_autostart_attempted = true
		_autostart()


func _autostart() -> void:
	var script_path := ProjectSettings.globalize_path("res://backend/run.sh")
	if not FileAccess.file_exists(script_path):
		print("LLMClient: backend/run.sh not found; the village runs on canned lines")
		return
	if OS.create_process("/bin/bash", [script_path]) > 0:
		print("LLMClient: starting backend — the village wakes shortly")


## Asks the backend to invent a whole new world: two model calls, validation,
## repair, and a retry before it gives up. Slow by nature, so it is awaited the
## same way the critique call is — the caller is holding a loading screen and
## has nothing else to do.
##
## Returns {} on any failure rather than raising. A world that doesn't arrive
## must degrade to the fallback village, never to a blank screen.
func request_world(seed: String = "", timeout_s: float = 240.0) -> Dictionary:
	if GameState.offline_mode or not backend_available:
		return {}
	var http := HTTPRequest.new()
	http.timeout = timeout_s
	add_child(http)
	if http.request(BACKEND + "/session/new", ["Content-Type: application/json"],
			HTTPClient.METHOD_POST, JSON.stringify({"seed": seed})) != OK:
		http.queue_free()
		return {}
	var res: Array = await http.request_completed
	http.queue_free()
	if res[0] != HTTPRequest.RESULT_SUCCESS or res[1] != 200:
		push_warning("generation failed (result %d, http %d)" % [res[0], res[1]])
		return {}
	var data = JSON.parse_string((res[3] as PackedByteArray).get_string_from_utf8())
	return data if typeof(data) == TYPE_DICTIONARY else {}


## Tells the backend the player uncovered a beat on their own — read a notice,
## opened a chest. Fire and forget, and idempotent server-side.
##
## Not optional bookkeeping: the server gates what each NPC is allowed to say on
## its own revealed set, so a beat found in the world and never reported leaves
## every villager who depends on it hinting forever.
func reveal_beat(beat_id: String) -> void:
	if GameState.offline_mode or not backend_available or beat_id == "":
		return
	var http := HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(func(_r, _c, _h, _b): http.queue_free())
	if http.request(BACKEND + "/beat/reveal", ["Content-Type: application/json"],
			HTTPClient.METHOD_POST, JSON.stringify({"beat_id": beat_id})) != OK:
		http.queue_free()


## Tells the backend which world the client is actually playing. Fire and
## forget — dialogue simply stays generic until it lands.
func push_world(world: Dictionary) -> void:
	if GameState.offline_mode or not backend_available:
		return
	var http := HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(func(_r, _c, _h, _b): http.queue_free())
	if http.request(BACKEND + "/world/set", ["Content-Type: application/json"],
			HTTPClient.METHOD_POST, JSON.stringify({"world": world})) != OK:
		http.queue_free()


## Posts a rendered map to the VLM layout review. Awaited rather than
## signal-based: it runs once, on the loading screen, and the caller has nothing
## to do until it returns. Result is the parsed response, or {} on any failure —
## a critique that doesn't come back must never stop the game starting.
func request_critique(png: PackedByteArray, world: Dictionary,
		timeout_s: float = 90.0) -> Dictionary:
	if GameState.offline_mode or not backend_available:
		return {}
	var http := HTTPRequest.new()
	http.timeout = timeout_s
	add_child(http)
	# Send the world being rendered, not just the image: the server must review
	# the same map the screenshot shows.
	var body := JSON.stringify({
		"png_base64": Marshalls.raw_to_base64(png),
		"world": world,
	})
	if http.request(BACKEND + "/world/critique", ["Content-Type: application/json"],
			HTTPClient.METHOD_POST, body) != OK:
		http.queue_free()
		return {}
	var res: Array = await http.request_completed
	http.queue_free()
	if res[0] != HTTPRequest.RESULT_SUCCESS or res[1] != 200:
		push_warning("critique failed (result %d, http %d)" % [res[0], res[1]])
		return {}
	var data = JSON.parse_string((res[3] as PackedByteArray).get_string_from_utf8())
	return data if typeof(data) == TYPE_DICTIONARY else {}


## Fire-and-forget. The caller puts an ellipsis on screen and the real line
## arrives via dialogue_received — or an empty one, if the request failed.
func request_dialogue(npc_id: String, utterance: String, gift: String = "") -> void:
	if GameState.offline_mode or not backend_available:
		return
	_pending_npc = npc_id
	var body := JSON.stringify({"npc_id": npc_id, "player_utterance": utterance,
		"gift": gift})
	if _http.request(BACKEND + "/npc/dialogue", ["Content-Type: application/json"],
			HTTPClient.METHOD_POST, body) != OK:
		_pending_npc = ""


func _on_dialogue_done(result: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		# Backend went away mid-session: degrade quietly and probe for its return.
		backend_available = false
		if _timer.is_stopped():
			_timer.start()
		# Still emit. The UI shows an ellipsis while a reply is in flight, so
		# returning silently here left the villager mid-sentence forever; an
		# empty line is the signal to fall back to their opener.
		dialogue_received.emit(_pending_npc, "", {"failed": true})
		return
	var data = JSON.parse_string(body.get_string_from_utf8())
	if typeof(data) != TYPE_DICTIONARY:
		return
	var meta: Dictionary = data.get("meta", {})
	if meta.has("beat"):
		GameState.reveal(str(meta["beat"]))
	dialogue_received.emit(str(data.get("npc_id", _pending_npc)),
		str(data.get("line", "")), meta)
