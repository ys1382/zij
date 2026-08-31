extends SceneTree
# Headless check that everything tools/tsx_convert.py emitted actually loads in
# Godot. A .tres that Godot silently rejects looks identical to a good one on
# disk, so this is the only real verification the pipeline has.
#
#   godot --headless --path . --script res://tools/verify_assets.gd

const CATALOG := "res://generated/assets_catalog.json"
## Tiled colliders are hand-drawn and sometimes sit a fraction of a pixel
## outside the art; allow that much slop before calling it a transform bug.
const EPS := 1.5

var _fails: int = 0

func _fail(msg: String) -> void:
	_fails += 1
	printerr("FAIL: ", msg)

func _initialize() -> void:
	var f := FileAccess.open(CATALOG, FileAccess.READ)
	if f == null:
		_fail("cannot open %s — run tools/tsx_convert.py first" % CATALOG)
		quit(1)
		return
	var cat: Dictionary = JSON.parse_string(f.get_as_text())

	var tiles_total := 0
	var colliders_total := 0
	var anim_total := 0
	var terrains_total := 0

	for name in cat["tilesets"]:
		var path: String = cat["tilesets"][name]["path"]
		var ts: TileSet = load(path)
		if ts == null:
			_fail("tileset failed to load: %s" % path)
			continue
		if ts.get_source_count() == 0:
			_fail("%s has no sources" % name)
			continue
		var src := ts.get_source(ts.get_source_id(0)) as TileSetAtlasSource
		if src == null:
			_fail("%s source 0 is not a TileSetAtlasSource" % name)
			continue
		if src.texture == null:
			_fail("%s source texture is null" % name)
			continue

		# Terrain sets round-tripped from the wangsets.
		for si in ts.get_terrain_sets_count():
			terrains_total += ts.get_terrains_count(si)

		var n := src.get_tiles_count()
		tiles_total += n
		for i in n:
			var coords := src.get_tile_id(i)
			if src.get_tile_animation_frames_count(coords) > 1:
				anim_total += 1
			var td := src.get_tile_data(coords, 0)
			if td == null:
				_fail("%s tile %s has no TileData" % [name, coords])
				continue
			colliders_total += td.get_collision_polygons_count(0)
		print("  ok  %-26s tiles=%4d" % [name, n])

	var objects: Dictionary = cat["objects"]
	var obj_colliders := 0
	for id in objects:
		var entry: Dictionary = objects[id]
		var ps: PackedScene = load(entry["scene"])
		if ps == null:
			_fail("prop scene failed to load: %s" % entry["scene"])
			continue
		var inst := ps.instantiate()
		if not (inst is StaticBody2D):
			_fail("%s root is %s, expected StaticBody2D" % [id, inst.get_class()])
		var sprite := inst.get_node_or_null("Sprite") as Sprite2D
		if sprite == null or sprite.texture == null:
			_fail("%s has no Sprite with a texture" % id)
		else:
			# The catalog's px must match the real image, or every footprint,
			# overlap test and reachability check downstream is wrong.
			var sz := sprite.texture.get_size()
			var want := Vector2(entry["px"][0], entry["px"][1])
			if sz != want:
				_fail("%s catalog px %s != texture %s" % [id, want, sz])
		# Objects are anchored bottom-centre, so with a w x h sprite every
		# collider point must fall inside x [-w/2, w/2], y [-h, 0]. This is the
		# real test that the Tiled -> Godot coordinate transform is right; a
		# sign error or a missing offset shows up here and nowhere else.
		var w: float = entry["px"][0]
		var h: float = entry["px"][1]
		for child in inst.get_children():
			if child is CollisionPolygon2D:
				obj_colliders += 1
				var poly := (child as CollisionPolygon2D).polygon
				if poly.size() < 3:
					_fail("%s has a degenerate collision polygon" % id)
				for p in poly:
					if p.x < -w * 0.5 - EPS or p.x > w * 0.5 + EPS \
							or p.y < -h - EPS or p.y > EPS:
						_fail("%s collider point %s outside sprite bounds %dx%d"
							% [id, p, int(w), int(h)])
						break
		if entry["solid"] and obj_colliders == 0:
			_fail("%s marked solid but has no collider" % id)
		inst.free()

	print("\ntileset tiles=%d colliders=%d animated=%d terrains=%d | objects=%d colliders=%d"
		% [tiles_total, colliders_total, anim_total, terrains_total,
		   objects.size(), obj_colliders])

	var total_colliders := colliders_total + obj_colliders
	if total_colliders != 563:
		_fail("total colliders %d != 563" % total_colliders)
	if anim_total != 83:
		_fail("animated tiles %d != 83" % anim_total)
	if terrains_total != 9:
		_fail("terrains %d != 9" % terrains_total)

	if _fails == 0:
		print("VERIFY OK — all generated assets load in Godot")
	quit(1 if _fails > 0 else 0)
