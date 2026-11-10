class_name Publisher
extends RefCounted
## Writes rendered zoom-0 tiles to the tile table with these rules:
##  * a tile is wanted when it is a candidate (inside the planned set) or already has a row; with only_missing, when it is
##    a candidate without a row;
##  * an unchanged HashCode is skipped, a blank tile deletes an existing row.

var store: TileStore
## sorted tile keys of the plan; empty = every rendered tile is a candidate
var candidates := PackedInt64Array()
var only_missing := false
## mega tile size of the caller's plan; only used to group still-missing tiles in the result
var mega := 8


func _init(store_: TileStore) -> void:
	store = store_


## Mega tile -> how many of its tiles are in `wanted_blank` (candidate tiles without a row that rendered
## blank in an only-missing upload). Pure bookkeeping for upload(); see its result.
static func still_megas(wanted_blank: Array, mega_: int) -> Dictionary:
	var out := {}
	for xy: Vector2i in wanted_blank:
		var m := Vector2i(ZoomBuilder.floor_div(xy.x, mega_), ZoomBuilder.floor_div(xy.y, mega_))
		out[m] = int(out.get(m, 0)) + 1
	return out


## tiles: Vector2i -> null | {"img", "hash"}. Returns {"changed": Vector2i -> Image|null, "text": summary}.
## In only-missing mode the result also carries "still_megas" (see still_megas()): mega tiles whose missing
## candidates rendered blank, so they are still missing. A tile can render blank because its chunk could not
## be read this time, not because it has no content; the caller leaves those mega tiles out of its done set
## so a later run tries them again instead of treating the hole as repaired.
func upload(tiles: Dictionary, now_ms: int) -> Dictionary:
	var existing := store.hashes(0, tiles.keys())
	var changed := {}
	var writes := []
	var drops: Array[Vector2i] = []
	var wanted_blank: Array[Vector2i] = []
	var same := 0
	var blank := 0
	for xy: Vector2i in tiles:
		var is_cand := candidates.is_empty() or Planner.has(candidates, xy.x, xy.y)
		var wanted := (is_cand and not existing.has(xy)) if only_missing else (is_cand or existing.has(xy))
		if not wanted:
			continue
		var t = tiles[xy]
		if t == null:
			blank += 1
			if existing.has(xy):
				drops.append(xy)
				changed[xy] = null
			elif only_missing:
				wanted_blank.append(xy)
			continue
		if existing.get(xy, -1) == t["hash"]:
			same += 1
			continue
		writes.append({"x": xy.x, "y": xy.y, "hash": t["hash"], "webp": TileCodec.encode_webp(t["img"])})
		changed[xy] = t["img"]
	store.write(0, writes, now_ms)
	store.delete(0, drops)
	var res := {"changed": changed, "text": "zoom 0: wrote %d, deleted %d, unchanged %d, blank %d" % [writes.size(), drops.size(), same, blank]}
	if only_missing and not wanted_blank.is_empty():
		res["still_megas"] = still_megas(wanted_blank, mega)
	return res
