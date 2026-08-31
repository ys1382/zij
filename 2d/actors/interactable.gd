class_name Interactable
extends Area2D
# One generic interaction component, attached to any prop the world JSON listed
# under "interactables". There is deliberately no per-prop scene: the verb comes
# from the asset catalog (which derives it from the semantics table in
# tools/tsx_convert.py) and the flavour text and story beat come from the JSON,
# so a new interactive prop needs a catalog entry and nothing else.
#
# Sits on physics layer 3, which the player's InteractArea masks.

## Verbs the world schema may ask for. Anything else falls back to "look".
const PROMPTS := {
	"talk": "Talk", "open": "Open", "read": "Read", "sit": "Sit", "look": "Look",
	"enter": "Go inside", "leave": "Leave",
}
## Upper bound on the reach box, in tiles. Big enough to step up to a house
## door, small enough that a building doesn't claim the square in front of it.
const MAX_REACH_TILES := Vector2i(4, 3)

signal used(it: Interactable)

var data: Dictionary = {}
var verb: String = "look"
var text: String = ""
var beat: String = ""
var used_once: bool = false
## Item ids. `gives` is handed over the first time this is used; `needs` gates
## it entirely until the player is carrying that item.
var gives: String = ""
var needs: String = ""
var locked_text: String = ""
## Non-empty on a building's door: the id of the object whose inside this opens.
var enters: String = ""


## Returns null if the entry names an asset the catalog doesn't have. Callers
## must handle that: Catalog.object() asserts, and a Godot assert only LOGS and
## carries on, so relying on it here produced a half-built Interactable with no
## verb and a cascade of follow-on errors.
static func attach(host: Node2D, entry: Dictionary) -> Interactable:
	var asset: String = entry.get("asset", "")
	if not Catalog.has_object(asset):
		push_warning("interactable %s names unknown asset '%s'; skipped"
			% [entry.get("id", "?"), asset])
		return null

	var it := Interactable.new()
	it.name = "Interact"
	it.data = entry
	it.text = entry.get("text", "")
	it.beat = entry.get("beat", "")
	it.gives = entry.get("gives_item", "")
	it.needs = entry.get("needs_item", "")
	it.locked_text = entry.get("locked_text", "")
	it.enters = entry.get("enters", "")
	it.verb = Catalog.object(asset)["verb"]
	if not PROMPTS.has(it.verb):
		it.verb = "look"

	it.collision_layer = 4    # interactable
	it.collision_mask = 0     # detected by the player, never detects
	it.monitoring = false
	it.monitorable = true

	# A reach box covering the prop plus a tile of slack — but CAPPED, and
	# anchored to the prop's foot rather than centred on its body.
	#
	# Sizing it from the raw footprint gave a door attached to an 8x8 house a
	# 9x9-tile trigger: you could open the theatre while standing on its roof,
	# and the box was large enough to swallow a villager in front of the door,
	# so pressing E greeted nobody and opened the building instead. You reach
	# anything — a door, a well, a chest — by standing at its base, so that is
	# where the trigger belongs.
	var fp := Catalog.footprint(asset)
	var tiles := Vector2i(mini(fp.x + 1, MAX_REACH_TILES.x),
		mini(fp.y + 1, MAX_REACH_TILES.y))
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(tiles) * Catalog.TILE
	shape.shape = rect
	# Host origin is the prop's bottom-centre, so drop the box half a tile below
	# it and let it rise: it then covers the prop's base and the ground in front.
	shape.position = Vector2(0, Catalog.TILE * 0.5 - rect.size.y * 0.5)
	it.add_child(shape)

	host.add_child(it)
	return it


func prompt() -> String:
	if locked():
		return "Try"
	if enters != "":
		return PROMPTS["enter"]
	if gives != "" and not GameState.has_item(gives):
		return "Take"
	return PROMPTS.get(verb, "Look")


func locked() -> bool:
	return needs != "" and not GameState.has_item(needs)


## What using this actually says. Returns the line to show, having applied every
## side effect — the beat and the pickup. A locked interactable does neither, so
## it can be tried as often as the player likes.
func use() -> String:
	if locked():
		return locked_text if locked_text != "" \
			else "You can't, not without %s." % GameState.item_name(needs)
	used_once = true
	# Going inside is the whole response — the flavour text, if any, is shown
	# once the player is standing in the room rather than over the doorstep.
	if enters != "":
		if beat != "":
			GameState.reveal(beat)
		used.emit(self)
		Interiors.enter(enters, text)
		return ""
	var line := text
	if gives != "" and GameState.take_item(gives):
		var got: Dictionary = GameState.item(gives)
		var blurb := str(got.get("text", ""))
		# The item's own line comes second: the player is looking at the chest
		# before they are looking at what was in it.
		line = "%s\n\n%s" % [text, blurb] if text != "" and blurb != "" \
			else (blurb if blurb != "" else text)
	if beat != "":
		GameState.reveal(beat)
	used.emit(self)
	return line
