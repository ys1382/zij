extends CharacterBody3D

@export var test_mode: bool = false
var test_input: Vector2 = Vector2.ZERO   # set by the test harness

@export var speed: float = 4.0
@export var turn_speed: float = 10.0

@onready var model: Node3D = $Model
@onready var anim: AnimationPlayer = $Model/AnimationPlayer

# Mixamo animation FBXs — each holds one clip called "mixamo_com".
const ANIM_SOURCES := {
	"idle": "res://assets/Basic Locomotion Pack/idle.fbx",
	"walk": "res://assets/Basic Locomotion Pack/walking.fbx",
	"jump": "res://assets/Basic Locomotion Pack/jump.fbx",
}

var current_animation: String = ""

func _ready() -> void:
	add_to_group("humanoid")
	collision_layer = 0b010
	collision_mask = 0b101
	floor_snap_length = 0.6
	floor_max_angle = deg_to_rad(50.0)
	floor_constant_speed = true
	_load_animations()
	_play("idle")

# Pull the single "mixamo_com" clip out of each FBX and register it by name
# in the model's own AnimationPlayer (identical skeleton, so tracks apply).
func _load_animations() -> void:
	var lib := anim.get_animation_library("")
	if lib == null:
		lib = AnimationLibrary.new()
		anim.add_animation_library("", lib)
	for name in ANIM_SOURCES:
		var ps := load(ANIM_SOURCES[name]) as PackedScene
		if ps == null:
			push_warning("Humanoid: could not load %s" % ANIM_SOURCES[name])
			continue
		var inst := ps.instantiate()
		var src_ap := inst.get_node("AnimationPlayer") as AnimationPlayer
		if src_ap != null and src_ap.has_animation("mixamo_com"):
			var clip := src_ap.get_animation("mixamo_com").duplicate() as Animation
			clip.loop_mode = Animation.LOOP_LINEAR if name != "jump" else Animation.LOOP_NONE
			lib.add_animation(name, clip)
		inst.free()

func _play(name: String) -> void:
	if current_animation == name:
		return
	if anim.has_animation(name):
		anim.play(name, 0.15)
		current_animation = name

func get_move_input() -> Vector2:
	if test_mode:
		return test_input
	return Input.get_vector("move_left", "move_right", "move_forward", "move_back")

func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity += get_gravity() * delta

	var input := get_move_input()
	var dir := Vector3(input.x, 0.0, input.y)
	if dir.length() > 1.0:
		dir = dir.normalized()
	velocity.x = dir.x * speed
	velocity.z = dir.z * speed

	move_and_slide()

	# Face travel direction and pick the matching clip.
	var horizontal := Vector2(velocity.x, velocity.z)
	if horizontal.length() > 0.1:
		var target_yaw := atan2(velocity.x, velocity.z)
		model.rotation.y = lerp_angle(model.rotation.y, target_yaw, turn_speed * delta)
		_play("walk")
	else:
		_play("idle")
