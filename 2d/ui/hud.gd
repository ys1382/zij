extends CanvasLayer
# Autoload. The player's hearts, top-left.
#
# It finds the player by group each frame rather than holding a reference: the
# VLM repair pass tears the whole world down and rebuilds it mid-load, so any
# cached node here would be freed out from under us. WorldManager exists for
# exactly this hazard; a group lookup per frame is cheaper than another way to
# get it wrong.

const PAD := 10
const FULL := "♥"
const EMPTY := "♡"

var _label: Label
var _last := -1

## The rival's hp during the showdown, on a second line. Purely cosmetic —
## the fight works the same without it — so a missing/renamed group never
## needs to be treated as an error, just hidden.
var _boss_label: Label


func _ready() -> void:
	layer = 15
	_label = Label.new()
	_label.add_theme_font_size_override("font_size", 14)
	_label.add_theme_color_override("font_color", Color(0.93, 0.29, 0.35))
	_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_label.add_theme_constant_override("outline_size", 4)
	_label.position = Vector2(PAD, PAD)
	_label.hide()
	add_child(_label)

	_boss_label = Label.new()
	_boss_label.add_theme_font_size_override("font_size", 14)
	_boss_label.add_theme_color_override("font_color", Color(0.62, 0.42, 0.9))
	_boss_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_boss_label.add_theme_constant_override("outline_size", 4)
	_boss_label.position = Vector2(PAD, PAD + 20)
	_boss_label.hide()
	add_child(_boss_label)


func _process(_delta: float) -> void:
	var p := get_tree().get_first_node_in_group("player")
	if p == null or not ("hp" in p):
		_label.hide()
	else:
		var hp: int = p.hp
		if hp != _last:
			_last = hp
			_label.text = FULL.repeat(hp) + EMPTY.repeat(maxi(0, Player.MAX_HP - hp))
			_label.show()

	var boss := get_tree().get_first_node_in_group("boss")
	if boss == null or not ("hp" in boss) or not ("max_hp" in boss):
		_boss_label.hide()
		return
	var bhp: int = boss.hp
	_boss_label.text = FULL.repeat(maxi(bhp, 0)) + EMPTY.repeat(maxi(0, boss.max_hp - bhp))
	_boss_label.show()
