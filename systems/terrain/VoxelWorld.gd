class_name VoxelWorld
extends Node3D

## VoxelWorld — Zylann VoxelTerrain + VoxelMesherBlocky own streaming, meshing, and
## collision. IslandGenerator writes TYPE ids (cubes + oriented grass ramps/corners).
## Player-built grid stays separate from natural terrain.

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
const SDF_AIR: float = 3.5
## Nearby collision radius in chunks (visuals use full view_distance_chunks).
const COLLISION_VIEW_CHUNKS: int = 6
## Capsule used for spawn clearance (matches PlayerController defaults).
const SPAWN_CAPSULE_RADIUS: float = 0.4
const SPAWN_CAPSULE_HEIGHT: float = 1.8
const SPAWN_FEET_CLEARANCE: float = 0.08
const SPAWN_SURFACE_TOLERANCE: float = 4.0
const MESH_BLOCK_SIZE: int = 16

signal voxel_mined(world_cell: Vector3i, block_type: StringName)
signal spawn_chunks_ready
signal view_distance_changed(voxels: int, chunks: int)
signal terrain_loading_status(message: String)

## Soft loading budget (~30s at 60fps) + extended grace for heavier grass/ore meshing.
const TERRAIN_WAIT_FRAMES: int = 1800
const TERRAIN_GRACE_FRAMES: int = 1800

const VIEW_DIST_CHUNKS_MIN: int = 8
## LOD backend practical ceiling (chunks). Far rings use lower detail — not full mesh/collision.
const VIEW_DIST_CHUNKS_MAX_LOD: int = 160
## Non-LOD VoxelTerrain fallback ceiling if LOD is unavailable in the build.
const VIEW_DIST_CHUNKS_MAX_FLAT: int = 32

@export var seed_value: int = 1337:
	set(val):
		seed_value = val
		_apply_generator_params()

@export var view_distance_chunks: int = 20:
	set(val):
		view_distance_chunks = clampi(val, VIEW_DIST_CHUNKS_MIN, _view_chunks_ceiling())
		_sync_view_distance()

@export var noise_frequency_2d: float = 0.0075
@export var noise_frequency_3d: float = 0.040
@export var noise_frequency_ore: float = 0.12
@export var island_density_threshold: float = 0.30
@export var island_vertical_scale: float = 3.5

## VoxelLodTerrain when available; otherwise VoxelTerrain. Keep node name "VoxelTerrain".
var _terrain: Node = null
var _uses_lod_terrain: bool = false
var _viewer: VoxelViewer = null
var _viewer_collision: VoxelViewer = null
var _voxel_tool: VoxelTool = null
var _chunks: Dictionary = {}
var _blocky_library: VoxelBlockyLibrary = null

var _noise_2d: FastNoiseLite = null
var _noise_3d: FastNoiseLite = null
var _noise_ore: FastNoiseLite = null
var _island_gen = null

const _IslandGeneratorScript = preload("res://systems/terrain/IslandGenerator.gd")
const _TerrainBlockyLibraryScript = preload("res://systems/terrain/TerrainBlockyLibrary.gd")

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
var max_frame_budget_ms: float = 6.0

var _view_down_prev: bool = false
var _view_up_prev: bool = false
var _delta_reapply_timer: float = 0.0
var _stream_diag_timer: float = 0.0
var _last_stream_diag: Dictionary = {}
var _backend_view_limit_voxels: int = 0
var _mesh_block_wake: bool = false

func _ready() -> void:
	randomize()
	# Fresh procedural world each session via noise seeds — do not move player or terrain.
	_randomize_generator_noise()
	# Do not load disk cache — edits must not persist between sessions.
	_mined_deltas.clear()
	_mined_deltas_set.clear()
	_build_terrain()
	# Force-disable VoxelTerrain stream so chunk edits are never saved to disk.
	# Keep terrain at origin so VoxelViewer chunk streaming stays in sync.
	if _terrain != null:
		_terrain.stream = null
		_terrain.position = Vector3.ZERO
		_terrain.global_position = Vector3.ZERO
	_build_viewer()

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

	_stream_diag_timer += delta
	if _stream_diag_timer >= 1.5:
		_stream_diag_timer = 0.0
		_refresh_stream_diagnostics()

# ---------------------------------------------------------------------------
# VoxelTerrain + VoxelMesherBlocky (mesh + collision)
# ---------------------------------------------------------------------------
func _build_terrain() -> void:
	_uses_lod_terrain = false
	_terrain = VoxelTerrain.new()
	_terrain.name = "VoxelTerrain"

	if ClassDB.class_exists("VoxelFormat"):
		var fmt = ClassDB.instantiate("VoxelFormat")
		if fmt != null and "format" in _terrain:
			_terrain.format = fmt

	_blocky_library = _TerrainBlockyLibraryScript.build_library()
	if _blocky_library != null:
		var model_count: int = _blocky_library.get_model_count() if _blocky_library.has_method("get_model_count") else (_blocky_library.models.size() if "models" in _blocky_library and _blocky_library.models != null else 0)
		for i in range(model_count):
			var model = _blocky_library.get_model(i) if _blocky_library.has_method("get_model") else (_blocky_library.models[i] if "models" in _blocky_library else null)
			if model != null and model.has_method("get_material_override"):
				var mat = model.get_material_override(0)
				if mat != null and mat is BaseMaterial3D:
					mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	var mesher := VoxelMesherBlocky.new()
	mesher.library = _blocky_library
	if "occlusion_enabled" in mesher:
		mesher.occlusion_enabled = true
	_terrain.mesher = mesher
	if "material_override" in _terrain and _terrain.material_override is BaseMaterial3D:
		_terrain.material_override.cull_mode = BaseMaterial3D.CULL_DISABLED

	_island_gen = _IslandGeneratorScript.new()
	_island_gen.noise_island = _noise_3d
	_island_gen.noise_island_2d = _noise_2d
	_island_gen.noise_ore = _noise_ore
	_island_gen.density_threshold = island_density_threshold
	_island_gen.vertical_scale = island_vertical_scale
	_terrain.generator = _island_gen

	# Classic mesh colliders from VoxelMesherBlocky (ramps/corners included).
	_terrain.generate_collisions = true
	_terrain.collision_layer = 1
	_terrain.collision_mask = 0
	if "collision_margin" in _terrain:
		_terrain.collision_margin = 0.04
	_terrain.mesh_block_size = MESH_BLOCK_SIZE
	_terrain.automatic_loading_enabled = true
	_terrain.block_enter_notification_enabled = true

	var y0: float = ISLAND_Y_MIN - 40.0
	var y_size: float = (ISLAND_Y_MAX - ISLAND_Y_MIN) + 80.0
	_terrain.bounds = AABB(Vector3(-500000.0, y0, -500000.0), Vector3(1000000.0, y_size, 1000000.0))

	if _terrain.has_signal("mesh_block_entered"):
		_terrain.mesh_block_entered.connect(_on_mesh_block_entered)

	_sync_view_distance()
	add_child(_terrain)

	_voxel_tool = _terrain.get_voxel_tool()
	if _voxel_tool != null:
		_voxel_tool.channel = VoxelBuffer.CHANNEL_TYPE

func _on_mesh_block_entered(_block_pos: Vector3i) -> void:
	_mesh_block_wake = true

func _build_viewer() -> void:
	_viewer = VoxelViewer.new()
	_viewer.name = "VoxelViewer"
	_viewer.requires_collisions = false
	_viewer.requires_visuals = true
	add_child(_viewer)

	_viewer_collision = VoxelViewer.new()
	_viewer_collision.name = "VoxelViewerCollision"
	_viewer_collision.requires_collisions = true
	_viewer_collision.requires_visuals = false
	add_child(_viewer_collision)

	_sync_view_distance()

func attach_viewer_to_player(player_node: Node3D) -> void:
	if player_node == null:
		return
	for v in [_viewer, _viewer_collision]:
		if v == null:
			continue
		if v.get_parent() != null:
			v.get_parent().remove_child(v)
		player_node.add_child(v)
		v.position = Vector3.ZERO
	_sync_view_distance()

func get_view_distance_voxels() -> int:
	return _effective_view_distance()

func get_view_distance_chunks() -> int:
	return view_distance_chunks

func get_view_distance_backend_limit_voxels() -> int:
	return _backend_view_limit_voxels

func uses_lod_terrain() -> bool:
	return _uses_lod_terrain

func adjust_view_distance_chunks(delta: int) -> void:
	view_distance_chunks = clampi(view_distance_chunks + delta, VIEW_DIST_CHUNKS_MIN, _view_chunks_ceiling())

func _view_chunks_ceiling() -> int:
	var lod_ok: bool = _uses_lod_terrain or ClassDB.class_exists("VoxelLodTerrain")
	return VIEW_DIST_CHUNKS_MAX_LOD if lod_ok else VIEW_DIST_CHUNKS_MAX_FLAT

func _effective_view_distance() -> int:
	return view_distance_chunks * 16

func _collision_view_distance() -> int:
	return COLLISION_VIEW_CHUNKS * 16

func _sync_view_distance() -> void:
	var dist := _effective_view_distance()
	var col_dist := mini(dist, _collision_view_distance())
	if _viewer != null:
		_viewer.view_distance = dist
		_viewer.requires_visuals = true
		_viewer.requires_collisions = false
		if "view_distance_vertical_ratio" in _viewer:
			_viewer.view_distance_vertical_ratio = 1.0
	if _viewer_collision != null:
		_viewer_collision.view_distance = col_dist
		_viewer_collision.requires_visuals = false
		_viewer_collision.requires_collisions = true
		if "view_distance_vertical_ratio" in _viewer_collision:
			_viewer_collision.view_distance_vertical_ratio = 1.0
	if _terrain != null:
		if _uses_lod_terrain:
			_terrain.set("view_distance", dist)
		elif "max_view_distance" in _terrain:
			_terrain.set("max_view_distance", dist)
		_backend_view_limit_voxels = _view_chunks_ceiling() * 16
	view_distance_changed.emit(dist, view_distance_chunks)

func _apply_generator_params() -> void:
	_setup_fallback_noise()
	if _island_gen != null:
		_island_gen.noise_island = _noise_3d
		_island_gen.noise_island_2d = _noise_2d
		_island_gen.noise_ore = _noise_ore
		_island_gen.density_threshold = island_density_threshold

func _randomize_generator_noise() -> void:
	## Re-seed FastNoiseLite inputs on the active generator for a new world layout.
	seed_value = randi()
	_setup_fallback_noise()
	if _island_gen != null:
		_island_gen.noise_island = _noise_3d
		_island_gen.noise_island_2d = _noise_2d
		_island_gen.noise_ore = _noise_ore
		_island_gen.density_threshold = island_density_threshold
		_island_gen.vertical_scale = island_vertical_scale
	if _terrain != null and _terrain.generator != _island_gen and _island_gen != null:
		_terrain.generator = _island_gen

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

func _refresh_stream_diagnostics() -> void:
	_last_stream_diag = {
		"backend": "VoxelTerrain+VoxelMesherBlocky",
		"view_chunks": view_distance_chunks,
		"view_limit_chunks": _view_chunks_ceiling(),
		"collision_chunks": COLLISION_VIEW_CHUNKS,
		"lod": false,
	}
	if _terrain != null and _terrain.has_method("get_statistics"):
		var stats: Dictionary = _terrain.get_statistics()
		_last_stream_diag["remaining_main_thread_blocks"] = int(stats.get("remaining_main_thread_blocks", 0))
		_last_stream_diag["updated_blocks"] = int(stats.get("updated_blocks", 0))

func get_stream_diagnostics() -> Dictionary:
	return _last_stream_diag.duplicate()

func _read_type_id(world_cell: Vector3i) -> int:
	if world_cell.y < 0 or world_cell.y >= WORLD_HEIGHT:
		return BLOCK_AIR
	var cx := floori(float(world_cell.x) / 16.0)
	var cz := floori(float(world_cell.z) / 16.0)
	var cp := Vector2i(cx, cz)
	var lc := Vector3i(posmod(world_cell.x, 16), world_cell.y, posmod(world_cell.z, 16))
	if _mined_deltas_set.has(cp) and _mined_deltas_set[cp].has(lc):
		return BLOCK_AIR
	if _voxel_tool != null and _has_data_at(world_cell):
		_voxel_tool.channel = VoxelBuffer.CHANNEL_TYPE
		return int(_voxel_tool.get_voxel(world_cell))
	if _island_gen != null and _island_gen.has_method("eval_voxel"):
		return int(_island_gen.eval_voxel(world_cell.x, world_cell.y, world_cell.z))
	return BLOCK_AIR

# ---------------------------------------------------------------------------
# Spawn helpers
# ---------------------------------------------------------------------------
func has_voxel(world_cell: Vector3i) -> bool:
	return is_solid_block(world_cell)

func _has_data_at(world_cell: Vector3i) -> bool:
	if _terrain == null:
		return false
	if _voxel_tool != null and _voxel_tool.has_method("is_area_editable"):
		var area := AABB(Vector3(world_cell), Vector3.ONE)
		if bool(_voxel_tool.is_area_editable(area)):
			return true
	if _terrain.has_method("has_data_block") and _terrain.has_method("voxel_to_data_block"):
		var block_pos: Vector3i = _terrain.voxel_to_data_block(Vector3(world_cell))
		return bool(_terrain.has_data_block(block_pos))
	return false

func is_chunk_ready(world_pos: Vector3) -> bool:
	if _terrain == null:
		return true
	var ipos := Vector3i(int(floor(world_pos.x)), int(floor(world_pos.y)), int(floor(world_pos.z)))
	var probe := Vector3i(ipos.x, clampi(ipos.y, int(ISLAND_Y_MIN), int(ISLAND_Y_MAX)), ipos.z)
	if not _has_data_at(probe):
		return false
	if _terrain.has_method("is_area_meshed"):
		var area := AABB(Vector3(probe) - Vector3(2, 2, 2), Vector3(5, 5, 5))
		var meshed: bool
		if _uses_lod_terrain:
			meshed = bool(_terrain.is_area_meshed(area, 0))
		else:
			meshed = bool(_terrain.is_area_meshed(area))
		if not meshed:
			return false
	return get_highest_solid_y(ipos.x, ipos.z) >= 0

func is_collision_ready_at(world_pos: Vector3) -> bool:
	## True when Voxel Tools has meshed the area and physics hits the walkable top.
	if not is_chunk_ready(world_pos):
		return false
	var hit := _raycast_top_surface(world_pos.x, world_pos.z)
	return not hit.is_empty()

func _viewer_near_enough(world_pos: Vector3) -> bool:
	if _viewer == null:
		return true
	var vp: Vector3 = _viewer.global_position if _viewer.is_inside_tree() else Vector3.ZERO
	return vp.distance_to(world_pos) < float(_effective_view_distance())

func _park_viewers_for_load(world_pos: Vector3) -> void:
	## Keep streaming focused on the required spawn column while waiting.
	var park := Vector3(world_pos.x, clampf(world_pos.y, ISLAND_Y_MIN, ISLAND_Y_MAX), world_pos.z)
	for v in [_viewer, _viewer_collision]:
		if v == null or not v.is_inside_tree():
			continue
		v.global_position = park

func _unpark_viewers() -> void:
	## Clear load-time local offsets so viewers follow the player again.
	for v in [_viewer, _viewer_collision]:
		if v == null or not v.is_inside_tree():
			continue
		v.position = Vector3.ZERO

func wait_for_terrain_at(world_pos: Vector3) -> bool:
	## Wait for Voxel Tools mesh+collision; never returns true without a top-surface hit.
	if not is_inside_tree() or _terrain == null:
		terrain_loading_status.emit("Terrain load failed — press Home to retry or Esc to quit")
		return false

	_park_viewers_for_load(world_pos)

	if is_collision_ready_at(world_pos):
		_apply_persisted_deltas()
		await get_tree().physics_frame
		await get_tree().process_frame
		if is_collision_ready_at(world_pos):
			_unpark_viewers()
			spawn_chunks_ready.emit()
			terrain_loading_status.emit("Terrain ready")
			return true

	terrain_loading_status.emit("Loading terrain… 5%")
	var cycles := 0
	var last_pct := -1
	var cell := Vector3i(int(floor(world_pos.x)), clampi(int(floor(world_pos.y)), int(ISLAND_Y_MIN), int(ISLAND_Y_MAX)), int(floor(world_pos.z)))

	while cycles < TERRAIN_WAIT_FRAMES:
		if is_collision_ready_at(world_pos):
			_apply_persisted_deltas()
			await get_tree().physics_frame
			await get_tree().process_frame
			if is_collision_ready_at(world_pos):
				_unpark_viewers()
				spawn_chunks_ready.emit()
				terrain_loading_status.emit("Terrain ready")
				return true

		var data_ready := _has_data_at(cell)
		var mesh_ready := false
		if _terrain != null and _terrain.has_method("is_area_meshed"):
			var area := AABB(Vector3(cell) - Vector3(2, 2, 2), Vector3(5, 5, 5))
			mesh_ready = bool(_terrain.is_area_meshed(area))

		var pct: int = 5
		var stage_desc: String = "streaming voxels"
		if not data_ready:
			pct = clampi(5 + int(float(cycles) / 30.0 * 20.0), 5, 25)
			stage_desc = "streaming voxels"
		elif not mesh_ready:
			pct = clampi(25 + int(float(cycles) / 45.0 * 45.0), 25, 70)
			stage_desc = "meshing chunks"
		else:
			pct = clampi(70 + int(float(cycles) / 60.0 * 25.0), 70, 95)
			stage_desc = "verifying surface"

		if pct != last_pct and cycles % 10 == 0:
			last_pct = pct
			terrain_loading_status.emit("Loading terrain… %s (%d%%)" % [stage_desc, pct])
			_park_viewers_for_load(world_pos)

		cycles += 1
		await get_tree().process_frame

	if not is_collision_ready_at(world_pos):
		terrain_loading_status.emit("Terrain slow — finishing mesh…")
		var grace := 0
		while grace < TERRAIN_GRACE_FRAMES:
			if is_collision_ready_at(world_pos):
				_apply_persisted_deltas()
				await get_tree().physics_frame
				await get_tree().process_frame
				if is_collision_ready_at(world_pos):
					_unpark_viewers()
					spawn_chunks_ready.emit()
					terrain_loading_status.emit("Terrain ready")
					return true
			grace += 1
			if grace % 30 == 0:
				_park_viewers_for_load(world_pos)
			await get_tree().process_frame

	_unpark_viewers()
	terrain_loading_status.emit("Terrain load failed — press Home to retry or Esc to quit")
	return false

func force_sync_spawn_chunks(cx: int = 0, cz: int = 0) -> void:
	if not is_inside_tree():
		return
	var world_pos := Vector3(float(cx * 16) + 0.5, 56.0, float(cz * 16) + 0.5)
	await wait_for_terrain_at(world_pos)

func get_highest_solid_y(x: int, z: int) -> int:
	if _voxel_tool != null and _has_data_at(Vector3i(x, int(ISLAND_Y_MAX), z)):
		_voxel_tool.channel = VoxelBuffer.CHANNEL_TYPE
		for y in range(int(ISLAND_Y_MAX) + 16, int(ISLAND_Y_MIN) - 48, -1):
			if int(_voxel_tool.get_voxel(Vector3i(x, y, z))) != BLOCK_AIR:
				var cx := floori(float(x) / 16.0)
				var cz := floori(float(z) / 16.0)
				var cp := Vector2i(cx, cz)
				var lc := Vector3i(posmod(x, 16), y, posmod(z, 16))
				if _mined_deltas_set.has(cp) and _mined_deltas_set[cp].has(lc):
					continue
				return y

	if _island_gen != null and _island_gen.has_method("eval_surface_y"):
		var sy: int = int(_island_gen.eval_surface_y(x, z))
		if sy >= 0:
			return sy

	for y2 in range(WORLD_HEIGHT - 1, -1, -1):
		if is_solid_block(Vector3i(x, y2, z)):
			return y2
	return -1

func _expected_surface_y(x: int, z: int) -> int:
	if _island_gen != null and _island_gen.has_method("eval_surface_y"):
		return int(_island_gen.eval_surface_y(x, z))
	return get_highest_solid_y(x, z)

func _raycast_top_surface(x: float, z: float) -> Dictionary:
	if not is_inside_tree() or get_world_3d() == null:
		return {}
	var space_state := get_world_3d().direct_space_state
	if space_state == null:
		return {}
	var query := PhysicsRayQueryParameters3D.create(
		Vector3(x, float(WORLD_HEIGHT) + 10.0, z),
		Vector3(x, float(ISLAND_Y_MIN) - 20.0, z)
	)
	query.collide_with_areas = false
	query.collide_with_bodies = true
	query.collision_mask = 1
	var hit := space_state.intersect_ray(query)
	if hit.is_empty() or not hit.has("position"):
		return {}
	var hit_pos: Vector3 = hit.position
	var hit_n: Vector3 = hit.get("normal", Vector3.UP)
	# Reject underside / steep wall hits — spawn must be on upper walkable surface.
	if hit_n.y < 0.50:
		return {}
	if hit_pos.y < ISLAND_Y_MIN - 4.0 or hit_pos.y > ISLAND_Y_MAX + 20.0:
		return {}
	return hit

func _feet_from_surface_hit(x: float, z: float, hit_y: float) -> Vector3:
	## CharacterBody3D origin at capsule bottom / feet.
	return Vector3(x, hit_y + SPAWN_FEET_CLEARANCE, z)

func verify_spawn_physics(candidate_pos: Vector3, exclude_rids: Array[RID] = []) -> bool:
	if not is_inside_tree():
		return true
	var space := get_world_3d().direct_space_state if get_world_3d() != null else null
	if space == null:
		return true

	var ground := _raycast_top_surface(candidate_pos.x, candidate_pos.z)
	if ground.is_empty():
		return false
	var ground_y: float = ground.position.y
	if absf(candidate_pos.y - (ground_y + SPAWN_FEET_CLEARANCE)) > 0.35:
		return false

	var capsule := CapsuleShape3D.new()
	capsule.radius = SPAWN_CAPSULE_RADIUS
	capsule.height = SPAWN_CAPSULE_HEIGHT
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = capsule
	query.transform = Transform3D(Basis(), candidate_pos + Vector3(0.0, SPAWN_CAPSULE_HEIGHT * 0.5, 0.0))
	query.collision_mask = 1 | 4
	query.exclude = exclude_rids
	query.margin = 0.01
	var overlaps := space.intersect_shape(query, 1)
	return overlaps.is_empty()

func get_spawn_position_raycast(x: float = 0.5, z: float = 0.5) -> Vector3:
	var hit := _raycast_top_surface(x, z)
	if not hit.is_empty():
		var feet := _feet_from_surface_hit(x, z, hit.position.y)
		if verify_spawn_physics(feet):
			return feet
	return Vector3.ZERO

func try_find_safe_spawn(max_radius: int = 16, carrier: Node3D = null) -> Vector3:
	## Search starter-island columns for a validated top-surface spawn with real collision.
	## Returns Vector3.ZERO if no confirmed physics surface exists.
	var spawn_x := 0.5
	var spawn_z := 0.5
	if carrier != null:
		carrier.global_position = Vector3(spawn_x, 250.0, spawn_z)
	elif _viewer != null and _viewer.is_inside_tree():
		_viewer.global_position = Vector3(spawn_x, 56.0, spawn_z)
		if _viewer_collision != null and _viewer_collision.is_inside_tree():
			_viewer_collision.global_position = Vector3(spawn_x, 56.0, spawn_z)

	# 1. Fast path: check spawn origin (0.5, 0.5) first
	var feet0 := get_spawn_position_raycast(spawn_x, spawn_z)
	if feet0 != Vector3.ZERO and verify_spawn_physics(feet0):
		return feet0

	# 2. Spiral rings outward, checking in bounded batches per frame
	var search_limit := clampi(max_radius, 1, 24)
	var origins: Array[Vector2i] = []
	for radius in range(1, search_limit + 1):
		for dx in range(-radius, radius + 1):
			for dz in range(-radius, radius + 1):
				if absi(dx) != radius and absi(dz) != radius:
					continue
				origins.append(Vector2i(dx, dz))

	var checked_this_frame := 0
	for col in origins:
		var x: float = float(col.x) + 0.5
		var z: float = float(col.y) + 0.5
		var feet := get_spawn_position_raycast(x, z)
		if feet != Vector3.ZERO and verify_spawn_physics(feet):
			return feet
		checked_this_frame += 1
		if checked_this_frame >= 16:
			checked_this_frame = 0
			await get_tree().process_frame

	return Vector3.ZERO

func get_spawn_position(x: int = 0, z: int = 0) -> Vector3:
	## Synchronous best-effort (tests / presets). Gameplay spawn uses try_find_safe_spawn().
	var ray := get_spawn_position_raycast(float(x) + 0.5, float(z) + 0.5)
	if ray != Vector3.ZERO:
		return ray

	var top_y := get_highest_solid_y(x, z)
	if top_y >= 0:
		var a1 := Vector3i(x, top_y + 1, z)
		var a2 := Vector3i(x, top_y + 2, z)
		if not is_solid_block(a1) and not is_solid_block(a2):
			var candidate := Vector3(float(x) + 0.5, float(top_y) + 1.0 + SPAWN_FEET_CLEARANCE, float(z) + 0.5)
			if verify_spawn_physics(candidate):
				return candidate

	for radius in range(1, 48):
		for dx in range(-radius, radius + 1):
			for dz in range(-radius, radius + 1):
				if abs(dx) != radius and abs(dz) != radius:
					continue
				var sy := get_highest_solid_y(x + dx, z + dz)
				if sy >= 0:
					if not is_solid_block(Vector3i(x + dx, sy + 1, z + dz)) \
					and not is_solid_block(Vector3i(x + dx, sy + 2, z + dz)):
						var c2 := Vector3(float(x + dx) + 0.5, float(sy) + 1.0 + SPAWN_FEET_CLEARANCE, float(z + dz) + 0.5)
						if verify_spawn_physics(c2):
							return c2

	return Vector3.ZERO

# ---------------------------------------------------------------------------
# Query API
# ---------------------------------------------------------------------------
func is_solid_block(world_cell: Vector3i) -> bool:
	if world_cell.y < 0 or world_cell.y >= WORLD_HEIGHT:
		return false
	return _read_type_id(world_cell) != BLOCK_AIR

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
# Mining — clear TYPE + SDF; Voxel Tools remeshes/collides automatically
# ---------------------------------------------------------------------------
func mine_voxel(world_cell: Vector3i) -> StringName:
	var b_type := get_voxel_at(world_cell)
	if b_type.is_empty():
		if is_solid_block(world_cell):
			b_type = &"stone"
		else:
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
	_voxel_tool.channel = VoxelBuffer.CHANNEL_SDF
	_voxel_tool.set_voxel_f(world_cell, SDF_AIR)
	_voxel_tool.channel = VoxelBuffer.CHANNEL_TYPE

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
		var probe := Vector3i(cp.x * 16 + 8, int(ISLAND_Y_MIN) + 16, cp.y * 16 + 8)
		return _has_data_at(probe)
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
	_results_mutex.lock()
	_results_ready.clear()
	_results_mutex.unlock()

func get_diagnostics() -> Dictionary:
	var diag := {
		"backend": "ZylannVoxelTerrain+VoxelMesherBlocky",
		"viewer_on_player": _viewer != null and _viewer.get_parent() != self,
		"view_distance_voxels": _effective_view_distance(),
		"view_distance_chunks": view_distance_chunks,
		"view_distance_limit_voxels": _backend_view_limit_voxels,
		"collision_view_chunks": COLLISION_VIEW_CHUNKS,
		"main_total_frame_time_ms": 0.0,
		"loaded_chunks": _chunks.size(),
		"total_chunks_generated": 0,
		"cancelled_tasks_count": 0,
		"stale_results_discarded": stale_results_discarded,
	}
	for k in _last_stream_diag.keys():
		diag[k] = _last_stream_diag[k]
	return diag

# ---------------------------------------------------------------------------
# Legacy test helpers
# ---------------------------------------------------------------------------
func _setup_noise() -> void:
	_setup_fallback_noise()

func _consume_ready_results(_frame_start: int) -> void:
	pass

func _ensure_island_gen() -> void:
	if _noise_3d == null or _noise_2d == null:
		_setup_fallback_noise()
	if _island_gen == null:
		_island_gen = _IslandGeneratorScript.new()
		_island_gen.noise_island = _noise_3d
		_island_gen.noise_island_2d = _noise_2d
		_island_gen.noise_ore = _noise_ore
		_island_gen.density_threshold = island_density_threshold
		_island_gen.vertical_scale = island_vertical_scale

func _evaluate_procedural_voxel(gx: int, gy: int, gz: int, cp: Vector2i, local_cell: Vector3i) -> StringName:
	return _procedural_voxel(gx, gy, gz, cp, local_cell)

func _load_or_generate_chunk_sync(cp: Vector2i) -> VoxelChunk:
	_chunk_generation[cp] = int(_chunk_generation.get(cp, 0))
	if _chunks.has(cp) and _chunks[cp] is VoxelChunk:
		return _chunks[cp] as VoxelChunk
	if _chunk_cache.has(cp) and _chunk_cache[cp] is VoxelChunk:
		return _restore_chunk_from_cache(cp, true) as VoxelChunk
	_ensure_island_gen()
	var chunk := VoxelChunk.new()
	chunk.name = "Chunk_%d_%d" % [cp.x, cp.y]
	chunk.chunk_pos = cp
	chunk.voxel_world = self
	var start_x := cp.x * VoxelChunk.SIZE_X
	var start_z := cp.y * VoxelChunk.SIZE_Z
	for lx in range(VoxelChunk.SIZE_X):
		for lz in range(VoxelChunk.SIZE_Z):
			var gx := start_x + lx
			var gz := start_z + lz
			for ly in range(VoxelChunk.SIZE_Y):
				var b_name: StringName = _evaluate_procedural_voxel(gx, ly, gz, cp, Vector3i(lx, ly, lz))
				chunk.set_voxel_local(lx, ly, lz, b_name)
	_chunks[cp] = chunk
	chunk.rebuild()
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
	return _TerrainBlockyLibraryScript.type_to_name(id)

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
	_ensure_island_gen()
	if _island_gen != null and _island_gen.has_method("eval_voxel"):
		return int(_island_gen.eval_voxel(gx, gy, gz))
	return BLOCK_AIR

func save_terrain_deltas() -> bool:
	# World caching disabled — never write chunk edits to disk.
	return true

func load_terrain_deltas() -> bool:
	# World caching disabled — ignore any existing disk cache.
	_mined_deltas.clear()
	_mined_deltas_set.clear()
	return false
