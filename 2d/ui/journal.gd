extends CanvasLayer
# Autoload. Everything the player is told about the story outside of dialogue:
# the opening card, a toast each time they uncover something, the journal itself
# (Tab), and the ending.
#
# This exists because the first playtest found the game unreadable: interacting
# printed a line of flavour text and nothing else, so there was no sign anything
# had been accomplished and no way to tell what to try next. The world JSON
# already carried a premise, a description per beat and a one-line hint per
# beat; none of it was ever shown.
#
# Built in code, like DialogueUI, so there is no .tscn to keep in sync.

const PAD := 12
## How long a reveal toast stays up. Long enough to read twice at nine years old.
const TOAST_S := 4.5

var _toast: PanelContainer
var _toast_label: Label
var _toast_timer: Timer
var _queued: Array[String] = []

var _panel: PanelContainer
var _panel_body: RichTextLabel
var _panel_title: Label

var _card: PanelContainer
var _card_title: Label
var _card_body: Label
var _card_hint: Label
## "" | "opening" | "showdown" | "won" — which card is up, so dismissing it
## knows whether to kick off the boss fight. Only "showdown" ever does.
var _card_kind: String = ""


func _ready() -> void:
	layer = 20
	# The journal pauses the game while it is up, so it must keep running itself
	# — and it must be the only thing still listening for input. Pausing is also
	# what stops the player acting on the keypress that dismisses a card:
	# _unhandled_input reaches the main scene BEFORE an autoload, so trying to
	# swallow the event here would already be too late.
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_toast()
	_build_panel()
	_build_card()
	GameState.beat_revealed.connect(_on_beat)
	GameState.finale_reached.connect(_on_finale)
	GameState.item_taken.connect(_on_item)
	GameState.showdown_started.connect(_on_showdown)
	GameState.game_won.connect(_on_won)
	GameState.world_event.connect(_on_world_event)


# --- input -------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if _card.visible:
		if event.is_action_pressed("interact") or event.is_action_pressed("ui_cancel"):
			_dismiss_card()
			get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("journal") \
			or (_panel.visible and event.is_action_pressed("ui_cancel")):
		toggle()
		get_viewport().set_input_as_handled()


func toggle() -> void:
	if _panel.visible:
		_panel.hide()
		_set_paused(false)
	else:
		# The interact prompt lives on a lower CanvasLayer but still shows
		# through the panel, and the player can't act on it while paused anyway.
		DialogueUI.hide_prompt()
		_refresh()
		_panel.show()
		_set_paused(true)


func is_open() -> bool:
	return _panel.visible or _card.visible


## Close whatever is up and hand control back. What pressing E on a card does,
## exposed so a scripted playthrough can acknowledge the ending and carry on
## instead of leaving the tree paused for every run that follows.
func dismiss() -> void:
	_panel.hide()
	if _card.visible:
		_dismiss_card()
	else:
		_set_paused(false)


## The one place a card ever closes. Unpausing BEFORE begin_showdown() is
## deliberate: begin_showdown() spawns the boss into the live scene, and a
## paused tree never advances an enemy's physics frame — spawning it first
## would leave the fight latched, exactly the failure mode a scripted
## playtest hit before this was the only path a dismissal could take.
func _dismiss_card() -> void:
	var kind := _card_kind
	_card_kind = ""
	_card.hide()
	_set_paused(false)
	if kind == "showdown":
		GameState.begin_showdown()


## Never leaves the tree paused with nothing on screen to unpause it.
func _set_paused(on: bool) -> void:
	get_tree().paused = on if on else is_open()


# --- the opening card --------------------------------------------------------

## Shown once, after the loading screen. Without it the player is dropped into a
## village with no idea what the problem is.
func show_opening() -> void:
	if GameState.world.is_empty():
		return
	_card_title.text = str(GameState.world.get("title", ""))
	var body := str(GameState.world.get("premise", ""))
	# The goal on the opening card, because the player is free to go anywhere
	# from here and nothing will steer them back.
	if GameState.goal() != "":
		body += "\n\nYour goal: %s" % GameState.goal()
	_card_body.text = body
	_card_hint.text = "E to begin     ·     Tab for your journal"
	_card_kind = "opening"
	DialogueUI.hide_prompt()
	_card.show()
	_set_paused(true)


## Rival-less worlds only: with a rival, GameState routes the ending through
## showdown_started/game_won instead, but still fires this at the very end for
## anything that only ever listened to finale_reached — which would otherwise
## stomp the "won" card _on_won just put up with the plain ending text.
func _on_finale(text: String) -> void:
	if not GameState.rival().is_empty():
		return
	_card_title.text = "Solved!"
	_card_body.text = text
	_card_hint.text = "E to close"
	_card_kind = "won"
	_panel.hide()
	_card.show()
	_set_paused(true)


## The rival shows itself: all condition beats are known. Dismissing this
## card is what actually spawns the boss (see _dismiss_card()).
func _on_showdown(rival: Dictionary, taunt: String) -> void:
	_card_title.text = str(rival.get("name", "???"))
	_card_body.text = taunt
	_card_hint.text = "E — face them!"
	_card_kind = "showdown"
	_panel.hide()
	_card.show()
	_set_paused(true)


func _on_won(text: String) -> void:
	_card_title.text = "Solved!"
	_card_body.text = text
	_card_hint.text = "E to close"
	_card_kind = "won"
	_panel.hide()
	_card.show()
	_set_paused(true)


func _on_world_event(evt: Dictionary) -> void:
	if str(evt.get("type", "")) == "rumor":
		_show_toast("👁  %s" % str(evt.get("line", "")))


# --- toast -------------------------------------------------------------------

func _on_beat(beat: Dictionary) -> void:
	if not beat.is_empty():
		_show_toast("✦  %s" % beat.get("desc", ""))


func _on_item(item: Dictionary) -> void:
	if not item.is_empty():
		_show_toast("+  %s" % item.get("name", "something"))


func _show_toast(text: String) -> void:
	# A pickup and the beat it reveals land in the same frame, so the second
	# would silently replace the first. Queue instead, and let the timer walk
	# through them.
	if _toast.visible:
		_queued.append(text)
		return
	_toast_label.text = text
	_toast.show()
	_toast.modulate.a = 1.0
	_toast_timer.start(TOAST_S)


func _fade_toast() -> void:
	var tween := create_tween()
	tween.tween_property(_toast, "modulate:a", 0.0, 0.6)
	tween.tween_callback(_toast.hide)
	tween.tween_callback(_next_toast)


func _next_toast() -> void:
	if _queued.is_empty():
		return
	_show_toast(_queued.pop_front())


# --- journal contents --------------------------------------------------------

func _refresh() -> void:
	_panel_title.text = str(GameState.world.get("title", "Journal"))
	_panel_body.text = contents()


## The journal's body text. Separate from _refresh() so a playtest can assert on
## what the player is actually being told — an empty goal line is exactly the
## kind of regression that otherwise ships silently.
func contents() -> String:
	var w := GameState.world
	var lines: Array[String] = []
	lines.append("[i]%s[/i]" % str(w.get("premise", "")))
	lines.append("")

	# The goal leads, because it is now the only thing fixed in advance. The old
	# journal opened with a list of "leads" derived from which beats had their
	# prerequisites met — a reading order the player was expected to follow. With
	# no prerequisites left there is no order to advertise, so this says what
	# you are trying to do and how far along you are, and leaves the route to you.
	var goal := GameState.goal()
	if goal != "":
		var p := GameState.progress()
		lines.append("[b]Your goal[/b]")
		lines.append("  %s" % goal)
		if GameState.goal_detail() != "":
			lines.append("  [i]%s[/i]" % GameState.goal_detail())
		if int(p[1]) > 0:
			lines.append("  %d of %d pieces worked out" % [p[0], p[1]])
		lines.append("")

	var known: Array[String] = []
	for b: Dictionary in w.get("beats", []):
		if GameState.known(str(b["id"])):
			known.append(str(b.get("desc", "")))

	if not GameState.inventory.is_empty():
		lines.append("[b]Carrying[/b]")
		for iid in GameState.inventory:
			lines.append("  + %s" % GameState.item_name(iid))
		lines.append("")

	lines.append("[b]What you know[/b]")
	if known.is_empty():
		lines.append("  Nothing yet. Talk to people, look at things, go inside.")
	else:
		for k in known:
			lines.append("  ✦ %s" % k)

	return "\n".join(lines)


# --- construction ------------------------------------------------------------

func _styled_panel(bg: Color) -> PanelContainer:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = Color(0.45, 0.38, 0.26)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(4)
	sb.set_content_margin_all(PAD)
	p.add_theme_stylebox_override("panel", sb)
	return p


func _build_toast() -> void:
	_toast = _styled_panel(Color(0.09, 0.1, 0.13, 0.94))
	_toast.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_toast.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_toast.offset_top = PAD
	_toast.hide()
	add_child(_toast)

	_toast_label = Label.new()
	_toast_label.add_theme_font_size_override("font_size", 11)
	_toast_label.add_theme_color_override("font_color", Color(1, 0.86, 0.5))
	_toast.add_child(_toast_label)

	_toast_timer = Timer.new()
	_toast_timer.one_shot = true
	_toast_timer.timeout.connect(_fade_toast)
	add_child(_toast_timer)


func _build_panel() -> void:
	_panel = _styled_panel(Color(0.08, 0.09, 0.11, 0.97))
	_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel.offset_left = 40
	_panel.offset_right = -40
	_panel.offset_top = 28
	_panel.offset_bottom = -28
	_panel.hide()
	add_child(_panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	_panel.add_child(box)

	_panel_title = Label.new()
	_panel_title.add_theme_font_size_override("font_size", 15)
	_panel_title.add_theme_color_override("font_color", Color(1, 0.86, 0.5))
	box.add_child(_panel_title)

	_panel_body = RichTextLabel.new()
	_panel_body.bbcode_enabled = true
	_panel_body.fit_content = false
	_panel_body.scroll_active = true
	_panel_body.add_theme_font_size_override("normal_font_size", 11)
	_panel_body.add_theme_font_size_override("bold_font_size", 11)
	_panel_body.add_theme_font_size_override("italics_font_size", 11)
	_panel_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(_panel_body)

	var footer := Label.new()
	footer.add_theme_font_size_override("font_size", 9)
	footer.add_theme_color_override("font_color", Color(0.5, 0.52, 0.56))
	footer.text = "Tab to close"
	box.add_child(footer)


func _build_card() -> void:
	_card = _styled_panel(Color(0.08, 0.09, 0.11, 0.97))
	_card.set_anchors_preset(Control.PRESET_CENTER)
	_card.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_card.grow_vertical = Control.GROW_DIRECTION_BOTH
	_card.custom_minimum_size = Vector2(320, 0)
	_card.hide()
	add_child(_card)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	_card.add_child(box)

	_card_title = Label.new()
	_card_title.add_theme_font_size_override("font_size", 15)
	_card_title.add_theme_color_override("font_color", Color(1, 0.86, 0.5))
	_card_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_card_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_card_title)

	_card_body = Label.new()
	_card_body.add_theme_font_size_override("font_size", 11)
	_card_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_card_body.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_card_body)

	_card_hint = Label.new()
	_card_hint.add_theme_font_size_override("font_size", 9)
	_card_hint.add_theme_color_override("font_color", Color(0.5, 0.52, 0.56))
	_card_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_card_hint)
