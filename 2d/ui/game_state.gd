extends Node
# Autoload. The player's side of the story: which beats they have uncovered,
# what that unlocks, and whether the mystery is solved.
#
# The backend keeps its own copy of this and gates NPC dialogue on it. The two
# must not drift, so reveal() reports upward — see LLMClient.reveal_beat().

signal cast_changed
## Fired once per beat, the first time it is uncovered. Carries the whole beat
## dictionary so the UI can show its description without looking it up.
signal beat_revealed(beat: Dictionary)
## Fired once per session, when the last of ending.condition_beats lands.
## Rival-less worlds only — a world with a rival goes through
## showdown_started/game_won instead. Still emitted at the very end (from
## notify_boss_defeated) for anything that only ever listened to this one.
signal finale_reached(text: String)
## Fired the first time each item is picked up.
signal item_taken(item: Dictionary)
## The rival escalating: a rumor becoming common talk, or minions/the boss
## needing to exist in the live scene. Mechanics only — WorldManager is the
## one thing that should act on these; Journal only toasts the rumors.
signal world_event(evt: Dictionary)
## All condition beats are known and the rival shows itself. `taunt` is its
## first line; Journal puts up the showdown card, and calling begin_showdown()
## once it is dismissed is what actually spawns the boss (see journal.gd for
## why the unpause has to happen first).
signal showdown_started(rival: Dictionary, taunt: String)
## The boss is beaten. `text` is the rival's defeat line plus the ending.
signal game_won(text: String)

var offline_mode: bool = false
var world: Dictionary = {}          # the validated world JSON for this session
var revealed_beats: Array[String] = []
var inventory: Array[String] = []
var cast: Array = []
var title: String = ""

## "explore" -> "showdown_pending" (card up, boss not spawned yet) ->
## "showdown" (boss alive) -> "won". Worlds with no rival skip straight from
## "explore" to "won" via the legacy finale_reached path.
var phase: String = "explore"

var _finale_shown: bool = false
var _acts_fired: int = 0


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	offline_mode = args.has("--offline") or OS.get_environment("ZIJ_OFFLINE") == "1"


## Adopting a world resets the story with it. The VLM repair pass rebuilds the
## scene mid-load, so this must be safe to call more than once.
func set_world(w: Dictionary) -> void:
	world = w
	title = str(w.get("title", ""))
	revealed_beats.clear()
	inventory.clear()
	_finale_shown = false
	_acts_fired = 0
	phase = "explore"


func beat(beat_id: String) -> Dictionary:
	for b in world.get("beats", []):
		if b["id"] == beat_id:
			return b
	return {}


func known(beat_id: String) -> bool:
	return revealed_beats.has(beat_id)


func rival() -> Dictionary:
	return world.get("rival", {})


# --- the bag -----------------------------------------------------------------

func item(item_id: String) -> Dictionary:
	for i in world.get("items", []):
		if i["id"] == item_id:
			return i
	return {}


func has_item(item_id: String) -> bool:
	return item_id != "" and inventory.has(item_id)


## Items are kept once taken — nothing consumes them. Handing the smith their
## tongs shouldn't make the tongs vanish from a child's bag with no explanation,
## and there is no second use for anything, so keeping them costs nothing.
func take_item(item_id: String) -> bool:
	if item_id == "" or inventory.has(item_id):
		return false
	inventory.append(item_id)
	item_taken.emit(item(item_id))
	return true


## The item's display name, falling back to the raw id so a world with a
## dangling reference still says something rather than showing an empty string.
func item_name(item_id: String) -> String:
	var i := item(item_id)
	return str(i.get("name", item_id)) if not i.is_empty() else item_id


## What the player is working toward. The one thing fixed in advance.
func goal() -> String:
	return str(world.get("goal", {}).get("summary", ""))


func goal_detail() -> String:
	return str(world.get("goal", {}).get("detail", ""))


## How much of the goal is accounted for. Beats no longer form a chain, so
## progress is a count of an unordered set rather than a position in a queue.
func progress() -> Array:
	var conds: Array = world.get("ending", {}).get("condition_beats", [])
	var have := 0
	for c in conds:
		if known(str(c)):
			have += 1
	return [have, conds.size()]


func reveal(beat_id: String) -> void:
	if beat_id == "" or revealed_beats.has(beat_id):
		return
	revealed_beats.append(beat_id)
	# Keep the server's story state in step; it decides what NPCs may say.
	LLMClient.reveal_beat(beat_id)
	beat_revealed.emit(beat(beat_id))
	_escalate()
	_check_finale()


## Every ending condition uncovered. Public so a playtest can assert the story
## is actually completable — the thing validate_world() cannot check.
func solved() -> bool:
	var conds: Array = world.get("ending", {}).get("condition_beats", [])
	if conds.is_empty():
		return false
	for c in conds:
		if not known(str(c)):
			return false
	return true


## Same table as worldgen.escalation_act() on the backend — mirrored here
## because the client always learns of a reveal before the server does: an
## interactable's beat only reaches the backend as an echo of what the client
## already knows, and an NPC-revealed beat arrives at the backend FIRST but at
## the client in the very same response. There is no single moment the server
## could fire a client-visible event from without missing half of them, so the
## mechanics live here and the server's matching copy only drives dialogue
## flavor (moods, rumors folded into world_facts).
static func _escalation_act(n: int, t: int) -> int:
	if t <= 0 or n <= 0:
		return 0
	if n >= t:
		return 4
	return clampi((3 * n + t - 1) / t, 1, 3)


## A ratchet: fires every act crossed since the last reveal, in order, never
## just the latest. Acts 1-3 are a rumor turning into common talk plus (at 2
## and 3) a wave of minions; act 4 is the showdown, and is handled by
## _check_finale()/begin_showdown() instead — reaching it here just stops the
## ratchet from re-firing acts 1-3 on every later reveal.
func _escalate() -> void:
	var riv := rival()
	if riv.is_empty():
		return
	var prog := progress()
	var act := _escalation_act(prog[0], prog[1])
	var rumors: Array = riv.get("rumors", [])
	while _acts_fired < act:
		_acts_fired += 1
		if _acts_fired <= 3:
			var i := _acts_fired - 1
			if i < rumors.size():
				world_event.emit({"type": "rumor", "line": str(rumors[i])})
			if _acts_fired == 2 or _acts_fired == 3:
				world_event.emit({"type": "spawn_minions", "count": _acts_fired})


func _check_finale() -> void:
	if _finale_shown or not solved():
		return
	_finale_shown = true
	var riv := rival()
	if riv.is_empty():
		phase = "won"
		finale_reached.emit(str(world.get("ending", {}).get("finale", "")))
		return
	phase = "showdown_pending"
	var taunts: Array = riv.get("taunts", [])
	showdown_started.emit(riv, str(taunts[0]) if not taunts.is_empty() else "")


## Called once the showdown card is dismissed — see journal.gd, which unpauses
## the tree BEFORE calling this, precisely so the boss never spawns into a
## still-paused game (the failure mode that used to latch a scripted playtest).
func begin_showdown() -> void:
	phase = "showdown"
	world_event.emit({"type": "spawn_boss"})


func notify_boss_defeated() -> void:
	phase = "won"
	var riv := rival()
	var ending_text := str(world.get("ending", {}).get("finale", ""))
	var text := str(riv.get("defeat", "")).strip_edges()
	if text != "":
		text += "\n\n"
	text += ending_text
	game_won.emit(text)
	finale_reached.emit(ending_text)  # legacy listeners


func set_cast(new_cast: Array, new_title: String) -> void:
	cast = new_cast
	title = new_title
	cast_changed.emit()
