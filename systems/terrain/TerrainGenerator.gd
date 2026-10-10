class_name TerrainGenerator
extends Node3D

## Procedural terrain generator using FastNoiseLite and chunked mesh/collision generation.
## Logically separate from player-built structures in GridSystem.
## Generates chunk meshes and combined ConcavePolygonShape3D collision geometry (no per-voxel physics bodies).

signal terrain_generated(seed_value: int, chunk_count: int)

@export var seed_value: int = 1337:
	set(val):
		seed_value = val
		if _noise != null:
			_noise.seed = seed_value

@export var chunk_size_x: int = 16
@export var chunk_size_z: int = 16
@export var world_chunks_x: int = 4
@export var world_chunks_z: int = 4

@export var min_height: int = 2
@export var max_height: int = 12
@export var noise_frequency: float = 0.03

var _noise: FastNoiseLite
var _chunks: Dictionary = {} # Vector2i -> Node3D (TerrainChunk)
var _height_map: Dictionary = {} # Vector2i(x,z) -> int (surface_y)

func _ready() -> void:
	_setup_noise()

func _setup_noise() -> void:
	_noise = FastNoiseLite.new()
	_noise.seed = seed_value
	_noise.noise_type = FastNoiseLite.TYPE_PERLIN
	_noise.frequency = noise_frequency

func set_seed(p_seed: int) -> void:
	seed_value = p_seed
	if _noise != null:
		_noise.seed = seed_value

func get_surface_y(x: int, z: int) -> int:
	var key := Vector2i(x, z)
	if _height_map.has(key):
		return _height_map[key]

	if _noise == null:
		_setup_noise()

	var n: float = (_noise.get_noise_2d(float(x), float(z)) + 1.0) * 0.5 # 0.0 to 1.0
	var y: int = int(round(lerpf(float(min_height), float(max_height), n)))
	_height_map[key] = y
	return y

func get_block_type_at(x: int, y: int, z: int) -> StringName:
	var surface_y := get_surface_y(x, z)
	if y > surface_y or y < 0:
		return &""
	elif y == surface_y:
		return &"stone" # Surface layer
	elif y >= surface_y - 2:
		return &"brick" # Subsurface layer
	else:
		return &"wood" # Deep layer

func generate_terrain() -> void:
	clear_terrain()
	if _noise == null:
		_setup_noise()

	_height_map.clear()

	var half_x := world_chunks_x / 2
	var half_z := world_chunks_z / 2

	var total_chunks := 0
	for cx in range(-half_x, half_x):
		for cz in range(-half_z, half_z):
			_generate_chunk(Vector2i(cx, cz))
			total_chunks += 1

	terrain_generated.emit(seed_value, total_chunks)

func _generate_chunk(chunk_pos: Vector2i) -> void:
	var chunk_node := StaticBody3D.new()
	chunk_node.name = "Chunk_%d_%d" % [chunk_pos.x, chunk_pos.y]
	# Layer 1 = ground / environment
	chunk_node.collision_layer = 1
	chunk_node.collision_mask = 7

	var start_x := chunk_pos.x * chunk_size_x
	var start_z := chunk_pos.y * chunk_size_z

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var faces: PackedVector3Array = []

	for lx in range(chunk_size_x):
		for lz in range(chunk_size_z):
			var gx := start_x + lx
			var gz := start_z + lz
			var surface_y := get_surface_y(gx, gz)

			for y in range(0, surface_y + 1):
				var b_type := get_block_type_at(gx, y, gz)
				if b_type.is_empty():
					continue

				# Check exposed faces (only add faces adjacent to air to optimize mesh)
				var pos := Vector3(float(gx), float(y), float(gz))
				_add_exposed_block_faces(gx, y, gz, pos, st, faces)

	st.generate_normals()
	var array_mesh := st.commit()

	if array_mesh.get_surface_count() > 0:
		var mesh_inst := MeshInstance3D.new()
		mesh_inst.mesh = array_mesh
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.45, 0.50, 0.40) # Natural terrain albedo
		mat.roughness = 0.9
		mesh_inst.material_override = mat
		chunk_node.add_child(mesh_inst)

		if not faces.is_empty():
			var col_shape := CollisionShape3D.new()
			var concave := ConcavePolygonShape3D.new()
			concave.set_faces(faces)
			col_shape.shape = concave
			chunk_node.add_child(col_shape)

	add_child(chunk_node)
	_chunks[chunk_pos] = chunk_node

func _add_exposed_block_faces(gx: int, gy: int, gz: int, block_min: Vector3, st: SurfaceTool, faces: PackedVector3Array) -> void:
	var cs := 1.0
	var min_p := block_min
	var max_p := block_min + Vector3.ONE * cs

	var dirs: Array[Vector3i] = [
		Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
		Vector3i(0, 1, 0), Vector3i(0, -1, 0),
		Vector3i(0, 0, 1), Vector3i(0, 0, -1)
	]

	for d: Vector3i in dirs:
		var nx: int = gx + d.x
		var ny: int = gy + d.y
		var nz: int = gz + d.z
		var is_air: bool = ny > get_surface_y(nx, nz) or ny < 0
		if is_air:
			_add_quad_face(min_p, max_p, d, st, faces)

func _add_quad_face(min_p: Vector3, max_p: Vector3, normal: Vector3i, st: SurfaceTool, faces: PackedVector3Array) -> void:
	var v0: Vector3
	var v1: Vector3
	var v2: Vector3
	var v3: Vector3

	if normal.y > 0: # TOP
		v0 = Vector3(min_p.x, max_p.y, min_p.z)
		v1 = Vector3(max_p.x, max_p.y, min_p.z)
		v2 = Vector3(max_p.x, max_p.y, max_p.z)
		v3 = Vector3(min_p.x, max_p.y, max_p.z)
	elif normal.y < 0: # BOTTOM
		v0 = Vector3(min_p.x, min_p.y, max_p.z)
		v1 = Vector3(max_p.x, min_p.y, max_p.z)
		v2 = Vector3(max_p.x, min_p.y, min_p.z)
		v3 = Vector3(min_p.x, min_p.y, min_p.z)
	elif normal.x > 0: # RIGHT
		v0 = Vector3(max_p.x, min_p.y, max_p.z)
		v1 = Vector3(max_p.x, min_p.y, min_p.z)
		v2 = Vector3(max_p.x, max_p.y, min_p.z)
		v3 = Vector3(max_p.x, max_p.y, max_p.z)
	elif normal.x < 0: # LEFT
		v0 = Vector3(min_p.x, min_p.y, min_p.z)
		v1 = Vector3(min_p.x, min_p.y, max_p.z)
		v2 = Vector3(min_p.x, max_p.y, max_p.z)
		v3 = Vector3(min_p.x, max_p.y, min_p.z)
	elif normal.z > 0: # FRONT
		v0 = Vector3(min_p.x, min_p.y, max_p.z)
		v1 = Vector3(max_p.x, min_p.y, max_p.z)
		v2 = Vector3(max_p.x, max_p.y, max_p.z)
		v3 = Vector3(min_p.x, max_p.y, max_p.z)
	else: # BACK
		v0 = Vector3(max_p.x, min_p.y, min_p.z)
		v1 = Vector3(min_p.x, min_p.y, min_p.z)
		v2 = Vector3(min_p.x, max_p.y, min_p.z)
		v3 = Vector3(max_p.x, max_p.y, min_p.z)

	# Triangle 1: v0, v1, v2
	st.add_vertex(v0)
	st.add_vertex(v1)
	st.add_vertex(v2)
	faces.append(v0)
	faces.append(v1)
	faces.append(v2)

	# Triangle 2: v0, v2, v3
	st.add_vertex(v0)
	st.add_vertex(v2)
	st.add_vertex(v3)
	faces.append(v0)
	faces.append(v2)
	faces.append(v3)

func clear_terrain() -> void:
	for chunk in _chunks.values():
		if is_instance_valid(chunk):
			chunk.queue_free()
	_chunks.clear()
	_height_map.clear()

func get_spawn_position(x: int = 0, z: int = 0) -> Vector3:
	var surface_y := get_surface_y(x, z)
	return Vector3(float(x) + 0.5, float(surface_y + 1) + 1.0, float(z) + 0.5)

func is_ground_cell(cell: Vector3i) -> bool:
	var surf_y := get_surface_y(cell.x, cell.z)
	return cell.y <= surf_y + 1
