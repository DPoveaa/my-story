class_name VoxelChunk
extends StaticBody3D

## Individual 16x32x16 3D Voxel Chunk for procedural floating terrain islands.
## Stores flat 1D voxel data array and generates ArrayMesh and ConcavePolygonShape3D collision geometry.
## Node is positioned at its world-space chunk origin; mesh/collision geometry use chunk-local coordinates.
##
## PERFORMANCE NOTES:
## - build_mesh_data_from_flat() is the primary hot path; it runs exclusively on worker threads.
## - Greedy meshing merges adjacent same-material faces on the Y axis (top/bottom planes),
##   dramatically reducing vertex count for flat terrain (common case).
## - On X/Z faces we retain simple quad meshing; greedy on all axes is a future improvement.
## - buf["verts"] write-back is performed ONCE per material per face direction, not per-voxel.
## - apply_mesh_and_collision_data() runs on main thread under the per-frame time budget.

const SIZE_X: int = 16
const SIZE_Y: int = 32
const SIZE_Z: int = 16
const TOTAL_CELLS: int = SIZE_X * SIZE_Y * SIZE_Z  # 8192

## Block type byte IDs stored in the PackedByteArray voxels buffer.
## 0 = air (empty), 1 = grass, 2 = dirt, 3 = stone, 4 = coal, 5 = iron, 6 = gold
const BLOCK_AIR:   int = 0
const BLOCK_GRASS: int = 1
const BLOCK_DIRT:  int = 2
const BLOCK_STONE: int = 3
const BLOCK_COAL:  int = 4
const BLOCK_IRON:  int = 5
const BLOCK_GOLD:  int = 6

## Reverse lookup: block byte ID → StringName (preserves external API compatibility).
const BLOCK_NAMES: Array[StringName] = [&"", &"grass", &"dirt", &"stone", &"coal", &"iron", &"gold"]
## Forward lookup: StringName → block byte ID.
const BLOCK_IDS: Dictionary = {&"": 0, &"grass": 1, &"dirt": 2, &"stone": 3, &"coal": 4, &"iron": 5, &"gold": 6}

var chunk_pos: Vector2i = Vector2i.ZERO
var voxel_world: Node = null # Back reference to VoxelWorld for neighbor chunk lookups

## Flat 1D Voxel block PackedByteArray of size 8192: [lx * 512 + ly * 16 + lz] = byte block ID
## 8 KB per chunk vs ~196 KB for Array[StringName] — zero GC overhead, CPU cache-friendly.
var voxels: PackedByteArray
var _mesh_inst: MeshInstance3D = null
var _col_shape: CollisionShape3D = null

## Opaque StandardMaterial3D instances per material type
static var _materials: Dictionary = {}

static func _init_materials() -> void:
	if not _materials.is_empty():
		return

	var mat_grass := StandardMaterial3D.new()
	mat_grass.albedo_color = Color(0.28, 0.62, 0.24)
	mat_grass.roughness = 0.85
	mat_grass.cull_mode = BaseMaterial3D.CULL_BACK
	_materials[&"grass"] = mat_grass

	var mat_dirt := StandardMaterial3D.new()
	mat_dirt.albedo_color = Color(0.42, 0.30, 0.20)
	mat_dirt.roughness = 0.90
	mat_dirt.cull_mode = BaseMaterial3D.CULL_BACK
	_materials[&"dirt"] = mat_dirt

	var mat_stone := StandardMaterial3D.new()
	mat_stone.albedo_color = Color(0.52, 0.54, 0.58)
	mat_stone.roughness = 0.80
	mat_stone.cull_mode = BaseMaterial3D.CULL_BACK
	_materials[&"stone"] = mat_stone

	var mat_coal := StandardMaterial3D.new()
	mat_coal.albedo_color = Color(0.22, 0.22, 0.24)
	mat_coal.roughness = 0.90
	mat_coal.cull_mode = BaseMaterial3D.CULL_BACK
	_materials[&"coal"] = mat_coal

	var mat_iron := StandardMaterial3D.new()
	mat_iron.albedo_color = Color(0.72, 0.74, 0.78)
	mat_iron.roughness = 0.50
	mat_iron.metallic = 0.60
	mat_iron.cull_mode = BaseMaterial3D.CULL_BACK
	_materials[&"iron"] = mat_iron

	var mat_gold := StandardMaterial3D.new()
	mat_gold.albedo_color = Color(0.95, 0.78, 0.22)
	mat_gold.roughness = 0.30
	mat_gold.metallic = 0.80
	mat_gold.cull_mode = BaseMaterial3D.CULL_BACK
	_materials[&"gold"] = mat_gold

# ============================================================
# PRECOMPUTED FACE GEOMETRY TABLES (Zero-allocation quad meshing)
# ============================================================
const DIRS: Array[Vector3i] = [
	Vector3i(1, 0, 0),   # 0: +X Right
	Vector3i(-1, 0, 0),  # 1: -X Left
	Vector3i(0, 1, 0),   # 2: +Y Top
	Vector3i(0, -1, 0),  # 3: -Y Bottom
	Vector3i(0, 0, 1),   # 4: +Z Front
	Vector3i(0, 0, -1)   # 5: -Z Back
]

const NORMALS: Array[Vector3] = [
	Vector3(1, 0, 0),
	Vector3(-1, 0, 0),
	Vector3(0, 1, 0),
	Vector3(0, -1, 0),
	Vector3(0, 0, 1),
	Vector3(0, 0, -1)
]

const FACE_VERT_OFFSETS: Array = [
	# 0: +X Right (v0, v2, v1, v0, v3, v2)
	[Vector3(1, 0, 1), Vector3(1, 1, 0), Vector3(1, 0, 0), Vector3(1, 0, 1), Vector3(1, 1, 1), Vector3(1, 1, 0)],
	# 1: -X Left
	[Vector3(0, 0, 0), Vector3(0, 1, 1), Vector3(0, 0, 1), Vector3(0, 0, 0), Vector3(0, 1, 0), Vector3(0, 1, 1)],
	# 2: +Y Top
	[Vector3(0, 1, 1), Vector3(1, 1, 0), Vector3(1, 1, 1), Vector3(0, 1, 1), Vector3(0, 1, 0), Vector3(1, 1, 0)],
	# 3: -Y Bottom
	[Vector3(0, 0, 0), Vector3(1, 0, 1), Vector3(1, 0, 0), Vector3(0, 0, 0), Vector3(0, 0, 1), Vector3(1, 0, 1)],
	# 4: +Z Front
	[Vector3(0, 0, 1), Vector3(1, 1, 1), Vector3(1, 0, 1), Vector3(0, 0, 1), Vector3(0, 1, 1), Vector3(1, 1, 1)],
	# 5: -Z Back
	[Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 1, 0), Vector3(0, 1, 0)]
]

const QUAD_UVS: Array[Vector2] = [
	Vector2(0, 0), Vector2(1, 1), Vector2(1, 0),
	Vector2(0, 0), Vector2(0, 1), Vector2(1, 1)
]

func _init() -> void:
	VoxelChunk._init_materials()
	voxels.resize(TOTAL_CELLS)
	# PackedByteArray is zero-initialized → BLOCK_AIR (0) everywhere; no fill() needed.

func setup_nodes() -> void:
	collision_layer = 1
	collision_mask = 7

	if _mesh_inst == null:
		_mesh_inst = MeshInstance3D.new()
		_mesh_inst.name = "ChunkMesh"
		add_child(_mesh_inst)

	if _col_shape == null:
		_col_shape = CollisionShape3D.new()
		_col_shape.name = "ChunkCollision"
		add_child(_col_shape)

func set_voxel_local(lx: int, ly: int, lz: int, type_id: StringName) -> void:
	if lx >= 0 and lx < SIZE_X and ly >= 0 and ly < SIZE_Y and lz >= 0 and lz < SIZE_Z:
		voxels[lx * 512 + ly * 16 + lz] = BLOCK_IDS.get(type_id, BLOCK_AIR)

func get_voxel_local(lx: int, ly: int, lz: int) -> StringName:
	if lx >= 0 and lx < SIZE_X and ly >= 0 and ly < SIZE_Y and lz >= 0 and lz < SIZE_Z:
		return BLOCK_NAMES[voxels[lx * 512 + ly * 16 + lz]]
	return &""

## O(1) Zero-copy assignment of flat voxel data into this chunk.
func load_from_flat(flat: PackedByteArray) -> void:
	voxels = flat

func to_flat() -> PackedByteArray:
	return voxels

func is_solid_local(lx: int, ly: int, lz: int) -> bool:
	if lx >= 0 and lx < SIZE_X and ly >= 0 and ly < SIZE_Y and lz >= 0 and lz < SIZE_Z:
		return voxels[lx * 512 + ly * 16 + lz] != BLOCK_AIR
	return false

## Returns true if this chunk and neighbor share at least one solid block across their border.
func shares_solid_boundary_with(neighbor: VoxelChunk, dir_to_neighbor: Vector2i) -> bool:
	if neighbor == null:
		return false
	if dir_to_neighbor == Vector2i(1, 0): # Neighbor is +X (Right)
		var base := (SIZE_X - 1) * 512
		for ly in range(SIZE_Y):
			var y_base := base + ly * 16
			for lz in range(SIZE_Z):
				if voxels[y_base + lz] != 0 and neighbor.is_solid_local(0, ly, lz):
					return true
	elif dir_to_neighbor == Vector2i(-1, 0): # Neighbor is -X (Left)
		for ly in range(SIZE_Y):
			var y_base := ly * 16
			for lz in range(SIZE_Z):
				if voxels[y_base + lz] != 0 and neighbor.is_solid_local(SIZE_X - 1, ly, lz):
					return true
	elif dir_to_neighbor == Vector2i(0, 1): # Neighbor is +Z (Front)
		for lx in range(SIZE_X):
			var x_base := lx * 512 + (SIZE_Z - 1)
			for ly in range(SIZE_Y):
				if voxels[x_base + ly * 16] != 0 and neighbor.is_solid_local(lx, ly, 0):
					return true
	elif dir_to_neighbor == Vector2i(0, -1): # Neighbor is -Z (Back)
		for lx in range(SIZE_X):
			var x_base := lx * 512
			for ly in range(SIZE_Y):
				if voxels[x_base + ly * 16] != 0 and neighbor.is_solid_local(lx, ly, SIZE_Z - 1):
					return true
	return false

# ============================================================
# MESH BUFFER HELPERS
# ============================================================

## Returns a per-material buffer dict, creating it if absent.
## Avoids repeated dictionary lookup by returning the reference.
static func _get_or_create_buf(mat_buffers: Dictionary, b_type: StringName) -> Dictionary:
	if mat_buffers.has(b_type):
		return mat_buffers[b_type]
	var buf := {
		"verts": PackedVector3Array(),
		"norms": PackedVector3Array(),
		"uvs": PackedVector2Array()
	}
	mat_buffers[b_type] = buf
	return buf

## Appends a single unit-cube face quad (2 triangles = 6 vertices) to the given buffers.
## block_min: chunk-local float position of the voxel.
## d_idx: direction index (0=+X, 1=-X, 2=+Y, 3=-Y, 4=+Z, 5=-Z).
## All parameters are pre-resolved by caller to avoid extra lookups.
static func _append_face(
	verts: PackedVector3Array, norms: PackedVector3Array, uvs: PackedVector2Array,
	col_faces: PackedVector3Array,
	block_min: Vector3, d_idx: int
) -> void:
	var norm: Vector3 = NORMALS[d_idx]
	var off: Array = FACE_VERT_OFFSETS[d_idx]
	var v0: Vector3 = block_min + off[0]
	var v1: Vector3 = block_min + off[1]
	var v2: Vector3 = block_min + off[2]
	var v3: Vector3 = block_min + off[3]
	var v4: Vector3 = block_min + off[4]
	var v5: Vector3 = block_min + off[5]

	verts.append(v0)
	verts.append(v1)
	verts.append(v2)
	verts.append(v3)
	verts.append(v4)
	verts.append(v5)

	norms.append(norm)
	norms.append(norm)
	norms.append(norm)
	norms.append(norm)
	norms.append(norm)
	norms.append(norm)

	uvs.append(QUAD_UVS[0])
	uvs.append(QUAD_UVS[1])
	uvs.append(QUAD_UVS[2])
	uvs.append(QUAD_UVS[3])
	uvs.append(QUAD_UVS[4])
	uvs.append(QUAD_UVS[5])

	col_faces.append(v0)
	col_faces.append(v1)
	col_faces.append(v2)
	col_faces.append(v3)
	col_faces.append(v4)
	col_faces.append(v5)

## Appends a greedy-merged rectangle face for +X (right) or -X (left) surfaces.
## origin: (lx, ly, lz) corner, dz: depth in Z, dy: height in Y.
static func _append_greedy_x_face(
	verts: PackedVector3Array, norms: PackedVector3Array, uvs: PackedVector2Array,
	col_faces: PackedVector3Array,
	lx: int, ly: int, lz: int, dz: int, dy: int, is_right: bool
) -> void:
	var norm: Vector3 = Vector3(1, 0, 0) if is_right else Vector3(-1, 0, 0)
	var x: float = float(lx + 1) if is_right else float(lx)
	var y0 := float(ly)
	var y1 := float(ly + dy)
	var z0 := float(lz)
	var z1 := float(lz + dz)

	var v0: Vector3
	var v1: Vector3
	var v2: Vector3
	var v3: Vector3

	if is_right:
		v0 = Vector3(x, y0, z1)
		v1 = Vector3(x, y1, z0)
		v2 = Vector3(x, y0, z0)
		v3 = Vector3(x, y1, z1)
	else:
		v0 = Vector3(x, y0, z0)
		v1 = Vector3(x, y1, z1)
		v2 = Vector3(x, y0, z1)
		v3 = Vector3(x, y1, z0)

	verts.append(v0); verts.append(v1); verts.append(v2)
	verts.append(v0); verts.append(v3); verts.append(v1)
	norms.append(norm); norms.append(norm); norms.append(norm)
	norms.append(norm); norms.append(norm); norms.append(norm)
	uvs.append(QUAD_UVS[0]); uvs.append(QUAD_UVS[1]); uvs.append(QUAD_UVS[2])
	uvs.append(QUAD_UVS[3]); uvs.append(QUAD_UVS[4]); uvs.append(QUAD_UVS[5])
	col_faces.append(v0); col_faces.append(v1); col_faces.append(v2)
	col_faces.append(v0); col_faces.append(v3); col_faces.append(v1)

## Appends a greedy-merged rectangle face for +Z (front) or -Z (back) surfaces.
## origin: (lx, ly, lz) corner, dx: width in X, dy: height in Y.
static func _append_greedy_z_face(
	verts: PackedVector3Array, norms: PackedVector3Array, uvs: PackedVector2Array,
	col_faces: PackedVector3Array,
	lx: int, ly: int, lz: int, dx: int, dy: int, is_front: bool
) -> void:
	var norm: Vector3 = Vector3(0, 0, 1) if is_front else Vector3(0, 0, -1)
	var z: float = float(lz + 1) if is_front else float(lz)
	var x0 := float(lx)
	var x1 := float(lx + dx)
	var y0 := float(ly)
	var y1 := float(ly + dy)

	var v0: Vector3
	var v1: Vector3
	var v2: Vector3
	var v3: Vector3

	if is_front:
		v0 = Vector3(x0, y0, z)
		v1 = Vector3(x1, y1, z)
		v2 = Vector3(x1, y0, z)
		v3 = Vector3(x0, y1, z)
	else:
		v0 = Vector3(x1, y0, z)
		v1 = Vector3(x0, y1, z)
		v2 = Vector3(x0, y0, z)
		v3 = Vector3(x1, y1, z)

	verts.append(v0); verts.append(v1); verts.append(v2)
	verts.append(v0); verts.append(v3); verts.append(v1)
	norms.append(norm); norms.append(norm); norms.append(norm)
	norms.append(norm); norms.append(norm); norms.append(norm)
	uvs.append(QUAD_UVS[0]); uvs.append(QUAD_UVS[1]); uvs.append(QUAD_UVS[2])
	uvs.append(QUAD_UVS[3]); uvs.append(QUAD_UVS[4]); uvs.append(QUAD_UVS[5])
	col_faces.append(v0); col_faces.append(v1); col_faces.append(v2)
	col_faces.append(v0); col_faces.append(v3); col_faces.append(v1)

## Appends a greedy-merged rectangle face for +Y (top) or -Y (bottom) surfaces.
## origin: (lx, lz) corner, w: width in X, d: depth in Z, ly: Y layer.
## Produces 2 triangles covering a w×d rectangle. Reduces vertex count for flat surfaces.
static func _append_greedy_y_face(
	verts: PackedVector3Array, norms: PackedVector3Array, uvs: PackedVector2Array,
	col_faces: PackedVector3Array,
	lx: int, ly: int, lz: int, w: int, d: int, is_top: bool
) -> void:
	var norm: Vector3 = Vector3(0, 1, 0) if is_top else Vector3(0, -1, 0)
	var y: float = float(ly + 1) if is_top else float(ly)
	var x0 := float(lx)
	var z0 := float(lz)
	var x1 := float(lx + w)
	var z1 := float(lz + d)

	var v0: Vector3
	var v1: Vector3
	var v2: Vector3
	var v3: Vector3

	if is_top:
		v0 = Vector3(x0, y, z1)
		v1 = Vector3(x1, y, z0)
		v2 = Vector3(x1, y, z1)
		v3 = Vector3(x0, y, z0)
	else:
		v0 = Vector3(x0, y, z0)
		v1 = Vector3(x1, y, z1)
		v2 = Vector3(x1, y, z0)
		v3 = Vector3(x0, y, z1)

	verts.append(v0); verts.append(v1); verts.append(v2)
	verts.append(v0); verts.append(v3); verts.append(v1)
	norms.append(norm); norms.append(norm); norms.append(norm)
	norms.append(norm); norms.append(norm); norms.append(norm)
	uvs.append(QUAD_UVS[0]); uvs.append(QUAD_UVS[1]); uvs.append(QUAD_UVS[2])
	uvs.append(QUAD_UVS[3]); uvs.append(QUAD_UVS[4]); uvs.append(QUAD_UVS[5])
	col_faces.append(v0); col_faces.append(v1); col_faces.append(v2)
	col_faces.append(v0); col_faces.append(v3); col_faces.append(v1)

# ============================================================
# ULTRA-FAST DIRECT MESH & COLLISION BUILDER (Thread-safe)
# ============================================================

## Generates mesh surface arrays and collision faces using direct PackedVector3Arrays.
## Can be called on ANY thread (WorkerThreadPool background thread or main thread).
##
## FULL 3-AXIS GREEDY MESHING:
## - Pass 1: X-planes (+X right, -X left) merged greedily across Z and Y.
## - Pass 2: Z-planes (+Z front, -Z back) merged greedily across X and Y.
## - Pass 3: Y-planes (+Y top, -Y bottom) merged greedily across X and Z.
## Reduces face and vertex counts drastically for planar geometry and contiguous terrain.
## Masks are PackedByteArray (int IDs) instead of Array[StringName], eliminating GC overhead.
static func build_mesh_data_from_flat(
	flat: PackedByteArray,
	left_border: Variant,   # Array of bool: [ly * 16 + lz]
	right_border: Variant,  # Array of bool: [ly * 16 + lz]
	back_border: Variant,   # Array of bool: [lx * 32 + ly]
	front_border: Variant   # Array of bool: [lx * 32 + ly]
) -> Dictionary:
	var mat_buffers: Dictionary = {}
	var col_faces: PackedVector3Array = PackedVector3Array()

	# ---- Pass 1: Greedy X-faces (+X Right and -X Left) ----
	# PackedByteArray masks: 0 = no face, 1-6 = block type ID.
	var mask_right: PackedByteArray
	var mask_left:  PackedByteArray
	var visited_x:  Array = []
	mask_right.resize(SIZE_Z * SIZE_Y)
	mask_left.resize(SIZE_Z * SIZE_Y)
	visited_x.resize(SIZE_Z * SIZE_Y)

	for lx in range(SIZE_X):
		mask_right.fill(0)
		mask_left.fill(0)
		var base_x := lx * 512

		for ly in range(SIZE_Y):
			var base_xy := base_x + ly * 16
			for lz in range(SIZE_Z):
				var b_id: int = flat[base_xy + lz]
				if b_id == 0:
					continue

				var mask_idx := lz * SIZE_Y + ly

				# +X Right
				var right_solid: bool
				if lx + 1 < SIZE_X:
					right_solid = flat[base_xy + 512 + lz] != 0
				elif right_border != null:
					right_solid = bool(right_border[ly * 16 + lz])
				else:
					right_solid = false
				if not right_solid:
					mask_right[mask_idx] = b_id

				# -X Left
				var left_solid: bool
				if lx > 0:
					left_solid = flat[base_xy - 512 + lz] != 0
				elif left_border != null:
					left_solid = bool(left_border[ly * 16 + lz])
				else:
					left_solid = false
				if not left_solid:
					mask_left[mask_idx] = b_id

		# Greedy merge +X Right
		visited_x.fill(false)
		for lz in range(SIZE_Z):
			for ly in range(SIZE_Y):
				var idx := lz * SIZE_Y + ly
				if visited_x[idx]:
					continue
				var b_id: int = mask_right[idx]
				if b_id == 0:
					continue
				var w := 1
				while lz + w < SIZE_Z and mask_right[(lz + w) * SIZE_Y + ly] == b_id and not visited_x[(lz + w) * SIZE_Y + ly]:
					w += 1
				var h := 1
				var can_extend := true
				while ly + h < SIZE_Y and can_extend:
					for dz in range(w):
						var chk := (lz + dz) * SIZE_Y + ly + h
						if mask_right[chk] != b_id or visited_x[chk]:
							can_extend = false
							break
					if can_extend:
						h += 1
				for dz in range(w):
					for dy in range(h):
						visited_x[(lz + dz) * SIZE_Y + ly + dy] = true
				var buf := _get_or_create_buf(mat_buffers, BLOCK_NAMES[b_id])
				_append_greedy_x_face(buf["verts"], buf["norms"], buf["uvs"], col_faces, lx, ly, lz, w, h, true)

		# Greedy merge -X Left
		visited_x.fill(false)
		for lz in range(SIZE_Z):
			for ly in range(SIZE_Y):
				var idx := lz * SIZE_Y + ly
				if visited_x[idx]:
					continue
				var b_id: int = mask_left[idx]
				if b_id == 0:
					continue
				var w := 1
				while lz + w < SIZE_Z and mask_left[(lz + w) * SIZE_Y + ly] == b_id and not visited_x[(lz + w) * SIZE_Y + ly]:
					w += 1
				var h := 1
				var can_extend := true
				while ly + h < SIZE_Y and can_extend:
					for dz in range(w):
						var chk := (lz + dz) * SIZE_Y + ly + h
						if mask_left[chk] != b_id or visited_x[chk]:
							can_extend = false
							break
					if can_extend:
						h += 1
				for dz in range(w):
					for dy in range(h):
						visited_x[(lz + dz) * SIZE_Y + ly + dy] = true
				var buf := _get_or_create_buf(mat_buffers, BLOCK_NAMES[b_id])
				_append_greedy_x_face(buf["verts"], buf["norms"], buf["uvs"], col_faces, lx, ly, lz, w, h, false)

	# ---- Pass 2: Greedy Z-faces (+Z Front and -Z Back) ----
	var mask_front: PackedByteArray
	var mask_back:  PackedByteArray
	var visited_z:  Array = []
	mask_front.resize(SIZE_X * SIZE_Y)
	mask_back.resize(SIZE_X * SIZE_Y)
	visited_z.resize(SIZE_X * SIZE_Y)

	for lz in range(SIZE_Z):
		mask_front.fill(0)
		mask_back.fill(0)

		for lx in range(SIZE_X):
			var base_x := lx * 512
			for ly in range(SIZE_Y):
				var base_xy := base_x + ly * 16
				var b_id: int = flat[base_xy + lz]
				if b_id == 0:
					continue

				var mask_idx := lx * SIZE_Y + ly

				# +Z Front
				var front_solid: bool
				if lz + 1 < SIZE_Z:
					front_solid = flat[base_xy + lz + 1] != 0
				elif front_border != null:
					front_solid = bool(front_border[lx * 32 + ly])
				else:
					front_solid = false
				if not front_solid:
					mask_front[mask_idx] = b_id

				# -Z Back
				var back_solid: bool
				if lz > 0:
					back_solid = flat[base_xy + lz - 1] != 0
				elif back_border != null:
					back_solid = bool(back_border[lx * 32 + ly])
				else:
					back_solid = false
				if not back_solid:
					mask_back[mask_idx] = b_id

		# Greedy merge +Z Front
		visited_z.fill(false)
		for lx in range(SIZE_X):
			for ly in range(SIZE_Y):
				var idx := lx * SIZE_Y + ly
				if visited_z[idx]:
					continue
				var b_id: int = mask_front[idx]
				if b_id == 0:
					continue
				var w := 1
				while lx + w < SIZE_X and mask_front[(lx + w) * SIZE_Y + ly] == b_id and not visited_z[(lx + w) * SIZE_Y + ly]:
					w += 1
				var h := 1
				var can_extend := true
				while ly + h < SIZE_Y and can_extend:
					for dx in range(w):
						var chk := (lx + dx) * SIZE_Y + ly + h
						if mask_front[chk] != b_id or visited_z[chk]:
							can_extend = false
							break
					if can_extend:
						h += 1
				for dx in range(w):
					for dy in range(h):
						visited_z[(lx + dx) * SIZE_Y + ly + dy] = true
				var buf := _get_or_create_buf(mat_buffers, BLOCK_NAMES[b_id])
				_append_greedy_z_face(buf["verts"], buf["norms"], buf["uvs"], col_faces, lx, ly, lz, w, h, true)

		# Greedy merge -Z Back
		visited_z.fill(false)
		for lx in range(SIZE_X):
			for ly in range(SIZE_Y):
				var idx := lx * SIZE_Y + ly
				if visited_z[idx]:
					continue
				var b_id: int = mask_back[idx]
				if b_id == 0:
					continue
				var w := 1
				while lx + w < SIZE_X and mask_back[(lx + w) * SIZE_Y + ly] == b_id and not visited_z[(lx + w) * SIZE_Y + ly]:
					w += 1
				var h := 1
				var can_extend := true
				while ly + h < SIZE_Y and can_extend:
					for dx in range(w):
						var chk := (lx + dx) * SIZE_Y + ly + h
						if mask_back[chk] != b_id or visited_z[chk]:
							can_extend = false
							break
					if can_extend:
						h += 1
				for dx in range(w):
					for dy in range(h):
						visited_z[(lx + dx) * SIZE_Y + ly + dy] = true
				var buf := _get_or_create_buf(mat_buffers, BLOCK_NAMES[b_id])
				_append_greedy_z_face(buf["verts"], buf["norms"], buf["uvs"], col_faces, lx, ly, lz, w, h, false)

	# ---- Pass 3: Greedy Y-faces (top +Y and bottom -Y) per layer ----
	var top_mask: PackedByteArray
	var bot_mask: PackedByteArray
	var visited_y: Array = []
	top_mask.resize(SIZE_X * SIZE_Z)
	bot_mask.resize(SIZE_X * SIZE_Z)
	visited_y.resize(SIZE_X * SIZE_Z)

	for ly in range(SIZE_Y):
		top_mask.fill(0)
		bot_mask.fill(0)

		var base_ly := ly * 16
		for lx in range(SIZE_X):
			var base_x := lx * 512
			var base_xy := base_x + base_ly
			for lz in range(SIZE_Z):
				var b_id: int = flat[base_xy + lz]
				if b_id == 0:
					continue
				# +Y Top: exposed if cell above is air
				if ly + 1 < SIZE_Y:
					if flat[base_xy + 16 + lz] == 0:
						top_mask[lx * SIZE_Z + lz] = b_id
				else:
					top_mask[lx * SIZE_Z + lz] = b_id
				# -Y Bottom: exposed if cell below is air
				if ly > 0:
					if flat[base_xy - 16 + lz] == 0:
						bot_mask[lx * SIZE_Z + lz] = b_id
				else:
					bot_mask[lx * SIZE_Z + lz] = b_id

		# Greedy merge on top_mask
		visited_y.fill(false)
		for lx in range(SIZE_X):
			for lz in range(SIZE_Z):
				var idx := lx * SIZE_Z + lz
				if visited_y[idx]:
					continue
				var b_id: int = top_mask[idx]
				if b_id == 0:
					continue
				# Extend in +Z
				var w := 1
				while lz + w < SIZE_Z and top_mask[lx * SIZE_Z + lz + w] == b_id and not visited_y[lx * SIZE_Z + lz + w]:
					w += 1
				# Extend in +X
				var d := 1
				var can_extend := true
				while lx + d < SIZE_X and can_extend:
					for dz in range(w):
						var chk := (lx + d) * SIZE_Z + lz + dz
						if top_mask[chk] != b_id or visited_y[chk]:
							can_extend = false
							break
					if can_extend:
						d += 1
				for dx in range(d):
					for dz in range(w):
						visited_y[(lx + dx) * SIZE_Z + lz + dz] = true
				var buf := _get_or_create_buf(mat_buffers, BLOCK_NAMES[b_id])
				_append_greedy_y_face(buf["verts"], buf["norms"], buf["uvs"], col_faces, lx, ly, lz, d, w, true)

		# Greedy merge on bot_mask
		visited_y.fill(false)
		for lx in range(SIZE_X):
			for lz in range(SIZE_Z):
				var idx := lx * SIZE_Z + lz
				if visited_y[idx]:
					continue
				var b_id: int = bot_mask[idx]
				if b_id == 0:
					continue
				var w := 1
				while lz + w < SIZE_Z and bot_mask[lx * SIZE_Z + lz + w] == b_id and not visited_y[lx * SIZE_Z + lz + w]:
					w += 1
				var d := 1
				var can_extend := true
				while lx + d < SIZE_X and can_extend:
					for dz in range(w):
						var chk := (lx + d) * SIZE_Z + lz + dz
						if bot_mask[chk] != b_id or visited_y[chk]:
							can_extend = false
							break
					if can_extend:
						d += 1
				for dx in range(d):
					for dz in range(w):
						visited_y[(lx + dx) * SIZE_Z + lz + dz] = true
				var buf := _get_or_create_buf(mat_buffers, BLOCK_NAMES[b_id])
				_append_greedy_y_face(buf["verts"], buf["norms"], buf["uvs"], col_faces, lx, ly, lz, d, w, false)

	return {
		"surfaces": mat_buffers,
		"collision_faces": col_faces
	}

## Applies pre-built surface buffers to mesh instance.
## Must be called on main thread. Returns mesh upload time in ms.
func apply_mesh_data(surfaces: Dictionary) -> float:
	setup_nodes()
	position = Vector3(float(chunk_pos.x * SIZE_X), 0.0, float(chunk_pos.y * SIZE_Z))

	var t_m0 := Time.get_ticks_usec()
	if surfaces.is_empty():
		_mesh_inst.mesh = null
	else:
		var combined_mesh := ArrayMesh.new()
		for mat_key in surfaces.keys():
			var buf: Dictionary = surfaces[mat_key]
			var verts: PackedVector3Array = buf["verts"]
			if verts.is_empty():
				continue

			var arrays := []
			arrays.resize(Mesh.ARRAY_MAX)
			arrays[Mesh.ARRAY_VERTEX] = verts
			arrays[Mesh.ARRAY_NORMAL] = buf["norms"]
			arrays[Mesh.ARRAY_TEX_UV] = buf["uvs"]

			combined_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			var mat: Material = _materials.get(mat_key, null)
			if mat != null:
				combined_mesh.surface_set_material(combined_mesh.get_surface_count() - 1, mat)

		if combined_mesh.get_surface_count() > 0:
			_mesh_inst.mesh = combined_mesh
		else:
			_mesh_inst.mesh = null
	return float(Time.get_ticks_usec() - t_m0) / 1000.0

## Applies collision shape or faces to collision node.
## Can take either a pre-built ConcavePolygonShape3D or PackedVector3Array faces.
## Returns collision assignment time in ms.
func apply_collision_data(collision_data: Variant) -> float:
	setup_nodes()
	position = Vector3(float(chunk_pos.x * SIZE_X), 0.0, float(chunk_pos.y * SIZE_Z))

	var t_c0 := Time.get_ticks_usec()
	if collision_data is ConcavePolygonShape3D:
		_col_shape.shape = collision_data
	elif collision_data is PackedVector3Array:
		var p_faces: PackedVector3Array = collision_data
		if not p_faces.is_empty():
			var concave := ConcavePolygonShape3D.new()
			concave.set_faces(p_faces)
			concave.backface_collision = true
			_col_shape.shape = concave
		else:
			_col_shape.shape = null
	elif collision_data == null:
		_col_shape.shape = null
	return float(Time.get_ticks_usec() - t_c0) / 1000.0

## Applies pre-built surface buffers and collision faces to node.
## Must be called on main thread. Returns dictionary with separate mesh and collision timings.
func apply_mesh_and_collision_data(surfaces: Dictionary, collision_data: Variant) -> Dictionary:
	var t_mesh_ms := apply_mesh_data(surfaces)
	var t_col_ms := apply_collision_data(collision_data)

	return {
		"mesh_upload_time_ms": t_mesh_ms,
		"collision_time_ms": t_col_ms
	}

## Extracts 1D border slice (size 32x16 = 512) for a given X coordinate.
func get_x_border_slice(lx: int) -> Array:
	var slice: Array = []
	slice.resize(SIZE_Y * SIZE_Z)
	var base := lx * 512
	for ly in range(SIZE_Y):
		var y_base := base + ly * 16
		for lz in range(SIZE_Z):
			slice[ly * 16 + lz] = voxels[y_base + lz] != BLOCK_AIR
	return slice

## Extracts 1D border slice (size 16x32 = 512) for a given Z coordinate.
func get_z_border_slice(lz: int) -> Array:
	var slice: Array = []
	slice.resize(SIZE_X * SIZE_Y)
	for lx in range(SIZE_X):
		var base := lx * 512 + lz
		for ly in range(SIZE_Y):
			slice[lx * 32 + ly] = voxels[base + ly * 16] != BLOCK_AIR
	return slice

## Rebuilds chunk mesh and ConcavePolygonShape3D collision geometry in chunk-local coordinates.
func rebuild_mesh_and_collision() -> void:
	setup_nodes()
	position = Vector3(float(chunk_pos.x * SIZE_X), 0.0, float(chunk_pos.y * SIZE_Z))

	var n_left: VoxelChunk = null
	var n_right: VoxelChunk = null
	var n_back: VoxelChunk = null
	var n_front: VoxelChunk = null

	if voxel_world != null and voxel_world.get("_chunks") != null:
		var chunks: Dictionary = voxel_world._chunks
		n_left = chunks.get(chunk_pos + Vector2i(-1, 0), null)
		n_right = chunks.get(chunk_pos + Vector2i(1, 0), null)
		n_back = chunks.get(chunk_pos + Vector2i(0, -1), null)
		n_front = chunks.get(chunk_pos + Vector2i(0, 1), null)

	var left_border: Variant = n_left.get_x_border_slice(SIZE_X - 1) if n_left != null else null
	var right_border: Variant = n_right.get_x_border_slice(0) if n_right != null else null
	var back_border: Variant = n_back.get_z_border_slice(SIZE_Z - 1) if n_back != null else null
	var front_border: Variant = n_front.get_z_border_slice(0) if n_front != null else null

	var mesh_data := build_mesh_data_from_flat(voxels, left_border, right_border, back_border, front_border)
	apply_mesh_and_collision_data(mesh_data["surfaces"], mesh_data["collision_faces"])
