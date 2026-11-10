class_name ShotCamera
extends RefCounted
## Perspective camera maths for still images ("shots"), in the conventions of the three.js
## camera the BlueMap web app uses: right-handed view space (the camera looks down -z) and
## matrices as 16 column-major elements, the order of three.js Matrix4.elements. An orbit
## camera is described the BlueMap way: a target point, a distance, a rotation (azimuth,
## radians) and an angle (polar angle from +y, radians). See docs/render-api.md.

const DEFAULT_FOV := 75.0


## Orbit parameters -> {"eye", "target", "view", "projection", "vp"} (matrices are
## PackedFloat64Array(16), column-major). Near and far follow BlueMap's rule for the distance.
static func orbit(target: Vector3, distance: float, rotation: float, angle: float, aspect: float, fov := DEFAULT_FOV) -> Dictionary:
	var eye := target + Vector3(-sin(rotation) * sin(angle), cos(angle), cos(rotation) * sin(angle)) * distance
	var near := clampf(distance / 1000.0, 0.01, 1.0)
	var far := clampf(2.0 * distance, maxf(near + 1.0, 2000.0), distance + 5000.0)
	if far - near > 10000.0:
		far = near + 10000.0
	var cam := from_eye(eye, target, aspect, fov)
	cam["near"] = near
	cam["far"] = far
	return cam


## Explicit camera: eye, the point it looks at, the image aspect ratio and a vertical field of
## view. Near/far are derived from the eye-target distance with the same rule as orbit().
static func from_eye(eye: Vector3, target: Vector3, aspect: float, fov := DEFAULT_FOV) -> Dictionary:
	var distance := eye.distance_to(target)
	var near := clampf(distance / 1000.0, 0.01, 1.0)
	var far := clampf(2.0 * distance, maxf(near + 1.0, 2000.0), distance + 5000.0)
	if far - near > 10000.0:
		far = near + 10000.0
	var view := look_at(eye, target, Vector3.UP)
	var proj := perspective(fov, aspect, near, far)
	return {"eye": eye, "target": target, "view": view, "projection": proj, "vp": multiply(proj, view), "near": near, "far": far}


## three.js Matrix4.lookAt: the view matrix (column-major) of a camera at eye looking at
## target. A target equal to the eye falls back to looking down -z.
static func look_at(eye: Vector3, target: Vector3, up: Vector3) -> PackedFloat64Array:
	var z := eye - target
	z = z.normalized() if z.length() > 1e-9 else Vector3(0, 0, 1)
	var x := up.cross(z)
	x = x.normalized() if x.length() > 1e-6 else Vector3(1, 0, 0)
	var y := z.cross(x)
	return PackedFloat64Array([
		x.x, y.x, z.x, 0.0,
		x.y, y.y, z.y, 0.0,
		x.z, y.z, z.z, 0.0,
		-x.dot(eye), -y.dot(eye), -z.dot(eye), 1.0])


## three.js PerspectiveCamera projection matrix (column-major); fov in degrees.
static func perspective(fov_deg: float, aspect: float, near: float, far: float) -> PackedFloat64Array:
	var f := 1.0 / tan(deg_to_rad(fov_deg) * 0.5)
	var e := PackedFloat64Array()
	e.resize(16)
	e[0] = f / aspect
	e[5] = f
	e[10] = (far + near) / (near - far)
	e[11] = -1.0
	e[14] = 2.0 * far * near / (near - far)
	return e


## a * b for column-major 16-element matrices.
static func multiply(a: PackedFloat64Array, b: PackedFloat64Array) -> PackedFloat64Array:
	var e := PackedFloat64Array()
	e.resize(16)
	for col in 4:
		for row in 4:
			var s := 0.0
			for k in 4:
				s += a[k * 4 + row] * b[col * 4 + k]
			e[col * 4 + row] = s
	return e
