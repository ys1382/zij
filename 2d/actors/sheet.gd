class_name Sheet
extends RefCounted
# Builds SpriteFrames from the Mystic Woods character sheets.
#
# These sheets are NOT uniform: the rows of a single sheet have different real
# frame counts (the player's attack rows hold 4 frames in a 6-wide grid, the
# rest is empty padding). Slicing every row at the grid width animates through
# blank cells, so each row's count is declared explicitly below.
#
# Layout convention for both sheets: states run top to bottom, and within a
# directional state the three rows are down / side / up. There is no left row —
# flip the side row horizontally (Sprite2D.flip_h) to face left.

## One row of a sheet: animation name, row index, real frame count, fps, loop.
class Row:
	var anim: String
	var row: int
	var frames: int
	var fps: float
	var loop: bool
	func _init(a: String, r: int, n: int, f: float = 10.0, l: bool = true) -> void:
		anim = a; row = r; frames = n; fps = f; loop = l

# player.png — 288x480, 48x48 cells, 6 cols x 10 rows.
# Rows [0-2] idle, [3-5] move, [6-8] attack, [9] death.
const PLAYER_TEXTURE := "res://assets/mystic_woods_free_2/sprites/characters/player.png"
const PLAYER_CELL := Vector2i(48, 48)

# slime.png — 224x416, 32x32 cells, 7 cols x 13 rows.
# Rows [0-2] idle, [3-5] move, [6-8] attack, [9-11] hurt, [12] death.
const SLIME_TEXTURE := "res://assets/mystic_woods_free_2/sprites/characters/slime.png"
const SLIME_CELL := Vector2i(32, 32)


static func player_rows() -> Array:
	return [
		Row.new("idle_down", 0, 6, 8.0), Row.new("idle_side", 1, 6, 8.0), Row.new("idle_up", 2, 6, 8.0),
		Row.new("move_down", 3, 6, 12.0), Row.new("move_side", 4, 6, 12.0), Row.new("move_up", 5, 6, 12.0),
		Row.new("attack_down", 6, 4, 14.0, false),
		Row.new("attack_side", 7, 4, 14.0, false),
		Row.new("attack_up", 8, 4, 14.0, false),
		Row.new("death", 9, 3, 6.0, false),
	]


static func slime_rows() -> Array:
	return [
		Row.new("idle_down", 0, 4, 6.0), Row.new("idle_side", 1, 4, 6.0), Row.new("idle_up", 2, 4, 6.0),
		Row.new("move_down", 3, 6, 10.0), Row.new("move_side", 4, 6, 10.0), Row.new("move_up", 5, 6, 10.0),
		Row.new("attack_down", 6, 7, 12.0, false),
		Row.new("attack_side", 7, 7, 12.0, false),
		Row.new("attack_up", 8, 7, 12.0, false),
		Row.new("hurt_down", 9, 3, 10.0, false),
		Row.new("hurt_side", 10, 3, 10.0, false),
		Row.new("hurt_up", 11, 3, 10.0, false),
		Row.new("death", 12, 5, 8.0, false),
	]


static func build(texture_path: String, cell: Vector2i, rows: Array) -> SpriteFrames:
	var tex: Texture2D = load(texture_path)
	assert(tex != null, "missing sheet %s" % texture_path)
	var sf := SpriteFrames.new()
	sf.remove_animation("default")
	for r: Row in rows:
		sf.add_animation(r.anim)
		sf.set_animation_speed(r.anim, r.fps)
		sf.set_animation_loop(r.anim, r.loop)
		for i in r.frames:
			var at := AtlasTexture.new()
			at.atlas = tex
			at.region = Rect2(i * cell.x, r.row * cell.y, cell.x, cell.y)
			sf.add_frame(r.anim, at)
	return sf


# The Fan-tasy pack's main character, used for villagers so NPCs don't all look
# like the player. Two sheets, both 160x192 = 4 cols x 4 rows of 40x48.
# Row order read off the sheet: 0/1 are the mirrored side pair, 2 is the back
# (up), 3 is front-facing (down). Only one side row is used — the other
# direction is flip_h, same as the Mystic Woods sheets.
const VILLAGER_IDLE := "res://assets/The Fan-tasy Tileset (Free)/Art/Characters/Main Character/Character_Idle.png"
const VILLAGER_WALK := "res://assets/The Fan-tasy Tileset (Free)/Art/Characters/Main Character/Character_Walk.png"
const VILLAGER_CELL := Vector2i(40, 48)


static func player_frames() -> SpriteFrames:
	return build(PLAYER_TEXTURE, PLAYER_CELL, player_rows())


static func villager_frames() -> SpriteFrames:
	var sf := build(VILLAGER_IDLE, VILLAGER_CELL, [
		Row.new("idle_side", 0, 4, 6.0),
		Row.new("idle_up", 2, 4, 6.0),
		Row.new("idle_down", 3, 4, 6.0),
	])
	# Merge the walk sheet's rows into the same SpriteFrames.
	var walk := build(VILLAGER_WALK, VILLAGER_CELL, [
		Row.new("move_side", 0, 4, 10.0),
		Row.new("move_up", 2, 4, 10.0),
		Row.new("move_down", 3, 4, 10.0),
	])
	for anim in walk.get_animation_names():
		sf.add_animation(anim)
		sf.set_animation_speed(anim, walk.get_animation_speed(anim))
		for i in walk.get_frame_count(anim):
			sf.add_frame(anim, walk.get_frame_texture(anim, i))
	return sf


static func slime_frames() -> SpriteFrames:
	return build(SLIME_TEXTURE, SLIME_CELL, slime_rows())


## Picks the animation row + whether to flip, from a facing vector.
## Returns [suffix, flip_h]. Vertical wins ties so walking diagonally up shows
## the back sprite rather than snapping sideways.
static func facing_suffix(facing: Vector2) -> Array:
	if absf(facing.x) > absf(facing.y):
		return ["side", facing.x < 0.0]
	return ["up" if facing.y < 0.0 else "down", false]
