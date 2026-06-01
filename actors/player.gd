extends CharacterBody3D

@export var test_mode: bool = false
var test_input: Vector2 = Vector2.ZERO   # set by the test harness

@export var speed: float = 5.0
@export var mouse_sensitivity: float = 0.0025
@export var min_pitch_deg: float = -70.0
@export var max_pitch_deg: float = 30.0

@onready var spring: SpringArm3D = $SpringArm3D

var _yaw: float = 0.0
var _pitch: float = deg_to_rad(-15.0)   # camera looks slightly down by default

func _ready() -> void:
	add_to_group("player")
	# Layer 2 = player; collide with environment (1) and interactables (3).
	collision_layer = 0b010
	collision_mask = 0b101
	floor_snap_length = 0.6
	floor_max_angle = deg_to_rad(50.0)
	floor_constant_speed = true
	if not test_mode:
		# Manual play: capture the mouse for free-look.
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		_apply_camera_rotation()

func _unhandled_input(event: InputEvent) -> void:
	if test_mode:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_yaw -= event.relative.x * mouse_sensitivity
		_pitch = clampf(_pitch - event.relative.y * mouse_sensitivity,
			deg_to_rad(min_pitch_deg), deg_to_rad(max_pitch_deg))
		_apply_camera_rotation()
	elif event.is_action_pressed("ui_cancel"):
		# Toggle the cursor free/captured so you can click away or quit.
		Input.mouse_mode = (Input.MOUSE_MODE_VISIBLE
			if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
			else Input.MOUSE_MODE_CAPTURED)

func _apply_camera_rotation() -> void:
	# Yaw + pitch live on the SpringArm so its collision raycast still works.
	spring.rotation = Vector3(_pitch, _yaw, 0.0)

func get_move_input() -> Vector2:
	if test_mode:
		return test_input
	return Input.get_vector("move_left", "move_right", "move_forward", "move_back")

func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity += get_gravity() * delta

	var input := get_move_input()
	var dir: Vector3
	if test_mode:
		# Tests drive world-axis input: x = strafe, y = forward/back (-y forward).
		dir = Vector3(input.x, 0.0, input.y)
	else:
		# Manual play: move relative to where the camera is looking (yaw only).
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

	move_and_slide()
