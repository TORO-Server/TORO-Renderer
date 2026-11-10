# Still images and the render API

Besides map tiles, the renderer can draw a single still image ("shot") of a map area from a
perspective camera, and the resident `watch` process serves those renders over HTTP. Shots are a
general capability: a caller names a map, a camera and an image size, and receives a PNG plus the
camera transform, so any overlay or annotation can be computed on the caller's side. Nothing in
this design is specific to one caller; known callers are evidence capture (a caller that needs a
picture of one damaged spot, promptly) and background-video generation for a website (a caller
that needs many frames of a slow camera orbit, in batches).

## The camera

The shot camera uses the same terms as BlueMap's perspective view, so a view that exists as a
BlueMap link or a BlueMap screenshot can be reproduced exactly:

- `target`: the world position the camera looks at (`x`, `y`, `z`).
- `distance`: distance from the target to the camera, in blocks.
- `rotation`: azimuth in radians; 0 looks towards north, increasing values turn the view
  clockwise seen from above.
- `angle`: tilt in radians; 0 is straight down from above, π/2 is horizontal.
- `fov`: vertical field of view in degrees (75 when omitted, BlueMap's value).

The camera position is `target + distance * (-sin(rotation) * sin(angle), cos(angle),
cos(rotation) * sin(angle))`, looking at the target with the world up vector. The projection is
the perspective projection with that field of view and the image's aspect ratio; near and far
planes follow BlueMap's rule for the distance (`near = clamp(distance / 1000, 0.01, 1)`,
`far = clamp(2 * distance, max(near + 1, 2000), distance + 5000)`).

### The effective target height

BlueMap does not use the given target height as-is: its map controls raise the target to a
suggested height derived from the terrain, every frame, and a settled screenshot therefore shows
that adjusted target. The shot camera reproduces the same rule, computed from the world data
itself (the terrain height is the top surface at the column, found by the same downward ray the
web app casts):

```
terrain      = top surface height at (target.x, target.z)
targetHeight = terrain + 3
byDistance   = lerp(targetHeight, 0, min(distance / 500, 1))
maxAngle     = clamp((1 - sqrt(max(distance - 5, 0.001) * 0.0005)) * π/2, 0, π/2)
cameraHeight = top surface height at the camera's (x, z)
minCamera    = cameraHeight - cos(maxAngle) * distance + 1   (0 when maxAngle < 0.1)
target.y     = max(byDistance, minCamera)
```

Callers that already know the height they want (for example a caller that computed its target
from the thing it wants to show) can pass `adjust_height: false` to use the given target
unchanged. The transform in the response always describes the camera that was actually used.

## What a shot draws

A shot draws the same world the tiles draw — the region files, read directly — with the full
block models at their native 16-pixel textures:

- **Perspective projection** (above), at any image size, for example 1280×720 or 1920×1080.
- **Block-entity blocks.** Blocks whose shape the client draws from code rather than from a
  block model — chests, banners, skulls and heads, shulker boxes — are baked from built-in
  models that mirror the client's own geometry and entity textures, so they appear in shots
  (and in tiles) like they do in the game. Sign and bed shapes come from their block models as
  usual; sign *text* is not drawn (in the game it is a per-block label, and callers that
  photograph signs for evidence suppress it there as well).
- **`uvlock`.** Block-state variants with `uvlock: true` keep their texture fixed to the world
  while the model rotates, as the client does.

Lighting and shading are the renderer's own (the same model the tiles use), which is not the
web app's sun/ambient model; geometry, textures and the camera match, tones can differ slightly.

## The HTTP API

The `watch` process serves the API when started with `--api-port` (the port is a deployment
setting; nothing about it is baked into the program). Requests are JSON:

`POST /v1/render`

```json
{
  "map": "overworld",
  "camera": {"target": [100, 70, -40], "distance": 120, "rotation": -0.6, "angle": 0.75},
  "width": 1280,
  "height": 720,
  "priority": "high"
}
```

- `map` is the map's name from the watch configuration. Instead of an orbit camera, a request
  may give an explicit camera: `"camera": {"eye": [...], "look_at": [...], "up": [0, 1, 0],
  "fov": 75}`.
- `priority` is `"high"` or `"normal"` (default). The watch loop serves the render queue
  about once a second between tile batches: every high-priority request in that step, and a
  few normal-priority ones, so a long batch sequence cannot starve an urgent single shot;
  tile updates keep their own queue and are not starved either, because a shot takes about
  a second.
- `background` (optional) is `[r, g, b]` or `[r, g, b, a]` with values 0-255: the colour the
  picture starts from, i.e. what shows where no block was drawn. The default is transparent
  black. A caller that composites the PNG over its own backdrop, or that matches another
  renderer's void colour, sets it explicitly.
- The response is JSON: `image` (the PNG, base64), `width`, `height`, `view` and `projection`
  (the camera matrices, 16 numbers each, in the column-major order three.js uses for
  `Matrix4.elements`, over world coordinates), `eye` and `target` (the effective camera), and
  `render_ms`.

Batch use (for example one video frame after another) is ordinary repeated requests; identical
requests are answered from a small in-memory cache, and the chunk and mesh caches stay warm
between frames of a sequence, so a slow orbit costs one render per frame, not one world load.

`GET /v1/maps` lists the served maps. `GET /v1/health` answers 204.

The same render is available without the server as a one-off command, which is what batch jobs
and tests use:

```
godot --path . -s scripts/main.gd -- shot --region-dir /worlds/overworld/region \
    --target 100,70,-40 --distance 120 --rotation -0.6 --angle 0.75 \
    --size 1280x720 --out shot.png
```

It writes the PNG and a `<name>.json` with the same fields as the API response.

## Verification

Equivalence with the BlueMap screenshot path was measured on a synthetic test world (built
for this purpose, containing the block-entity blocks listed above, uvlock variants and a
damaged area) drawn two ways with the same camera: once by BlueMap itself (Paper + BlueMap,
screen-captured in a browser) and once by the shot renderer, at 1280×720. The renderer's
transparent void was composited over black, the void colour of the comparison capture.

- Damage view (distance 70, rotation -0.6, angle 0.75): the two pictures agree on which
  pixels show world (rather than void) for 94.9% of the pixels either one shows as world;
  88.9% of all pixels are within ±12 per channel and 97.0% within ±30; the mean
  maximum-channel difference over all pixels is 4.4 (of 255).
- Close-up view (distance 45, angle 0.9): world agreement 93.1%; 80.7% of pixels within ±12
  and 93.6% within ±30; mean maximum-channel difference 8.2.

The remaining differences are the shading and texture filtering of two independent
renderers, not the geometry or the camera: chests (single and double), the ender and trapped
chests, banners, skulls and heads, shulker boxes and the uvlock variants are present and
identifiable in both pictures at the same positions.

Rendering speed on the same machine (RTX 3060): a 1280×720 evidence view renders in about
0.4-0.9 s; a 1920×1080 background view at distance 420 renders in about 0.6-0.9 s. The API
answers a high-priority request in about 1.5 s end to end while the watch process is
otherwise idle.
