class_name ShotCmd
extends RefCounted
## `shot --out FILE.png [--config maps.json] [--map NAME] [--map-id N] [--region-dir DIR] [--data-dir DIR]
##       [--target x,y,z] [--distance D] [--rotation R] [--angle A] [--fov F] [--size WxH]
##       [--eye x,y,z --look-at x,y,z] [--no-adjust-height] [--min-y N] [--max-y N] [--background r,g,b[,a]]`
## One perspective picture of a map (docs/render-api.md). Writes the PNG and a .json next to it
## with the camera transform: the same fields the HTTP API returns.


static func _vec3(text: String, fallback: Vector3) -> Vector3:
	var p := text.split(",")
	if p.size() == 3:
		return Vector3(float(p[0]), float(p[1]), float(p[2]))
	return fallback


static func run(args: Args) -> int:
	var out := args.text("out")
	if out == "":
		push_error("shot needs --out FILE.png")
		return 2
	var cfg := MapDef.load_config(args.text("config"))
	var map: MapDef = null
	var sel := args.text("map")
	if sel != "":
		for e in cfg.get("maps", []):
			var d := MapDef.from_entry(e)
			if d.name == sel or str(d.id) == sel:
				map = d
				break
	if map == null:
		map = MapDef.from_args(args, cfg)
	if args.has("region-dir"):
		map.region_dir = args.text("region-dir")
	if map.region_dir == "":
		push_error("shot needs a map (--map with --config, or --region-dir)")
		return 2
	var pool := RendererPool.create(args.text("data-dir", ProjectSettings.globalize_path("res://data")))
	if pool == null:
		return 1
	var sr := pool.shot_renderer(map.region_dir)
	if sr == null:
		return 1
	sr.min_y = args.integer("min-y", map.min_y)
	sr.max_y = args.integer("max-y", map.max_y)
	var size := args.text("size", "1280x720").split("x")
	var width := int(size[0]) if size.size() == 2 else 0
	var height := int(size[1]) if size.size() == 2 else 0
	if width < 16 or height < 16 or width > 4096 or height > 4096:
		push_error("shot needs --size WxH with both sides within 16..4096")
		return 2
	var aspect := float(width) / float(height)
	var fov := args.number("fov", ShotCamera.DEFAULT_FOV)
	var cam: Dictionary
	if args.has("eye"):
		cam = ShotCamera.from_eye(_vec3(args.text("eye"), Vector3.ZERO), _vec3(args.text("look-at", "0,70,0"), Vector3(0, 70, 0)), aspect, fov)
	else:
		var target := _vec3(args.text("target", "0,70,0"), Vector3(0, 70, 0))
		var distance := args.number("distance", 120.0)
		var rotation := args.number("rotation", 0.0)
		var angle := args.number("angle", 0.75)
		if not args.flag("no-adjust-height"):
			target = sr.effective_target(target, distance, rotation, angle)
		cam = ShotCamera.orbit(target, distance, rotation, angle, aspect, fov)
	var dist := (cam["eye"] as Vector3).distance_to(cam["target"])
	var chunks := sr.shot_chunks(cam["vp"], cam["target"], dist)
	var t0 := Time.get_ticks_usec()
	if args.has("background"):
		var bg := args.text("background").split(",")
		if bg.size() >= 3:
			sr.background = Color(int(bg[0]) / 255.0, int(bg[1]) / 255.0, int(bg[2]) / 255.0, (int(bg[3]) / 255.0) if bg.size() >= 4 else 1.0)
	var img := sr.render_shot(cam, width, height, chunks)
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	DirAccess.make_dir_recursive_absolute(out.get_base_dir())
	if img.save_png(out) != OK:
		push_error("cannot write %s" % out)
		return 1
	var eye: Vector3 = cam["eye"]
	var tgt: Vector3 = cam["target"]
	var info := {
		"width": width, "height": height,
		"view": Array(cam["view"]), "projection": Array(cam["projection"]),
		"eye": [eye.x, eye.y, eye.z], "target": [tgt.x, tgt.y, tgt.z],
		"render_ms": ms, "chunks": chunks.size(),
	}
	FileAccess.open(out.get_basename() + ".json", FileAccess.WRITE).store_string(JSON.stringify(info, "  "))
	print("shot: %s (%dx%d, %d chunks, %.0f ms)" % [out, width, height, chunks.size(), ms])
	return 0
