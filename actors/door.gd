extends Node3D

signal opened

var is_open: bool = false
var body_entered_count: int = 0

@onready var trigger: Area3D = $Trigger
@onready var panel: Node3D = $Panel

func _ready() -> void:
	# Trigger lives on layer 3 (interactables), detects the player on layer 2.
	trigger.collision_layer = 0b100
	trigger.collision_mask = 0b010
	trigger.body_entered.connect(_on_body_entered)

func _on_body_entered(body: Node3D) -> void:
	body_entered_count += 1
	# Explicit log so we can tell the trigger from the response if it breaks.
	print("DOOR :: body_entered fired by '", body.name, "' (count=", body_entered_count, ")")
	if body.is_in_group("player") and not is_open:
		open()

func open() -> void:
	is_open = true
	print("DOOR :: opening (is_open=true)")
	emit_signal("opened")
	var tw := create_tween()
	tw.tween_property(panel, "position:y", panel.position.y + 3.0, 0.5)
