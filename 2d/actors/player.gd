class_name Player
extends CharacterBody2D
# 8-way movement on a 4-directional sheet: the art has down/side/up rows only,
# so diagonals pick the dominant axis and left is the side row flipped.
#
# The collider is a small ellipse at the character's feet, not the whole 48x48
# cell — top-down games read correctly when only the feet collide, and it lets
# the player tuck under the overhanging parts of trees and roofs.

const SPEED := 70.0
const ACCEL := 900.0
const FRICTION := 1100.0

const MAX_HP := 5
## After a hit you are untouchable for this long, and flash. Without it a slime
## sitting on top of you drains the whole bar in well under a second and the
## player never learns what hit them.
const INVULN_S := 1.2
## Reach of a swing, and how wide a cone counts as "in front of me". The dot
## product against `facing` is what stops a swing from hitting something behind.
const ATTACK_REACH := 26.0
const ATTACK_CONE := 0.35
const ATTACK_DAMAGE := 1
## Long enough to read the death animation before the world snaps back.
const RESPAWN_S := 1.6

signal interact_pressed
signal health_changed(current: int, maximum: int)
signal died

@onready var _sprite: AnimatedSprite2D = $Sprite
@onready var _reach: Area2D = $InteractArea

var facing := Vector2.DOWN
var hp: int = MAX_HP
## Where to put the player back after a defeat. Set by the WorldBuilder, which
## is the only thing that knows the world's player_start.
var spawn_point := Vector2.ZERO

var _attacking := false
var _invuln := 0.0
var _dead := false
## Set by the agent bridge to drive the player without keyboard input; zero
## means "use the real input". Public so test/agent_bridge.gd can steer.
var agent_input := Vector2.ZERO
var focus: Node = null


func _ready() -> void:
	add_to_group("player")
	_sprite.sprite_frames = Sheet.player_frames()
	# The sheet's feet sit near the bottom of the 48x48 cell; lift the sprite so
	# the node origin is the feet (matches prop anchors and makes Y-sort work).
	_sprite.position = Vector2(0, -16)
	_sprite.animation_finished.connect(_on_anim_finished)
	_play("idle")


func _physics_process(delta: float) -> void:
	if _invuln > 0.0:
		_invuln -= delta
		# Flash while it lasts, then make sure the sprite ends up fully opaque —
		# an odd number of frames would otherwise leave it stuck half-faded.
		_sprite.modulate.a = 0.35 if int(_invuln * 12.0) % 2 == 0 else 1.0
		if _invuln <= 0.0:
			_sprite.modulate.a = 1.0
	if _dead:
		velocity = Vector2.ZERO
		move_and_slide()
		return

	var input := agent_input if agent_input != Vector2.ZERO \
		else Input.get_vector("move_left", "move_right", "move_up", "move_down")
	if _attacking:
		input = Vector2.ZERO
	if input != Vector2.ZERO:
		velocity = velocity.move_toward(input.normalized() * SPEED, ACCEL * delta)
		facing = input
	else:
		velocity = velocity.move_toward(Vector2.ZERO, FRICTION * delta)
	move_and_slide()
	if not _attacking:
		_play("move" if input != Vector2.ZERO else "idle")
	_update_focus()


# --- interaction -------------------------------------------------------------

## Nearest thing in reach wins, so standing between a bench and a villager
## doesn't flicker between prompts.
##
## People break ties. Only a tie: an earlier "NPCs always beat scenery" rule
## meant a single villager wandering past a chest made the chest impossible to
## open, which is worse than the problem it fixed. The actual fix was capping
## interactable reach boxes (see Interactable.MAX_REACH_TILES); distances are
## comparable again, so nearest genuinely wins.
func _update_focus() -> void:
	var best: Node = null
	var best_d := INF
	for area in _reach.get_overlapping_areas():
		if area is Interactable:
			var d := global_position.distance_squared_to((area as Node2D).global_position)
			if d < best_d:
				best_d = d
				best = area
	for body in _reach.get_overlapping_bodies():
		if body is Npc:
			var d := global_position.distance_squared_to((body as Node2D).global_position)
			if d <= best_d:   # <= so a person wins an exact tie
				best_d = d
				best = body
	focus = best

	if DialogueUI.is_open():
		return
	if focus is Interactable:
		DialogueUI.show_prompt("E — %s" % (focus as Interactable).prompt())
	elif focus is Npc:
		DialogueUI.show_prompt("E — Talk to %s" % (focus as Npc).display_name)
	else:
		DialogueUI.hide_prompt()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("interact"):
		interact_pressed.emit()
		use_focus()
	elif event.is_action_pressed("attack"):
		swing()


# --- combat -------------------------------------------------------------------

func swing() -> void:
	if _attacking or _dead:
		return
	_attacking = true
	_play("attack")
	_strike()


## Hits every enemy in a cone in front of the player. Deliberately a one-shot
## geometric query rather than a hitbox Area2D: the swing lasts four frames, so
## an area would have to be enabled and disabled in step with the animation, and
## whether a hit registers would depend on frame timing. This always resolves.
func _strike() -> void:
	var dir := facing.normalized()
	for enemy in get_tree().get_nodes_in_group("enemy"):
		var e := enemy as Node2D
		if e == null or not is_instance_valid(e):
			continue
		var to := e.global_position - global_position
		if to.length() > ATTACK_REACH or dir.dot(to.normalized()) < ATTACK_CONE:
			continue
		if e.has_method("take_damage"):
			e.take_damage(ATTACK_DAMAGE, dir)


func take_damage(amount: int) -> void:
	if _dead or _invuln > 0.0 or amount <= 0:
		return
	hp = maxi(0, hp - amount)
	_invuln = INVULN_S
	health_changed.emit(hp, MAX_HP)
	if hp == 0:
		_die()


func _die() -> void:
	_dead = true
	_attacking = false
	died.emit()
	_sprite.play("death")
	await get_tree().create_timer(RESPAWN_S).timeout
	if not is_instance_valid(self):
		return
	# Respawn rather than end the run. This is a mystery for children: losing
	# the story you have pieced together because a slime cornered you would be
	# a punishment out of all proportion, so beats are untouched.
	global_position = spawn_point
	hp = MAX_HP
	_dead = false
	_invuln = INVULN_S
	_sprite.modulate.a = 1.0
	health_changed.emit(hp, MAX_HP)
	_play("idle")


## Returns what happened, so a caller knows whether a model reply is still
## coming: "" (nothing/closed), "interactable", "give", or "talk". Only "talk"
## has a request in flight — the agent bridge used to await one unconditionally
## and sat through its whole timeout whenever an NPC simply took a gift.
func use_focus() -> String:
	# A second press closes an open panel rather than immediately re-triggering.
	if DialogueUI.is_open():
		DialogueUI.close()
		return ""
	if focus is Interactable:
		var it := focus as Interactable
		var line := it.use()
		# Entering a building and leaving one both return "" — the change of
		# scene IS the response, and an empty panel over it would just be in
		# the way.
		if line != "":
			DialogueUI.show_line("", line)
		return "interactable"
	if focus is Npc:
		var npc := focus as Npc
		npc.attend(global_position)
		# A gift is not its own scripted moment any more — it is context for the
		# conversation it starts. The character is told what they were just
		# handed and decides what that earns, same as any other exchange.
		var gift := npc.accept_item()
		npc.met = true
		if gift != "" and not GameState.offline_mode and LLMClient.backend_available:
			DialogueUI.show_thinking(npc.display_name)
			LLMClient.request_dialogue(npc.npc_id, "", gift)
			return "talk"
		if gift != "":
			DialogueUI.show_line(npc.display_name,
				"You hand over %s. They turn it over and over in their hands."
					% GameState.item_name(gift))
			return "give"
		# One line, not two. This used to show the canned opener immediately and
		# then swap in the model's reply a second later, which read as the
		# character saying two different things back to back. Now the interim is
		# an ellipsis — plainly "still speaking" rather than a sentence — and the
		# opener is only ever shown as the ACTUAL line, when there is no model to
		# ask. LLMClient emits an empty line on failure so this cannot stick.
		if GameState.offline_mode or not LLMClient.backend_available:
			DialogueUI.show_line(npc.display_name, npc.data.get("opener", "..."))
			return "talk"
		DialogueUI.show_thinking(npc.display_name)
		LLMClient.request_dialogue(npc.npc_id, "")
		return "talk"
	return ""


func _on_anim_finished() -> void:
	if _sprite.animation.begins_with("attack"):
		_attacking = false


func _play(state: String) -> void:
	if _dead:
		return
	var parts := Sheet.facing_suffix(facing)
	_sprite.flip_h = parts[1]
	var anim := "%s_%s" % [state, parts[0]]
	if _sprite.animation != anim or not _sprite.is_playing():
		_sprite.play(anim)
