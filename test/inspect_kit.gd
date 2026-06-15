extends SceneTree
# Measures footprints (world AABB) of selected Downtown City MegaKit tiles so the
# grid module can be grounded in real numbers. Run headless:
#   godot --headless --path . --script res://test/inspect_kit.gd

const ROOT := "res://assets/Downtown City MegaKit[Standard]/Exports/glTF (Godot)/"

const NAMES := [
	"Street_2Lane", "Street_4Lane", "Street_4WayIntersection", "Street_TIntersection",
	"Street_Asphalt_6x6", "Street_Asphalt_9x9",
	"Sidewalk_Straight_3m", "Sidewalk_Corner_Flat_3m",
	"Building_Small_1", "Building_Medium_2_001", "Building_Large_2",
]

func _init() -> void:
	for name in NAMES:
		var ps := load(ROOT + name + ".gltf") as PackedScene
		if ps == null:
			print("MISS  %s" % name)
			continue
		var root := ps.instantiate() as Node3D
		get_root().add_child(root)
		var agg := AABB()
		var first := true
		for mi in root.find_children("*", "MeshInstance3D", true, false):
			var a: AABB = (mi as MeshInstance3D).global_transform * (mi as MeshInstance3D).get_aabb()
			if first: agg = a; first = false
			else: agg = agg.merge(a)
		print("%-26s size=(%.3f, %.3f, %.3f)  pos=(%.3f, %.3f, %.3f)" % [
			name, agg.size.x, agg.size.y, agg.size.z, agg.position.x, agg.position.y, agg.position.z])
		root.queue_free()
		get_root().remove_child(root)
	quit()
