class_name LoadingScreen
extends CanvasLayer
# Covers the world while it is generated, built, screenshotted, repaired and
# rebuilt. Without this the player watches the village flicker as the repair
# pass tears it down and puts it back.
#
# Not an autoload — main.gd owns one and frees it when the world is ready.

var _label: Label
var _sub: Label
var _clock: Label
## Generation is two model calls and can run past a minute. Without a ticking
## number the screen is indistinguishable from a hang.
var _step_started_ms: int = 0


func _init() -> void:
	layer = 100
	_step_started_ms = Time.get_ticks_msec()

	var bg := ColorRect.new()
	bg.color = Color(0.06, 0.07, 0.09)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.grow_horizontal = Control.GROW_DIRECTION_BOTH
	box.grow_vertical = Control.GROW_DIRECTION_BOTH
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	add_child(box)

	_label = Label.new()
	_label.add_theme_font_size_override("font_size", 18)
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_label)

	_sub = Label.new()
	_sub.add_theme_font_size_override("font_size", 11)
	_sub.add_theme_color_override("font_color", Color(0.6, 0.62, 0.66))
	_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_sub)

	_clock = Label.new()
	_clock.add_theme_font_size_override("font_size", 10)
	_clock.add_theme_color_override("font_color", Color(0.38, 0.4, 0.44))
	_clock.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_clock)


func _process(_delta: float) -> void:
	# Only from five seconds in: on the fast paths the counter would just flash.
	var secs := (Time.get_ticks_msec() - _step_started_ms) / 1000
	_clock.text = "%ds" % secs if secs >= 5 else ""


func status(title: String, detail: String = "") -> void:
	_label.text = title
	_sub.text = detail
	_step_started_ms = Time.get_ticks_msec()
	_clock.text = ""
	# The build and capture steps block the main loop, so without an explicit
	# frame yield the text never actually appears before the work starts.
	await get_tree().process_frame
	await get_tree().process_frame
