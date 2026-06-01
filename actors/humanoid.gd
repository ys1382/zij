extends CharacterBody3D

@export var test_mode: bool = false
var test_input: Vector2 = Vector2.ZERO   # set by the test harness

@export var speed: float = 4.0
@export var turn_speed: float = 10.0
@export var jump_velocity: float = 5.0
@export var mouse_sensitivity: float = 0.0025
@export var min_pitch_deg: float = -70.0
@export var max_pitch_deg: float = 30.0

@onready var model: Node3D = $Model
@onready var anim: AnimationPlayer = $Model/AnimationPlayer
@onready var spring: SpringArm3D = $SpringArm3D

# Mixamo animation FBXs — each holds one clip called "mixamo_com".
const ANIM_SOURCES := {
	"idle": "res://assets/Basic Locomotion Pack/idle.fbx",
	"walk": "res://assets/Basic Locomotion Pack/walking.fbx",
	"jump": "res://assets/Basic Locomotion Pack/jump.fbx",
}

var current_animation: String = ""
var _yaw: float = 0.0
var _pitch: float = deg_to_rad(-15.0)

func _ready() -> void:
	add_to_group("humanoid")
	add_to_group("player")
	collision_layer = 0b010
	collision_mask = 0b101
	floor_snap_length = 0.6
	floor_max_angle = deg_to_rad(50.0)
	floor_constant_speed = true
	_load_animations()
	_play("idle")
	if not test_mode:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		_apply_camera_rotation()

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
			_strip_root_motion(clip)
			lib.add_animation(name, clip)
		inst.free()

# Mixamo clips bake forward translation into the Hips ("root motion"). We move
# the body in code, so lock the Hips' horizontal (X/Z) drift to its first key —
# keeping the vertical bob — so the animation plays in place without snapping.
func _strip_root_motion(clip: Animation) -> void:
	for t in clip.get_track_count():
		if clip.track_get_type(t) != Animation.TYPE_POSITION_3D:
			continue
		if not str(clip.track_get_path(t)).contains("Hips"):
			continue
		var n := clip.track_get_key_count(t)
		if n == 0:
			continue
		var base: Vector3 = clip.track_get_key_value(t, 0)
		for k in range(n):
			var v: Vector3 = clip.track_get_key_value(t, k)
			clip.track_set_key_value(t, k, Vector3(base.x, v.y, base.z))

func _play(name: String) -> void:
	if current_animation == name:
		return
	if anim.has_animation(name):
		anim.play(name, 0.15)
		current_animation = name

func _unhandled_input(event: InputEvent) -> void:
	if test_mode:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_yaw -= event.relative.x * mouse_sensitivity
		_pitch = clampf(_pitch - event.relative.y * mouse_sensitivity,
			deg_to_rad(min_pitch_deg), deg_to_rad(max_pitch_deg))
		_apply_camera_rotation()
	elif event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = (Input.MOUSE_MODE_VISIBLE
			if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
			else Input.MOUSE_MODE_CAPTURED)

func _apply_camera_rotation() -> void:
	spring.rotation = Vector3(_pitch, _yaw, 0.0)

func get_move_input() -> Vector2:
	if test_mode:
		return test_input
	return Input.get_vector("move_left", "move_right", "move_forward", "move_back")

func _physics_process(delta: float) -> void:
	var grounded := is_on_floor()
	if not grounded:
		velocity += get_gravity() * delta

	var input := get_move_input()
	var dir: Vector3
	if test_mode:
		dir = Vector3(input.x, 0.0, input.y)
	else:
		var basis := spring.global_transform.basis
		var forward := -basis.z
		forward.y = 0.0
		forward = forward.normalized()
		var right := basis.x
		right.y = 0.0
		right = right.normalized()
		dir = right * input.x + forward * (-input.y)
	if dir.length() > 1.0:
		dir = dir.normalized()
	velocity.x = dir.x * speed
	velocity.z = dir.z * speed

	if not test_mode and grounded and Input.is_action_just_pressed("jump"):
		velocity.y = jump_velocity

	move_and_slide()

	# Animation + facing.
	var horizontal := Vector2(velocity.x, velocity.z)
	if not is_on_floor():
		_play("jump")
	elif horizontal.length() > 0.1:
		var target_yaw := atan2(velocity.x, velocity.z)
		model.rotation.y = lerp_angle(model.rotation.y, target_yaw, turn_speed * delta)
		_play("walk")
	else:
		_play("idle")
