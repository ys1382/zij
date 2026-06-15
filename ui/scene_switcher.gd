extends CanvasLayer

const SCENES := {
	"City": "res://scenes/city.tscn",
	"Big City": "res://scenes/big_city.tscn",
	"Desert City": "res://scenes/desert_city.tscn",
	"Main": "res://scenes/main.tscn",
}

func _ready() -> void:
	layer = 10

	var panel := PanelContainer.new()
	add_child(panel)
	panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	panel.position = Vector2(8, 8)

	var hbox := HBoxContainer.new()
	panel.add_child(hbox)
	hbox.add_theme_constant_override("separation", 4)

	for label in SCENES.keys():
		var btn := Button.new()
		btn.text = label
		btn.pressed.connect(_switch_to.bind(SCENES[label]))
		hbox.add_child(btn)

func _switch_to(path: String) -> void:
	get_tree().change_scene_to_file(path)
