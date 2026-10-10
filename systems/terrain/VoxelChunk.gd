class_name VoxelChunk
extends StaticBody3D

## Individual 16x32x16 3D Voxel Chunk for procedural floating terrain islands.
## Stores 3D voxel data array and generates single ArrayMesh and ConcavePolygonShape3D collision geometry.
## Hides internal faces between adjacent solid blocks to eliminate internal geometry.

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
	_materials[&"grass"] = mat_grass

	var mat_dirt := StandardMaterial3D.new()
	mat_dirt.albedo_color = Color(0.42, 0.30, 0.20)
	mat_dirt.roughness = 0.90
	_materials[&"dirt"] = mat_dirt

	var mat_stone := StandardMaterial3D.new()
	mat_stone.albedo_color = Color(0.52, 0.54, 0.58)
	mat_stone.roughness = 0.80
	_materials[&"stone"] = mat_stone

	var mat_coal := StandardMaterial3D.new()
	mat_coal.albedo_color = Color(0.22, 0.22, 0.24)
	mat_coal.roughness = 0.90
	_materials[&"coal"] = mat_coal

	var mat_iron := StandardMaterial3D.new()
	mat_iron.albedo_color = Color(0.72, 0.74, 0.78)
	mat_iron.roughness = 0.50
	mat_iron.metallic = 0.60
	_materials[&"iron"] = mat_iron

	var mat_gold := StandardMaterial3D.new()
	mat_gold.albedo_color = Color(0.95, 0.78, 0.22)
	mat_gold.roughness = 0.30
	mat_gold.metallic = 0.80
	_materials[&"gold"] = mat_gold

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

func is_solid_local(lx: int, ly: int, lz: int) -> bool:
	return not get_voxel_local(lx, ly, lz).is_empty()

## Rebuilds chunk mesh and ConcavePolygonShape3D collision geometry.
## Only generates exposed faces bordering air to eliminate internal faces.
func rebuild_mesh_and_collision() -> void:
	setup_nodes()

	var start_x := chunk_pos.x * SIZE_X
	var start_z := chunk_pos.y * SIZE_Z

	# Separate SurfaceTools per material type to avoid per-vertex material spam
	var st_map: Dictionary = {}
	for mat_key in _materials.keys():
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		st_map[mat_key] = st

	# Default fallback SurfaceTool
	var st_default := SurfaceTool.new()
	st_default.begin(Mesh.PRIMITIVE_TRIANGLES)

	var collision_faces: PackedVector3Array = []

	var dirs: Array[Vector3i] = [
		Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
		Vector3i(0, 1, 0), Vector3i(0, -1, 0),
		Vector3i(0, 0, 1), Vector3i(0, 0, -1)
	]

	for lx in range(SIZE_X):
		for ly in range(SIZE_Y):
			for lz in range(SIZE_Z):
				var b_type: StringName = voxels[lx][ly][lz]
				if b_type.is_empty():
					continue

				var gx := start_x + lx
				var gy := ly
				var gz := start_z + lz
				var block_min := Vector3(float(gx), float(gy), float(gz))

				var st: SurfaceTool = st_map.get(b_type, st_default)

				for d: Vector3i in dirs:
					var nx := lx + d.x
					var ny := ly + d.y
					var nz := lz + d.z

					var neighbor_is_solid := false
					if nx >= 0 and nx < SIZE_X and ny >= 0 and ny < SIZE_Y and nz >= 0 and nz < SIZE_Z:
						neighbor_is_solid = not StringName(voxels[nx][ny][nz]).is_empty()
					else:
						# Query world for neighbor voxel across chunk boundary
						if voxel_world != null and voxel_world.has_method("is_solid_block"):
							neighbor_is_solid = voxel_world.is_solid_block(Vector3i(gx + d.x, gy + d.y, gz + d.z))

					# Render face ONLY if adjacent neighbor is empty space (air)
					if not neighbor_is_solid:
						_add_face_quad(block_min, d, st, collision_faces)

	# Combine surfaces into a single ArrayMesh
	var combined_mesh := ArrayMesh.new()
	for mat_key in st_map.keys():
		var st: SurfaceTool = st_map[mat_key]
		st.generate_normals()
		var sub_mesh := st.commit()
		if sub_mesh.get_surface_count() > 0:
			var mat: Material = _materials[mat_key]
			combined_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, sub_mesh.surface_get_arrays(0))
			combined_mesh.surface_set_material(combined_mesh.get_surface_count() - 1, mat)

	if combined_mesh.get_surface_count() > 0:
		_mesh_inst.mesh = combined_mesh
	else:
		_mesh_inst.mesh = null

	if not collision_faces.is_empty():
		var concave := ConcavePolygonShape3D.new()
		concave.set_faces(collision_faces)
		_col_shape.shape = concave
	else:
		_col_shape.shape = null

func _add_face_quad(min_p: Vector3, normal: Vector3i, st: SurfaceTool, collision_faces: PackedVector3Array) -> void:
	var max_p := min_p + Vector3.ONE
	var v0: Vector3
	var v1: Vector3
	var v2: Vector3
	var v3: Vector3

	if normal.y > 0: # TOP (+Y)
		v0 = Vector3(min_p.x, max_p.y, min_p.z)
		v1 = Vector3(max_p.x, max_p.y, min_p.z)
		v2 = Vector3(max_p.x, max_p.y, max_p.z)
		v3 = Vector3(min_p.x, max_p.y, max_p.z)
	elif normal.y < 0: # BOTTOM (-Y)
		v0 = Vector3(min_p.x, min_p.y, max_p.z)
		v1 = Vector3(max_p.x, min_p.y, max_p.z)
		v2 = Vector3(max_p.x, min_p.y, min_p.z)
		v3 = Vector3(min_p.x, min_p.y, min_p.z)
	elif normal.x > 0: # RIGHT (+X)
		v0 = Vector3(max_p.x, min_p.y, max_p.z)
		v1 = Vector3(max_p.x, min_p.y, min_p.z)
		v2 = Vector3(max_p.x, max_p.y, min_p.z)
		v3 = Vector3(max_p.x, max_p.y, max_p.z)
	elif normal.x < 0: # LEFT (-X)
		v0 = Vector3(min_p.x, min_p.y, min_p.z)
		v1 = Vector3(min_p.x, min_p.y, max_p.z)
		v2 = Vector3(min_p.x, max_p.y, max_p.z)
		v3 = Vector3(min_p.x, max_p.y, min_p.z)
	elif normal.z > 0: # FRONT (+Z)
		v0 = Vector3(min_p.x, min_p.y, max_p.z)
		v1 = Vector3(max_p.x, min_p.y, max_p.z)
		v2 = Vector3(max_p.x, max_p.y, max_p.z)
		v3 = Vector3(min_p.x, max_p.y, max_p.z)
	else: # BACK (-Z)
		v0 = Vector3(max_p.x, min_p.y, min_p.z)
		v1 = Vector3(min_p.x, min_p.y, min_p.z)
		v2 = Vector3(min_p.x, max_p.y, min_p.z)
		v3 = Vector3(max_p.x, max_p.y, min_p.z)

	# Triangle 1
	st.add_vertex(v0)
	st.add_vertex(v1)
	st.add_vertex(v2)
	collision_faces.append(v0)
	collision_faces.append(v1)
	collision_faces.append(v2)

	# Triangle 2
	st.add_vertex(v0)
	st.add_vertex(v2)
	st.add_vertex(v3)
	collision_faces.append(v0)
	collision_faces.append(v2)
	collision_faces.append(v3)
