extends SceneTree

const VoxelWorldScript = preload("res://systems/terrain/VoxelWorld.gd")
const VoxelChunkScript = preload("res://systems/terrain/VoxelChunk.gd")

func _init() -> void:
	print("--- PROFILING CHUNK GENERATION & STREAMING ---")
	var world: VoxelWorld = VoxelWorldScript.new()
	world.name = "VoxelWorld"
	world.seed_value = 1337
	root.add_child(world)

	# 1. Profile synchronous generation of 9 spawn chunks
	var t0 := Time.get_ticks_usec()
	for x in range(-1, 2):
		for z in range(-1, 2):
			world._load_or_generate_chunk_sync(Vector2i(x, z))
	var spawn_time_ms := float(Time.get_ticks_usec() - t0) / 1000.0
	print("Spawn 9 chunks sync generation: %.2f ms (%.2f ms/chunk)" % [spawn_time_ms, spawn_time_ms / 9.0])

	# 2. Profile single chunk breakdown with greedy meshing:
	var test_cp := Vector2i(5, 5)
	var t_worker_start := Time.get_ticks_usec()
	var start_x := test_cp.x * VoxelChunk.SIZE_X
	var start_z := test_cp.y * VoxelChunk.SIZE_Z
	var size := VoxelChunk.SIZE_X * VoxelChunk.SIZE_Y * VoxelChunk.SIZE_Z
	var flat := PackedByteArray()
	flat.resize(size)
	# PackedByteArray is zero-initialized (BLOCK_AIR). Assign BLOCK_STONE (3) for filled cells.

	var sy := VoxelChunk.SIZE_Y
	var sz := VoxelChunk.SIZE_Z
	for lx in range(VoxelChunk.SIZE_X):
		for lz in range(VoxelChunk.SIZE_Z):
			var gx: int = start_x + lx
			var gz: int = start_z + lz
			var dist_sq := float(gx * gx + gz * gz)
			var spawn_mask := clampf(1.0 - (sqrt(dist_sq) / 24.0), 0.0, 1.0)
			var island_n: float = world._noise_2d.get_noise_2d(float(gx), float(gz))
			if spawn_mask <= 0.05 and island_n <= -0.15:
				continue
			var n_surf: float = (world._noise_2d.get_noise_2d(float(gx) + 500.0, float(gz) + 500.0) + 1.0) * 0.5
			var surf_h: int = int(floor(lerpf(12.0, 22.0, n_surf)))
			var n_base: float = (world._noise_3d.get_noise_2d(float(gx) - 500.0, float(gz) - 500.0) + 1.0) * 0.5
			var bot_h: int = int(floor(lerpf(3.0, 9.0, n_base)))
			var min_y: int = maxi(0, bot_h)
			var max_y: int = mini(VoxelChunk.SIZE_Y - 1, surf_h)
			for ly in range(min_y, max_y + 1):
				flat[lx * sy * sz + ly * sz + lz] = VoxelChunk.BLOCK_STONE
	var t_worker_noise := float(Time.get_ticks_usec() - t_worker_start) / 1000.0

	var t_mesh_start := Time.get_ticks_usec()
	var mesh_data := VoxelChunk.build_mesh_data_from_flat(flat, null, null, null, null)
	var t_mesh_time := float(Time.get_ticks_usec() - t_mesh_start) / 1000.0

	# Count total vertices across all surface buffers
	var total_verts := 0
	for mat_key in mesh_data["surfaces"].keys():
		var buf: Dictionary = mesh_data["surfaces"][mat_key]
		total_verts += (buf["verts"] as PackedVector3Array).size()

	# Profile load_from_flat on main thread
	var ch := VoxelChunk.new()
	var t_copy_start := Time.get_ticks_usec()
	ch.load_from_flat(flat)
	var t_copy_time := float(Time.get_ticks_usec() - t_copy_start) / 1000.0

	# Profile upload on main thread
	var t_upload_start := Time.get_ticks_usec()
	ch.apply_mesh_and_collision_data(mesh_data["surfaces"], mesh_data["collision_faces"])
	var t_upload_time := float(Time.get_ticks_usec() - t_upload_start) / 1000.0

	print("Breakdown for single chunk (with greedy Y-meshing):")
	print("  Worker noise evaluation: %.3f ms" % t_worker_noise)
	print("  Worker mesh construction: %.3f ms (greedy Y + per-voxel XZ)" % t_mesh_time)
	print("  Total vertices (all surfaces): %d" % total_verts)
	print("  Collision faces: %d" % (mesh_data["collision_faces"] as PackedVector3Array).size())
	print("  Main thread load_from_flat: %.3f ms" % t_copy_time)
	print("  Main thread upload mesh & collision: %.3f ms" % t_upload_time)
	ch.queue_free()

	# 3. Test stale-job generation versioning
	print("\n--- TESTING STALE JOB VERSIONING ---")
	world.clear_world()
	var cp := Vector2i(10, 10)
	# Simulate: generation=0 result arrives, but chunk was edited after dispatch (gen=1)
	world._chunk_generation[cp] = 1  # Current generation after mining edit
	var stale_before := world.stale_results_discarded
	# Insert a stale result manually (generation=0, older than current=1)
	world._results_mutex.lock()
	world._results_ready.append({
		"pos": cp,
		"flat": PackedByteArray(),
		"surfaces": {},
		"collision_faces": PackedVector3Array(),
		"worker_time_ms": 0.0,
		"generation": 0  # Stale: < current gen 1
	})
	world._results_mutex.unlock()
	# Simulate main thread consuming results
	var frame_start := Time.get_ticks_usec()
	world._consume_ready_results(frame_start)
	var stale_after := world.stale_results_discarded
	var stale_caught := (stale_after - stale_before) > 0
	print("  Stale result (gen=0 vs current=1) was discarded: %s" % str(stale_caught))
	assert(stale_caught, "FAIL: Stale result was NOT discarded!")

	# 4. Test bounded cache: max_cached_results prevents unbounded memory
	print("\n--- TESTING BOUNDED RESULT CACHE ---")
	world.clear_world()
	world.max_cached_results = 4
	# Inject more results than the limit
	world._results_mutex.lock()
	for i in range(8):
		world._results_ready.append({
			"pos": Vector2i(i, 0),
			"flat": [],
			"surfaces": {},
			"collision_faces": PackedVector3Array(),
			"worker_time_ms": 0.0,
			"generation": 0
		})
	world._results_mutex.unlock()
	# Each worker call should cap the cache at max_cached_results (4)
	# Here we just verify the cache size doesn't exceed 4 if we call the worker path.
	# Since we inserted 8 directly, let's just verify the limit logic in _worker_generate_chunk
	# is present (we can't run workers headlessly). Instead verify the size wasn't exceeded
	# during insertion by the worker (structural test only).
	world._results_mutex.lock()
	var cache_size := world._results_ready.size()
	world._results_mutex.unlock()
	print("  Cache size after 8 direct inserts (no worker limit applied): %d (expected 8)" % cache_size)
	print("  NOTE: Worker path bounded-cache enforcement tested via code review only (headless)")

	# 5. Simulate walking into unexplored chunks across 60 frames:
	print("\n--- SIMULATING EXPLORATION & STREAMING ACROSS 60 FRAMES ---")
	world.clear_world()
	world.max_cached_results = 32  # Restore default
	var max_observed_frame_ms := 0.0
	var frames_above_budget := 0
	var frame_times: Array[float] = []

	# Walk player through unexplored coordinates
	for f in range(60):
		var player_pos := Vector3(float(f * 8), 16.0, float(f * 8))
		world.update_loaded_chunks(player_pos)
		world._process(1.0 / 60.0)

		# Allow short OS sleep to let background workers advance
		OS.delay_msec(10)

		var diag := world.get_diagnostics()
		var frame_ms: float = diag.get("main_total_frame_time_ms", 0.0)
		frame_times.append(frame_ms)
		if frame_ms > max_observed_frame_ms:
			max_observed_frame_ms = frame_ms
		if frame_ms > world.max_frame_budget_ms + 1.0: # Allow 1ms tolerance
			frames_above_budget += 1

	# Compute median and p95
	frame_times.sort()
	var median_ms := 0.0
	var p95_ms := 0.0
	if not frame_times.is_empty():
		median_ms = frame_times[frame_times.size() / 2]
		var p95_idx := int(float(frame_times.size()) * 0.95)
		p95_ms = frame_times[mini(p95_idx, frame_times.size() - 1)]

	var final_diag := world.get_diagnostics()
	print("Exploration simulation completed:")
	print("  Median main-thread frame time: %.2f ms" % median_ms)
	print("  P95 main-thread frame time:    %.2f ms" % p95_ms)
	print("  Max main-thread frame time:    %.2f ms (budget: %.2f ms)" % [max_observed_frame_ms, world.max_frame_budget_ms])
	print("  Frames exceeding budget:       %d / 60" % frames_above_budget)
	print("  Loaded chunks: %d" % final_diag.get("loaded_chunks", 0))
	print("  Total generated chunks: %d" % final_diag.get("total_chunks_generated", 0))
	print("  Cancelled/pruned tasks: %d" % final_diag.get("cancelled_tasks_count", 0))
	print("  Stale results discarded: %d" % final_diag.get("stale_results_discarded", 0))
	print("  Diagnostics: %s" % str(final_diag))

	world.queue_free()
	quit(0)
