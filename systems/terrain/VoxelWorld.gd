class_name VoxelWorld
extends Node3D

## VoxelWorld — thin setup wrapper around Zylann's VoxelTerrain C++ plugin.
##
## Responsibilities:
##   1. Build and configure a VoxelTerrain child with a VoxelMesherBlocky + VoxelBlockyLibrary.
##   2. Attach a VoxelGeneratorNoise2D whose parameters match the old procedural shape.
##   3. Expose the same public API surface used by GameWorld / stability_system / DebrisGrabber
##      (get_spawn_position, is_solid_block, get_voxel_at, mine_voxel, voxel_mined signal).
##   4. Manage a VoxelViewer child that must be reparented onto the player after spawn.

# ---------------------------------------------------------------------------
# Block ID constants — mirror VoxelChunk for external compatibility.
# ---------------------------------------------------------------------------
const BLOCK_AIR:   int = 0
const BLOCK_GRASS: int = 1
const BLOCK_DIRT:  int = 2
const BLOCK_STONE: int = 3
const BLOCK_COAL:  int = 4
const BLOCK_IRON:  int = 5
const BLOCK_GOLD:  int = 6

## World height used for spawn surface search.
const WORLD_HEIGHT: int = 32

## Approximate surface band — the noise generator targets this band.
const SURF_MIN: float = 12.0
const SURF_MAX: float = 22.0

## Legacy test compatibility radius
const SPAWN_SYNC_RADIUS: int = 2

# ---------------------------------------------------------------------------
# Signals (kept identical to old API so GameWorld needs no changes).
# ---------------------------------------------------------------------------
signal voxel_mined(world_cell: Vector3i, block_type: StringName)
## Emitted once the spawn-area VoxelViewer reports its first chunk_generated.
signal spawn_chunks_ready

# ---------------------------------------------------------------------------
# Exports
# ---------------------------------------------------------------------------
@export var seed_value: int = 1337:
	set(val):
		seed_value = val
		_apply_generator_params()

@export var view_distance_chunks: int = 4:
	set(val):
		view_distance_chunks = clampi(val, 2, 8)
		if _viewer != null:
			_viewer.view_distance = clampi(view_distance_chunks * 16, 64, 128)

@export var noise_frequency_2d: float = 0.025
@export var noise_frequency_3d: float = 0.045

# ---------------------------------------------------------------------------
# Internal nodes
# ---------------------------------------------------------------------------
var _terrain: VoxelTerrain       = null
var _viewer:  VoxelViewer        = null
var _library: VoxelBlockyLibrary = null
var _voxel_tool: VoxelTool       = null
var _chunks: Dictionary          = {}

# Fallback noise for get_voxel_at() on unloaded voxels (procedural query only).
var _noise_2d:  FastNoiseLite = null
var _noise_3d:  FastNoiseLite = null
var _noise_ore: FastNoiseLite = null

# Mined-cell persistence (same format as before so save files stay compatible).
const DELTA_SAVE_PATH: String = "user://terrain_deltas.json"
var _mined_deltas:     Dictionary = {}  # Vector2i -> Array[Vector3i]
var _mined_deltas_set: Dictionary = {}  # Vector2i -> Dictionary[Vector3i, bool]

# ---------------------------------------------------------------------------
# _ready
# ---------------------------------------------------------------------------
func _ready() -> void:
	_setup_fallback_noise()
	load_terrain_deltas()
	_build_library()
	_build_terrain()
	_build_viewer()

# ---------------------------------------------------------------------------
# Library — maps block IDs to coloured StandardMaterial3D models.
# ---------------------------------------------------------------------------
func _build_library() -> void:
	_library = VoxelBlockyLibrary.new()

	# --- AIR (ID 0) ---
	var air := VoxelBlockyModelEmpty.new()
	_library.add_model(air)

	# Helper to create and register solid cube models
	var add_cube := func(albedo: Color, rough: float = 0.8, metal: float = 0.0) -> void:
		var mat := StandardMaterial3D.new()
		mat.albedo_color = albedo
		mat.roughness = rough
		mat.metallic = metal
		var cube := VoxelBlockyModelCube.new()
		cube.set_material_override(0, mat)
		_library.add_model(cube)

	# --- GRASS (ID 1) ---
	add_cube.call(Color(0.28, 0.62, 0.24), 0.85, 0.0)

	# --- DIRT (ID 2) ---
	add_cube.call(Color(0.42, 0.30, 0.20), 0.90, 0.0)

	# --- STONE (ID 3) ---
	add_cube.call(Color(0.52, 0.54, 0.58), 0.80, 0.0)

	# --- COAL (ID 4) ---
	add_cube.call(Color(0.22, 0.22, 0.24), 0.90, 0.0)

	# --- IRON (ID 5) ---
	add_cube.call(Color(0.72, 0.74, 0.78), 0.50, 0.60)

	# --- GOLD (ID 6) ---
	add_cube.call(Color(0.90, 0.76, 0.10), 0.25, 0.85)

	_library.bake()

# ---------------------------------------------------------------------------
# VoxelTerrain
# ---------------------------------------------------------------------------
func _build_terrain() -> void:
	_terrain = VoxelTerrain.new()
	_terrain.name = "VoxelTerrain"

	# Mesher
	var mesher := VoxelMesherBlocky.new()
	mesher.library = _library
	_terrain.mesher = mesher

	# Generator — VoxelGeneratorNoise2D produces a heightmap blocky terrain.
	# We pass our already-configured FastNoiseLite so the shape is identical.
	var gen := VoxelGeneratorNoise2D.new()
	gen.channel      = VoxelBuffer.CHANNEL_TYPE
	gen.noise        = _noise_2d
	gen.height_start = SURF_MIN
	gen.height_range  = SURF_MAX - SURF_MIN
	_terrain.generator = gen

	# Max view distance in voxels supported by terrain (viewer distance is configured on _viewer)
	_terrain.max_view_distance = clampi(maxi(128, view_distance_chunks * 16), 128, 256)
	_terrain.generate_collisions = true

	# Ensure collisions are only generated close to player (LOD 0/1)
	if "collision_lod_count" in _terrain:
		_terrain.collision_lod_count = 1
	elif _terrain.has_method("set_collision_lod_count"):
		_terrain.call("set_collision_lod_count", 1)

	_terrain.collision_layer = 1
	_terrain.collision_mask = 1
	_terrain.block_enter_notification_enabled = true
	_terrain.mesh_block_entered.connect(_on_mesh_block_entered)

	add_child(_terrain)

	_voxel_tool = _terrain.get_voxel_tool()
	if _voxel_tool != null:
		_voxel_tool.channel = VoxelBuffer.CHANNEL_TYPE

func _on_mesh_block_entered(_block_pos: Vector3i) -> void:
	if is_chunk_ready(Vector3(0.5, 16.0, 0.5)):
		spawn_chunks_ready.emit()

# ---------------------------------------------------------------------------
# VoxelViewer — tells the C++ engine where the player is.
# ---------------------------------------------------------------------------
func _build_viewer() -> void:
	_viewer = VoxelViewer.new()
	_viewer.name               = "VoxelViewer"
	_viewer.view_distance      = clampi(view_distance_chunks * 16, 64, 128)
	_viewer.requires_collisions = true
	add_child(_viewer)

## Reparent the VoxelViewer onto the player so the C++ engine streams around it.
## Call this from GameWorld AFTER the player is positioned on the terrain.
## Example: voxel_world.attach_viewer_to_player(player)
func attach_viewer_to_player(player_node: Node3D) -> void:
	if _viewer == null or player_node == null:
		return
	if _viewer.get_parent() != null:
		_viewer.get_parent().remove_child(_viewer)
	player_node.add_child(_viewer)
	_viewer.position = Vector3.ZERO
	_viewer.view_distance = clampi(view_distance_chunks * 16, 64, 128)
	_viewer.requires_collisions = true

# ---------------------------------------------------------------------------
# Generator parameter sync
# ---------------------------------------------------------------------------
func _apply_generator_params() -> void:
	_setup_fallback_noise()
	if _terrain != null and _terrain.generator is VoxelGeneratorNoise2D:
		var gen: VoxelGeneratorNoise2D = _terrain.generator
		gen.noise = _noise_2d

func _setup_fallback_noise() -> void:
	_noise_2d = FastNoiseLite.new()
	_noise_2d.seed       = seed_value
	_noise_2d.noise_type = FastNoiseLite.TYPE_PERLIN
	_noise_2d.frequency  = noise_frequency_2d

	_noise_3d = FastNoiseLite.new()
	_noise_3d.seed       = seed_value + 100
	_noise_3d.noise_type = FastNoiseLite.TYPE_PERLIN
	_noise_3d.frequency  = noise_frequency_3d

	_noise_ore = FastNoiseLite.new()
	_noise_ore.seed       = seed_value + 200
	_noise_ore.noise_type = FastNoiseLite.TYPE_PERLIN
	_noise_ore.frequency  = 0.12

# ---------------------------------------------------------------------------
# Spawn helpers
# ---------------------------------------------------------------------------

## Checks if a solid voxel exists in the live terrain buffer or procedural fallback.
func has_voxel(world_cell: Vector3i) -> bool:
	if _terrain != null and _voxel_tool != null:
		var block_pos: Vector3i = _terrain.voxel_to_data_block(Vector3(world_cell))
		if _terrain.has_data_block(block_pos):
			var block_id: int = _voxel_tool.get_voxel(world_cell)
			return block_id != BLOCK_AIR
	return is_solid_block(world_cell)

## Verifies whether the chunk and collision mesh directly under world_pos are generated and ready.
func is_chunk_ready(world_pos: Vector3) -> bool:
	if _terrain == null:
		return true
	var ipos := Vector3i(int(floor(world_pos.x)), int(floor(world_pos.y)), int(floor(world_pos.z)))
	var block_pos: Vector3i = _terrain.voxel_to_data_block(Vector3(ipos))
	if not _terrain.has_data_block(block_pos):
		return false

	# Ensure solid terrain exists in this column
	var solid_y := get_highest_solid_y(int(floor(world_pos.x)), int(floor(world_pos.z)))
	return solid_y >= 0

## Async: waits for Zylann's VoxelTerrain to finish generating and meshing the chunk under world_pos.
func wait_for_terrain_at(world_pos: Vector3) -> void:
	if not is_inside_tree() or _terrain == null:
		return

	if is_chunk_ready(world_pos):
		await get_tree().process_frame
		return

	var max_wait_cycles := 120
	var cycles := 0
	while not is_chunk_ready(world_pos) and cycles < max_wait_cycles:
		cycles += 1
		await get_tree().process_frame

	# Ensure physics server synchronizes collision shapes with Jolt
	await get_tree().physics_frame
	await get_tree().process_frame

## Async: waits for the terrain to generate the spawn chunks, then waits for
## collision shapes to be committed to PhysicsServer3D.
func force_sync_spawn_chunks(cx: int = 0, cz: int = 0) -> void:
	if not is_inside_tree():
		return
	var world_pos := Vector3(float(cx * 16) + 0.5, 16.0, float(cz * 16) + 0.5)
	await wait_for_terrain_at(world_pos)

## Queries the highest solid block Y coordinate at world (x, z) using top-down raycast or VoxelTool.
func get_highest_solid_y(x: int, z: int) -> int:
	# 1. Try VoxelTool raycast downward from above world height
	if _voxel_tool != null:
		var ray_origin := Vector3(float(x) + 0.5, float(WORLD_HEIGHT) + 4.0, float(z) + 0.5)
		var hit = _voxel_tool.raycast(ray_origin, Vector3.DOWN, float(WORLD_HEIGHT) + 8.0)
		if hit != null and hit.position != null:
			return hit.position.y

	# 2. Check live VoxelTool voxel coordinates directly from top to bottom
	if _terrain != null and _voxel_tool != null:
		var block_pos: Vector3i = _terrain.voxel_to_data_block(Vector3(x, 16, z))
		if _terrain.has_data_block(block_pos):
			for y in range(WORLD_HEIGHT - 1, -1, -1):
				var cell := Vector3i(x, y, z)
				if _voxel_tool.get_voxel(cell) != BLOCK_AIR:
					return y

	# 3. Deterministic procedural fallback if chunk is not yet loaded in live buffer
	for y in range(WORLD_HEIGHT - 1, -1, -1):
		if is_solid_block(Vector3i(x, y, z)):
			return y

	return -1

## Top-down physics raycast to find the exact top surface collision point in PhysicsServer3D.
func get_spawn_position_raycast(x: float = 0.5, z: float = 0.5) -> Vector3:
	if is_inside_tree() and get_world_3d() != null:
		var space_state := get_world_3d().direct_space_state
		if space_state != null:
			var query := PhysicsRayQueryParameters3D.create(
				Vector3(x, float(WORLD_HEIGHT) + 10.0, z),
				Vector3(x, -5.0, z)
			)
			query.collide_with_areas = false
			query.collide_with_bodies = true
			query.collision_mask = 1 # Only collide with terrain, not characters
			var hit := space_state.intersect_ray(query)
			if not hit.is_empty() and hit.has("position"):
				# Feet positioned safely 0.5m above collision mesh face to prevent capsule penetration
				return Vector3(x, hit.position.y + 0.5, z)
	return get_spawn_position(int(floor(x)), int(floor(z)))

## Returns a safe above-surface world position for the player to spawn at.
func get_spawn_position(x: int = 0, z: int = 0) -> Vector3:
	var top_y := get_highest_solid_y(x, z)
	if top_y >= 0:
		var a1 := Vector3i(x, top_y + 1, z)
		var a2 := Vector3i(x, top_y + 2, z)
		if not is_solid_block(a1) and not is_solid_block(a2):
			return Vector3(float(x) + 0.5, float(top_y) + 1.5, float(z) + 0.5)

	# Spiral fallback
	for radius in range(1, 8):
		for dx in range(-radius, radius + 1):
			for dz in range(-radius, radius + 1):
				if abs(dx) != radius and abs(dz) != radius:
					continue
				var sy := get_highest_solid_y(x + dx, z + dz)
				if sy >= 0:
					if not is_solid_block(Vector3i(x + dx, sy + 1, z + dz)) \
					and not is_solid_block(Vector3i(x + dx, sy + 2, z + dz)):
						return Vector3(float(x + dx) + 0.5, float(sy) + 1.5, float(z + dz) + 0.5)

	return Vector3(0.5, SURF_MAX + 2.0, 0.5)

# ---------------------------------------------------------------------------
# Query API (mirrors old public surface)
# ---------------------------------------------------------------------------

func is_solid_block(world_cell: Vector3i) -> bool:
	return not get_voxel_at(world_cell).is_empty()

func is_ground_cell(world_cell: Vector3i) -> bool:
	return is_solid_block(world_cell) or is_solid_block(world_cell - Vector3i(0, 1, 0))

## Returns the StringName block type at a world cell.
## Reads from VoxelTerrain's live buffer when the chunk is loaded;
## falls back to deterministic procedural evaluation otherwise.
func get_voxel_at(world_cell: Vector3i) -> StringName:
	if world_cell.y < 0 or world_cell.y >= WORLD_HEIGHT:
		return &""

	var cx := floori(float(world_cell.x) / 16.0)
	var cz := floori(float(world_cell.z) / 16.0)
	var cp  := Vector2i(cx, cz)
	var lx  := posmod(world_cell.x, 16)
	var lz  := posmod(world_cell.z, 16)
	var lc  := Vector3i(lx, world_cell.y, lz)

	# Check mined-out deltas first.
	if _mined_deltas_set.has(cp) and _mined_deltas_set[cp].has(lc):
		return &""

	# Query live terrain data when available and block is loaded.
	if _terrain != null and _voxel_tool != null:
		var block_pos := _terrain.voxel_to_data_block(Vector3(world_cell))
		if _terrain.has_data_block(block_pos):
			var block_id: int = _voxel_tool.get_voxel(world_cell)
			return _id_to_name(block_id)

	# Procedural fallback for not-yet-streamed chunks.
	return _procedural_voxel(world_cell.x, world_cell.y, world_cell.z, cp, lc)

# ---------------------------------------------------------------------------
# Mining
# ---------------------------------------------------------------------------

func mine_voxel(world_cell: Vector3i) -> StringName:
	var b_type := get_voxel_at(world_cell)
	if b_type.is_empty():
		return &""

	# Write AIR into the live terrain so the C++ engine remeshes the chunk.
	if _voxel_tool != null:
		_voxel_tool.set_voxel(world_cell, BLOCK_AIR)

	# Record delta for persistence + procedural-fallback invalidation.
	var cx := floori(float(world_cell.x) / 16.0)
	var cz := floori(float(world_cell.z) / 16.0)
	var cp  := Vector2i(cx, cz)
	var lc  := Vector3i(posmod(world_cell.x, 16), world_cell.y, posmod(world_cell.z, 16))

	if not _mined_deltas.has(cp):
		_mined_deltas[cp]     = []
		_mined_deltas_set[cp] = {}
	if not _mined_deltas_set[cp].has(lc):
		_mined_deltas[cp].append(lc)
		_mined_deltas_set[cp][lc] = true

	save_terrain_deltas()
	voxel_mined.emit(world_cell, b_type)
	return b_type

# ---------------------------------------------------------------------------
# Stub: update_loaded_chunks — no-op; streaming is handled by VoxelViewer.
# Kept so GameWorld / PlayerController callers need no changes.
# ---------------------------------------------------------------------------
func update_loaded_chunks(_player_world_pos: Vector3, _force_sync: bool = false) -> void:
	pass

func is_chunk_loaded(cp: Vector2i) -> bool:
	if _terrain != null:
		var block_pos := Vector3i(cp.x, 0, cp.y)
		return _terrain.has_data_block(block_pos)
	return true

func clear_world() -> void:
	_chunks.clear()

func verify_spawn_physics(_pos: Vector3) -> bool:
	return true

# ---------------------------------------------------------------------------
# Diagnostics stub
# ---------------------------------------------------------------------------
func get_diagnostics() -> Dictionary:
	return {
		"backend": "ZylannVoxelTerrain",
		"viewer_on_player": _viewer != null and _viewer.get_parent() != self
	}

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

func _setup_noise() -> void:
	_setup_fallback_noise()

func _evaluate_procedural_voxel(gx: int, gy: int, gz: int, cp: Vector2i, local_cell: Vector3i) -> StringName:
	return _procedural_voxel(gx, gy, gz, cp, local_cell)

func _id_to_name(id: int) -> StringName:
	match id:
		BLOCK_GRASS: return &"grass"
		BLOCK_DIRT:  return &"dirt"
		BLOCK_STONE: return &"stone"
		BLOCK_COAL:  return &"coal"
		BLOCK_IRON:  return &"iron"
		BLOCK_GOLD:  return &"gold"
		_:           return &""

## Deterministic procedural evaluation — mirrors the old VoxelWorld logic exactly.
## Used as a fallback when a chunk is not yet streamed by VoxelTerrain.
func _procedural_voxel(gx: int, gy: int, gz: int, cp: Vector2i, local_cell: Vector3i) -> StringName:
	if _mined_deltas_set.has(cp) and _mined_deltas_set[cp].has(local_cell):
		return &""
	if _noise_2d == null or _noise_3d == null:
		return &""

	var dist_from_origin := sqrt(float(gx * gx + gz * gz))
	var spawn_mask := clampf(1.0 - (dist_from_origin / 24.0), 0.0, 1.0)
	var island_n: float = _noise_2d.get_noise_2d(float(gx), float(gz))
	if spawn_mask <= 0.05 and island_n <= -0.15:
		return &""

	var n_surf: float = (_noise_2d.get_noise_2d(float(gx) + 500.0, float(gz) + 500.0) + 1.0) * 0.5
	var surf_h: int   = int(floor(lerpf(SURF_MIN, SURF_MAX, n_surf)))

	var n_base: float = (_noise_3d.get_noise_2d(float(gx) - 500.0, float(gz) - 500.0) + 1.0) * 0.5
	var bot_h: int    = int(floor(lerpf(3.0, 9.0, n_base)))

	if gy < bot_h or gy > surf_h:
		return &""

	if gy == surf_h:
		return &"grass"
	if gy >= surf_h - 2:
		return &"dirt"

	if _noise_ore != null:
		var ore_n: float = _noise_ore.get_noise_3d(float(gx), float(gy), float(gz))
		if gy <= 8  and ore_n > 0.45: return &"gold"
		if gy <= 12 and ore_n > 0.35: return &"iron"
		if gy <= 15 and ore_n > 0.25: return &"coal"

	return &"stone"

# ---------------------------------------------------------------------------
# Persistence
# ---------------------------------------------------------------------------

func save_terrain_deltas() -> bool:
	var dict: Dictionary = { "version": 1, "seed": seed_value, "deltas": {} }
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
