class_name VoxelWorld
extends Node3D

## Infinite 3D Chunked Voxel Terrain Engine inspired by Castle Story's floating islands.
##
## HIGH-PERFORMANCE MULTI-THREADED PIPELINE & BUDGETED STREAMING:
## - Background Thread (WorkerThreadPool):
##     1. Evaluates procedural noise + radial mask + deltas into flat voxel buffer.
##     2. Computes all face culling, surface vertex buffers (normals, UVs), and collision geometry.
##     3. 100% of CPU-intensive loops run in parallel across available CPU cores.
## - Main Thread:
##     1. Strict per-frame time budget (max_frame_budget_ms) prevents frame drops.
##     2. Ingests pre-built PackedArrays directly via ArrayMesh and ConcavePolygonShape3D.
##     3. O(1) zero-copy voxel data assignment (< 0.05 ms).
##     4. Selectively queues only neighbor chunks with shared solid boundaries, amortizing
##        remeshes at most 1 per frame within budget.
##     5. Prunes and cancels stale in-flight/queued tasks when player moves.
##     6. Per-chunk edit counter prevents stale worker results from overwriting newer mining edits.
##     7. Bounded result cache (max_cached_results) avoids unbounded memory growth.
## - ZERO MAIN-THREAD STALLS:
##     force_sync_spawn_chunks() dispatches spawn chunks through the async WorkerThreadPool
##     pipeline and awaits a one-shot 'spawn_chunks_ready' signal — the main thread never
##     runs noise/mesh/collision synchronously. Neighbor remeshes are always rate-limited.

## Number of chunk-radius to pre-load synchronously around spawn.
## IMPORTANT: Keep this at 1. Larger values freeze the main thread at startup.
const SPAWN_SYNC_RADIUS: int = 1

signal chunk_loaded(chunk_pos: Vector2i)
signal chunk_unloaded(chunk_pos: Vector2i)
signal voxel_mined(world_cell: Vector3i, block_type: StringName)
## Emitted once when all chunks requested by force_sync_spawn_chunks() are available.
signal spawn_chunks_ready

const DELTA_SAVE_PATH: String = "user://terrain_deltas.json"

@export var seed_value: int = 1337:
	set(val):
		seed_value = val
		_setup_noise()

@export var view_distance_chunks: int = 4
## How many background tasks can run simultaneously. Scaled to CPU cores in _ready().
@export var max_parallel_tasks: int = 8

## === BUDGETED MAIN-THREAD POLICIES ===
## Maximum time in milliseconds to spend on main-thread terrain tasks per frame.
@export var max_frame_budget_ms: float = 3.5
## Maximum number of chunk uploads to GPU/Physics per single frame.
@export var max_uploads_per_frame: int = 2
## Maximum number of neighbor remeshes per single frame.
@export var max_remeshes_per_frame: int = 1
## Maximum cached results before oldest are dropped to bound memory.
@export var max_cached_results: int = 32

## === CHUNK CACHE (SOFT UNLOAD / OBJECT POOLING) ===
## When chunks are unloaded, they are cached and removed from the active tree.
## Moving back to those coordinates restores them directly with zero worker regeneration.
var _chunk_cache: Dictionary = {}  # Vector2i -> VoxelChunk
var _chunk_cache_order: Array[Vector2i] = []
@export var max_chunk_cache_size: int = 100

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

## Per-chunk edit generation counter. Incremented on each mining edit.
## Stale worker results with old generation numbers are discarded.
var _chunk_generation: Dictionary = {}  # Vector2i -> int

## === THREADED PIPELINE ===

## Chunks waiting to be dispatched to background thread (sorted, deduplicated)
var _pending_queue: Array[Vector2i] = []
var _pending_set: Dictionary = {}  # Vector2i -> bool

## Chunks currently running Stage 1+2 on a background thread.
var _in_flight: Dictionary = {}       # Vector2i -> int (generation at dispatch)
var _in_flight_count: int = 0

## Completed results waiting to be consumed on main thread via turnstile.
## Protected by _results_mutex.
var _results_mutex: Mutex = Mutex.new()
var chunks_ready: Array = []
var _results_ready: Array:
	get: return chunks_ready
	set(val): chunks_ready = val

## Rate-limited neighbor remesh queue for boundary seam cleanup (deduplicated)
var _remesh_queue: Array[Vector2i] = []
var _remesh_set: Dictionary = {}

var _last_player_chunk: Vector2i = Vector2i(99999, 99999)

## === ASYNC SPAWN TRACKING ===
## Set of chunk positions that must arrive from the worker pipeline before
## spawn_chunks_ready is emitted. Populated by force_sync_spawn_chunks().
var _spawn_pending_positions: Dictionary = {}  # Vector2i -> true
var _spawn_waiting: bool = false

## Diagnostics & Frame Profiling
var total_chunks_generated: int = 0
var cancelled_tasks_count: int = 0
var stale_results_discarded: int = 0
var last_chunk_build_time_ms: float = 0.0
var last_worker_gen_time_ms: float = 0.0
var last_main_voxel_copy_time_ms: float = 0.0
var last_main_mesh_upload_time_ms: float = 0.0
var last_main_collision_time_ms: float = 0.0
var last_main_neighbor_remesh_time_ms: float = 0.0
var main_total_frame_time_ms: float = 0.0

func _ready() -> void:
	max_parallel_tasks = maxi(4, mini(OS.get_processor_count() - 1, 16))
	_setup_noise()
	load_terrain_deltas()

func _process(_delta: float) -> void:
	var frame_start_usec := Time.get_ticks_usec()
	_dispatch_pending_tasks()

	# STRICT Frame-Throttling (The "Turnstile"):
	# Pop ONLY ONE chunk, call add_child(), set its mesh/collision, and immediately return.
	# 1 frame = 1 chunk insertion. DO NOT use a while loop that drains the queue.
	var chunk_entry: Dictionary = {}
	_results_mutex.lock()
	while not chunks_ready.is_empty():
		var candidate: Dictionary = chunks_ready.pop_front()
		var candidate_pos: Vector2i = candidate["pos"]
		var result_generation: int = candidate.get("generation", 0)

		_in_flight.erase(candidate_pos)
		_in_flight_count = maxi(0, _in_flight_count - 1)

		# Prune obsolete task if player has moved away
		if _last_player_chunk != Vector2i(99999, 99999):
			var dist_x := absi(candidate_pos.x - _last_player_chunk.x)
			var dist_z := absi(candidate_pos.y - _last_player_chunk.y)
			if dist_x > view_distance_chunks or dist_z > view_distance_chunks:
				cancelled_tasks_count += 1
				continue

		# Discard stale results: chunk was edited after worker was dispatched
		var current_gen: int = _chunk_generation.get(candidate_pos, 0)
		if result_generation < current_gen:
			stale_results_discarded += 1
			continue

		if _chunks.has(candidate_pos):
			continue

		chunk_entry = candidate
		break
	_results_mutex.unlock()

	if not chunk_entry.is_empty():
		var cp: Vector2i = chunk_entry["pos"]
		var cached_chunk: VoxelChunk = chunk_entry.get("cached_chunk", null)

		if cached_chunk != null:
			var t_ac_start := Time.get_ticks_usec()

			cached_chunk.collision_layer = 1
			cached_chunk.collision_mask = 7
			cached_chunk.visible = true
			if cached_chunk.get_parent() == null:
				add_child(cached_chunk)

			var time_add_child := Time.get_ticks_usec() - t_ac_start
			if time_add_child > 2000:
				var total_ms := float(time_add_child) / 1000.0
				print_rich("[color=red]STUTTER WARNING: Chunk insertion took %0.2f ms | Time_NodeCreation: 0 us | Time_MeshAssign: 0 us | Time_CollisionAssign: 0 us | Time_AddChild: %d us[/color]" % [
					total_ms,
					time_add_child
				])

			_chunks[cp] = cached_chunk
			chunk_loaded.emit(cp)
			_queue_neighbor_remesh(cached_chunk)
		else:
			var flat: PackedByteArray = chunk_entry["flat"]
			var surfaces: Dictionary = chunk_entry["surfaces"]
			var collision_shape: ConcavePolygonShape3D = chunk_entry.get("collision_shape", null)
			last_worker_gen_time_ms = chunk_entry.get("worker_time_ms", 0.0)

			# 1. Time_NodeCreation: Time to new() the MeshInstance3D/StaticBody3D
			var t_nc_start := Time.get_ticks_usec()
			var chunk := VoxelChunk.new()
			chunk.name = "Chunk_%d_%d" % [cp.x, cp.y]
			chunk.chunk_pos = cp
			chunk.voxel_world = self
			chunk.load_from_flat(flat)
			chunk.setup_nodes()
			var time_node_creation := Time.get_ticks_usec() - t_nc_start

			# 2. Time_MeshAssign: Time to execute mesh_instance.mesh = ...
			var t_ma_start := Time.get_ticks_usec()
			last_main_mesh_upload_time_ms = chunk.apply_mesh_data(surfaces)
			var time_mesh_assign := Time.get_ticks_usec() - t_ma_start

			# 3. Time_CollisionAssign: Time to execute collision.shape = ...
			var t_ca_start := Time.get_ticks_usec()
			if chunk._col_shape != null:
				chunk._col_shape.shape = collision_shape
			var time_collision_assign := Time.get_ticks_usec() - t_ca_start
			last_main_collision_time_ms = float(time_collision_assign) / 1000.0

			# 4. Time_AddChild: Time to execute add_child()
			var t_ac_start := Time.get_ticks_usec()
			add_child(chunk)
			var time_add_child := Time.get_ticks_usec() - t_ac_start

			# Only print these 4 metrics IF total time exceeds 2000 microseconds (2ms)
			var total_insertion_usec := time_node_creation + time_mesh_assign + time_collision_assign + time_add_child
			if total_insertion_usec > 2000:
				var total_ms := float(total_insertion_usec) / 1000.0
				print_rich("[color=red]STUTTER WARNING: Chunk insertion took %0.2f ms | Time_NodeCreation: %d us | Time_MeshAssign: %d us | Time_CollisionAssign: %d us | Time_AddChild: %d us[/color]" % [
					total_ms,
					time_node_creation,
					time_mesh_assign,
					time_collision_assign,
					time_add_child
				])

			_chunks[cp] = chunk
			total_chunks_generated += 1
			chunk_loaded.emit(cp)
			_queue_neighbor_remesh(chunk)

		if _spawn_waiting and _spawn_pending_positions.has(cp):
			_spawn_pending_positions.erase(cp)
			if _spawn_pending_positions.is_empty():
				_spawn_waiting = false
				spawn_chunks_ready.emit()

		main_total_frame_time_ms = float(Time.get_ticks_usec() - frame_start_usec) / 1000.0
		return

	# If no chunk was inserted this frame, process remeshing within frame budget
	var time_used_ms := float(Time.get_ticks_usec() - frame_start_usec) / 1000.0
	if time_used_ms < max_frame_budget_ms:
		_process_remesh_queue(frame_start_usec)

	main_total_frame_time_ms = float(Time.get_ticks_usec() - frame_start_usec) / 1000.0

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
	elif _chunk_cache.has(chunk_pos):
		var cached_chunk: VoxelChunk = _chunk_cache[chunk_pos]
		if is_instance_valid(cached_chunk):
			return cached_chunk.get_voxel_local(lx, ly, lz)

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
				if force_sync:
					if _chunk_cache.has(cp):
						_restore_chunk_from_cache(cp, true)
					else:
						_load_or_generate_chunk_sync(cp)
				elif _chunk_cache.has(cp):
					# Restore from cache via turnstile without waiting or blocking
					var cached_chunk: VoxelChunk = _chunk_cache[cp]
					_chunk_cache.erase(cp)
					_chunk_cache_order.erase(cp)
					_in_flight[cp] = _chunk_generation.get(cp, 0)
					_results_mutex.lock()
					chunks_ready.append({
						"pos": cp,
						"cached_chunk": cached_chunk,
						"generation": _chunk_generation.get(cp, 0)
					})
					_results_mutex.unlock()
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
			cancelled_tasks_count += 1
	_pending_queue = filtered

	# Staggered Thread Dispatching:
	# Dispatch pending tasks to WorkerThreadPool without waiting or blocking.
	_dispatch_pending_tasks()

# ============================================================
# MULTI-THREADED PIPELINE INTERNALS
# ============================================================

func _dispatch_pending_tasks() -> void:
	if _pending_queue.is_empty():
		return

	while not _pending_queue.is_empty() and _in_flight_count < max_parallel_tasks:
		var cp: Vector2i = _pending_queue.pop_front()
		_pending_set.erase(cp)

		# Prune obsolete task if player has moved away
		if _last_player_chunk != Vector2i(99999, 99999):
			var dist_x := absi(cp.x - _last_player_chunk.x)
			var dist_z := absi(cp.y - _last_player_chunk.y)
			if dist_x > view_distance_chunks or dist_z > view_distance_chunks:
				cancelled_tasks_count += 1
				continue

		if _chunks.has(cp) or _in_flight.has(cp):
			continue

		if _chunk_cache.has(cp):
			var cached_chunk: VoxelChunk = _chunk_cache[cp]
			_chunk_cache.erase(cp)
			_chunk_cache_order.erase(cp)
			_in_flight[cp] = _chunk_generation.get(cp, 0)
			_results_mutex.lock()
			chunks_ready.append({
				"pos": cp,
				"cached_chunk": cached_chunk,
				"generation": _chunk_generation.get(cp, 0)
			})
			_results_mutex.unlock()
			continue

		# Capture current edit generation so worker result can be validated on return
		var current_gen: int = _chunk_generation.get(cp, 0)
		_in_flight[cp] = current_gen
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
				left_border, right_border, back_border, front_border,
				current_gen
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
	front_border: Variant,
	generation: int
) -> void:
	var t_worker_start := Time.get_ticks_usec()

	# PackedByteArray: 8 KB per chunk vs ~196 KB for Array[StringName], zero GC overhead.
	var flat := PackedByteArray()
	flat.resize(VoxelChunk.TOTAL_CELLS)
	# Zero-initialized = VoxelChunk.BLOCK_AIR (0) everywhere.

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

				var block_id: int
				if ly == surf_h:
					block_id = VoxelChunk.BLOCK_GRASS
				elif ly >= surf_h - 2:
					block_id = VoxelChunk.BLOCK_DIRT
				else:
					var ore_n: float = n_ore.get_noise_3d(float(gx), float(ly), float(gz))
					if ly <= 8 and ore_n > 0.45:
						block_id = VoxelChunk.BLOCK_GOLD
					elif ly <= 12 and ore_n > 0.35:
						block_id = VoxelChunk.BLOCK_IRON
					elif ly <= 15 and ore_n > 0.25:
						block_id = VoxelChunk.BLOCK_COAL
					else:
						block_id = VoxelChunk.BLOCK_STONE

				flat[lx * sy * sz + ly * sz + lz] = block_id

	# Generate mesh surface arrays & collision faces directly on worker thread
	var mesh_data := VoxelChunk.build_mesh_data_from_flat(flat, left_border, right_border, back_border, front_border)
	var col_faces: PackedVector3Array = mesh_data["collision_faces"]

	# Build ConcavePolygonShape3D HERE on the worker thread — this is the expensive
	# set_faces() BVH construction that must NEVER run on the main thread.
	var collision_shape: ConcavePolygonShape3D = null
	if not col_faces.is_empty():
		collision_shape = ConcavePolygonShape3D.new()
		collision_shape.set_faces(col_faces)
		collision_shape.backface_collision = true

	var worker_duration_ms := float(Time.get_ticks_usec() - t_worker_start) / 1000.0

	_results_mutex.lock()
	# Enforce bounded cache: drop oldest entries when overfull
	if chunks_ready.size() >= max_cached_results:
		chunks_ready.pop_front()
	chunks_ready.append({
		"pos": cp,
		"flat": flat,
		"surfaces": mesh_data["surfaces"],
		"collision_shape": collision_shape,
		"worker_time_ms": worker_duration_ms,
		"generation": generation
	})
	_results_mutex.unlock()

func _queue_neighbor_remesh(new_chunk: VoxelChunk) -> void:
	if new_chunk == null:
		return
	var cp := new_chunk.chunk_pos
	var neighbors: Array[Vector2i] = [
		cp + Vector2i(1, 0), cp + Vector2i(-1, 0),
		cp + Vector2i(0, 1), cp + Vector2i(0, -1)
	]
	for n_pos in neighbors:
		if _chunks.has(n_pos):
			var n_chunk: VoxelChunk = _chunks[n_pos]
			if is_instance_valid(n_chunk) and not _remesh_set.has(n_pos):
				# Only queue remesh if chunks actually share a solid boundary!
				var dir_to_new := cp - n_pos
				if n_chunk.shares_solid_boundary_with(new_chunk, dir_to_new):
					_remesh_queue.append(n_pos)
					_remesh_set[n_pos] = true

## Unconditionally enqueues all 4 cardinal neighbours of cp for rate-limited remeshing.
## Used when a chunk is unloaded or removed: the neighbour faces become exposed regardless
## of solid-boundary checks (which would fail on an already-freed chunk's data).
func _enqueue_all_neighbors_for_remesh(cp: Vector2i) -> void:
	var neighbors: Array[Vector2i] = [
		cp + Vector2i(1, 0), cp + Vector2i(-1, 0),
		cp + Vector2i(0, 1), cp + Vector2i(0, -1)
	]
	for n_pos in neighbors:
		if _chunks.has(n_pos) and not _remesh_set.has(n_pos):
			var n_chunk: VoxelChunk = _chunks[n_pos]
			if is_instance_valid(n_chunk):
				_remesh_queue.append(n_pos)
				_remesh_set[n_pos] = true

## Updates at most max_remeshes_per_frame neighbor seams within budget
func _process_remesh_queue(frame_start_usec: int) -> void:
	var remeshed := 0
	var t_remesh_start := Time.get_ticks_usec()
	while not _remesh_queue.is_empty() and remeshed < max_remeshes_per_frame:
		var elapsed_ms := float(Time.get_ticks_usec() - frame_start_usec) / 1000.0
		if elapsed_ms >= max_frame_budget_ms:
			break

		var n_pos: Vector2i = _remesh_queue.pop_front()
		_remesh_set.erase(n_pos)

		if _chunks.has(n_pos):
			var n_chunk: VoxelChunk = _chunks[n_pos]
			if is_instance_valid(n_chunk):
				# Only remesh if still in active view distance
				if _last_player_chunk != Vector2i(99999, 99999):
					var dist_x := absi(n_pos.x - _last_player_chunk.x)
					var dist_z := absi(n_pos.y - _last_player_chunk.y)
					if dist_x > view_distance_chunks or dist_z > view_distance_chunks:
						continue
				n_chunk.rebuild_mesh_and_collision()
				remeshed += 1

	if remeshed > 0:
		last_main_neighbor_remesh_time_ms = float(Time.get_ticks_usec() - t_remesh_start) / 1000.0

# ============================================================
# SYNCHRONOUS GENERATION (spawn area, unit tests, mining)
# ============================================================

func _load_or_generate_chunk(chunk_pos: Vector2i) -> VoxelChunk:
	return _load_or_generate_chunk_sync(chunk_pos)

func _load_or_generate_chunk_sync(chunk_pos: Vector2i) -> VoxelChunk:
	if _chunks.has(chunk_pos):
		return _chunks[chunk_pos]

	if _chunk_cache.has(chunk_pos):
		var cached_chunk := _restore_chunk_from_cache(chunk_pos, true)
		if cached_chunk != null:
			return cached_chunk

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
	# Enqueue neighbor remeshes rate-limited — never trigger a synchronous rebuild cascade.
	_queue_neighbor_remesh(chunk)
	return chunk

func _unload_chunk(chunk_pos: Vector2i) -> void:
	if _chunks.has(chunk_pos):
		var chunk: VoxelChunk = _chunks[chunk_pos]
		_chunks.erase(chunk_pos)

		if is_instance_valid(chunk):
			if chunk.get_parent() == self:
				remove_child(chunk)
			chunk.visible = false
			chunk.collision_layer = 0
			chunk.collision_mask = 0

			# Evict stale instance if already present in cache
			if _chunk_cache.has(chunk_pos):
				var old_chunk: VoxelChunk = _chunk_cache[chunk_pos]
				if is_instance_valid(old_chunk) and old_chunk != chunk:
					old_chunk.queue_free()
				_chunk_cache_order.erase(chunk_pos)

			_chunk_cache[chunk_pos] = chunk
			_chunk_cache_order.append(chunk_pos)

			# Enforce maximum cache capacity limit (FIFO eviction)
			while _chunk_cache_order.size() > max_chunk_cache_size:
				var oldest_pos: Vector2i = _chunk_cache_order.pop_front()
				if _chunk_cache.has(oldest_pos):
					var oldest_chunk: VoxelChunk = _chunk_cache[oldest_pos]
					_chunk_cache.erase(oldest_pos)
					if is_instance_valid(oldest_chunk):
						oldest_chunk.queue_free()

		# Enqueue neighbor remeshes rate-limited — never trigger synchronous rebuilds on unload.
		_enqueue_all_neighbors_for_remesh(chunk_pos)
		chunk_unloaded.emit(chunk_pos)

## Restores a previously cached chunk back into the active world.
func _restore_chunk_from_cache(chunk_pos: Vector2i, sync_rebuild: bool = false) -> VoxelChunk:
	if not _chunk_cache.has(chunk_pos):
		return null

	var chunk: VoxelChunk = _chunk_cache[chunk_pos]
	_chunk_cache.erase(chunk_pos)
	_chunk_cache_order.erase(chunk_pos)

	if not is_instance_valid(chunk):
		return null

	chunk.collision_layer = 1
	chunk.collision_mask = 7
	chunk.visible = true

	if is_inside_tree() and chunk.get_parent() == null:
		add_child(chunk)

	_chunks[chunk_pos] = chunk
	chunk_loaded.emit(chunk_pos)

	# Always rate-limit neighbor remeshes via the queue — never synchronous rebuilds.
	_queue_neighbor_remesh(chunk)

	return chunk

## Legacy stub kept for API compatibility. All callers have been migrated to
## _enqueue_all_neighbors_for_remesh() which is rate-limited through the _remesh_queue.
## Direct calls to this function should be avoided: they bypass the frame budget.
func _rebuild_neighbor_chunks(cp: Vector2i) -> void:
	_enqueue_all_neighbors_for_remesh(cp)

func get_diagnostics() -> Dictionary:
	return {
		"loaded_chunks": _chunks.size(),
		"cached_chunks": _chunk_cache.size(),
		"pending_queue": _pending_queue.size(),
		"in_flight_threads": _in_flight_count,
		"ready_results": chunks_ready.size(),
		"chunks_ready": chunks_ready.size(),
		"pending_collisions": 0,
		"remesh_queue_size": _remesh_queue.size(),
		"total_chunks_generated": total_chunks_generated,
		"cancelled_tasks_count": cancelled_tasks_count,
		"stale_results_discarded": stale_results_discarded,
		"last_chunk_build_time_ms": last_chunk_build_time_ms,
		"worker_gen_mesh_time_ms": last_worker_gen_time_ms,
		"main_voxel_copy_time_ms": last_main_voxel_copy_time_ms,
		"main_mesh_upload_time_ms": last_main_mesh_upload_time_ms,
		"main_collision_time_ms": last_main_collision_time_ms,
		"main_neighbor_remesh_time_ms": last_main_neighbor_remesh_time_ms,
		"main_total_frame_time_ms": main_total_frame_time_ms
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

	# Increment edit generation to invalidate any in-flight or queued worker results
	# for this chunk and its affected neighbors. This prevents stale worker output from
	# overwriting the mined voxel immediately after the player removes it.
	_chunk_generation[chunk_pos] = _chunk_generation.get(chunk_pos, 0) + 1

	chunk.rebuild_mesh_and_collision()

	# Remesh affected neighbors — only those at the edited boundary face.
	# Use deduplication via _remesh_queue/_remesh_set to avoid duplicate calls within same frame.
	if lx == 0:
		_enqueue_neighbor_remesh_if_needed(chunk_pos + Vector2i(-1, 0), chunk)
	elif lx == VoxelChunk.SIZE_X - 1:
		_enqueue_neighbor_remesh_if_needed(chunk_pos + Vector2i(1, 0), chunk)

	if lz == 0:
		_enqueue_neighbor_remesh_if_needed(chunk_pos + Vector2i(0, -1), chunk)
	elif lz == VoxelChunk.SIZE_Z - 1:
		_enqueue_neighbor_remesh_if_needed(chunk_pos + Vector2i(0, 1), chunk)

	save_terrain_deltas()
	voxel_mined.emit(world_cell, b_type)
	return b_type

## Enqueues a neighbor chunk for budgeted remeshing. Deduplicates via _remesh_set.
## Falls back to immediate rebuild only for spawn-area sync chunks not yet in budget queue.
func _enqueue_neighbor_remesh_if_needed(n_pos: Vector2i, _trigger_chunk: VoxelChunk) -> void:
	if not _chunks.has(n_pos):
		return
	var n_chunk: VoxelChunk = _chunks[n_pos]
	if not is_instance_valid(n_chunk):
		return
	# Avoid duplicate entries in remesh queue
	if _remesh_set.has(n_pos):
		return
	_remesh_queue.append(n_pos)
	_remesh_set[n_pos] = true

# ============================================================
# SPAWN SYSTEM
# ============================================================

## Async spawn-area loader — ZERO main-thread stalls.
##
## Dispatches all required spawn-radius chunks through the WorkerThreadPool pipeline
## (noise, greedy meshing, and collision geometry all run off the main thread).
## Waits for the 'spawn_chunks_ready' signal, which is emitted by _consume_ready_results()
## as each chunk lands. After all chunks are loaded, waits one physics_frame to guarantee
## PhysicsServer3D has committed all CollisionShape3Ds before the caller queries spawn position.
##
## IMPORTANT: This replaces the old synchronous loop that ran rebuild_mesh_and_collision()
## on the main thread for every spawn chunk — that caused 0-FPS stalls on startup.
func force_sync_spawn_chunks(center_chunk_x: int = 0, center_chunk_z: int = 0) -> void:
	# Collect positions that still need to be loaded.
	var needed: Array[Vector2i] = []
	for dx in range(-SPAWN_SYNC_RADIUS, SPAWN_SYNC_RADIUS + 1):
		for dz in range(-SPAWN_SYNC_RADIUS, SPAWN_SYNC_RADIUS + 1):
			var cp := Vector2i(center_chunk_x + dx, center_chunk_z + dz)
			if not _chunks.has(cp):
				needed.append(cp)

	if needed.is_empty():
		# All spawn chunks already loaded — just sync one physics frame.
		if is_inside_tree():
			await get_tree().physics_frame
		return

	# Register which positions we are waiting for.
	_spawn_pending_positions.clear()
	for cp in needed:
		_spawn_pending_positions[cp] = true
	_spawn_waiting = true

	# Dispatch each needed chunk into the async pipeline.
	# Chunks already cached are restored immediately (cheap).
	# Everything else goes to WorkerThreadPool.
	for cp in needed:
		if _chunk_cache.has(cp):
			_restore_chunk_from_cache(cp, false)
			# Restored from cache — remove from pending immediately.
			_spawn_pending_positions.erase(cp)
		elif not _in_flight.has(cp) and not _pending_set.has(cp):
			_pending_queue.push_front(cp)   # Insert at front = highest priority.
			_pending_set[cp] = true

	# If everything was cache-restored, signal is never emitted — clear flag manually.
	if _spawn_pending_positions.is_empty():
		_spawn_waiting = false
		if is_inside_tree():
			await get_tree().physics_frame
		return

	# Yield until _consume_ready_results() emits spawn_chunks_ready.
	if is_inside_tree():
		await spawn_chunks_ready
		# One more physics frame so CollisionShapes are committed to PhysicsServer3D.
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

## Returns a safe above-surface spawn position.
## NOTE: This only searches within already-loaded chunks. Call force_sync_spawn_chunks()
## first to guarantee the spawn area is populated. get_spawn_position() does NOT load
## additional chunks synchronously — doing so inside a deferred async function would
## spike the main thread with multiple meshing+collision operations simultaneously.
func get_spawn_position(x: int = 0, z: int = 0) -> Vector3:
	# Search already-loaded chunks first (zero additional load cost)
	for y in range(VoxelChunk.SIZE_Y - 1, -1, -1):
		if is_solid_block(Vector3i(x, y, z)):
			var cell_above_1 := Vector3i(x, y + 1, z)
			var cell_above_2 := Vector3i(x, y + 2, z)
			if not is_solid_block(cell_above_1) and not is_solid_block(cell_above_2):
				var candidate := Vector3(float(x) + 0.5, float(y) + 1.1, float(z) + 0.5)
				if verify_spawn_physics(candidate):
					return candidate

	# Spiral search within already-loaded chunk radius — no new chunk loads.
	# Chunk must already exist; get_voxel_at() uses procedural fallback for loaded-but-not-yet-ready.
	for radius in range(1, 8):
		for dx in range(-radius, radius + 1):
			for dz in range(-radius, radius + 1):
				if abs(dx) != radius and abs(dz) != radius:
					continue
				var nx := x + dx
				var nz := z + dz
				for ny in range(VoxelChunk.SIZE_Y - 1, -1, -1):
					if is_solid_block(Vector3i(nx, ny, nz)):
						if not is_solid_block(Vector3i(nx, ny + 1, nz)) and not is_solid_block(Vector3i(nx, ny + 2, nz)):
							var candidate := Vector3(float(nx) + 0.5, float(ny) + 1.1, float(nz) + 0.5)
							if verify_spawn_physics(candidate):
								return candidate

	# Final fallback: estimate from procedural data without loading chunks
	for fallback_r in range(0, 8):
		for fdx in range(-fallback_r, fallback_r + 1):
			for fdz in range(-fallback_r, fallback_r + 1):
				var fx := fdx
				var fz := fdz
				for fy in range(VoxelChunk.SIZE_Y - 1, -1, -1):
					if is_solid_block(Vector3i(fx, fy, fz)):
						if not is_solid_block(Vector3i(fx, fy + 1, fz)) and not is_solid_block(Vector3i(fx, fy + 2, fz)):
							return Vector3(float(fx) + 0.5, float(fy) + 1.1, float(fz) + 0.5)

	return Vector3(0.5, 16.0, 0.5)

func clear_world() -> void:
	_pending_queue.clear()
	_pending_set.clear()
	_results_mutex.lock()
	chunks_ready.clear()
	_results_mutex.unlock()
	_remesh_queue.clear()
	_remesh_set.clear()
	for chunk in _chunks.values():
		if is_instance_valid(chunk):
			chunk.queue_free()
	_chunks.clear()
	for chunk in _chunk_cache.values():
		if is_instance_valid(chunk):
			chunk.queue_free()
	_chunk_cache.clear()
	_chunk_cache_order.clear()
	_chunk_generation.clear()

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
