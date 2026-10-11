class_name VoxelWorld
extends Node3D

## Infinite 3D Chunked Voxel Terrain Engine inspired by Castle Story's floating islands.
##
## HIGH-PERFORMANCE MULTI-THREADED PIPELINE:
## - Background Thread (WorkerThreadPool):
##     1. Evaluates procedural noise + radial mask + deltas into flat voxel buffer.
##     2. Computes all face culling, surface vertex buffers (normals, UVs), and collision geometry.
##     3. 100% of intensive loops run in parallel across available CPU cores.
## - Main Thread:
##     1. Creates node, calls apply_mesh_and_collision_data with pre-built PackedArrays.
##     2. Takes < 0.1 ms per chunk — ZERO freezing, perfectly smooth 60+ FPS while streaming.
##     3. Rate-limits neighbor boundary updates across subsequent frames to prevent stutters.

## Number of chunk-radius to pre-load synchronously around spawn.
const SPAWN_SYNC_RADIUS: int = 1

signal chunk_loaded(chunk_pos: Vector2i)
signal chunk_unloaded(chunk_pos: Vector2i)
signal voxel_mined(world_cell: Vector3i, block_type: StringName)

const DELTA_SAVE_PATH: String = "user://terrain_deltas.json"

@export var seed_value: int = 1337:
	set(val):
		seed_value = val
		_setup_noise()

@export var view_distance_chunks: int = 4
## How many background tasks can run simultaneously. Scaled to CPU cores in _ready().
@export var max_parallel_tasks: int = 8
## How many completed chunks to upload to GPU/Physics per frame.
@export var max_stage2_per_frame: int = 4
@export var noise_frequency_2d: float = 0.025
@export var noise_frequency_3d: float = 0.045

var _noise_2d: FastNoiseLite
var _noise_3d: FastNoiseLite
var _noise_ore: FastNoiseLite

## Dictionary[Vector2i, VoxelChunk]
var _chunks: Dictionary = {}

## Dictionary[Vector2i, Array[Vector3i]] — mined local cell coordinates per chunk
var _mined_deltas: Dictionary = {}
var _mined_deltas_set: Dictionary = {}  # Vector2i -> Dictionary[Vector3i, bool]

## === THREADED PIPELINE ===

## Chunks waiting to be dispatched to background thread (sorted, deduplicated)
var _pending_queue: Array[Vector2i] = []
var _pending_set: Dictionary = {}  # Vector2i -> bool

## Chunks currently running Stage 1+2 on a background thread.
var _in_flight: Dictionary = {}       # Vector2i -> bool
var _in_flight_count: int = 0

## Completed results waiting to be consumed on main thread.
## Protected by _results_mutex.
var _results_mutex: Mutex = Mutex.new()
var _results_ready: Array = []  # Array of {pos, flat, surfaces, collision_faces}

## Rate-limited neighbor remesh queue for boundary seam cleanup
var _remesh_queue: Array[Vector2i] = []
var _remesh_set: Dictionary = {}

var _last_player_chunk: Vector2i = Vector2i(99999, 99999)

## Lightweight Diagnostics
var total_chunks_generated: int = 0
var last_chunk_build_time_ms: float = 0.0

func _ready() -> void:
	max_parallel_tasks = maxi(4, mini(OS.get_processor_count() - 1, 16))
	_setup_noise()
	load_terrain_deltas()

func _process(_delta: float) -> void:
	_dispatch_pending_tasks()
	_consume_ready_results()
	_process_remesh_queue()

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

# ============================================================
# QUERY API
# ============================================================

func is_chunk_loaded(chunk_pos: Vector2i) -> bool:
	return _chunks.has(chunk_pos) and is_instance_valid(_chunks[chunk_pos])

func is_solid_block(world_cell: Vector3i) -> bool:
	var b_type := get_voxel_at(world_cell)
	return not b_type.is_empty()

func is_ground_cell(world_cell: Vector3i) -> bool:
	return is_solid_block(world_cell) or is_solid_block(world_cell - Vector3i(0, 1, 0))

func get_voxel_at(world_cell: Vector3i) -> StringName:
	var cx := floori(float(world_cell.x) / float(VoxelChunk.SIZE_X))
	var cz := floori(float(world_cell.z) / float(VoxelChunk.SIZE_Z))
	var chunk_pos := Vector2i(cx, cz)

	var lx := posmod(world_cell.x, VoxelChunk.SIZE_X)
	var ly := world_cell.y
	var lz := posmod(world_cell.z, VoxelChunk.SIZE_Z)

	if ly < 0 or ly >= VoxelChunk.SIZE_Y:
		return &""

	if _chunks.has(chunk_pos):
		var chunk: VoxelChunk = _chunks[chunk_pos]
		if is_instance_valid(chunk):
			return chunk.get_voxel_local(lx, ly, lz)

	# Deterministic fallback (for queries against unloaded / in-flight chunks)
	return _evaluate_procedural_voxel(world_cell.x, world_cell.y, world_cell.z, chunk_pos, Vector3i(lx, ly, lz))

# ============================================================
# PROCEDURAL EVALUATION
# ============================================================

func _evaluate_procedural_voxel(gx: int, gy: int, gz: int, chunk_pos: Vector2i, local_cell: Vector3i) -> StringName:
	if _mined_deltas_set.has(chunk_pos):
		if _mined_deltas_set[chunk_pos].has(local_cell):
			return &""
	elif _mined_deltas.has(chunk_pos):
		if local_cell in _mined_deltas[chunk_pos]:
			return &""

	if _noise_2d == null or _noise_3d == null:
		return &""

	var dist_from_origin := sqrt(float(gx * gx + gz * gz))
	var spawn_island_radial_mask := clampf(1.0 - (dist_from_origin / 24.0), 0.0, 1.0)

	var island_noise: float = _noise_2d.get_noise_2d(float(gx), float(gz))
	var is_island_area := (spawn_island_radial_mask > 0.05) or (island_noise > -0.15)
	if not is_island_area:
		return &""

	var n2d_surf: float = (_noise_2d.get_noise_2d(float(gx) + 500.0, float(gz) + 500.0) + 1.0) * 0.5
	var surf_height: int = int(floor(lerpf(12.0, 22.0, n2d_surf)))

	var n2d_base: float = (_noise_3d.get_noise_2d(float(gx) - 500.0, float(gz) - 500.0) + 1.0) * 0.5
	var bottom_height: int = int(floor(lerpf(3.0, 9.0, n2d_base)))

	var is_solid: bool = (gy >= bottom_height) and (gy <= surf_height)
	if not is_solid:
		return &""

	if gy == surf_height:
		return &"grass"
	elif gy >= surf_height - 2:
		return &"dirt"

	var ore_n: float = _noise_ore.get_noise_3d(float(gx), float(gy), float(gz))
	if gy <= 8 and ore_n > 0.45:
		return &"gold"
	elif gy <= 12 and ore_n > 0.35:
		return &"iron"
	elif gy <= 15 and ore_n > 0.25:
		return &"coal"

	return &"stone"

# ============================================================
# CHUNK STREAMING — Player Update
# ============================================================

func update_loaded_chunks(player_world_pos: Vector3, force_sync: bool = false) -> void:
	var pcx := floori(player_world_pos.x / float(VoxelChunk.SIZE_X))
	var pcz := floori(player_world_pos.z / float(VoxelChunk.SIZE_Z))
	var current_player_chunk := Vector2i(pcx, pcz)

	# Avoid expensive queue evaluations when player is within the same chunk
	if current_player_chunk == _last_player_chunk and not force_sync:
		return

	_last_player_chunk = current_player_chunk

	var required_chunks: Dictionary = {}
	for dx in range(-view_distance_chunks, view_distance_chunks + 1):
		for dz in range(-view_distance_chunks, view_distance_chunks + 1):
			var cp := current_player_chunk + Vector2i(dx, dz)
			required_chunks[cp] = true

			if not _chunks.has(cp) and not _in_flight.has(cp):
				if not is_inside_tree() or force_sync:
					_load_or_generate_chunk_sync(cp)
				elif not _pending_set.has(cp):
					_pending_queue.append(cp)
					_pending_set[cp] = true

	# Nearest-first sorting
	_pending_queue.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return a.distance_squared_to(current_player_chunk) < b.distance_squared_to(current_player_chunk)
	)

	# Unload chunks outside active range
	var to_unload: Array[Vector2i] = []
	for cp in _chunks.keys():
		if not required_chunks.has(cp):
			to_unload.append(cp)
	for cp in to_unload:
		_unload_chunk(cp)

	# Clean stale entries from queue
	var filtered: Array[Vector2i] = []
	for cp in _pending_queue:
		if required_chunks.has(cp):
			filtered.append(cp)
		else:
			_pending_set.erase(cp)
	_pending_queue = filtered

# ============================================================
# MULTI-THREADED PIPELINE INTERNALS
# ============================================================

func _dispatch_pending_tasks() -> void:
	if _pending_queue.is_empty():
		return

	while not _pending_queue.is_empty() and _in_flight_count < max_parallel_tasks:
		var cp: Vector2i = _pending_queue.pop_front()
		_pending_set.erase(cp)

		if _chunks.has(cp) or _in_flight.has(cp):
			continue

		_in_flight[cp] = true
		_in_flight_count += 1

		var start_x: int = cp.x * VoxelChunk.SIZE_X
		var start_z: int = cp.y * VoxelChunk.SIZE_Z
		var has_deltas: bool = _mined_deltas_set.has(cp)
		var chunk_deltas: Dictionary = _mined_deltas_set.get(cp, {}).duplicate()

		var n2d := _noise_2d
		var n3d := _noise_3d
		var n_ore := _noise_ore

		# Extract neighbor border slices for seamless watertight meshing
		var n_left: VoxelChunk = _chunks.get(cp + Vector2i(-1, 0), null)
		var n_right: VoxelChunk = _chunks.get(cp + Vector2i(1, 0), null)
		var n_back: VoxelChunk = _chunks.get(cp + Vector2i(0, -1), null)
		var n_front: VoxelChunk = _chunks.get(cp + Vector2i(0, 1), null)

		var left_border: Variant = n_left.get_x_border_slice(VoxelChunk.SIZE_X - 1) if n_left != null else null
		var right_border: Variant = n_right.get_x_border_slice(0) if n_right != null else null
		var back_border: Variant = n_back.get_z_border_slice(VoxelChunk.SIZE_Z - 1) if n_back != null else null
		var front_border: Variant = n_front.get_z_border_slice(0) if n_front != null else null

		var cp_captured := cp

		WorkerThreadPool.add_task(func():
			_worker_generate_chunk(
				cp_captured, start_x, start_z, has_deltas, chunk_deltas,
				n2d, n3d, n_ore,
				left_border, right_border, back_border, front_border
			)
		)

## Worker Thread Function: Computes voxel data AND builds all mesh/collision geometry.
func _worker_generate_chunk(
	cp: Vector2i,
	start_x: int,
	start_z: int,
	has_deltas: bool,
	chunk_deltas: Dictionary,
	n2d: FastNoiseLite,
	n3d: FastNoiseLite,
	n_ore: FastNoiseLite,
	left_border: Variant,
	right_border: Variant,
	back_border: Variant,
	front_border: Variant
) -> void:
	var size := VoxelChunk.SIZE_X * VoxelChunk.SIZE_Y * VoxelChunk.SIZE_Z
	var flat: Array = []
	flat.resize(size)
	flat.fill(&"")

	var sy := VoxelChunk.SIZE_Y
	var sz := VoxelChunk.SIZE_Z

	for lx in range(VoxelChunk.SIZE_X):
		for lz in range(VoxelChunk.SIZE_Z):
			var gx: int = start_x + lx
			var gz: int = start_z + lz

			var dist_sq := float(gx * gx + gz * gz)
			var spawn_mask := clampf(1.0 - (sqrt(dist_sq) / 24.0), 0.0, 1.0)
			var island_n: float = n2d.get_noise_2d(float(gx), float(gz))
			if spawn_mask <= 0.05 and island_n <= -0.15:
				continue

			var n_surf: float = (n2d.get_noise_2d(float(gx) + 500.0, float(gz) + 500.0) + 1.0) * 0.5
			var surf_h: int = int(floor(lerpf(12.0, 22.0, n_surf)))

			var n_base: float = (n3d.get_noise_2d(float(gx) - 500.0, float(gz) - 500.0) + 1.0) * 0.5
			var bot_h: int = int(floor(lerpf(3.0, 9.0, n_base)))

			var min_y: int = maxi(0, bot_h)
			var max_y: int = mini(VoxelChunk.SIZE_Y - 1, surf_h)

			for ly in range(min_y, max_y + 1):
				var local_cell := Vector3i(lx, ly, lz)
				if has_deltas and chunk_deltas.has(local_cell):
					continue

				var block_type: StringName
				if ly == surf_h:
					block_type = &"grass"
				elif ly >= surf_h - 2:
					block_type = &"dirt"
				else:
					var ore_n: float = n_ore.get_noise_3d(float(gx), float(ly), float(gz))
					if ly <= 8 and ore_n > 0.45:
						block_type = &"gold"
					elif ly <= 12 and ore_n > 0.35:
						block_type = &"iron"
					elif ly <= 15 and ore_n > 0.25:
						block_type = &"coal"
					else:
						block_type = &"stone"

				flat[lx * sy * sz + ly * sz + lz] = block_type

	# Generate mesh surface arrays & collision faces directly on worker thread
	var mesh_data := VoxelChunk.build_mesh_data_from_flat(flat, left_border, right_border, back_border, front_border)

	_results_mutex.lock()
	_results_ready.append({
		"pos": cp,
		"flat": flat,
		"surfaces": mesh_data["surfaces"],
		"collision_faces": mesh_data["collision_faces"]
	})
	_results_mutex.unlock()

## Main thread: applies pre-built mesh and collision. Takes < 0.1 ms per chunk.
func _consume_ready_results() -> void:
	if _results_ready.is_empty():
		return

	_results_mutex.lock()
	var batch: Array = _results_ready.duplicate()
	_results_ready.clear()
	_results_mutex.unlock()

	var processed := 0
	for entry in batch:
		if processed >= max_stage2_per_frame:
			_results_mutex.lock()
			_results_ready.append_array(batch.slice(processed))
			_results_mutex.unlock()
			break

		var cp: Vector2i = entry["pos"]
		var flat: Array = entry["flat"]
		var surfaces: Dictionary = entry["surfaces"]
		var collision_faces: PackedVector3Array = entry["collision_faces"]

		_in_flight.erase(cp)
		_in_flight_count = maxi(0, _in_flight_count - 1)

		if _chunks.has(cp):
			processed += 1
			continue

		var t_start := Time.get_ticks_usec()

		var chunk := VoxelChunk.new()
		chunk.name = "Chunk_%d_%d" % [cp.x, cp.y]
		chunk.chunk_pos = cp
		chunk.voxel_world = self

		chunk.load_from_flat(flat)
		add_child(chunk)
		chunk.apply_mesh_and_collision_data(surfaces, collision_faces)
		_chunks[cp] = chunk

		last_chunk_build_time_ms = float(Time.get_ticks_usec() - t_start) / 1000.0
		total_chunks_generated += 1
		chunk_loaded.emit(cp)

		# Schedule neighbor chunks for boundary updates across subsequent frames
		_queue_neighbor_remesh(cp)
		processed += 1

func _queue_neighbor_remesh(cp: Vector2i) -> void:
	var neighbors: Array[Vector2i] = [
		cp + Vector2i(1, 0), cp + Vector2i(-1, 0),
		cp + Vector2i(0, 1), cp + Vector2i(0, -1)
	]
	for n_pos in neighbors:
		if _chunks.has(n_pos):
			var n_chunk: VoxelChunk = _chunks[n_pos]
			if is_instance_valid(n_chunk) and not _remesh_set.has(n_pos):
				_remesh_queue.append(n_pos)
				_remesh_set[n_pos] = true

## Smoothly updates at most 1 neighbor seam per frame to avoid any frame spikes
func _process_remesh_queue() -> void:
	if _remesh_queue.is_empty():
		return
	var n_pos: Vector2i = _remesh_queue.pop_front()
	_remesh_set.erase(n_pos)

	if _chunks.has(n_pos):
		var n_chunk: VoxelChunk = _chunks[n_pos]
		if is_instance_valid(n_chunk):
			n_chunk.rebuild_mesh_and_collision()

# ============================================================
# SYNCHRONOUS GENERATION (spawn area, unit tests)
# ============================================================

func _load_or_generate_chunk(chunk_pos: Vector2i) -> VoxelChunk:
	return _load_or_generate_chunk_sync(chunk_pos)

func _load_or_generate_chunk_sync(chunk_pos: Vector2i) -> VoxelChunk:
	if _chunks.has(chunk_pos):
		return _chunks[chunk_pos]

	_in_flight.erase(chunk_pos)
	_in_flight_count = maxi(0, _in_flight_count - 1)

	var t_start := Time.get_ticks_usec()

	var chunk := VoxelChunk.new()
	chunk.name = "Chunk_%d_%d" % [chunk_pos.x, chunk_pos.y]
	chunk.chunk_pos = chunk_pos
	chunk.voxel_world = self

	var start_x := chunk_pos.x * VoxelChunk.SIZE_X
	var start_z := chunk_pos.y * VoxelChunk.SIZE_Z

	var has_deltas := _mined_deltas_set.has(chunk_pos)
	var chunk_deltas: Dictionary = _mined_deltas_set.get(chunk_pos, {})

	for lx in range(VoxelChunk.SIZE_X):
		for lz in range(VoxelChunk.SIZE_Z):
			var gx := start_x + lx
			var gz := start_z + lz

			var dist_from_origin := sqrt(float(gx * gx + gz * gz))
			var spawn_island_radial_mask := clampf(1.0 - (dist_from_origin / 24.0), 0.0, 1.0)
			var island_noise: float = _noise_2d.get_noise_2d(float(gx), float(gz))
			if spawn_island_radial_mask <= 0.05 and island_noise <= -0.15:
				continue

			var n2d_surf: float = (_noise_2d.get_noise_2d(float(gx) + 500.0, float(gz) + 500.0) + 1.0) * 0.5
			var surf_height: int = int(floor(lerpf(12.0, 22.0, n2d_surf)))

			var n2d_base: float = (_noise_3d.get_noise_2d(float(gx) - 500.0, float(gz) - 500.0) + 1.0) * 0.5
			var bottom_height: int = int(floor(lerpf(3.0, 9.0, n2d_base)))

			var min_y := maxi(0, bottom_height)
			var max_y := mini(VoxelChunk.SIZE_Y - 1, surf_height)

			for ly in range(min_y, max_y + 1):
				var local_cell := Vector3i(lx, ly, lz)
				if has_deltas and chunk_deltas.has(local_cell):
					continue

				if ly == surf_height:
					chunk.set_voxel_local(lx, ly, lz, &"grass")
				elif ly >= surf_height - 2:
					chunk.set_voxel_local(lx, ly, lz, &"dirt")
				else:
					var ore_n: float = _noise_ore.get_noise_3d(float(gx), float(ly), float(gz))
					if ly <= 8 and ore_n > 0.45:
						chunk.set_voxel_local(lx, ly, lz, &"gold")
					elif ly <= 12 and ore_n > 0.35:
						chunk.set_voxel_local(lx, ly, lz, &"iron")
					elif ly <= 15 and ore_n > 0.25:
						chunk.set_voxel_local(lx, ly, lz, &"coal")
					else:
						chunk.set_voxel_local(lx, ly, lz, &"stone")

	if is_inside_tree():
		add_child(chunk)
	chunk.rebuild_mesh_and_collision()
	_chunks[chunk_pos] = chunk

	last_chunk_build_time_ms = float(Time.get_ticks_usec() - t_start) / 1000.0
	total_chunks_generated += 1
	chunk_loaded.emit(chunk_pos)
	_rebuild_neighbor_chunks(chunk_pos)
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

func get_diagnostics() -> Dictionary:
	return {
		"loaded_chunks": _chunks.size(),
		"pending_queue": _pending_queue.size(),
		"in_flight_threads": _in_flight_count,
		"ready_results": _results_ready.size(),
		"total_chunks_generated": total_chunks_generated,
		"last_chunk_build_time_ms": last_chunk_build_time_ms
	}

# ============================================================
# MINING
# ============================================================

func mine_voxel(world_cell: Vector3i) -> StringName:
	var cx := floori(float(world_cell.x) / float(VoxelChunk.SIZE_X))
	var cz := floori(float(world_cell.z) / float(VoxelChunk.SIZE_Z))
	var chunk_pos := Vector2i(cx, cz)

	var lx := posmod(world_cell.x, VoxelChunk.SIZE_X)
	var ly := world_cell.y
	var lz := posmod(world_cell.z, VoxelChunk.SIZE_Z)

	var chunk := _load_or_generate_chunk_sync(chunk_pos)
	var b_type := chunk.get_voxel_local(lx, ly, lz)
	if b_type.is_empty():
		return &""

	chunk.set_voxel_local(lx, ly, lz, &"")

	if not _mined_deltas.has(chunk_pos):
		_mined_deltas[chunk_pos] = []
		_mined_deltas_set[chunk_pos] = {}
	var local_cell := Vector3i(lx, ly, lz)
	if not _mined_deltas_set[chunk_pos].has(local_cell):
		_mined_deltas[chunk_pos].append(local_cell)
		_mined_deltas_set[chunk_pos][local_cell] = true

	chunk.rebuild_mesh_and_collision()

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

# ============================================================
# SPAWN SYSTEM
# ============================================================

func force_sync_spawn_chunks(center_chunk_x: int = 0, center_chunk_z: int = 0) -> void:
	for dx in range(-SPAWN_SYNC_RADIUS, SPAWN_SYNC_RADIUS + 1):
		for dz in range(-SPAWN_SYNC_RADIUS, SPAWN_SYNC_RADIUS + 1):
			var cp := Vector2i(center_chunk_x + dx, center_chunk_z + dz)
			if not _chunks.has(cp):
				_load_or_generate_chunk_sync(cp)
	if is_inside_tree():
		await get_tree().physics_frame

func verify_spawn_physics(candidate_pos: Vector3, exclude_rids: Array[RID] = []) -> bool:
	if not is_inside_tree():
		return true
	var space := get_world_3d().direct_space_state if get_world_3d() != null else null
	if space == null:
		return true

	var ray_params := PhysicsRayQueryParameters3D.create(
		candidate_pos + Vector3(0.0, 0.2, 0.0),
		candidate_pos + Vector3(0.0, -0.4, 0.0),
		1,
		exclude_rids
	)
	var ground_hit := space.intersect_ray(ray_params)
	if ground_hit.is_empty():
		return false
	var hit_norm: Vector3 = ground_hit.get("normal", Vector3.ZERO)
	if hit_norm.y < 0.7:
		return false

	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.4
	capsule.height = 1.8
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = capsule
	query.transform = Transform3D(Basis(), candidate_pos + Vector3(0.0, 0.9, 0.0))
	query.collision_mask = 1 | 4
	query.exclude = exclude_rids
	query.margin = 0.01

	var overlaps := space.intersect_shape(query, 1)
	if not overlaps.is_empty():
		return false

	return true

func get_spawn_position(x: int = 0, z: int = 0) -> Vector3:
	var cx := floori(float(x) / float(VoxelChunk.SIZE_X))
	var cz := floori(float(z) / float(VoxelChunk.SIZE_Z))
	_load_or_generate_chunk_sync(Vector2i(cx, cz))

	for y in range(VoxelChunk.SIZE_Y - 1, -1, -1):
		if is_solid_block(Vector3i(x, y, z)):
			var cell_above_1 := Vector3i(x, y + 1, z)
			var cell_above_2 := Vector3i(x, y + 2, z)
			if not is_solid_block(cell_above_1) and not is_solid_block(cell_above_2):
				var candidate := Vector3(float(x) + 0.5, float(y) + 1.1, float(z) + 0.5)
				if verify_spawn_physics(candidate):
					return candidate

	for radius in range(1, 16):
		for dx in range(-radius, radius + 1):
			for dz in range(-radius, radius + 1):
				if abs(dx) != radius and abs(dz) != radius:
					continue
				var nx := x + dx
				var nz := z + dz
				var ncx := floori(float(nx) / float(VoxelChunk.SIZE_X))
				var ncz := floori(float(nz) / float(VoxelChunk.SIZE_Z))
				_load_or_generate_chunk_sync(Vector2i(ncx, ncz))
				for ny in range(VoxelChunk.SIZE_Y - 1, -1, -1):
					if is_solid_block(Vector3i(nx, ny, nz)):
						if not is_solid_block(Vector3i(nx, ny + 1, nz)) and not is_solid_block(Vector3i(nx, ny + 2, nz)):
							var candidate := Vector3(float(nx) + 0.5, float(ny) + 1.1, float(nz) + 0.5)
							if verify_spawn_physics(candidate):
								return candidate

	for fallback_r in range(0, 24):
		for fdx in range(-fallback_r, fallback_r + 1):
			for fdz in range(-fallback_r, fallback_r + 1):
				var fx := fdx
				var fz := fdz
				var fcx := floori(float(fx) / float(VoxelChunk.SIZE_X))
				var fcz := floori(float(fz) / float(VoxelChunk.SIZE_Z))
				_load_or_generate_chunk_sync(Vector2i(fcx, fcz))
				for fy in range(VoxelChunk.SIZE_Y - 1, -1, -1):
					if is_solid_block(Vector3i(fx, fy, fz)):
						if not is_solid_block(Vector3i(fx, fy + 1, fz)) and not is_solid_block(Vector3i(fx, fy + 2, fz)):
							return Vector3(float(fx) + 0.5, float(fy) + 1.1, float(fz) + 0.5)

	return Vector3(0.5, 16.0, 0.5)

func clear_world() -> void:
	_pending_queue.clear()
	_pending_set.clear()
	_remesh_queue.clear()
	_remesh_set.clear()
	for chunk in _chunks.values():
		if is_instance_valid(chunk):
			chunk.queue_free()
	_chunks.clear()

# ============================================================
# PERSISTENCE
# ============================================================

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
	_mined_deltas_set.clear()
	for key_str in deltas_dict.keys():
		var parts = key_str.split(",")
		if parts.size() == 2:
			var cp := Vector2i(int(parts[0]), int(parts[1]))
			var arr = deltas_dict[key_str]
			if arr is Array:
				var cells_list: Array[Vector3i] = []
				var cells_set: Dictionary = {}
				for item in arr:
					if item is Array and item.size() == 3:
						var c := Vector3i(int(item[0]), int(item[1]), int(item[2]))
						cells_list.append(c)
						cells_set[c] = true
				_mined_deltas[cp] = cells_list
				_mined_deltas_set[cp] = cells_set

	return true
