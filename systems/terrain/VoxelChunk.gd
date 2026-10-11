class_name VoxelChunk
extends StaticBody3D

## Individual 16x32x16 3D Voxel Chunk for procedural floating terrain islands.
## Stores 3D voxel data array and generates single ArrayMesh and ConcavePolygonShape3D collision geometry.
## Node is positioned at its world-space chunk origin; mesh/collision geometry use chunk-local coordinates.

const SIZE_X: int = 16
const SIZE_Y: int = 32
const SIZE_Z: int = 16

var chunk_pos: Vector2i = Vector2i.ZERO
var voxel_world: Node = null # Back reference to VoxelWorld for neighbor chunk lookups

## 3D Voxel block array: Array[Array[Array[StringName]]]
var voxels: Array = []
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

	# Initialize empty 3D voxels array 16x32x16
	voxels.resize(SIZE_X)
	for x in range(SIZE_X):
		var plane: Array = []
		plane.resize(SIZE_Y)
		for y in range(SIZE_Y):
			var col: Array = []
			col.resize(SIZE_Z)
			for z in range(SIZE_Z):
				col[z] = &""
			plane[y] = col
		voxels[x] = plane

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
		voxels[lx][ly][lz] = type_id

func get_voxel_local(lx: int, ly: int, lz: int) -> StringName:
	if lx >= 0 and lx < SIZE_X and ly >= 0 and ly < SIZE_Y and lz >= 0 and lz < SIZE_Z:
		return StringName(voxels[lx][ly][lz])
	return &""

## Transfers a flat voxel data array into this chunk's 3D voxel structure.
func load_from_flat(flat: Array) -> void:
	var sy := SIZE_Y
	var sz := SIZE_Z
	for lx in range(SIZE_X):
		for ly in range(SIZE_Y):
			for lz in range(SIZE_Z):
				voxels[lx][ly][lz] = flat[lx * sy * sz + ly * sz + lz]

func is_solid_local(lx: int, ly: int, lz: int) -> bool:
	return not get_voxel_local(lx, ly, lz).is_empty()

# ============================================================
# ULTRA-FAST DIRECT MESH & COLLISION BUILDER (Thread-safe)
# ============================================================

## Generates mesh surface arrays and collision faces using direct PackedVector3Arrays.
## Can be called on ANY thread (WorkerThreadPool background thread or main thread).
static func build_mesh_data_from_flat(
	flat: Array,
	left_border: Variant,   # Array of bool: [ly * SIZE_Z + lz]
	right_border: Variant,  # Array of bool: [ly * SIZE_Z + lz]
	back_border: Variant,   # Array of bool: [lx * SIZE_Y + ly]
	front_border: Variant   # Array of bool: [lx * SIZE_Y + ly]
) -> Dictionary:
	var sy := SIZE_Y
	var sz := SIZE_Z

	# Per-material vertex buffers: mat_name -> { "verts": PackedVector3Array, "norms": PackedVector3Array, "uvs": PackedVector2Array }
	var mat_buffers: Dictionary = {}
	var col_faces: PackedVector3Array = PackedVector3Array()

	var uvs0 := QUAD_UVS[0]
	var uvs1 := QUAD_UVS[1]
	var uvs2 := QUAD_UVS[2]
	var uvs3 := QUAD_UVS[3]
	var uvs4 := QUAD_UVS[4]
	var uvs5 := QUAD_UVS[5]

	for lx in range(SIZE_X):
		for ly in range(SIZE_Y):
			for lz in range(SIZE_Z):
				var b_type: StringName = flat[lx * sy * sz + ly * sz + lz]
				if b_type.is_empty():
					continue

				var block_min := Vector3(float(lx), float(ly), float(lz))

				var buf: Dictionary
				if mat_buffers.has(b_type):
					buf = mat_buffers[b_type]
				else:
					buf = {
						"verts": PackedVector3Array(),
						"norms": PackedVector3Array(),
						"uvs": PackedVector2Array()
					}
					mat_buffers[b_type] = buf

				var verts: PackedVector3Array = buf["verts"]
				var norms: PackedVector3Array = buf["norms"]
				var uvs: PackedVector2Array = buf["uvs"]

				for d_idx in range(6):
					var dir: Vector3i = DIRS[d_idx]
					var nx: int = lx + dir.x
					var ny: int = ly + dir.y
					var nz: int = lz + dir.z

					var neighbor_solid: bool = false
					if nx >= 0 and nx < SIZE_X and ny >= 0 and ny < SIZE_Y and nz >= 0 and nz < SIZE_Z:
						var n_type: StringName = flat[nx * sy * sz + ny * sz + nz]
						neighbor_solid = not n_type.is_empty()
					elif ny < 0 or ny >= SIZE_Y:
						neighbor_solid = false
					elif nx < 0:
						if left_border != null:
							neighbor_solid = bool(left_border[ly * sz + lz])
						else:
							neighbor_solid = false
					elif nx >= SIZE_X:
						if right_border != null:
							neighbor_solid = bool(right_border[ly * sz + lz])
						else:
							neighbor_solid = false
					elif nz < 0:
						if back_border != null:
							neighbor_solid = bool(back_border[lx * sy + ly])
						else:
							neighbor_solid = false
					elif nz >= SIZE_Z:
						if front_border != null:
							neighbor_solid = bool(front_border[lx * sy + ly])
						else:
							neighbor_solid = false

					if not neighbor_solid:
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

						uvs.append(uvs0)
						uvs.append(uvs1)
						uvs.append(uvs2)
						uvs.append(uvs3)
						uvs.append(uvs4)
						uvs.append(uvs5)

						col_faces.append(v0)
						col_faces.append(v1)
						col_faces.append(v2)
						col_faces.append(v3)
						col_faces.append(v4)
						col_faces.append(v5)

				buf["verts"] = verts
				buf["norms"] = norms
				buf["uvs"] = uvs

	return {
		"surfaces": mat_buffers,
		"collision_faces": col_faces
	}

## Applies pre-built surface buffers and collision faces to node.
## Must be called on main thread. Takes < 0.1 ms.
func apply_mesh_and_collision_data(surfaces: Dictionary, collision_faces: PackedVector3Array) -> void:
	setup_nodes()
	position = Vector3(float(chunk_pos.x * SIZE_X), 0.0, float(chunk_pos.y * SIZE_Z))

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

	if not collision_faces.is_empty():
		var concave := ConcavePolygonShape3D.new()
		concave.set_faces(collision_faces)
		concave.backface_collision = true
		_col_shape.shape = concave
	else:
		_col_shape.shape = null

## Extracts 1D border slice (size 32x16 = 512) for a given X coordinate.
func get_x_border_slice(lx: int) -> Array:
	var slice: Array = []
	slice.resize(SIZE_Y * SIZE_Z)
	for ly in range(SIZE_Y):
		for lz in range(SIZE_Z):
			var b: StringName = voxels[lx][ly][lz]
			slice[ly * SIZE_Z + lz] = not b.is_empty()
	return slice

## Extracts 1D border slice (size 16x32 = 512) for a given Z coordinate.
func get_z_border_slice(lz: int) -> Array:
	var slice: Array = []
	slice.resize(SIZE_X * SIZE_Y)
	for lx in range(SIZE_X):
		for ly in range(SIZE_Y):
			var b: StringName = voxels[lx][ly][lz]
			slice[lx * SIZE_Y + ly] = not b.is_empty()
	return slice

## Converts 3D voxels to flat array.
func to_flat() -> Array:
	var flat: Array = []
	var size := SIZE_X * SIZE_Y * SIZE_Z
	flat.resize(size)
	var sy := SIZE_Y
	var sz := SIZE_Z
	for lx in range(SIZE_X):
		for ly in range(SIZE_Y):
			for lz in range(SIZE_Z):
				flat[lx * sy * sz + ly * sz + lz] = voxels[lx][ly][lz]
	return flat

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

	var flat := to_flat()
	var mesh_data := build_mesh_data_from_flat(flat, left_border, right_border, back_border, front_border)
	apply_mesh_and_collision_data(mesh_data["surfaces"], mesh_data["collision_faces"])
