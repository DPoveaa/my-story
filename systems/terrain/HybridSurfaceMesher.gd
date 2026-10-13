class_name HybridSurfaceMesher
extends RefCounted

## Castle Story–style hybrid surface mesher.
## Authoritative data remains the discrete TYPE voxel grid.
## Only the top face of each column’s topmost solid voxel is smoothed via shared
## corner heights. Slopes are limited to ~1:1; steeper jumps become vertical cliffs.
## Side / underside / cave faces stay angular voxel facets.
## Built-in VoxelMesherBlocky / Transvoxel cannot express this hybrid; this is the
## smallest GDScript mesh+collision path driven by the same voxel data.

const BLOCK_AIR: int = 0
const BLOCK_GRASS: int = 1
const BLOCK_DIRT: int = 2
const BLOCK_STONE: int = 3
const BLOCK_COAL: int = 4
const BLOCK_IRON: int = 5
const BLOCK_GOLD: int = 6

const BLOCK_NAMES: Array[StringName] = [
	&"", &"grass", &"dirt", &"stone", &"coal", &"iron", &"gold"
]

## types: padded flat array, size (sx+2)*(sy+2)*(sz+2), local coords in [-1, size]
## Index: ((x+1)*(sy+2)+(y+1))*(sz+2)+(z+1)
static func build(
	types: PackedByteArray,
	size: Vector3i
) -> Dictionary:
	var sx: int = size.x
	var sy: int = size.y
	var sz: int = size.z
	var py: int = sy + 2
	var pz: int = sz + 2

	var top_y: PackedInt32Array = PackedInt32Array()
	var col_w: int = sx + 2
	var col_d: int = sz + 2
	top_y.resize(col_w * col_d)
	top_y.fill(-1)

	for lx in range(-1, sx + 1):
		for lz in range(-1, sz + 1):
			var cidx: int = (lx + 1) * col_d + (lz + 1)
			var found_top: int = -1
			for ly in range(sy, -2, -1):
				if _type_at(types, lx, ly, lz, py, pz) != BLOCK_AIR:
					found_top = ly
					break
			top_y[cidx] = found_top

	# Shared corner heights at integer grid points [0..sx] x [0..sz] in local space.
	var corner: PackedFloat32Array = PackedFloat32Array()
	corner.resize((sx + 1) * (sz + 1))
	for cx in range(sx + 1):
		for cz in range(sz + 1):
			corner[cx * (sz + 1) + cz] = _shared_corner_height(top_y, col_d, cx, cz)

	var mat_buffers: Dictionary = {}
	var col_faces: PackedVector3Array = PackedVector3Array()

	for lx in range(sx):
		for ly in range(sy):
			for lz in range(sz):
				var b_id: int = _type_at(types, lx, ly, lz, py, pz)
				if b_id == BLOCK_AIR:
					continue
				var is_top: bool = (top_y[(lx + 1) * col_d + (lz + 1)] == ly)
				var buf: Dictionary = _buf(mat_buffers, b_id)

				# +Y: smooth shared-corner top on column surface; flat elsewhere (caves/ledges).
				if _type_at(types, lx, ly + 1, lz, py, pz) == BLOCK_AIR:
					if is_top:
						var h00: float = _corner_for_cell(corner, sz, lx, lz, ly)
						var h10: float = _corner_for_cell(corner, sz, lx + 1, lz, ly)
						var h01: float = _corner_for_cell(corner, sz, lx, lz + 1, ly)
						var h11: float = _corner_for_cell(corner, sz, lx + 1, lz + 1, ly)
						_append_top_quad(
							buf["verts"], buf["norms"], buf["uvs"], col_faces,
							float(lx), float(lz), h00, h10, h01, h11
						)
						_emit_top_skirts(
							types, top_y, col_d, mat_buffers, col_faces,
							lx, lz, ly, h00, h10, h01, h11, py, pz
						)
					else:
						_append_axis_face(
							buf["verts"], buf["norms"], buf["uvs"], col_faces,
							Vector3(float(lx), float(ly + 1), float(lz)),
							Vector3(float(lx + 1), float(ly + 1), float(lz)),
							Vector3(float(lx + 1), float(ly + 1), float(lz + 1)),
							Vector3(float(lx), float(ly + 1), float(lz + 1)),
							Vector3.UP
						)

				# -Y underside / cave floors
				if _type_at(types, lx, ly - 1, lz, py, pz) == BLOCK_AIR:
					_append_axis_face(
						buf["verts"], buf["norms"], buf["uvs"], col_faces,
						Vector3(float(lx), float(ly), float(lz)),
						Vector3(float(lx), float(ly), float(lz + 1)),
						Vector3(float(lx + 1), float(ly), float(lz + 1)),
						Vector3(float(lx + 1), float(ly), float(lz)),
						Vector3.DOWN
					)

				# Angular ±X / ±Z — skip surface voxel edges (skirts already emitted).
				if is_top:
					continue
				if _type_at(types, lx + 1, ly, lz, py, pz) == BLOCK_AIR:
					_append_axis_face(
						buf["verts"], buf["norms"], buf["uvs"], col_faces,
						Vector3(float(lx + 1), float(ly), float(lz)),
						Vector3(float(lx + 1), float(ly), float(lz + 1)),
						Vector3(float(lx + 1), float(ly + 1), float(lz + 1)),
						Vector3(float(lx + 1), float(ly + 1), float(lz)),
						Vector3.RIGHT
					)
				if _type_at(types, lx - 1, ly, lz, py, pz) == BLOCK_AIR:
					_append_axis_face(
						buf["verts"], buf["norms"], buf["uvs"], col_faces,
						Vector3(float(lx), float(ly), float(lz + 1)),
						Vector3(float(lx), float(ly), float(lz)),
						Vector3(float(lx), float(ly + 1), float(lz)),
						Vector3(float(lx), float(ly + 1), float(lz + 1)),
						Vector3.LEFT
					)
				if _type_at(types, lx, ly, lz + 1, py, pz) == BLOCK_AIR:
					_append_axis_face(
						buf["verts"], buf["norms"], buf["uvs"], col_faces,
						Vector3(float(lx), float(ly), float(lz + 1)),
						Vector3(float(lx + 1), float(ly), float(lz + 1)),
						Vector3(float(lx + 1), float(ly + 1), float(lz + 1)),
						Vector3(float(lx), float(ly + 1), float(lz + 1)),
						Vector3.BACK
					)
				if _type_at(types, lx, ly, lz - 1, py, pz) == BLOCK_AIR:
					_append_axis_face(
						buf["verts"], buf["norms"], buf["uvs"], col_faces,
						Vector3(float(lx + 1), float(ly), float(lz)),
						Vector3(float(lx), float(ly), float(lz)),
						Vector3(float(lx), float(ly + 1), float(lz)),
						Vector3(float(lx + 1), float(ly + 1), float(lz)),
						Vector3.FORWARD
					)

	return {"surfaces": mat_buffers, "collision_faces": col_faces}


static func _type_at(types: PackedByteArray, x: int, y: int, z: int, py: int, pz: int) -> int:
	var ix: int = x + 1
	var iy: int = y + 1
	var iz: int = z + 1
	if iy < 0 or iy >= py or ix < 0 or iz < 0:
		return BLOCK_AIR
	var idx: int = (ix * py + iy) * pz + iz
	if idx < 0 or idx >= types.size():
		return BLOCK_AIR
	return types[idx]


static func _shared_corner_height(top_y: PackedInt32Array, col_d: int, cx: int, cz: int) -> float:
	## Average only the highest compatible cluster (within 1 voxel). Steeper neighbors
	## are excluded so cliff-edge corners stay high and 1:1 ramps stay continuous.
	var vals: Array[float] = []
	for dx in [-1, 0]:
		for dz in [-1, 0]:
			var cidx: int = (cx + dx + 1) * col_d + (cz + dz + 1)
			if cidx < 0 or cidx >= top_y.size():
				continue
			var t: int = top_y[cidx]
			if t < 0:
				continue
			vals.append(float(t + 1))
	if vals.is_empty():
		return 0.0
	var mx: float = vals[0]
	for v in vals:
		mx = maxf(mx, v)
	var sum: float = 0.0
	var count: float = 0.0
	for v2 in vals:
		if mx - v2 <= 1.0 + 1e-4:
			sum += v2
			count += 1.0
	if count < 1.0:
		return mx
	return sum / count


static func _corner_for_cell(
	corner: PackedFloat32Array, sz: int, cx: int, cz: int, cell_top: int
) -> float:
	var raw: float = corner[cx * (sz + 1) + cz]
	return clampf(raw, float(cell_top), float(cell_top + 1))


static func _emit_top_skirts(
	types: PackedByteArray,
	top_y: PackedInt32Array,
	col_d: int,
	mat_buffers: Dictionary,
	col_faces: PackedVector3Array,
	lx: int, lz: int, t: int,
	h00: float, h10: float, h01: float, h11: float,
	py: int, pz: int
) -> void:
	## Only the surface voxel’s side band (sloped edge → floor of this voxel).
	## Lower cliff strata are emitted as ordinary angular faces by the main loop.
	var dirs: Array = [
		{"nx": 1, "nz": 0, "a": h10, "b": h11, "x0": lx + 1, "z0": lz, "x1": lx + 1, "z1": lz + 1, "out": Vector3.RIGHT},
		{"nx": -1, "nz": 0, "a": h00, "b": h01, "x0": lx, "z0": lz + 1, "x1": lx, "z1": lz, "out": Vector3.LEFT},
		{"nx": 0, "nz": 1, "a": h01, "b": h11, "x0": lx, "z0": lz + 1, "x1": lx + 1, "z1": lz + 1, "out": Vector3.BACK},
		{"nx": 0, "nz": -1, "a": h00, "b": h10, "x0": lx + 1, "z0": lz, "x1": lx, "z1": lz, "out": Vector3.FORWARD},
	]
	var floor_y: float = float(t)
	for d in dirs:
		var ntop: int = top_y[(lx + int(d.nx) + 1) * col_d + (lz + int(d.nz) + 1)]
		var edge_lo: float = minf(float(d.a), float(d.b))
		var edge_hi: float = maxf(float(d.a), float(d.b))
		# Same-height or 1:1 ramp neighbor — top quad already forms the transition.
		if ntop >= t - 1:
			# Still close a thin band if the sloped edge sits above this voxel floor
			# and the neighbor doesn't cover the side (air / missing).
			if ntop >= t:
				continue
			# ntop == t-1: ramp; only emit if edge is above floor (partial side).
			if edge_lo <= floor_y + 1e-4:
				continue
		elif ntop >= 0 and ntop < t - 1:
			# Cliff: vertical drop from sloped edge to this voxel's floor; lower layers
			# continue the cliff via the main angular face pass.
			pass
		else:
			# Island rim / air neighbor — drop side to voxel floor.
			pass
		if edge_hi <= floor_y + 1e-4:
			continue
		var b_id: int = _type_at(types, lx, t, lz, py, pz)
		if b_id == BLOCK_AIR:
			continue
		var buf: Dictionary = _buf(mat_buffers, b_id)
		var y0: float = float(d.a)
		var y1: float = float(d.b)
		var v0 := Vector3(float(d.x0), y0, float(d.z0))
		var v1 := Vector3(float(d.x1), y1, float(d.z1))
		var v2 := Vector3(float(d.x1), floor_y, float(d.z1))
		var v3 := Vector3(float(d.x0), floor_y, float(d.z0))
		_append_axis_face(
			buf["verts"], buf["norms"], buf["uvs"], col_faces,
			v0, v1, v2, v3, d.out
		)


static func _buf(mat_buffers: Dictionary, b_id: int) -> Dictionary:
	var key: StringName = BLOCK_NAMES[b_id] if b_id >= 0 and b_id < BLOCK_NAMES.size() else &"stone"
	if key == &"":
		key = &"stone"
	if mat_buffers.has(key):
		return mat_buffers[key]
	var buf := {
		"verts": PackedVector3Array(),
		"norms": PackedVector3Array(),
		"uvs": PackedVector2Array(),
	}
	mat_buffers[key] = buf
	return buf


static func _append_top_quad(
	verts: PackedVector3Array, norms: PackedVector3Array, uvs: PackedVector2Array,
	col_faces: PackedVector3Array,
	x: float, z: float,
	h00: float, h10: float, h01: float, h11: float
) -> void:
	var v00 := Vector3(x, h00, z)
	var v10 := Vector3(x + 1.0, h10, z)
	var v11 := Vector3(x + 1.0, h11, z + 1.0)
	var v01 := Vector3(x, h01, z + 1.0)
	# Heightfield normals at corners so walkable tops shade smoothly across the cell.
	var n00 := Vector3(h00 - h10, 1.0, h00 - h01).normalized()
	var n10 := Vector3(h00 - h10, 1.0, h10 - h11).normalized()
	var n11 := Vector3(h01 - h11, 1.0, h10 - h11).normalized()
	var n01 := Vector3(h01 - h11, 1.0, h00 - h01).normalized()
	_append_tri_shaded(verts, norms, uvs, col_faces, v00, v10, v11, n00, n10, n11)
	_append_tri_shaded(verts, norms, uvs, col_faces, v00, v11, v01, n00, n11, n01)


static func _append_tri_shaded(
	verts: PackedVector3Array, norms: PackedVector3Array, uvs: PackedVector2Array,
	col_faces: PackedVector3Array,
	a: Vector3, b: Vector3, c: Vector3,
	na: Vector3, nb: Vector3, nc: Vector3
) -> void:
	var area_n: Vector3 = (b - a).cross(c - a)
	if area_n.length_squared() < 1e-12:
		return
	verts.append(a)
	verts.append(b)
	verts.append(c)
	norms.append(na)
	norms.append(nb)
	norms.append(nc)
	uvs.append(Vector2(a.x, a.z))
	uvs.append(Vector2(b.x, b.z))
	uvs.append(Vector2(c.x, c.z))
	col_faces.append(a)
	col_faces.append(b)
	col_faces.append(c)


static func _append_axis_face(
	verts: PackedVector3Array, norms: PackedVector3Array, uvs: PackedVector2Array,
	col_faces: PackedVector3Array,
	v0: Vector3, v1: Vector3, v2: Vector3, v3: Vector3,
	face_n: Vector3
) -> void:
	_append_tri(verts, norms, uvs, col_faces, v0, v1, v2, face_n)
	_append_tri(verts, norms, uvs, col_faces, v0, v2, v3, face_n)


static func _append_tri(
	verts: PackedVector3Array, norms: PackedVector3Array, uvs: PackedVector2Array,
	col_faces: PackedVector3Array,
	a: Vector3, b: Vector3, c: Vector3,
	flat_n: Vector3
) -> void:
	var n: Vector3
	if flat_n != Vector3.ZERO:
		n = flat_n.normalized()
	else:
		n = (b - a).cross(c - a)
		if n.length_squared() < 1e-12:
			return
		n = n.normalized()
	# Degenerate flat faces (zero area from matching edge heights).
	if flat_n != Vector3.ZERO:
		var area_n: Vector3 = (b - a).cross(c - a)
		if area_n.length_squared() < 1e-12:
			return
	verts.append(a)
	verts.append(b)
	verts.append(c)
	norms.append(n)
	norms.append(n)
	norms.append(n)
	uvs.append(Vector2(a.x, a.z))
	uvs.append(Vector2(b.x, b.z))
	uvs.append(Vector2(c.x, c.z))
	col_faces.append(a)
	col_faces.append(b)
	col_faces.append(c)


static func build_array_mesh(surfaces: Dictionary, materials: Dictionary) -> ArrayMesh:
	if surfaces.is_empty():
		return null
	var mesh := ArrayMesh.new()
	for mat_key in surfaces.keys():
		var buf: Dictionary = surfaces[mat_key]
		var verts: PackedVector3Array = buf["verts"]
		if verts.is_empty():
			continue
		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts
		arrays[Mesh.ARRAY_NORMAL] = buf["norms"]
		arrays[Mesh.ARRAY_TEX_UV] = buf["uvs"]
		var mat: Material = materials.get(mat_key, null)
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		if mat != null:
			mesh.surface_set_material(mesh.get_surface_count() - 1, mat)
	return mesh


static func make_materials(shader: Shader) -> Dictionary:
	var mats: Dictionary = {}
	mats[&"grass"] = _mat(shader, Color(0.33, 0.56, 0.27), 0.92, 0.0, 0.08, 0.35)
	mats[&"dirt"] = _mat(shader, Color(0.62, 0.40, 0.23), 0.94, 0.0, 0.10, 0.95)
	mats[&"stone"] = _mat(shader, Color(0.50, 0.46, 0.41), 0.90, 0.0, 0.14, 1.0)
	mats[&"coal"] = _mat(shader, Color(0.20, 0.20, 0.22), 0.92, 0.0, 0.12, 1.0)
	mats[&"iron"] = _mat(shader, Color(0.68, 0.66, 0.62), 0.55, 0.45, 0.35, 1.0)
	mats[&"gold"] = _mat(shader, Color(0.86, 0.70, 0.16), 0.40, 0.70, 0.45, 1.0)
	return mats


static func _mat(
	shader: Shader, albedo: Color, roughness: float, metallic: float, specular: float, facet: float
) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = shader
	m.set_shader_parameter("u_albedo", albedo)
	m.set_shader_parameter("u_roughness", roughness)
	m.set_shader_parameter("u_metallic", metallic)
	m.set_shader_parameter("u_specular", specular)
	m.set_shader_parameter("u_facet_strength", facet)
	return m
