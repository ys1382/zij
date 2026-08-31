class_name Slime
extends CharacterBody2D
# The "moving goblin" of the brief. It is a slime: both Mystic Woods skeleton
# sheets are watermarked preview art and the Tiny RPG orc is side-view only, so
# this is the one usable top-down enemy in the packs on disk.
#
# Wanders until the player comes within chase_range, then follows and bites.
# Three hits to kill by default, and it hurts back — see Player.take_damage().
# The boss is this same scene with its @export tuning reconfigured at spawn
# time (see WorldBuilder.spawn_boss) rather than a second enemy class.

## Exported (not const) so world_builder.gd can retune an instance at spawn
## time — the boss is this same scene, scaled up and reconfigured, rather
## than a second copy of the enemy logic.
@export var speed := 26.0
@export var chase_speed := 40.0
@export var chase_range := 90.0
const WANDER_EVERY := 2.2

@export var max_hp := 3
## Close enough to bite — a little under the sprite's width, so it has to
## actually reach you rather than catching you on a corner.
@export var touch_dist := 14.0
## Its own cooldown, on top of the player's invulnerability window, so a slime
## that loses you and finds you again doesn't get a free instant second bite.
@export var bite_every := 1.4
const HURT_S := 0.35
## Shoved back when hit, so a swing reads as having landed and you get room.
@export var knockback := 90.0
const KNOCKBACK_DECAY := 420.0

@onready var _sprite: AnimatedSprite2D = $Sprite

## Emitted the instant hp reaches 0, before the death animation plays — a
## boss's death has to be observable right away (GameState.notify_boss_defeated
## triggers the finale off this), not after however long "death" takes.
signal died

var hp: int = 0

var facing := Vector2.DOWN
var _heading := Vector2.ZERO
var _timer := 0.0
var _hurt := 0.0
var _bite_cd := 0.0
var _knockback := Vector2.ZERO
var _dying := false


func _ready() -> void:
	add_to_group("enemy")
	hp = max_hp
	_sprite.sprite_frames = Sheet.slime_frames()
	_sprite.position = Vector2(0, -10)
	_timer = randf() * WANDER_EVERY
	_sprite.animation_finished.connect(_on_anim_finished)


func _physics_process(delta: float) -> void:
	_bite_cd = maxf(0.0, _bite_cd - delta)
	_knockback = _knockback.move_toward(Vector2.ZERO, KNOCKBACK_DECAY * delta)

	if _dying or _hurt > 0.0:
		_hurt = maxf(0.0, _hurt - delta)
		velocity = _knockback
		move_and_slide()
		return

	var player := get_tree().get_first_node_in_group("player") as Node2D
	var cur_speed := speed
	if player != null:
		var dist := global_position.distance_to(player.global_position)
		if dist < touch_dist:
			if _bite_cd <= 0.0:
				_bite(player)
				return
			# Hold at arm's length between bites. Enemies don't collide with the
			# player (layer 16 vs 2, both masking only the environment), so
			# without this the slime walks right inside them and sits there —
			# giving it a mask instead would let it shove the player through
			# doorways and into scenery.
			_heading = Vector2.ZERO
		elif dist < chase_range:
			_heading = global_position.direction_to(player.global_position)
			cur_speed = chase_speed
		else:
			_wander(delta)
	else:
		_wander(delta)

	velocity = _heading * cur_speed + _knockback
	move_and_slide()
	if _heading != Vector2.ZERO:
		facing = _heading
	_play("move" if _heading != Vector2.ZERO else "idle")


func _wander(delta: float) -> void:
	_timer -= delta
	if _timer <= 0.0:
		_timer = WANDER_EVERY
		_heading = Vector2.ZERO if randf() < 0.3 else \
			Vector2.RIGHT.rotated(randf() * TAU)


func _bite(player: Node2D) -> void:
	_bite_cd = bite_every
	facing = global_position.direction_to(player.global_position)
	_heading = Vector2.ZERO
	velocity = Vector2.ZERO
	move_and_slide()
	_play("attack")
	if player.has_method("take_damage"):
		player.take_damage(1)


## `from` is the direction the blow travelled in, used for the knockback.
func take_damage(amount: int, from: Vector2 = Vector2.ZERO) -> void:
	if _dying or amount <= 0:
		return
	hp -= amount
	_knockback = from.normalized() * knockback
	if hp <= 0:
		_die()
		return
	_hurt = HURT_S
	if from != Vector2.ZERO:
		facing = -from
	_play("hurt")


func _die() -> void:
	_dying = true
	died.emit()
	# Stop colliding immediately. A corpse still blocking the doorway it died in
	# for the length of a death animation is worse than no animation at all.
	collision_layer = 0
	collision_mask = 0
	_sprite.play("death")


func _on_anim_finished() -> void:
	if _sprite.animation == "death":
		queue_free()


func _play(state: String) -> void:
	var parts := Sheet.facing_suffix(facing)
	_sprite.flip_h = parts[1]
	var anim := "%s_%s" % [state, parts[0]]
	if _sprite.animation != anim or not _sprite.is_playing():
		_sprite.play(anim)
