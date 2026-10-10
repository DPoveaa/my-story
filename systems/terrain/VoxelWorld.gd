class_name VoxelWorld
extends Node3D

## Infinite 3D Chunked Voxel Terrain Engine inspired by Castle Story's floating islands.
## Manages 3D voxel chunk loading/unloading, FastNoiseLite density noise generation,
## mining interaction, persistence, and ground support for construction.
## Uses multi-stage incremental chunk generation with frame time budget to eliminate frame stalls.

signal chunk_loaded(chunk_pos: Vector2i)
signal chunk_unloaded(chunk_pos: Vector2i)
signal voxel_mined(world_cell: Vector3i, block_type: StringName)

const DELTA_SAVE_PATH: String = "user://terrain_deltas.json"

@export var seed_value: int = 1337:
	set(val):
		seed_value = val
		_setup_noise()

@export var view_distance_chunks: int = 3
@export var max_chunks_per_frame: int = 2
@export var max_frame_time_ms: float = 6.0
@export var noise_frequency_2d: float = 0.025
@export var noise_frequency_3d: float = 0.045

var _noise_2d: FastNoiseLite
var _noise_3d: FastNoiseLite
var _noise_ore: FastNoiseLite

## Dictionary[Vector2i, VoxelChunk]
var _chunks: Dictionary = {}

## Dictionary[Vector2i, Array[Vector3i]] — mined local cell coordinates per chunk
var _mined_deltas: Dictionary = {}

## Incremental Multi-Stage Generation Queue
var _generation_queue: Array[Vector2i] = []
var _queued_chunks: Dictionary = {} # Vector2i -> bool

var _last_player_chunk: Vector2i = Vector2i(99999, 99999)

## Lightweight Diagnostics
var total_chunks_generated: int = 0
var last_chunk_build_time_ms: float = 0.0

func _ready() -> void:
	_setup_noise()
	load_terrain_deltas()

func _process(_delta: float) -> void:
	_process_generation_queue()

func _setup_noise() -> void:
	_noise_2d = FastNoiseLite.new()
	_noise_2d.seed = seed_value
	_noise_2d.noise_type = FastNoiseLite.TYPE_PERLIN
	_noise_2d.frequency = noise_frequency_2d

	_noise_3d = FastNoiseLite.new()
	_noise_3d.seed = seed_value + 100
	_noise_3d.noise_type = FastNoiseLite.TYPE_PERLIN
	_noise_3d.frequency = noise_frequency_3d

	_noise_ore = FastNoiseLite.new()
	_noise_ore.seed = seed_value + 200
	_noise_ore.noise_type = FastNoiseLite.TYPE_PERLIN
	_noise_ore.frequency = 0.12

func set_seed(p_seed: int) -> void:
	seed_value = p_seed
	_setup_noise()
	clear_world()

## Helper method to check if chunk is currently loaded in memory
func is_chunk_loaded(chunk_pos: Vector2i) -> bool:
	return _chunks.has(chunk_pos) and is_instance_valid(_chunks[chunk_pos])

## Returns true if a solid natural terrain block exists at world_cell.
func is_solid_block(world_cell: Vector3i) -> bool:
	var b_type := get_voxel_at(world_cell)
	return not b_type.is_empty()

## Integration with StabilitySystem anchor checking.
## Returns true if world_cell is inside solid terrain or directly resting on top of solid terrain.
func is_ground_cell(world_cell: Vector3i) -> bool:
	return is_solid_block(world_cell) or is_solid_block(world_cell - Vector3i(0, 1, 0))

## Returns the natural block type at world_cell, or &"" if air/unloaded.
func get_voxel_at(world_cell: Vector3i) -> StringName:
	var cx := floori(float(world_cell.x) / float(VoxelChunk.SIZE_X))
	var cz := floori(float(world_cell.z) / float(VoxelChunk.SIZE_Z))
	var chunk_pos := Vector2i(cx, cz)

	var lx := posmod(world_cell.x, VoxelChunk.SIZE_X)
	var ly := world_cell.y
	var lz := posmod(world_cell.z, VoxelChunk.SIZE_Z)

	if ly < 0 or ly >= VoxelChunk.SIZE_Y:
		return &""

	# Check if chunk is loaded in memory
	if _chunks.has(chunk_pos):
		var chunk: VoxelChunk = _chunks[chunk_pos]
		if is_instance_valid(chunk):
			return chunk.get_voxel_local(lx, ly, lz)

	# Calculate procedural voxel deterministically
	return _evaluate_procedural_voxel(world_cell.x, world_cell.y, world_cell.z, chunk_pos, Vector3i(lx, ly, lz))

func _evaluate_procedural_voxel(gx: int, gy: int, gz: int, chunk_pos: Vector2i, local_cell: Vector3i) -> StringName:
	# Check if this cell was previously mined by player
	if _mined_deltas.has(chunk_pos):
		if local_cell in _mined_deltas[chunk_pos]:
			return &""

	if _noise_2d == null or _noise_3d == null:
		_setup_noise()

	# Floating Island Presence & Shape Noise
	var island_noise: float = _noise_2d.get_noise_2d(float(gx), float(gz))
	# Ensure origin (0,0) starting area is always a solid starting island
	if island_noise < -0.20 and (abs(gx) > 16 or abs(gz) > 16):
		# Air space between floating islands
		return &""

	# 2D Height Surface Noise
	var n2d_surf: float = (_noise_2d.get_noise_2d(float(gx) + 500.0, float(gz) + 500.0) + 1.0) * 0.5
	var surf_height: int = int(floor(lerpf(12.0, 22.0, n2d_surf)))

	# 2D Bottom Base Noise for Castle Story-style floating island underside
	var n2d_base: float = (_noise_3d.get_noise_2d(float(gx) - 500.0, float(gz) - 500.0) + 1.0) * 0.5
	var bottom_height: int = int(floor(lerpf(3.0, 9.0, n2d_base)))

	# Ensure solid, contiguous interior between bottom_height and surf_height
	var is_solid: bool = (gy >= bottom_height) and (gy <= surf_height)
	if not is_solid:
		return &""

	# Block Layering
	if gy == surf_height:
		return &"grass"
	elif gy >= surf_height - 2:
		return &"dirt"

	# Subsurface Stone & Ore Deposits
	var ore_n: float = _noise_ore.get_noise_3d(float(gx), float(gy), float(gz))
	if gy <= 8 and ore_n > 0.45:
		return &"gold"
	elif gy <= 12 and ore_n > 0.35:
		return &"iron"
	elif gy <= 15 and ore_n > 0.25:
		return &"coal"

	return &"stone"

## Streams and enqueues chunk load/unload requests around player position without frame stalls.
func update_loaded_chunks(player_world_pos: Vector3) -> void:
	var pcx := floori(player_world_pos.x / float(VoxelChunk.SIZE_X))
	var pcz := floori(player_world_pos.z / float(VoxelChunk.SIZE_Z))
	var current_player_chunk := Vector2i(pcx, pcz)

	if current_player_chunk == _last_player_chunk and not _generation_queue.is_empty():
		return

	_last_player_chunk = current_player_chunk

	var required_chunks: Dictionary = {}
	for dx in range(-view_distance_chunks, view_distance_chunks + 1):
		for dz in range(-view_distance_chunks, view_distance_chunks + 1):
			var cp := current_player_chunk + Vector2i(dx, dz)
			required_chunks[cp] = true

			if not _chunks.has(cp) and not _queued_chunks.has(cp):
				_generation_queue.append(cp)
				_queued_chunks[cp] = true

	# Sort queue by distance to player chunk so nearest chunks build first
	_generation_queue.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		var dist_a := a.distance_squared_to(current_player_chunk)
		var dist_b := b.distance_squared_to(current_player_chunk)
		return dist_a < dist_b
	)

	# Unload chunks outside active range
	var to_unload: Array[Vector2i] = []
	for cp in _chunks.keys():
		if not required_chunks.has(cp):
			to_unload.append(cp)

	for cp in to_unload:
		_unload_chunk(cp)

	# Clean up queue items outside view distance
	var filtered_queue: Array[Vector2i] = []
	for cp in _generation_queue:
		if required_chunks.has(cp):
			filtered_queue.append(cp)
		else:
			_queued_chunks.erase(cp)
	_generation_queue = filtered_queue

func _process_generation_queue() -> void:
	if _generation_queue.is_empty():
		return

	var start_time := Time.get_ticks_usec()
	var processed := 0

	while not _generation_queue.is_empty() and processed < max_chunks_per_frame:
		var cp: Vector2i = _generation_queue.pop_front()
		_queued_chunks.erase(cp)
		if not _chunks.has(cp):
			_load_or_generate_chunk(cp)
			processed += 1

		# Strict time budget guard per frame
		var elapsed_ms := float(Time.get_ticks_usec() - start_time) / 1000.0
		if elapsed_ms >= max_frame_time_ms:
			break

func _load_or_generate_chunk(chunk_pos: Vector2i) -> VoxelChunk:
	if _chunks.has(chunk_pos):
		return _chunks[chunk_pos]

	var t_start := Time.get_ticks_usec()

	# If this chunk was queued, remove it from queue since we're generating it
	if _queued_chunks.has(chunk_pos):
		_queued_chunks.erase(chunk_pos)
		_generation_queue.erase(chunk_pos)

	var chunk := VoxelChunk.new()
	chunk.name = "Chunk_%d_%d" % [chunk_pos.x, chunk_pos.y]
	chunk.chunk_pos = chunk_pos
	chunk.voxel_world = self

	var start_x := chunk_pos.x * VoxelChunk.SIZE_X
	var start_z := chunk_pos.y * VoxelChunk.SIZE_Z

	# Stage 1: Voxel Data Evaluation
	for lx in range(VoxelChunk.SIZE_X):
		for lz in range(VoxelChunk.SIZE_Z):
			var gx := start_x + lx
			var gz := start_z + lz
			for ly in range(VoxelChunk.SIZE_Y):
				var local_cell := Vector3i(lx, ly, lz)
				var b_type := _evaluate_procedural_voxel(gx, ly, gz, chunk_pos, local_cell)
				chunk.set_voxel_local(lx, ly, lz, b_type)

	# Stage 2: Scene & Physics Geometry Construction
	add_child(chunk)
	chunk.rebuild_mesh_and_collision()
	_chunks[chunk_pos] = chunk

	# Stage 3: Rebuild adjacent loaded chunks to update boundary faces
	_rebuild_neighbor_chunks(chunk_pos)

	total_chunks_generated += 1
	last_chunk_build_time_ms = float(Time.get_ticks_usec() - t_start) / 1000.0

	chunk_loaded.emit(chunk_pos)
	return chunk

func _unload_chunk(chunk_pos: Vector2i) -> void:
	if _chunks.has(chunk_pos):
		var chunk: VoxelChunk = _chunks[chunk_pos]
		if is_instance_valid(chunk):
			chunk.queue_free()
		_chunks.erase(chunk_pos)
		_rebuild_neighbor_chunks(chunk_pos)
		chunk_unloaded.emit(chunk_pos)

func _rebuild_neighbor_chunks(cp: Vector2i) -> void:
	var neighbors: Array[Vector2i] = [
		cp + Vector2i(1, 0), cp + Vector2i(-1, 0),
		cp + Vector2i(0, 1), cp + Vector2i(0, -1)
	]
	for n_pos in neighbors:
		if _chunks.has(n_pos):
			var n_chunk: VoxelChunk = _chunks[n_pos]
			if is_instance_valid(n_chunk):
				n_chunk.rebuild_mesh_and_collision()

## Diagnostics accessor dictionary
func get_diagnostics() -> Dictionary:
	return {
		"loaded_chunks": _chunks.size(),
		"queued_chunks": _generation_queue.size(),
		"total_chunks_generated": total_chunks_generated,
		"last_chunk_build_time_ms": last_chunk_build_time_ms
	}

## Mines an individual natural terrain block at world_cell.
## Updates voxel data, rebuilds affected chunk geometry/collision, and returns the mined block_type.
func mine_voxel(world_cell: Vector3i) -> StringName:
	var cx := floori(float(world_cell.x) / float(VoxelChunk.SIZE_X))
	var cz := floori(float(world_cell.z) / float(VoxelChunk.SIZE_Z))
	var chunk_pos := Vector2i(cx, cz)

	var lx := posmod(world_cell.x, VoxelChunk.SIZE_X)
	var ly := world_cell.y
	var lz := posmod(world_cell.z, VoxelChunk.SIZE_Z)

	var chunk := _load_or_generate_chunk(chunk_pos)
	var b_type := chunk.get_voxel_local(lx, ly, lz)
	if b_type.is_empty():
		return &""

	# Remove block locally
	chunk.set_voxel_local(lx, ly, lz, &"")

	# Record mined delta for session persistence
	if not _mined_deltas.has(chunk_pos):
		_mined_deltas[chunk_pos] = []
	var local_cell := Vector3i(lx, ly, lz)
	if not _mined_deltas[chunk_pos].has(local_cell):
		_mined_deltas[chunk_pos].append(local_cell)

	# Rebuild mesh and collision
	chunk.rebuild_mesh_and_collision()

	# Rebuild adjacent chunk if mined block was on chunk boundary
	if lx == 0 and _chunks.has(chunk_pos + Vector2i(-1, 0)):
		_chunks[chunk_pos + Vector2i(-1, 0)].rebuild_mesh_and_collision()
	elif lx == VoxelChunk.SIZE_X - 1 and _chunks.has(chunk_pos + Vector2i(1, 0)):
		_chunks[chunk_pos + Vector2i(1, 0)].rebuild_mesh_and_collision()

	if lz == 0 and _chunks.has(chunk_pos + Vector2i(0, -1)):
		_chunks[chunk_pos + Vector2i(0, -1)].rebuild_mesh_and_collision()
	elif lz == VoxelChunk.SIZE_Z - 1 and _chunks.has(chunk_pos + Vector2i(0, 1)):
		_chunks[chunk_pos + Vector2i(0, 1)].rebuild_mesh_and_collision()

	save_terrain_deltas()
	voxel_mined.emit(world_cell, b_type)
	return b_type

## Finds a safe, un-obstructed spawn position on natural top terrain at (x, z).
## Accounts for player capsule height (~1.8m) to prevent spawning inside solid voxels.
func get_spawn_position(x: int = 0, z: int = 0) -> Vector3:
	var cx := floori(float(x) / float(VoxelChunk.SIZE_X))
	var cz := floori(float(z) / float(VoxelChunk.SIZE_Z))
	_load_or_generate_chunk(Vector2i(cx, cz))

	# Scan downwards for top solid voxel
	for y in range(VoxelChunk.SIZE_Y - 1, -1, -1):
		if is_solid_block(Vector3i(x, y, z)):
			# Check that 2 cells above top solid voxel (body + head) are clear air
			var cell_above_1 := Vector3i(x, y + 1, z)
			var cell_above_2 := Vector3i(x, y + 2, z)
			if not is_solid_block(cell_above_1) and not is_solid_block(cell_above_2):
				return Vector3(float(x) + 0.5, float(y + 1) + 1.0, float(z) + 0.5)

	# Search in expanding spiral around (x,z) if target column is blocked or void
	for radius in range(1, 10):
		for dx in range(-radius, radius + 1):
			for dz in range(-radius, radius + 1):
				if abs(dx) != radius and abs(dz) != radius:
					continue
				var nx := x + dx
				var nz := z + dz
				for ny in range(VoxelChunk.SIZE_Y - 1, -1, -1):
					if is_solid_block(Vector3i(nx, ny, nz)):
						if not is_solid_block(Vector3i(nx, ny + 1, nz)) and not is_solid_block(Vector3i(nx, ny + 2, nz)):
							return Vector3(float(nx) + 0.5, float(ny + 1) + 1.0, float(nz) + 0.5)

	return Vector3(0.5, 16.0, 0.5)

func clear_world() -> void:
	_generation_queue.clear()
	_queued_chunks.clear()
	for chunk in _chunks.values():
		if is_instance_valid(chunk):
			chunk.queue_free()
	_chunks.clear()

# ==============================================================================
# PERSISTENCE (user://terrain_deltas.json)
# ==============================================================================

func save_terrain_deltas() -> bool:
	var dict: Dictionary = {
		"version": 1,
		"seed": seed_value,
		"deltas": {}
	}
	for cp in _mined_deltas.keys():
		var key_str := "%d,%d" % [cp.x, cp.y]
		var cells_arr: Array = []
		for cell in _mined_deltas[cp]:
			cells_arr.append([cell.x, cell.y, cell.z])
		dict["deltas"][key_str] = cells_arr

	var file := FileAccess.open(DELTA_SAVE_PATH, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(dict, "\t"))
	file.close()
	return true

func load_terrain_deltas() -> bool:
	if not FileAccess.file_exists(DELTA_SAVE_PATH):
		return false

	var file := FileAccess.open(DELTA_SAVE_PATH, FileAccess.READ)
	if file == null:
		return false

	var content: String = file.get_as_text()
	file.close()

	var json := JSON.new()
	if json.parse(content) != OK or not (json.data is Dictionary):
		return false

	var dict: Dictionary = json.data
	var deltas_dict = dict.get("deltas", null)
	if not (deltas_dict is Dictionary):
		return false

	_mined_deltas.clear()
	for key_str in deltas_dict.keys():
		var parts = key_str.split(",")
		if parts.size() == 2:
			var cp := Vector2i(int(parts[0]), int(parts[1]))
			var arr = deltas_dict[key_str]
			if arr is Array:
				var cells_list: Array[Vector3i] = []
				for item in arr:
					if item is Array and item.size() == 3:
						cells_list.append(Vector3i(int(item[0]), int(item[1]), int(item[2])))
				_mined_deltas[cp] = cells_list

	return true
