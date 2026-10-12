class_name VoxelWorld
extends Node3D

## VoxelWorld — wrapper around Zylann's VoxelTerrain + VoxelMesherBlocky.
## Streaming / collisions / mining use CHANNEL_TYPE. Public API kept for GameWorld.

const BLOCK_AIR:   int = 0
const BLOCK_GRASS: int = 1
const BLOCK_DIRT:  int = 2
const BLOCK_STONE: int = 3
const BLOCK_COAL:  int = 4
const BLOCK_IRON:  int = 5
const BLOCK_GOLD:  int = 6

const WORLD_HEIGHT: int = 128
const ISLAND_Y_MIN: float = 32.0
const ISLAND_Y_MAX: float = 80.0
const SURF_MIN: float = ISLAND_Y_MIN
const SURF_MAX: float = ISLAND_Y_MAX
const SPAWN_SYNC_RADIUS: int = 2

signal voxel_mined(world_cell: Vector3i, block_type: StringName)
signal spawn_chunks_ready
signal view_distance_changed(voxels: int, chunks: int)

const VIEW_DIST_CHUNKS_MIN: int = 16
const VIEW_DIST_CHUNKS_MAX: int = 32

@export var seed_value: int = 1337:
	set(val):
		seed_value = val
		_apply_generator_params()

@export var view_distance_chunks: int = 20:
	set(val):
		view_distance_chunks = clampi(val, VIEW_DIST_CHUNKS_MIN, VIEW_DIST_CHUNKS_MAX)
		_sync_view_distance()

@export var noise_frequency_2d: float = 0.0075
@export var noise_frequency_3d: float = 0.040
@export var noise_frequency_ore: float = 0.12
@export var island_density_threshold: float = 0.30
@export var island_vertical_scale: float = 3.5

var _terrain: VoxelTerrain = null
var _viewer: VoxelViewer = null
var _library: VoxelBlockyLibrary = null
var _voxel_tool: VoxelTool = null
var _chunks: Dictionary = {}

var _noise_2d: FastNoiseLite = null
var _noise_3d: FastNoiseLite = null
var _noise_ore: FastNoiseLite = null
var _island_gen = null

const _IslandGeneratorScript = preload("res://systems/terrain/IslandGenerator.gd")

const DELTA_SAVE_PATH: String = "user://terrain_deltas.json"
var _mined_deltas: Dictionary = {}
var _mined_deltas_set: Dictionary = {}

## Legacy test stubs
var stale_results_discarded: int = 0
var _chunk_generation: Dictionary = {}
var _results_ready: Array = []
var _results_mutex := Mutex.new()
var _chunk_cache: Dictionary = {}
var max_chunk_cache_size: int = 32
var max_cached_results: int = 32
var max_frame_budget_ms: float = 8.0

var _view_down_prev: bool = false
var _view_up_prev: bool = false
var _delta_reapply_timer: float = 0.0

func _ready() -> void:
	_setup_fallback_noise()
	load_terrain_deltas()
	_build_library()
	_build_terrain()
	_build_viewer()
	_apply_persisted_deltas()

func _process(delta: float) -> void:
	if _viewer == null:
		return
	var mouse_free: bool = Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED
	if not mouse_free:
		var down_pressed := (
			(InputMap.has_action(&"view_distance_down") and Input.is_action_pressed(&"view_distance_down"))
			or Input.is_physical_key_pressed(KEY_MINUS)
			or Input.is_physical_key_pressed(KEY_KP_SUBTRACT)
			or Input.is_physical_key_pressed(KEY_BRACKETLEFT)
		)
		if down_pressed and not _view_down_prev:
			adjust_view_distance_chunks(-1)
		_view_down_prev = down_pressed

		var up_pressed := (
			(InputMap.has_action(&"view_distance_up") and Input.is_action_pressed(&"view_distance_up"))
			or Input.is_physical_key_pressed(KEY_EQUAL)
			or Input.is_physical_key_pressed(KEY_KP_ADD)
			or Input.is_physical_key_pressed(KEY_BRACKETRIGHT)
		)
		if up_pressed and not _view_up_prev:
			adjust_view_distance_chunks(1)
		_view_up_prev = up_pressed
	else:
		_view_down_prev = false
		_view_up_prev = false

	if not _mined_deltas.is_empty():
		_delta_reapply_timer += delta
		if _delta_reapply_timer >= 0.75:
			_delta_reapply_timer = 0.0
			var center: Vector3 = _viewer.global_position if _viewer.is_inside_tree() else Vector3.ZERO
			_apply_persisted_deltas_near(center, float(_effective_view_distance()))

# ---------------------------------------------------------------------------
# Library + VoxelTerrain (Blocky) — known-good streaming path
# ---------------------------------------------------------------------------
func _build_library() -> void:
	_library = VoxelBlockyLibrary.new()

	var air := VoxelBlockyModelEmpty.new()
	_library.add_model(air)

	var add_cube := func(albedo: Color, rough: float = 0.8, metal: float = 0.0) -> void:
		var mat := StandardMaterial3D.new()
		mat.albedo_color = albedo
		mat.roughness = rough
		mat.metallic = metal
		var cube := VoxelBlockyModelCube.new()
		cube.set_material_override(0, mat)
		_library.add_model(cube)

	add_cube.call(Color(0.28, 0.62, 0.24), 0.85, 0.0) # grass
	add_cube.call(Color(0.42, 0.30, 0.20), 0.90, 0.0) # dirt
	add_cube.call(Color(0.52, 0.54, 0.58), 0.80, 0.0) # stone
	add_cube.call(Color(0.22, 0.22, 0.24), 0.90, 0.0) # coal
	add_cube.call(Color(0.72, 0.74, 0.78), 0.50, 0.60) # iron
	add_cube.call(Color(0.90, 0.76, 0.10), 0.25, 0.85) # gold
	_library.bake()

func _build_terrain() -> void:
	_terrain = VoxelTerrain.new()
	_terrain.name = "VoxelTerrain"

	var mesher := VoxelMesherBlocky.new()
	mesher.library = _library
	_terrain.mesher = mesher

	_island_gen = _IslandGeneratorScript.new()
	_island_gen.noise_island = _noise_3d
	_island_gen.noise_island_2d = _noise_2d
	_island_gen.noise_ore = _noise_ore
	_island_gen.density_threshold = island_density_threshold
	_island_gen.vertical_scale = island_vertical_scale
	_terrain.generator = _island_gen

	_terrain.generate_collisions = true
	_terrain.collision_layer = 1
	_terrain.collision_mask = 1
	_terrain.mesh_block_size = 16
	_terrain.automatic_loading_enabled = true
	_terrain.block_enter_notification_enabled = true
	if _terrain.has_signal("mesh_block_entered"):
		_terrain.mesh_block_entered.connect(_on_mesh_block_entered)

	_sync_view_distance()
	add_child(_terrain)

	_voxel_tool = _terrain.get_voxel_tool()
	if _voxel_tool != null:
		_voxel_tool.channel = VoxelBuffer.CHANNEL_TYPE

func _on_mesh_block_entered(_block_pos: Vector3i) -> void:
	if is_chunk_ready(Vector3(0.5, 56.0, 0.5)):
		spawn_chunks_ready.emit()

func _build_viewer() -> void:
	_viewer = VoxelViewer.new()
	_viewer.name = "VoxelViewer"
	_viewer.requires_collisions = true
	_viewer.requires_visuals = true
	_sync_view_distance()
	add_child(_viewer)

func attach_viewer_to_player(player_node: Node3D) -> void:
	if _viewer == null or player_node == null:
		return
	if _viewer.get_parent() != null:
		_viewer.get_parent().remove_child(_viewer)
	player_node.add_child(_viewer)
	_viewer.position = Vector3.ZERO
	_viewer.requires_collisions = true
	_viewer.requires_visuals = true
	_sync_view_distance()

func get_view_distance_voxels() -> int:
	return _effective_view_distance()

func get_view_distance_chunks() -> int:
	return view_distance_chunks

func adjust_view_distance_chunks(delta: int) -> void:
	view_distance_chunks = clampi(view_distance_chunks + delta, VIEW_DIST_CHUNKS_MIN, VIEW_DIST_CHUNKS_MAX)

func _effective_view_distance() -> int:
	return view_distance_chunks * 16

func _sync_view_distance() -> void:
	var dist := _effective_view_distance()
	if _viewer != null:
		_viewer.view_distance = dist
		_viewer.requires_visuals = true
		_viewer.requires_collisions = true
		# Enough vertical reach so floating islands below the player still stream.
		if "view_distance_vertical_ratio" in _viewer:
			_viewer.view_distance_vertical_ratio = 1.0
	if _terrain != null:
		_terrain.max_view_distance = dist
	view_distance_changed.emit(dist, view_distance_chunks)

func _apply_generator_params() -> void:
	_setup_fallback_noise()
	if _island_gen != null:
		_island_gen.noise_island = _noise_3d
		_island_gen.noise_island_2d = _noise_2d
		_island_gen.noise_ore = _noise_ore
		_island_gen.density_threshold = island_density_threshold

func _setup_fallback_noise() -> void:
	_noise_2d = FastNoiseLite.new()
	_noise_2d.seed = seed_value
	_noise_2d.noise_type = FastNoiseLite.TYPE_PERLIN
	_noise_2d.frequency = noise_frequency_2d
	_noise_2d.fractal_type = FastNoiseLite.FRACTAL_FBM
	_noise_2d.fractal_octaves = 3
	_noise_2d.fractal_lacunarity = 2.0
	_noise_2d.fractal_gain = 0.45

	_noise_3d = FastNoiseLite.new()
	_noise_3d.seed = seed_value + 100
	_noise_3d.noise_type = FastNoiseLite.TYPE_PERLIN
	_noise_3d.frequency = noise_frequency_3d

	_noise_ore = FastNoiseLite.new()
	_noise_ore.seed = seed_value + 200
	_noise_ore.noise_type = FastNoiseLite.TYPE_PERLIN
	_noise_ore.frequency = noise_frequency_ore

# ---------------------------------------------------------------------------
# Spawn helpers
# ---------------------------------------------------------------------------
func has_voxel(world_cell: Vector3i) -> bool:
	if _terrain != null and _voxel_tool != null and _has_data_at(world_cell):
		_voxel_tool.channel = VoxelBuffer.CHANNEL_TYPE
		return _voxel_tool.get_voxel(world_cell) != BLOCK_AIR
	return is_solid_block(world_cell)

func _has_data_at(world_cell: Vector3i) -> bool:
	if _terrain == null:
		return false
	var block_pos: Vector3i = _terrain.voxel_to_data_block(Vector3(world_cell))
	return _terrain.has_data_block(block_pos)

func is_chunk_ready(world_pos: Vector3) -> bool:
	if _terrain == null:
		return true
	var ipos := Vector3i(int(floor(world_pos.x)), int(floor(world_pos.y)), int(floor(world_pos.z)))
	# Prefer a sample inside the island band so readiness matches real terrain.
	var probe := Vector3i(ipos.x, clampi(ipos.y, int(ISLAND_Y_MIN), int(ISLAND_Y_MAX)), ipos.z)
	if not _has_data_at(probe):
		return get_highest_solid_y(ipos.x, ipos.z) >= 0 and _viewer_near_enough(world_pos)
	return get_highest_solid_y(ipos.x, ipos.z) >= 0

func _viewer_near_enough(world_pos: Vector3) -> bool:
	if _viewer == null:
		return true
	var vp: Vector3 = _viewer.global_position if _viewer.is_inside_tree() else Vector3.ZERO
	return vp.distance_to(world_pos) < float(_effective_view_distance())

func wait_for_terrain_at(world_pos: Vector3) -> void:
	if not is_inside_tree() or _terrain == null:
		return
	if is_chunk_ready(world_pos):
		await get_tree().process_frame
		return
	var max_wait_cycles := 240
	var cycles := 0
	while not is_chunk_ready(world_pos) and cycles < max_wait_cycles:
		cycles += 1
		await get_tree().process_frame
	_apply_persisted_deltas()
	await get_tree().physics_frame
	await get_tree().process_frame
	spawn_chunks_ready.emit()

func force_sync_spawn_chunks(cx: int = 0, cz: int = 0) -> void:
	if not is_inside_tree():
		return
	# Wait on a point inside the floating-island band (not y=16 void).
	var world_pos := Vector3(float(cx * 16) + 0.5, 56.0, float(cz * 16) + 0.5)
	await wait_for_terrain_at(world_pos)

func get_highest_solid_y(x: int, z: int) -> int:
	if _voxel_tool != null:
		_voxel_tool.channel = VoxelBuffer.CHANNEL_TYPE
		var ray_origin := Vector3(float(x) + 0.5, float(WORLD_HEIGHT) + 4.0, float(z) + 0.5)
		var hit = _voxel_tool.raycast(ray_origin, Vector3.DOWN, float(WORLD_HEIGHT) + 8.0)
		if hit != null:
			return hit.position.y

	if _terrain != null and _voxel_tool != null and _has_data_at(Vector3i(x, int(ISLAND_Y_MAX), z)):
		_voxel_tool.channel = VoxelBuffer.CHANNEL_TYPE
		for y in range(WORLD_HEIGHT - 1, -1, -1):
			if _voxel_tool.get_voxel(Vector3i(x, y, z)) != BLOCK_AIR:
				return y

	for y in range(WORLD_HEIGHT - 1, -1, -1):
		if is_solid_block(Vector3i(x, y, z)):
			return y
	return -1

func get_spawn_position_raycast(x: float = 0.5, z: float = 0.5) -> Vector3:
	if is_inside_tree() and get_world_3d() != null:
		var space_state := get_world_3d().direct_space_state
		if space_state != null:
			var query := PhysicsRayQueryParameters3D.create(
				Vector3(x, float(WORLD_HEIGHT) + 10.0, z),
				Vector3(x, -10.0, z)
			)
			query.collide_with_areas = false
			query.collide_with_bodies = true
			query.collision_mask = 1
			var hit := space_state.intersect_ray(query)
			if not hit.is_empty() and hit.has("position"):
				return Vector3(x, hit.position.y + 0.5, z)
	return get_spawn_position(int(floor(x)), int(floor(z)))

func get_spawn_position(x: int = 0, z: int = 0) -> Vector3:
	var top_y := get_highest_solid_y(x, z)
	if top_y >= 0:
		var a1 := Vector3i(x, top_y + 1, z)
		var a2 := Vector3i(x, top_y + 2, z)
		if not is_solid_block(a1) and not is_solid_block(a2):
			return Vector3(float(x) + 0.5, float(top_y) + 1.5, float(z) + 0.5)

	for radius in range(1, 48):
		for dx in range(-radius, radius + 1):
			for dz in range(-radius, radius + 1):
				if abs(dx) != radius and abs(dz) != radius:
					continue
				var sy := get_highest_solid_y(x + dx, z + dz)
				if sy >= 0:
					if not is_solid_block(Vector3i(x + dx, sy + 1, z + dz)) \
					and not is_solid_block(Vector3i(x + dx, sy + 2, z + dz)):
						return Vector3(float(x + dx) + 0.5, float(sy) + 1.5, float(z + dz) + 0.5)

	return Vector3(0.5, ISLAND_Y_MAX + 2.0, 0.5)

# ---------------------------------------------------------------------------
# Query API
# ---------------------------------------------------------------------------
func is_solid_block(world_cell: Vector3i) -> bool:
	return not get_voxel_at(world_cell).is_empty()

func is_ground_cell(world_cell: Vector3i) -> bool:
	return is_solid_block(world_cell) or is_solid_block(world_cell - Vector3i(0, 1, 0))

func get_voxel_at(world_cell: Vector3i) -> StringName:
	if world_cell.y < 0 or world_cell.y >= WORLD_HEIGHT:
		return &""

	var cx := floori(float(world_cell.x) / 16.0)
	var cz := floori(float(world_cell.z) / 16.0)
	var cp := Vector2i(cx, cz)
	var lx := posmod(world_cell.x, 16)
	var lz := posmod(world_cell.z, 16)
	var lc := Vector3i(lx, world_cell.y, lz)

	if _mined_deltas_set.has(cp) and _mined_deltas_set[cp].has(lc):
		return &""

	if _terrain != null and _voxel_tool != null and _has_data_at(world_cell):
		_voxel_tool.channel = VoxelBuffer.CHANNEL_TYPE
		var block_id: int = _voxel_tool.get_voxel(world_cell)
		return _id_to_name(block_id)

	return _procedural_voxel(world_cell.x, world_cell.y, world_cell.z, cp, lc)

# ---------------------------------------------------------------------------
# Mining — single authoritative TYPE clear
# ---------------------------------------------------------------------------
func mine_voxel(world_cell: Vector3i) -> StringName:
	var b_type := get_voxel_at(world_cell)
	if b_type.is_empty():
		return &""

	var cx := floori(float(world_cell.x) / 16.0)
	var cz := floori(float(world_cell.z) / 16.0)
	var cp := Vector2i(cx, cz)
	_chunk_generation[cp] = int(_chunk_generation.get(cp, 0)) + 1

	_apply_air_edit(world_cell)
	_record_mine_delta(world_cell)
	voxel_mined.emit(world_cell, b_type)
	return b_type

func _apply_air_edit(world_cell: Vector3i) -> void:
	if _voxel_tool == null:
		return
	if _voxel_tool.has_method("is_area_editable"):
		var area := AABB(Vector3(world_cell), Vector3.ONE)
		if not bool(_voxel_tool.is_area_editable(area)):
			return
	_voxel_tool.channel = VoxelBuffer.CHANNEL_TYPE
	_voxel_tool.set_voxel(world_cell, BLOCK_AIR)

func _record_mine_delta(world_cell: Vector3i) -> void:
	var cx := floori(float(world_cell.x) / 16.0)
	var cz := floori(float(world_cell.z) / 16.0)
	var cp := Vector2i(cx, cz)
	var lc := Vector3i(posmod(world_cell.x, 16), world_cell.y, posmod(world_cell.z, 16))
	if not _mined_deltas.has(cp):
		_mined_deltas[cp] = []
		_mined_deltas_set[cp] = {}
	if not _mined_deltas_set[cp].has(lc):
		_mined_deltas[cp].append(lc)
		_mined_deltas_set[cp][lc] = true
	save_terrain_deltas()

func _apply_persisted_deltas() -> void:
	_apply_persisted_deltas_near(Vector3.ZERO, 1.0e9)

func _apply_persisted_deltas_near(center: Vector3, radius: float) -> void:
	if _voxel_tool == null:
		return
	var r2: float = radius * radius
	for cp in _mined_deltas.keys():
		for lc in _mined_deltas[cp]:
			var world_cell := Vector3i(
				cp.x * 16 + lc.x,
				lc.y,
				cp.y * 16 + lc.z
			)
			var dx: float = float(world_cell.x) + 0.5 - center.x
			var dz: float = float(world_cell.z) + 0.5 - center.z
			if dx * dx + dz * dz > r2:
				continue
			_apply_air_edit(world_cell)
	_voxel_tool.channel = VoxelBuffer.CHANNEL_TYPE

func update_loaded_chunks(player_world_pos: Vector3, _force_sync: bool = false) -> void:
	_apply_persisted_deltas_near(player_world_pos, 48.0)

func is_chunk_loaded(cp: Vector2i) -> bool:
	if _chunks.has(cp):
		return true
	if _terrain != null:
		# Probe mid island band for this XZ column.
		var probe := Vector3i(cp.x * 16 + 8, int(ISLAND_Y_MIN) + 16, cp.y * 16 + 8)
		return _terrain.has_data_block(_terrain.voxel_to_data_block(Vector3(probe)))
	return false

func clear_world() -> void:
	for cp in _chunks.keys():
		var ch = _chunks[cp]
		if is_instance_valid(ch):
			ch.queue_free()
	for cp in _chunk_cache.keys():
		var ch2 = _chunk_cache[cp]
		if is_instance_valid(ch2):
			ch2.queue_free()
	_chunks.clear()
	_chunk_cache.clear()
	_chunk_generation.clear()
	_results_ready.clear()

func verify_spawn_physics(_pos: Vector3) -> bool:
	return true

func get_diagnostics() -> Dictionary:
	return {
		"backend": "ZylannVoxelTerrain",
		"viewer_on_player": _viewer != null and _viewer.get_parent() != self,
		"view_distance_voxels": _effective_view_distance(),
		"view_distance_chunks": view_distance_chunks,
		"main_total_frame_time_ms": 0.0,
		"loaded_chunks": _chunks.size(),
		"total_chunks_generated": 0,
		"cancelled_tasks_count": 0,
		"stale_results_discarded": stale_results_discarded,
	}

# ---------------------------------------------------------------------------
# Legacy test helpers
# ---------------------------------------------------------------------------
func _setup_noise() -> void:
	_setup_fallback_noise()

func _consume_ready_results(_frame_start: int) -> void:
	_results_mutex.lock()
	var kept: Array = []
	for item in _results_ready:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var pos = item.get("pos", Vector2i.ZERO)
		var gen: int = int(item.get("generation", 0))
		var current: int = int(_chunk_generation.get(pos, 0))
		if gen < current:
			stale_results_discarded += 1
			continue
		kept.append(item)
	_results_ready = kept
	_results_mutex.unlock()

func _load_or_generate_chunk_sync(cp: Vector2i) -> VoxelChunk:
	_chunk_generation[cp] = int(_chunk_generation.get(cp, 0))
	if _chunks.has(cp) and _chunks[cp] is VoxelChunk:
		return _chunks[cp] as VoxelChunk
	if _chunk_cache.has(cp) and _chunk_cache[cp] is VoxelChunk:
		return _restore_chunk_from_cache(cp, true) as VoxelChunk
	var chunk := VoxelChunk.new()
	chunk.name = "StubChunk_%d_%d" % [cp.x, cp.y]
	chunk.chunk_pos = cp
	chunk.voxel_world = self
	_chunks[cp] = chunk
	return chunk

func _load_or_generate_chunk(cp: Vector2i) -> void:
	_load_or_generate_chunk_sync(cp)

func _unload_chunk(cp: Vector2i) -> void:
	if _chunks.has(cp):
		var ch = _chunks[cp]
		_chunks.erase(cp)
		if is_instance_valid(ch):
			if "visible" in ch:
				ch.visible = false
			if "collision_layer" in ch:
				ch.collision_layer = 0
			_chunk_cache[cp] = ch
			while _chunk_cache.size() > max_chunk_cache_size:
				var oldest = _chunk_cache.keys()[0]
				var old = _chunk_cache[oldest]
				_chunk_cache.erase(oldest)
				if is_instance_valid(old):
					old.queue_free()

func _restore_chunk_from_cache(cp: Vector2i, _enable: bool = true) -> VoxelChunk:
	if not _chunk_cache.has(cp):
		return null
	var ch: VoxelChunk = _chunk_cache[cp] as VoxelChunk
	_chunk_cache.erase(cp)
	if ch == null:
		return null
	_chunks[cp] = ch
	ch.visible = true
	ch.collision_layer = 1
	return ch

func _id_to_name(id: int) -> StringName:
	match id:
		BLOCK_GRASS: return &"grass"
		BLOCK_DIRT:  return &"dirt"
		BLOCK_STONE: return &"stone"
		BLOCK_COAL:  return &"coal"
		BLOCK_IRON:  return &"iron"
		BLOCK_GOLD:  return &"gold"
		_:           return &""

func _procedural_voxel(gx: int, gy: int, gz: int, cp: Vector2i, local_cell: Vector3i) -> StringName:
	if _mined_deltas_set.has(cp) and _mined_deltas_set[cp].has(local_cell):
		return &""
	if _noise_3d == null:
		return &""
	var block_id: int = _island_density_to_id(gx, gy, gz)
	if block_id == BLOCK_AIR:
		return &""
	return _id_to_name(block_id)

func _island_density_to_id(gx: int, gy: int, gz: int) -> int:
	if _island_gen != null and _island_gen.has_method("eval_voxel"):
		return int(_island_gen.eval_voxel(gx, gy, gz))
	return BLOCK_AIR

func save_terrain_deltas() -> bool:
	var dict: Dictionary = {"version": 1, "seed": seed_value, "deltas": {}}
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
