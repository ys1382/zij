extends CanvasLayer
# Autoload. Two pieces of on-screen text: a small verb prompt that follows what
# the player is standing next to ("E — Read"), and a panel for the line itself.
# Built in code so there is no .tscn to keep in sync with the script.
#
# The panel grows to fit its line rather than living in a fixed rect. At a 360px
# logical height a fixed box held about five wrapped lines and silently clipped
# anything longer, so a villager who ran on lost the end of their sentence.

const PAD := 10
const BODY_SIZE := 11
const SPEAKER_SIZE := 12
const SPACING := 4
## Never eat more than this share of the screen; past it the body scrolls.
const MAX_SCREEN_FRACTION := 0.55

var _prompt: Label
var _panel: PanelContainer
var _box: VBoxContainer
var _speaker: Label
var _body: RichTextLabel


func _ready() -> void:
	layer = 10

	_prompt = Label.new()
	_prompt.add_theme_font_size_override("font_size", 12)
	_prompt.add_theme_color_override("font_outline_color", Color.BLACK)
	_prompt.add_theme_constant_override("outline_size", 4)
	_prompt.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_prompt.offset_top = -104
	_prompt.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_prompt.hide()
	add_child(_prompt)

	_panel = PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.09, 0.11, 0.94)
	sb.border_color = Color(0.45, 0.38, 0.26)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(4)
	sb.set_content_margin_all(PAD)
	_panel.add_theme_stylebox_override("panel", sb)
	_panel.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_panel.offset_left = PAD * 2
	_panel.offset_right = -PAD * 2
	_panel.offset_bottom = -PAD
	_panel.hide()
	add_child(_panel)

	_box = VBoxContainer.new()
	_box.add_theme_constant_override("separation", SPACING)
	_panel.add_child(_box)

	_speaker = Label.new()
	_speaker.add_theme_font_size_override("font_size", SPEAKER_SIZE)
	_speaker.add_theme_color_override("font_color", Color(1, 0.86, 0.5))
	_box.add_child(_speaker)

	_body = RichTextLabel.new()
	_body.bbcode_enabled = false
	_body.scroll_active = true
	_body.fit_content = true
	_body.add_theme_font_size_override("normal_font_size", BODY_SIZE)
	_box.add_child(_body)


func show_prompt(text: String) -> void:
	if is_open():
		return
	_prompt.text = text
	_prompt.show()


func hide_prompt() -> void:
	_prompt.hide()


## The one-frame placeholder while a model reply is in flight. Deliberately not
## a sentence: showing the NPC's canned opener here and then swapping in the
## real line read as the character saying two different things a second apart.
func show_thinking(speaker: String) -> void:
	show_line(speaker, "…")


func show_line(speaker: String, text: String) -> void:
	_prompt.hide()
	_speaker.text = speaker
	_speaker.visible = speaker != ""
	_body.text = text
	_fit(text, speaker != "")
	_panel.show()


## Sizes the panel to the wrapped text. Font.get_multiline_string_size gives the
## real wrapped height for a given width, so this needs no layout frame — doing
## it after a frame instead made the box pop up small and then jump.
func _fit(text: String, has_speaker: bool) -> void:
	var screen := get_viewport().get_visible_rect().size
	var inner := screen.x - PAD * 4 - PAD * 2       # panel margins, then padding
	var font := _body.get_theme_font("normal_font")
	if font == null:
		font = ThemeDB.fallback_font
	var body_h := font.get_multiline_string_size(
		text, HORIZONTAL_ALIGNMENT_LEFT, inner, BODY_SIZE).y
	var h := body_h + PAD * 2
	if has_speaker:
		h += float(SPEAKER_SIZE) + SPACING
	var capped := minf(h, screen.y * MAX_SCREEN_FRACTION)
	# fit_content would force the label to its full height and overflow the cap;
	# turn it off in the rare case the line is long enough to need scrolling.
	_body.fit_content = h <= capped
	_panel.offset_top = -(capped + PAD)


func is_open() -> bool:
	return _panel.visible


## What the panel is currently saying. The agent bridge reads this to assert on
## lines the game produces locally — item pickups, locked_text, gift lines —
## which never go through the model and so never reach dialogue_received.
func body() -> String:
	return _body.text


func close() -> void:
	_panel.hide()
