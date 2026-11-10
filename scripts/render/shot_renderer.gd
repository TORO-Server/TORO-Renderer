class_name ShotRenderer
extends IsoRenderer
## Perspective "photographs" of a map: the tile renderer's baked quads, atlas and shading,
## drawn through a real perspective camera (ShotCamera, docs/render-api.md). Chunk offsets are
## world coordinates here, not map offsets, and the tile path's top-down shortcut never applies.

## Colour the picture starts from (what shows where no block was drawn). Transparent by
## default; a caller compositing over its own backdrop (or matching another renderer's
## void colour) sets it per request.
var background := Color(0, 0, 0, 0)
var _shader_p := RID()
var _pipe_p_opaque := RID()
var _pipe_p_trans := RID()
## clip-space conversion for the Vulkan rasteriser: y flipped, GL depth [-1, 1] -> reversed
## [1, 0], so the greater-depth-wins test of the tile path keeps the nearest surface.
static var _VK := PackedFloat64Array([1, 0, 0, 0, 0, -1, 0, 0, 0, 0, -0.5, 0, 0, 0, 0.5, 1])


func setup_shot(reg_: StateRegistry, tbl: BlockTable, w: WorldReader) -> bool:
	if not setup(Persp.make("shot", 0.0, 90.0, 16), reg_, tbl, w):
		return false
	mesher.topdown = false
	gmesher.topdown = false
	_shader_p = _compile("res://shaders/raster_persp.glsl")
	return _shader_p.is_valid()


## Top surface height of a column (the highest non-air block's top, y + 1), or -1 when the
## chunk is not there. This is the height BlueMap's downward ray reports.
func top_at(x: int, z: int) -> float:
	var c := world.chunk(x >> 4, z >> 4)
	if c == null:
		return -1.0
	var y := mini(c.max_y() - 1, max_y)
	var lo := maxi(c.min_y(), min_y)
	while y >= lo:
		if reg.s_air[c.block(x & 15, y, z & 15)] == 0:
			return float(y + 1)
		y -= 1
	return -1.0


## BlueMap's settled orbit target (docs/render-api.md): the web app does not use the given
## target height; every frame it raises the target over the terrain, and a settled screenshot
## shows the adjusted one. Computed from the world data with the same rule.
func effective_target(target: Vector3, distance: float, rotation: float, angle: float) -> Vector3:
	var terrain := top_at(floori(target.x), floori(target.z))
	if terrain < 0.0:
		return target
	var by_distance := lerpf(terrain + 3.0, 0.0, minf(distance / 500.0, 1.0))
	var max_angle := clampf((1.0 - sqrt(maxf(distance - 5.0, 0.001) * 0.0005)) * PI / 2.0, 0.0, PI / 2.0)
	var min_camera := 0.0
	if max_angle >= 0.1:
		var ex := target.x - sin(rotation) * sin(angle) * distance
		var ez := target.z + cos(rotation) * sin(angle) * distance
		var cam_h := top_at(floori(ex), floori(ez))
		if cam_h >= 0.0:
			min_camera = cam_h - cos(max_angle) * distance + 1.0
	return Vector3(target.x, maxf(by_distance, min_camera), target.z)


## Chunk columns whose (min_y..max_y) box can intersect the camera frustum. The search is
## bounded to target +/- (distance + 64) and a hard radius, so a far camera cannot pull in
## the whole map.
func shot_chunks(vp: PackedFloat64Array, target: Vector3, distance: float) -> Array[Vector2i]:
	var rows := []
	for i in 4:
		rows.append(Vector4(vp[i], vp[4 + i], vp[8 + i], vp[12 + i]))
	var planes := []
	for d in [[3, 0, 1.0], [3, 0, -1.0], [3, 1, 1.0], [3, 1, -1.0], [3, 2, 1.0], [3, 2, -1.0]]:
		var a: Vector4 = rows[d[0]]
		var b: Vector4 = rows[d[1]]
		var s: float = d[2]
		planes.append(Vector4(a.x + s * b.x, a.y + s * b.y, a.z + s * b.z, a.w + s * b.w))
	var reach := minf(distance + 64.0, 1200.0)
	var out: Array[Vector2i] = []
	var cx0 := floori((target.x - reach) / 16.0)
	var cx1 := floori((target.x + reach) / 16.0)
	var cz0 := floori((target.z - reach) / 16.0)
	var cz1 := floori((target.z + reach) / 16.0)
	for cz in range(cz0, cz1 + 1):
		for cx in range(cx0, cx1 + 1):
			var x0 := cx * 16.0
			var z0 := cz * 16.0
			var inside := true
			for pl in planes:
				var px := x0 + 16.0 if pl.x >= 0.0 else x0
				var py := float(max_y) if pl.y >= 0.0 else float(min_y)
				var pz := z0 + 16.0 if pl.z >= 0.0 else z0
				if pl.x * px + pl.y * py + pl.z * pz + pl.w < 0.0:
					inside = false
					break
			if inside:
				out.append(Vector2i(cx, cz))
	return out


## Draws one shot. cam is a ShotCamera result ({"vp", "view", ...}); chunks from shot_chunks().
func render_shot(cam: Dictionary, width: int, height: int, chunks: Array[Vector2i]) -> Image:
	var offs := PackedFloat32Array()
	for c in chunks:
		offs.append(float(c.x * 16))
		offs.append(0.0)
		offs.append(float(c.y * 16))
		offs.append(0.0)
	var view: PackedFloat64Array = cam["view"]
	# translucent order: back to front along the view direction (the negated view z row makes
	# the tile sorter's ascending order end with the nearest quad)
	var row2 := PackedFloat64Array([-view[2], -view[6], -view[10]])
	var g := gmesher.mesh(world, chunks, offs, row2, reg.water_tex, reg.lava_tex)
	var order := _sort_translucent(g["trans"], chunks, row2)
	var b_vf: RID = g["vf"]
	var b_vi: RID = g["vi"]
	var b_qc: RID = g["qchunk"]
	var nquads: int = g["nquads"]
	if nquads == 0:
		b_vf = _storage(PackedByteArray())
		b_vi = _storage(PackedByteArray())
		b_qc = _storage(PackedByteArray())
	var vp_vk := ShotCamera.multiply(_VK, cam["vp"])
	var bytes := _draw_persp(width, height, b_vf, b_vi, b_qc, offs, order, nquads, vp_vk)
	return Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, bytes)


func _ensure_pipes() -> void:
	if _pipe_p_opaque.is_valid():
		return
	_pipe_p_opaque = _make_persp_pipeline(false)
	_pipe_p_trans = _make_persp_pipeline(true)


func _make_persp_pipeline(trans: bool) -> RID:
	var rs := RDPipelineRasterizationState.new()
	rs.cull_mode = RenderingDevice.POLYGON_CULL_DISABLED  # block models emit single-sided faces
	var ms := RDPipelineMultisampleState.new()
	var ds := RDPipelineDepthStencilState.new()
	ds.enable_depth_test = true
	ds.enable_depth_write = not trans
	ds.depth_compare_operator = RenderingDevice.COMPARE_OP_GREATER
	var cb := RDPipelineColorBlendState.new()
	var att := RDPipelineColorBlendStateAttachment.new()
	if trans:
		att.enable_blend = true
		att.src_color_blend_factor = RenderingDevice.BLEND_FACTOR_ONE
		att.dst_color_blend_factor = RenderingDevice.BLEND_FACTOR_ONE_MINUS_SRC_ALPHA
		att.color_blend_op = RenderingDevice.BLEND_OP_ADD
		att.src_alpha_blend_factor = RenderingDevice.BLEND_FACTOR_ONE
		att.dst_alpha_blend_factor = RenderingDevice.BLEND_FACTOR_ONE_MINUS_SRC_ALPHA
		att.alpha_blend_op = RenderingDevice.BLEND_OP_ADD
	cb.attachments = [att]
	var sc := RDPipelineSpecializationConstant.new()
	sc.constant_id = 0
	sc.value = trans
	return rd.render_pipeline_create(_shader_p, _fb_format, RenderingDevice.INVALID_FORMAT_ID, RenderingDevice.RENDER_PRIMITIVE_TRIANGLES, rs, ms, ds, cb, 0, 0, [sc])


## The perspective twin of _draw (same buffers, atlas, finish pass and readback).
func _draw_persp(w: int, h: int, b_vf: RID, b_vi: RID, b_qc: RID, offs: PackedFloat32Array, order: PackedInt32Array, nquads: int, vp_vk: PackedFloat64Array) -> PackedByteArray:
	var fbd := _get_fb(w, h)
	_ensure_pipes()
	var u := PackedFloat32Array()
	for i in 16:
		u.append(float(vp_vk[i]))
	u.append_array(PackedFloat32Array([float(w), float(h), 0.0, 0.0]))
	var ui := PackedInt32Array([16, ATLAS_COLS, 0, 0])
	ui.append_array(_shadow)
	var ubytes := u.to_byte_array()
	ubytes.append_array(ui.to_byte_array())
	var ubuf := rd.uniform_buffer_create(ubytes.size(), ubytes)
	var b_off := _storage(offs.to_byte_array())
	var b_order := _storage(order.to_byte_array())
	var uset := rd.uniform_set_create([
		_u(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER, 0, [ubuf]),
		_u(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 1, [_sampler, _atlas]),
		_u(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 2, [b_vf]),
		_u(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 3, [b_vi]),
		_u(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 4, [b_off]),
		_u(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 5, [b_order]),
		_u(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 6, [b_qc]),
	], _shader_p, 0)
	var out_buf := rd.storage_buffer_create(w * h * 4)
	var fin_set := rd.uniform_set_create([
		_u(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 0, [_sampler, fbd["color"]]),
		_u(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 1, [out_buf]),
	], _finish_shader, 0)
	var dl := rd.draw_list_begin(fbd["fb"], RenderingDevice.DRAW_CLEAR_COLOR_ALL | RenderingDevice.DRAW_CLEAR_DEPTH, PackedColorArray([background]), 0.0)
	if nquads > 0:
		rd.draw_list_bind_uniform_set(dl, uset, 0)
		rd.draw_list_bind_render_pipeline(dl, _pipe_p_opaque)
		rd.draw_list_draw(dl, false, 1, nquads * 6)
		if order.size() > 0:
			rd.draw_list_bind_render_pipeline(dl, _pipe_p_trans)
			rd.draw_list_draw(dl, false, 1, order.size() * 6)
	rd.draw_list_end()
	var pc := PackedInt32Array([w, h, 0, 0]).to_byte_array()
	var cl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, _finish_pipe)
	rd.compute_list_bind_uniform_set(cl, fin_set, 0)
	rd.compute_list_set_push_constant(cl, pc, pc.size())
	rd.compute_list_dispatch(cl, ceili(w / 8.0), ceili(h / 8.0), 1)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	var bytes := rd.buffer_get_data(out_buf)
	for r in [fin_set, uset, out_buf, b_order, b_off, b_qc, b_vi, b_vf, ubuf]:
		rd.free_rid(r)
	return bytes

