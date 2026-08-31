class_name Npc
extends CharacterBody2D
# A villager placed by the world JSON. Carries its story data (persona, secret,
# knows_beats) so the dialogue layer can build a system prompt for it without
# looking anything up, and wanders gently if the world asked it to.

const SPEED := 18.0
const WANDER_EVERY := 3.0
const WANDER_RADIUS := 40.0

@onready var _sprite: AnimatedSprite2D = $Sprite

var data: Dictionary = {}
var npc_id: String = ""
var display_name: String = ""
## The canned opener covers the round trip to the model, but it is the same
## sentence every time. After the first hello it stops being a greeting and
## starts being a stuck record, so later visits get an ellipsis instead.
var met: bool = false
## Whether they have already been given what they were waiting for.
var _gave: bool = false

var facing := Vector2.DOWN
var _home := Vector2.ZERO
var _heading := Vector2.ZERO
var _timer := 0.0
var _paused := 0.0


func setup(d: Dictionary) -> void:
	data = d
	npc_id = d["id"]
	display_name = d["name"]


func _ready() -> void:
	add_to_group("npc")
	_sprite.sprite_frames = Sheet.villager_frames()
	_sprite.position = Vector2(0, -16)
	# `tint` keeps a cast of identical villager sprites visually distinguishable.
	# modulate MULTIPLIES, so a saturated tint turns the sprite into a dark
	# silhouette — blend most of the way to white to keep the hue but not lose
	# the art.
	var tint: String = data.get("tint", "")
	if tint.is_valid_html_color():
		_sprite.modulate = Color(tint).lerp(Color.WHITE, 0.6)
	_home = position
	_timer = randf() * WANDER_EVERY
	_play("idle")


func _physics_process(delta: float) -> void:
	if data.get("movement", "idle") != "wander":
		return
	# A villager who strides off mid-conversation is maddening; zij3d had to add
	# the same courtesy pause after playtesting.
	if _paused > 0.0:
		_paused -= delta
		velocity = Vector2.ZERO
		_play("idle")
		return

	_timer -= delta
	if _timer <= 0.0:
		_timer = WANDER_EVERY
		if randf() < 0.4 or position.distance_to(_home) > WANDER_RADIUS:
			_heading = position.direction_to(_home) if position.distance_to(_home) > WANDER_RADIUS \
				else Vector2.ZERO
		else:
			_heading = Vector2.RIGHT.rotated(randf() * TAU)

	velocity = _heading * SPEED
	move_and_slide()
	if _heading != Vector2.ZERO:
		facing = _heading
	_play("move" if _heading != Vector2.ZERO else "idle")


## If this villager is waiting on something the player is now carrying, accept
## it and return the item id. Returns "" the rest of the time, and after the
## exchange has already happened.
##
## Deliberately reveals nothing by itself. It used to dump every beat this
## character had been assigned — which only worked while characters owned beats,
## and pre-assignment is exactly what was removed. What the gift earns is now
## decided in the conversation it triggers, like everything else.
func accept_item() -> String:
	var want: String = data.get("wants_item", "")
	if want == "" or _gave or not GameState.has_item(want):
		return ""
	_gave = true
	return want


## Called when the player starts talking: stop wandering and turn to face them.
func attend(to: Vector2, seconds: float = 8.0) -> void:
	_paused = seconds
	facing = position.direction_to(to)
	_play("idle")


func _play(state: String) -> void:
	var parts := Sheet.facing_suffix(facing)
	_sprite.flip_h = parts[1]
	_sprite.play("%s_%s" % [state, parts[0]])
