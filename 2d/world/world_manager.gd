extends Node
# Autoload. Owns the live world root so the VLM repair pass can tear down and
# rebuild without anything else holding stale node references.

var world_root: Node2D = null


func _ready() -> void:
	# GameState is an earlier autoload (see project.godot), so it already
	# exists by the time this one's _ready() runs.
	GameState.world_event.connect(handle_event)


## Routes the rival's escalation mechanics (decided client-side in
## GameState._escalate()/begin_showdown(), see those for why) to the live
## scene. world_root is only null for the instant between builder teardown and
## the next build() — ignore an event that arrives in that gap rather than
## erroring on it.
func handle_event(evt: Dictionary) -> void:
	if world_root == null:
		return
	match evt.get("type", ""):
		"spawn_minions":
			world_root.spawn_minions(int(evt.get("count", 0)))
		"spawn_boss":
			world_root.spawn_boss(GameState.rival())
