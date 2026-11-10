class_name ShotApi
extends RefCounted
## The HTTP front of the render API (docs/render-api.md), served by the resident watch process
## when it is started with --api-port: POST /v1/render draws one perspective picture of a map,
## GET /v1/maps lists the served maps, GET /v1/health answers 204. The API is a general
## renderer capability: callers name a map, a camera and an image size and receive a PNG plus
## the camera transform; annotations and other caller-specific overlays are computed by the
## caller from that transform.
##
## The watch loop drives this object: poll() moves bytes (accept, read, write) and runs in the
## loop's rest slices, serve_step() renders the queued requests between tile batches. "high"
## priority requests are all served in a step, "normal" ones only a few per step, so a batch
## of background frames cannot starve the tile updater. Identical requests are answered from
## a small in-memory cache (10 s), and meshes stay cached across a sequence of frames.

const MAX_HEAD := 16384
const MAX_BODY := 65536
const MAX_DIM := 4096
const CACHE_TTL := 10.0
const CACHE_MAX := 32
const NORMALS_PER_STEP := 2
const CONN_TIMEOUT := 30.0

var pool: RendererPool
var maps: Array = []  # of MapDef

var _server := TCPServer.new()
var _conns := {}  # StreamPeerTCP -> {"state", "buf", "need", "out", "touched"}
var _queue := []  # of {"conn", "params", "priority", "key"}
var _cache := {}  # key -> {"at", "body"}
var _cache_order := []


func start(port: int) -> bool:
	var err := _server.listen(port)
	if err != OK:
		push_error("render api: cannot listen on port %d (%s)" % [port, error_string(err)])
		return false
	Term.say("render api listening on port %d" % port)
	return true


func register(def: MapDef) -> void:
	maps.append(def)


func _find_map(sel: String) -> MapDef:
	for d in maps:
		if d.name == sel or str(d.id) == sel:
			return d
	return null


## Moves bytes only. Called from the watch loop's rest slices and serve_step.
func poll() -> void:
	while _server.is_connection_available():
		var c := _server.take_connection()
		if c != null:
			_conns[c] = {"state": "head", "buf": PackedByteArray(), "need": 0, "out": PackedByteArray(), "touched": Time.get_unix_time_from_system()}
	for c in _conns.keys():
		_step(c)


## Renders queued requests between tile batches: every high-priority one, then a few normal.
func serve_step() -> void:
	poll()
	if _queue.is_empty():
		return
	var jobs := _queue
	_queue = []
	var normals := []
	for job in jobs:
		if job["priority"] == "high":
			_answer(job)
		else:
			normals.append(job)
	var n := 0
	for job in normals:
		if n < NORMALS_PER_STEP:
			_answer(job)
			n += 1
		else:
			_queue.append(job)
	poll()


func _step(c: StreamPeerTCP) -> void:
	c.poll()
	if c.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		_conns.erase(c)
		return
	var st: Dictionary = _conns[c]
	# "queued" is exempt: the caller waits for the render step on purpose, its own
	# client-side timeout is the bound there
	if Time.get_unix_time_from_system() - float(st["touched"]) > CONN_TIMEOUT and st["state"] != "write" and st["state"] != "queued":
		c.disconnect_from_host()
		_conns.erase(c)
		return
	var avail := c.get_available_bytes()
	if avail > 0:
		# get_partial_data: get_data reports ERR_FILE_EOF for a short read and the bytes
		# would be dropped; a request usually arrives in fragments smaller than the ask.
		# The buffer is assigned back because a PackedByteArray read out of a Dictionary
		# is copy-on-write: appending to the copy would never grow the stored buffer.
		var got := c.get_partial_data(mini(avail, MAX_BODY + MAX_HEAD))
		if not (got[1] as PackedByteArray).is_empty():
			st["touched"] = Time.get_unix_time_from_system()
			var grown: PackedByteArray = st["buf"]
			grown.append_array(got[1])
			st["buf"] = grown
	if st["state"] == "head":
		var buf: PackedByteArray = st["buf"]
		var end := _find_header_end(buf)
		if end < 0:
			if buf.size() > MAX_HEAD:
				_reply(c, st, 431, {"error": "headers too large"})
			return
		_on_headers(c, st, end)
	elif st["state"] == "body":
		if (st["buf"] as PackedByteArray).size() >= st["need"]:
			_on_body(c, st)
	if st["state"] == "write":
		var out: PackedByteArray = st["out"]
		if not out.is_empty():
			var sent := c.put_partial_data(out)
			if sent[0] == OK:
				st["out"] = out.slice(int(sent[1]))
				st["touched"] = Time.get_unix_time_from_system()
		if (st["out"] as PackedByteArray).is_empty():
			c.disconnect_from_host()
			_conns.erase(c)


static func _find_header_end(buf: PackedByteArray) -> int:
	for i in range(0, buf.size() - 3):
		if buf[i] == 13 and buf[i + 1] == 10 and buf[i + 2] == 13 and buf[i + 3] == 10:
			return i + 4
	return -1


func _on_headers(c: StreamPeerTCP, st: Dictionary, head_end: int) -> void:
	var head := (st["buf"] as PackedByteArray).slice(0, head_end).get_string_from_utf8()
	var lines := head.split("\r\n")
	var parts := lines[0].split(" ")
	if parts.size() < 2:
		_reply(c, st, 400, {"error": "bad request line"})
		return
	var method := parts[0]
	var path := parts[1]
	var length := 0
	for ln in lines.slice(1):
		var kv := ln.split(":", true, 1)
		if kv.size() == 2 and kv[0].strip_edges().to_lower() == "content-length":
			length = int(kv[1].strip_edges())
	st["buf"] = (st["buf"] as PackedByteArray).slice(head_end)
	if method == "GET" and path == "/v1/health":
		_reply_raw(c, st, 204, PackedByteArray())
		return
	if method == "GET" and path == "/v1/maps":
		var list := []
		for d in maps:
			list.append({"name": d.name, "id": d.id})
		_reply(c, st, 200, {"maps": list})
		return
	if method == "POST" and path == "/v1/render":
		if length <= 0 or length > MAX_BODY:
			_reply(c, st, 413, {"error": "request body missing or too large"})
			return
		st["need"] = length
		st["state"] = "body"
		if (st["buf"] as PackedByteArray).size() >= length:
			_on_body(c, st)
		return
	_reply(c, st, 404, {"error": "not found"})


func _on_body(c: StreamPeerTCP, st: Dictionary) -> void:
	var body := (st["buf"] as PackedByteArray).slice(0, st["need"]).get_string_from_utf8()
	st["state"] = "queued"
	var parsed = JSON.parse_string(body)
	if not parsed is Dictionary:
		_reply(c, st, 400, {"error": "request is not a JSON object"})
		return
	var key := JSON.stringify(parsed)
	var hit = _cache.get(key)
	if hit != null and Time.get_unix_time_from_system() - float(hit["at"]) <= CACHE_TTL:
		_reply_raw(c, st, 200, hit["body"])
		return
	_queue.append({"conn": c, "params": parsed, "priority": str(parsed.get("priority", "normal")), "key": key})


func _answer(job: Dictionary) -> void:
	var c: StreamPeerTCP = job["conn"]
	if not _conns.has(c):
		return  # the caller went away while waiting
	var st: Dictionary = _conns[c]
	var res := _render(job["params"])
	if int(res["status"]) == 200:
		_cache[job["key"]] = {"at": Time.get_unix_time_from_system(), "body": res["body"]}
		_cache_order.append(job["key"])
		while _cache_order.size() > CACHE_MAX:
			_cache.erase(_cache_order.pop_front())
	_reply_raw(c, st, int(res["status"]), res["body"])


func _reply(c: StreamPeerTCP, st: Dictionary, status: int, obj: Dictionary) -> void:
	_reply_raw(c, st, status, JSON.stringify(obj).to_utf8_buffer())


func _reply_raw(c: StreamPeerTCP, st: Dictionary, status: int, body: PackedByteArray) -> void:
	var reason: String = {200: "OK", 204: "No Content", 400: "Bad Request", 404: "Not Found", 413: "Content Too Large", 431: "Request Header Fields Too Large", 500: "Internal Server Error"}.get(status, "OK")
	var head := "HTTP/1.1 %d %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % [status, reason, body.size()]
	st["out"] = head.to_utf8_buffer() + body
	st["state"] = "write"


static func _vec3(v: Variant, fallback: Vector3) -> Vector3:
	if v is Array and v.size() == 3:
		return Vector3(float(v[0]), float(v[1]), float(v[2]))
	return fallback


## Renders one request; returns {"status", "body"} with the API response as bytes.
func _render(params: Dictionary) -> Dictionary:
	var def := _find_map(str(params.get("map", "")))
	if def == null:
		return {"status": 400, "body": JSON.stringify({"error": "unknown map"}).to_utf8_buffer()}
	var width := int(params.get("width", 0))
	var height := int(params.get("height", 0))
	if width < 16 or height < 16 or width > MAX_DIM or height > MAX_DIM:
		return {"status": 400, "body": JSON.stringify({"error": "width/height out of range"}).to_utf8_buffer()}
	var sr := pool.shot_renderer(def.region_dir)
	if sr == null:
		return {"status": 500, "body": JSON.stringify({"error": "renderer unavailable"}).to_utf8_buffer()}
	var bg = params.get("background")
	if bg is Array and bg.size() >= 3:
		sr.background = Color(float(bg[0]) / 255.0, float(bg[1]) / 255.0, float(bg[2]) / 255.0, (float(bg[3]) / 255.0) if bg.size() >= 4 else 1.0)
	else:
		sr.background = Color(0, 0, 0, 0)
	sr.min_y = def.min_y
	sr.max_y = def.max_y
	var cam_raw = params.get("camera")
	var cam_in: Dictionary = cam_raw if cam_raw is Dictionary else {}
	var adjust: bool = params.get("adjust_height", cam_in.get("adjust_height", true))
	var aspect := float(width) / float(height)
	var cam: Dictionary
	var target: Vector3
	if cam_in.has("eye"):
		target = _vec3(cam_in.get("look_at", cam_in.get("target")), Vector3.ZERO)
		var eye := _vec3(cam_in.get("eye"), Vector3.ZERO)
		cam = ShotCamera.from_eye(eye, target, aspect, float(cam_in.get("fov", ShotCamera.DEFAULT_FOV)))
	else:
		target = _vec3(cam_in.get("target"), Vector3(0, 70, 0))
		var distance := float(cam_in.get("distance", 120.0))
		var rotation := float(cam_in.get("rotation", 0.0))
		var angle := float(cam_in.get("angle", 0.75))
		if adjust:
			target = sr.effective_target(target, distance, rotation, angle)
		cam = ShotCamera.orbit(target, distance, rotation, angle, aspect, float(cam_in.get("fov", ShotCamera.DEFAULT_FOV)))
	var dist := (cam["eye"] as Vector3).distance_to(cam["target"])
	var chunks := sr.shot_chunks(cam["vp"], cam["target"], dist)
	var t0 := Time.get_ticks_usec()
	var img := sr.render_shot(cam, width, height, chunks)
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	sr.next_generation()
	var png := img.save_png_to_buffer()
	var resp := {
		"image": Marshalls.raw_to_base64(png),
		"width": width,
		"height": height,
		"view": Array(cam["view"]),
		"projection": Array(cam["projection"]),
		"eye": [(cam["eye"] as Vector3).x, (cam["eye"] as Vector3).y, (cam["eye"] as Vector3).z],
		"target": [(cam["target"] as Vector3).x, (cam["target"] as Vector3).y, (cam["target"] as Vector3).z],
		"render_ms": ms,
	}
	return {"status": 200, "body": JSON.stringify(resp).to_utf8_buffer()}
