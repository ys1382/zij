extends CharacterBody3D

@export var test_mode: bool = false
var test_input: Vector2 = Vector2.ZERO   # set by the test harness

@export var speed: float = 5.0

func _ready() -> void:
	add_to_group("player")
	# Layer 2 = player; collide with environment (1) and interactables (3).
	collision_layer = 0b010
	collision_mask = 0b101
	floor_snap_length = 0.6
	floor_max_angle = deg_to_rad(50.0)
	floor_constant_speed = true

func get_move_input() -> Vector2:
	if test_mode:
		return test_input
	return Input.get_vector("move_left", "move_right", "move_forward", "move_back")

func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity += get_gravity() * delta

	var input := get_move_input()
	# Map 2D input to world XZ: x = strafe, y = forward/back (-y is forward).
	var dir := Vector3(input.x, 0.0, input.y)
	if dir.length() > 1.0:
		dir = dir.normalized()
	velocity.x = dir.x * speed
	velocity.z = dir.z * speed

	move_and_slide()
