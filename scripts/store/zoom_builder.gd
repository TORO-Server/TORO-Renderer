class_name ZoomBuilder
extends RefCounted
## Rebuilds the zoom-out levels above zoom 0 for the tiles that changed. Parents are the 2x2 mean of four children
## (shaders/zoom.glsl on the GPU, combine_cpu as the reference / fallback); children come from memory when a level
## just changed them and are point-read otherwise. Parent tiles are kept as lossless WebP between levels, so a
## --zoom-all over tens of thousands of parents stays within a small memory budget.

const T := 128
const BATCH := 64

var store: TileStore
var rd: RenderingDevice
var log_fn := Callable()
var _shader := RID()
var _pipe := RID()


func _init(store_: TileStore, rd_: RenderingDevice = null) -> void:
	store = store_
	rd = rd_
	if rd != null:
		var spirv := (load("res://shaders/zoom.glsl") as RDShaderFile).get_spirv()
		if spirv.compile_error_compute != "":
			push_error("zoom.glsl: " + spirv.compile_error_compute)
			rd = null
			return
		_shader = rd.shader_create_from_spirv(spirv)
		_pipe = rd.compute_pipeline_create(_shader)


func _log(msg: String) -> void:
	if log_fn.is_valid():
		log_fn.call(msg)
	else:
		print(msg)


static func floor_div(a: int, b: int) -> int:
	return (a - posmod(a, b)) / b


static func parent_of(c: Vector2i, zoom: int) -> Vector2i:
	var s2 := 2 * (1 << zoom)
	return Vector2i(floor_div(c.x, s2) * s2, -(floor_div(-c.y, s2) * s2))


## top-right, bottom-right, top-left, bottom-left
static func children_of(p: Vector2i, zoom: int) -> Array[Vector2i]:
	var s := 1 << zoom
	return [Vector2i(p.x + s, p.y), Vector2i(p.x + s, p.y - s), Vector2i(p.x, p.y), Vector2i(p.x, p.y - s)]


## RGBA8 bytes of a child given as Image, WebP bytes or null (absent).
static func _bytes_of(v: Variant) -> PackedByteArray:
	if v is Image:
		return (v as Image).get_data()
	if v is PackedByteArray:
		var img := TileStore.decode(v)
		return img.get_data() if img != null else PackedByteArray()
	return PackedByteArray()


## Reference implementation of the shader: 4 children (RGBA8 bytes or empty) -> parent RGBA8 bytes.
static func combine_cpu(kids: Array) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(T * T * 4)
	var half := T / 2
	for i in 4:
		var src: PackedByteArray = kids[i]
		if src.is_empty():
			continue
		var ox := 0 if (i >> 1) != 0 else half
		var oy := (i & 1) * half
		for y in half:
			for x in half:
				var s := ((y * 2) * T + x * 2) * 4
				var d := ((oy + y) * T + ox + x) * 4
				for c in 4:
					out[d + c] = (src[s + c] + src[s + 4 + c] + src[s + T * 4 + c] + src[s + T * 4 + 4 + c]) >> 2
	return out


## kids_list: per parent four RGBA8 byte arrays (empty = absent) -> one RGBA8 byte array per parent.
func combine(kids_list: Array) -> Array:
	var out := []
	if rd == null:
		for kids in kids_list:
			out.append(combine_cpu(kids))
		return out
	var n := kids_list.size()
	var zero := PackedByteArray()
	zero.resize(T * T * 4)
	var src := PackedByteArray()
	for kids in kids_list:
		for k in 4:
			src.append_array(kids[k] if not (kids[k] as PackedByteArray).is_empty() else zero)
	var src_buf := rd.storage_buffer_create(src.size(), src)
	var dst_buf := rd.storage_buffer_create(n * T * T * 4)
	var set_rid := rd.uniform_set_create([_ssbo(0, src_buf), _ssbo(1, dst_buf)], _shader, 0)
	var cl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, _pipe)
	rd.compute_list_bind_uniform_set(cl, set_rid, 0)
	rd.compute_list_dispatch(cl, T / 8, T / 8, n)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	var bytes := rd.buffer_get_data(dst_buf)
	for r in [set_rid, src_buf, dst_buf]:
		rd.free_rid(r)
	for i in n:
		out.append(bytes.slice(i * T * T * 4, (i + 1) * T * T * 4))
	return out


func _ssbo(binding: int, id: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = binding
	u.add_id(id)
	return u


## Bookkeeping for one batch of parents at one level: per parent, whether its row is written ("write"), an
## existing row is dropped because the parent came out blank ("drop"), the parent is blank and has no row
## ("absent") or the stored row already matches ("same"). Every parent of the batch is in "next_keys": every
## processed parent propagates to the next level regardless of its outcome, because a missing parent can only
## be created while its children are being processed. If unchanged children stopped propagating, a parent that
## was never built (or was lost) would stay missing forever, and a higher parent would bake the absence in as a
## transparent quadrant. "hashes" carries the combined hash of every non-blank parent.
static func plan_level(batch: Array, combined: Array, old: Dictionary) -> Dictionary:
	var action: Array[String] = []
	var hashes: Array[int] = []
	var next_keys := {}
	for i in batch.size():
		var p: Vector2i = batch[i]
		next_keys[p] = true
		var px: PackedByteArray = combined[i]
		if TileCodec.is_blank(px):
			action.append("drop" if old.has(p) else "absent")
			hashes.append(0)
			continue
		var h := TileCodec.crc_hash(px)
		hashes.append(h)
		action.append("same" if old.get(p, -1) == h else "write")
	return {"action": action, "hashes": hashes, "next_keys": next_keys}


## keys: Vector2i -> true, the zoom-0 tiles that changed. known: Vector2i -> Image (new content) or null (deleted).
## zoom_all: also re-check every parent that exists (scans whole levels; fixes stale quadrants and orphans)
## and, because every processed parent propagates (plan_level), creates the parents that are missing, so a
## zoom_all pass leaves no existing tile without its parent.
func rebuild(keys: Dictionary, known: Dictionary, zoom_max: int, zoom_all: bool, now_ms: int) -> void:
	var level_keys := keys.duplicate()
	var level_known := known.duplicate()
	if zoom_all:
		for c in store.all_hashes(0):
			level_keys[c] = true
		_log("zoom-all: %d zoom-0 tiles in the database" % level_keys.size())
	for zoom in zoom_max:
		var parent_set := {}
		for c: Vector2i in level_keys:
			parent_set[parent_of(c, zoom)] = true
		var old := {}
		if zoom_all:
			old = store.all_hashes(zoom + 1)
			for p in old:
				parent_set[p] = true
		var parents: Array = parent_set.keys()
		if parents.is_empty():
			break
		parents.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return a.x < b.x or (a.x == b.x and a.y < b.y))
		if not zoom_all:
			old = store.hashes(zoom + 1, parents)
		var next_keys := {}
		var next_known := {}
		var written := 0
		var deleted := 0
		for b in range(0, parents.size(), BATCH):
			var batch := parents.slice(b, mini(b + BATCH, parents.size()))
			var need := {}
			for p: Vector2i in batch:
				for c in children_of(p, zoom):
					if not level_known.has(c):
						need[c] = true
			var fetched := store.read_images(zoom, need.keys()) if not need.is_empty() else {}
			var kids_list := []
			for p: Vector2i in batch:
				var kids := []
				for c in children_of(p, zoom):
					kids.append(_bytes_of(level_known[c] if level_known.has(c) else fetched.get(c)))
				kids_list.append(kids)
			var combined := combine(kids_list)
			var plan := plan_level(batch, combined, old)
			var writes := []
			var drops: Array[Vector2i] = []
			for i in batch.size():
				var p: Vector2i = batch[i]
				next_keys[p] = true
				match plan["action"][i]:
					"write":
						var webp := TileCodec.encode_webp(Image.create_from_data(T, T, false, Image.FORMAT_RGBA8, combined[i]))
						writes.append({"x": p.x, "y": p.y, "hash": plan["hashes"][i], "webp": webp})
						next_known[p] = webp
					"drop":
						drops.append(p)
						next_known[p] = null
					"absent":
						next_known[p] = null
					_:  # "same": the stored row stands; the next level reads it back when it needs it
						pass
			store.write(zoom + 1, writes, now_ms)
			store.delete(zoom + 1, drops)
			written += writes.size()
			deleted += drops.size()
			if store.error != "":
				_log("zoom %d: database error: %s" % [zoom + 1, store.error])
				return
		_log("zoom %d: wrote %d, deleted %d (of %d parents)" % [zoom + 1, written, deleted, parents.size()])
		level_keys = next_keys
		level_known = next_known
