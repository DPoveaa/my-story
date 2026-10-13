class_name VoxelWorld
extends Node3D

## VoxelWorld — Zylann VoxelLodTerrain + VoxelMesherTransvoxel (hybrid SDF).
## CHANNEL_SDF drives mesh/collision; CHANNEL_TYPE holds mineable IDs; CHANNEL_INDICES textures.
## LOD enables far visuals without full-detail geometry; dual viewers keep collisions nearby.
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

signal voxel_mined(world_cell: Vector3i, block_type: StringName)
signal spawn_chunks_ready
signal view_distance_changed(voxels: int, chunks: int)

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
var _terrain_material: ShaderMaterial = null

var _noise_2d: FastNoiseLite = null
var _noise_3d: FastNoiseLite = null
var _noise_ore: FastNoiseLite = null
var _island_gen = null

const _IslandGeneratorScript = preload("res://systems/terrain/IslandGenerator.gd")
const _TRANSVOXEL_SHADER = preload("res://systems/terrain/terrain_transvoxel.gdshader")

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
var _stream_diag_timer: float = 0.0
var _last_stream_diag: Dictionary = {}
var _backend_view_limit_voxels: int = 0

func _ready() -> void:
	_setup_fallback_noise()
	load_terrain_deltas()
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

	_stream_diag_timer += delta
	if _stream_diag_timer >= 1.5:
		_stream_diag_timer = 0.0
		_refresh_stream_diagnostics()

# ---------------------------------------------------------------------------
# VoxelTerrain + Transvoxel (SDF)
# ---------------------------------------------------------------------------
func _build_terrain_material() -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = _TRANSVOXEL_SHADER
	mat.set_shader_parameter("u_uv_scale", 0.45)
	mat.set_shader_parameter("u_transition_mask", 0)
	mat.set_shader_parameter("u_texture_array", _build_terrain_texture_array())
	_terrain_material = mat
	return mat

func _build_terrain_texture_array() -> Texture2DArray:
	## Solid-color layers indexed by CHANNEL_INDICES (0=air unused, 1..6 materials).
	var colors: Array[Color] = [
		Color(0.05, 0.05, 0.06, 1.0), # 0 unused
		Color(0.30, 0.66, 0.26, 1.0), # grass
		Color(0.55, 0.36, 0.20, 1.0), # dirt (warm brown mantle)
		Color(0.58, 0.55, 0.50, 1.0), # stone (warm grey, not blue underside)
		Color(0.22, 0.22, 0.24, 1.0), # coal
		Color(0.72, 0.74, 0.78, 1.0), # iron
		Color(0.90, 0.76, 0.10, 1.0), # gold
	]
	var images: Array[Image] = []
	for c in colors:
		var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
		img.fill(c)
		images.append(img)
	var arr := Texture2DArray.new()
	arr.create_from_images(images)
	return arr

func _build_terrain() -> void:
	_uses_lod_terrain = ClassDB.class_exists("VoxelLodTerrain")
	if _uses_lod_terrain:
		_terrain = ClassDB.instantiate("VoxelLodTerrain")
	else:
		_terrain = VoxelTerrain.new()
	# Keep legacy node name so PlayerController / tools keep finding the terrain.
	_terrain.name = "VoxelTerrain"

	# TEXTURES_SINGLE_S4 needs 8-bit indices.
	if ClassDB.class_exists("VoxelFormat"):
		var fmt = ClassDB.instantiate("VoxelFormat")
		if fmt != null and "indices_depth" in fmt:
			fmt.indices_depth = VoxelBuffer.DEPTH_8_BIT
			if "format" in _terrain:
				_terrain.format = fmt

	var mesher := VoxelMesherTransvoxel.new()
	if "texturing_mode" in mesher:
		# TEXTURES_SINGLE_S4 = 2 — pairs with terrain_transvoxel.gdshader + CHANNEL_INDICES.
		mesher.texturing_mode = 2
	if "transitions_enabled" in mesher:
		# LOD seams need transition meshes; flat VoxelTerrain does not.
		mesher.transitions_enabled = _uses_lod_terrain
	_terrain.set("mesher", mesher)

	var mat := _build_terrain_material()
	if _uses_lod_terrain and _terrain.has_method("set_material"):
		_terrain.call("set_material", mat)
	elif "material_override" in _terrain:
		_terrain.material_override = mat

	_island_gen = _IslandGeneratorScript.new()
	_island_gen.noise_island = _noise_3d
	_island_gen.noise_island_2d = _noise_2d
	_island_gen.noise_ore = _noise_ore
	_island_gen.density_threshold = island_density_threshold
	_island_gen.vertical_scale = island_vertical_scale
	_terrain.set("generator", _island_gen)

	_terrain.set("generate_collisions", true)
	_terrain.set("collision_layer", 1)
	_terrain.set("collision_mask", 1)
	if "mesh_block_size" in _terrain:
		_terrain.set("mesh_block_size", 16)

	# Vertical volume clamped to the floating-island band.
	var y0: float = ISLAND_Y_MIN - 40.0
	var y_size: float = (ISLAND_Y_MAX - ISLAND_Y_MIN) + 80.0
	var volume := AABB(Vector3(-500000.0, y0, -500000.0), Vector3(1000000.0, y_size, 1000000.0))
	if _uses_lod_terrain:
		_terrain.set("voxel_bounds", volume)
		_terrain.set("lod_count", 7)
		_terrain.set("lod_distance", 64.0)
		if "secondary_lod_distance" in _terrain:
			_terrain.set("secondary_lod_distance", 64.0)
		# Only full-detail LOD rings get collision meshes.
		_terrain.set("collision_lod_count", 1)
		if "streaming_system" in _terrain:
			# STREAMING_SYSTEM_CLIPBOX = 1
			_terrain.set("streaming_system", 1)
	else:
		if "bounds" in _terrain:
			_terrain.set("bounds", volume)
		if "automatic_loading_enabled" in _terrain:
			_terrain.set("automatic_loading_enabled", true)
		if "block_enter_notification_enabled" in _terrain:
			_terrain.set("block_enter_notification_enabled", true)

	if _terrain.has_signal("mesh_block_entered"):
		_terrain.connect("mesh_block_entered", _on_mesh_block_entered)

	_backend_view_limit_voxels = _view_chunks_ceiling() * 16
	_sync_view_distance()
	add_child(_terrain)

	_voxel_tool = _terrain.get_voxel_tool()
	if _voxel_tool != null:
		_voxel_tool.channel = VoxelBuffer.CHANNEL_TYPE

func _on_mesh_block_entered(_block_pos: Vector3i) -> void:
	if is_chunk_ready(Vector3(0.5, 56.0, 0.5)):
		spawn_chunks_ready.emit()

func _build_viewer() -> void:
	# Visuals at full view distance (no distant colliders).
	_viewer = VoxelViewer.new()
	_viewer.name = "VoxelViewer"
	_viewer.requires_collisions = false
	_viewer.requires_visuals = true
	add_child(_viewer)

	# Nearby collisions only — never allocate full-detail colliders for far LOD rings.
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
		# Reflect the active backend ceiling (LOD high; flat VoxelTerrain lower).
		_backend_view_limit_voxels = _view_chunks_ceiling() * 16
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

func _refresh_stream_diagnostics() -> void:
	_last_stream_diag = {
		"backend": "VoxelLodTerrain+Transvoxel" if _uses_lod_terrain else "VoxelTerrain+Transvoxel",
		"view_chunks": view_distance_chunks,
		"view_limit_chunks": _view_chunks_ceiling(),
		"collision_chunks": COLLISION_VIEW_CHUNKS,
		"lod": _uses_lod_terrain,
	}
	if _terrain != null and _terrain.has_method("get_statistics"):
		var stats: Dictionary = _terrain.get_statistics()
		_last_stream_diag["remaining_main_thread_blocks"] = int(stats.get("remaining_main_thread_blocks", 0))
		_last_stream_diag["updated_blocks"] = int(stats.get("updated_blocks", 0))

func get_stream_diagnostics() -> Dictionary:
	return _last_stream_diag.duplicate()

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
	## True only when a validated top-surface physics hit is available.
	if not is_chunk_ready(world_pos):
		return false
	var hit := _raycast_top_surface(world_pos.x, world_pos.z)
	return not hit.is_empty()

func _viewer_near_enough(world_pos: Vector3) -> bool:
	if _viewer == null:
		return true
	var vp: Vector3 = _viewer.global_position if _viewer.is_inside_tree() else Vector3.ZERO
	return vp.distance_to(world_pos) < float(_effective_view_distance())

func wait_for_terrain_at(world_pos: Vector3) -> void:
	if not is_inside_tree() or _terrain == null:
		return
	if is_collision_ready_at(world_pos):
		await get_tree().process_frame
		return
	var max_wait_cycles := 480
	var cycles := 0
	while not is_collision_ready_at(world_pos) and cycles < max_wait_cycles:
		cycles += 1
		await get_tree().process_frame
	_apply_persisted_deltas()
	await get_tree().physics_frame
	await get_tree().process_frame
	if is_collision_ready_at(world_pos):
		spawn_chunks_ready.emit()

func force_sync_spawn_chunks(cx: int = 0, cz: int = 0) -> void:
	if not is_inside_tree():
		return
	var world_pos := Vector3(float(cx * 16) + 0.5, 56.0, float(cz * 16) + 0.5)
	await wait_for_terrain_at(world_pos)

func get_highest_solid_y(x: int, z: int) -> int:
	if _voxel_tool != null and _has_data_at(Vector3i(x, int(ISLAND_Y_MAX), z)):
		_voxel_tool.channel = VoxelBuffer.CHANNEL_SDF
		var ray_origin := Vector3(float(x) + 0.5, float(WORLD_HEIGHT) + 4.0, float(z) + 0.5)
		var hit = _voxel_tool.raycast(ray_origin, Vector3.DOWN, float(WORLD_HEIGHT) + 8.0)
		if hit != null:
			return hit.position.y

	if _island_gen != null and _island_gen.has_method("eval_surface_y"):
		var sy: int = int(_island_gen.eval_surface_y(x, z))
		if sy >= 0:
			return sy

	for y in range(WORLD_HEIGHT - 1, -1, -1):
		if is_solid_block(Vector3i(x, y, z)):
			return y
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

	# Check player capsule clearance (ensure no intersecting solid walls/blocks)
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
	if not overlaps.is_empty():
		return false

	var ground := _raycast_top_surface(candidate_pos.x, candidate_pos.z)
	if not ground.is_empty():
		var ground_y: float = ground.position.y
		if absf(candidate_pos.y - (ground_y + SPAWN_FEET_CLEARANCE)) > 1.5:
			return false
	return true

func get_spawn_position_raycast(x: float = 0.5, z: float = 0.5) -> Vector3:
	var hit := _raycast_top_surface(x, z)
	if not hit.is_empty():
		var feet := _feet_from_surface_hit(x, z, hit.position.y)
		if verify_spawn_physics(feet):
			return feet
	return Vector3.ZERO

func try_find_safe_spawn(max_radius: int = 8, carrier: Node3D = null) -> Vector3:
	## Fast non-blocking search for starter-island top-surface spawn (< 1ms).
	var spawn_x := 0.5
	var spawn_z := 0.5
	if carrier != null:
		carrier.global_position = Vector3(spawn_x, 90.0, spawn_z)
	elif _viewer != null and _viewer.is_inside_tree():
		_viewer.global_position = Vector3(spawn_x, 56.0, spawn_z)
		if _viewer_collision != null and _viewer_collision.is_inside_tree():
			_viewer_collision.global_position = Vector3(spawn_x, 56.0, spawn_z)

	var search_limit := clampi(max_radius, 1, 8)
	var origins: Array[Vector2i] = [Vector2i(0, 0)]
	for radius in range(1, search_limit + 1):
		for dx in range(-radius, radius + 1):
			for dz in range(-radius, radius + 1):
				if absi(dx) != radius and absi(dz) != radius:
					continue
				origins.append(Vector2i(dx, dz))

	# Phase 1: Check 3D physics raycast surface hit on nearby columns (up to 3 frames wait)
	for attempt in range(3):
		for col in origins:
			var x: float = float(col.x) + 0.5
			var z: float = float(col.y) + 0.5
			var feet := get_spawn_position_raycast(x, z)
			if feet != Vector3.ZERO and verify_spawn_physics(feet):
				return feet
		await get_tree().physics_frame

	# Phase 2: Instant procedural fallback based on noise height profile
	for col in origins:
		var x: float = float(col.x) + 0.5
		var z: float = float(col.y) + 0.5
		var top_y := get_highest_solid_y(col.x, col.y)
		if top_y >= 0:
			var candidate := Vector3(x, float(top_y) + 1.0 + SPAWN_FEET_CLEARANCE, z)
			if verify_spawn_physics(candidate):
				return candidate

	return Vector3(0.5, 56.0, 0.5)

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
	var cx := floori(float(world_cell.x) / 16.0)
	var cz := floori(float(world_cell.z) / 16.0)
	var cp := Vector2i(cx, cz)
	var lc := Vector3i(posmod(world_cell.x, 16), world_cell.y, posmod(world_cell.z, 16))
	if _mined_deltas_set.has(cp) and _mined_deltas_set[cp].has(lc):
		return false

	if _terrain != null and _voxel_tool != null and _has_data_at(world_cell):
		_voxel_tool.channel = VoxelBuffer.CHANNEL_SDF
		return _voxel_tool.get_voxel_f(world_cell) < 0.0

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
# Mining — clear TYPE + SDF + INDICES together
# ---------------------------------------------------------------------------
func mine_voxel(world_cell: Vector3i) -> StringName:
	var b_type := get_voxel_at(world_cell)
	if b_type.is_empty():
		# SDF solid without TYPE label still yields stone for resources.
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
	_voxel_tool.channel = VoxelBuffer.CHANNEL_INDICES
	_voxel_tool.set_voxel(world_cell, BLOCK_AIR)
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
	_results_ready.clear()

func get_diagnostics() -> Dictionary:
	var diag := {
		"backend": "ZylannVoxelLodTerrain+Transvoxel" if _uses_lod_terrain else "ZylannVoxelTerrain+Transvoxel",
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
