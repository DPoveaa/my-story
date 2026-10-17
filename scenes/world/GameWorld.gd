class_name GameWorld
extends Node3D

## Main test world scene for Milestone 1 / Milestone 2 / Milestone 3.
## Demonstrates grid-based block building, support calculations, presets, physics collapse,
## physical first-person character, Soul Projection, mortar face visuals, and
## block durability recovery classification.

const PlayerControllerScript = preload("res://scenes/player/PlayerController.gd")
const MortarOverlayRendererScript = preload("res://systems/rendering/MortarOverlayRenderer.gd")
const VoxelWorldScript = preload("res://systems/terrain/VoxelWorld.gd")
const AStarGridManagerScript = preload("res://systems/terrain/AStarGridManager.gd")

enum GameMode { SURVIVAL, CREATIVE }
@export var current_game_mode: GameMode = GameMode.SURVIVAL

@onready var grid_renderer: GridRenderer = $GridRenderer
@onready var preview_ghost: PreviewGhost = $PreviewGhost
@onready var collapse_orchestrator: CollapseOrchestrator = $CollapseOrchestrator
@onready var debris_container: Node3D = $DebrisContainer
@onready var player: CharacterBody3D = get_node_or_null("Player")
@onready var build_camera: BuildCamera = get_node_or_null("BuildCamera")
@onready var build_hud: BuildHUD = $BuildHUD

var grid_system: Node
var stability_system: Node
var voxel_world: VoxelWorld = null
## AStar3D grid pathfinder — replaces the unreliable NavigationRegion3D for voxel terrain.
var astar_grid: Node = null
var astar_manager: Node:
	get: return astar_grid
	set(val): astar_grid = val
var _debug_camera_active: bool = false
var _mortar_overlay_renderer: Node3D = null
## Large XZ shift each session so the same generator yields a fresh landscape without reseeding.
var _session_spawn_xz: Vector2 = Vector2(0.5, 0.5)

func _ready() -> void:
	if grid_system == null and has_node("/root/GridSystem"):
		grid_system = get_node("/root/GridSystem")
	if stability_system == null and has_node("/root/StabilitySystem"):
		stability_system = get_node("/root/StabilitySystem")

	randomize()
	_session_spawn_xz = Vector2(
		float(randi_range(-10000, 10000)) + 0.5,
		float(randi_range(-10000, 10000)) + 0.5
	)

	# Instantiate 3D Chunked Voxel World
	voxel_world = VoxelWorldScript.new()
	voxel_world.name = "VoxelWorld"
	voxel_world.seed_value = 1337
	add_child(voxel_world)
	# NOTE: do NOT call update_loaded_chunks or get_spawn_position here.
	# VoxelChunk StaticBody3D nodes added via add_child() during _ready() have their
	# CollisionShape3Ds deferred to PhysicsServer3D. Placing the player in this same
	# _ready() call means no collision is registered yet — player falls through terrain.
	# Defer all player placement to after the first physics frame (see _spawn_player_on_terrain).

	# Spawn mortar overlay renderer as a child so face visuals work in-game.
	_mortar_overlay_renderer = MortarOverlayRendererScript.new()
	_mortar_overlay_renderer.name = "MortarOverlayRenderer"
	_mortar_overlay_renderer.grid_system = grid_system
	add_child(_mortar_overlay_renderer)

	if stability_system != null:
		stability_system.terrain_generator = voxel_world
		stability_system.require_joints_for_lateral_support = true

	# Wire Survival Objectives
	if has_node("/root/SurvivalObjectiveManager"):
		var obj_mgr = get_node("/root/SurvivalObjectiveManager")
		obj_mgr.is_active = (current_game_mode == GameMode.SURVIVAL)
		if voxel_world != null and not voxel_world.voxel_mined.is_connected(obj_mgr.on_voxel_mined):
			voxel_world.voxel_mined.connect(obj_mgr.on_voxel_mined)

	# Wire HUD
	if build_hud != null:
		build_hud.grid_system = grid_system
		build_hud.orchestrator = collapse_orchestrator
		build_hud.player = player
		if build_hud.has_method("bind_voxel_world"):
			build_hud.bind_voxel_world(voxel_world)
		else:
			build_hud.voxel_world = voxel_world

	# Wire Player (primary gameplay controller).
	# Spawn on physics-validated safe surface AFTER terrain collision is committed to PhysicsServer3D.
	# This is done via an async deferred call so VoxelChunk StaticBody3Ds are fully registered.
	if player != null:
		player.game_mode = current_game_mode
		player.grid_system = grid_system
		player.stability_system = stability_system
		player.orchestrator = collapse_orchestrator
		player.preview_ghost = preview_ghost
		player.build_hud = build_hud

		player.block_type_changed.connect(build_hud.set_selected_block_type)
		player.state_changed.connect(build_hud.set_player_state)
		if player.has_signal("carried_block_changed"):
			player.carried_block_changed.connect(build_hud.set_carried_block)
		if player.has_signal("cement_changed"):
			player.cement_changed.connect(build_hud.set_cement)
		if player.has_signal("target_face_changed"):
			player.target_face_changed.connect(build_hud.set_target_face_info)
		if player.has_signal("raw_materials_changed"):
			player.raw_materials_changed.connect(build_hud.set_raw_materials)
		build_hud.set_selected_block_type(player.get_selected_type())
		build_hud.set_player_mode("Survival" if current_game_mode == GameMode.SURVIVAL else "Creative")
		build_hud.set_cement(player.get_cement_count(), player.max_cement)

		# Attach viewer to player so Zylann VoxelTerrain streams around player location
		if voxel_world.has_method("attach_viewer_to_player"):
			voxel_world.attach_viewer_to_player(player)

		if player.has_method("suspend_physics"):
			player.suspend_physics()
		# Hold just above the island band near the randomized session column.
		# Y stays within collision viewer range (~96 vx); XZ is massively shifted.
		player.global_position = Vector3(_session_spawn_xz.x, 90.0, _session_spawn_xz.y)
		if build_hud != null and build_hud.has_method("set_loading_overlay"):
			build_hud.set_loading_overlay(true, "Loading terrain…")
		_spawn_player_on_terrain.call_deferred()

	# Wire BuildCamera as secondary/debug tool
	if build_camera != null:
		build_camera.grid_system = grid_system
		build_camera.stability_system = stability_system
		build_camera.orchestrator = collapse_orchestrator
		build_camera.preview_ghost = preview_ghost
		if player != null:
			build_camera.current = false
		else:
			build_camera.block_type_changed.connect(build_hud.set_selected_block_type)
			build_hud.set_selected_block_type(build_camera.get_selected_type())

	_setup_astar_grid()

## Async: hold player still with loading UI until a validated top-surface spawn exists.
func _spawn_player_on_terrain() -> void:
	if player == null or voxel_world == null:
		return

	# Snap the session column onto nearby procedural land before streaming collision.
	if voxel_world.has_method("find_nearby_land_column"):
		var land: Vector2 = voxel_world.find_nearby_land_column(_session_spawn_xz.x, _session_spawn_xz.y, 256)
		if land != Vector2.ZERO:
			_session_spawn_xz = land

	var hold := Vector3(_session_spawn_xz.x, 90.0, _session_spawn_xz.y)
	player.global_position = hold
	if player.has_method("suspend_physics"):
		player.suspend_physics()
	if build_hud != null and build_hud.has_method("set_loading_overlay"):
		build_hud.set_loading_overlay(true, "Loading terrain…")

	# Park viewers at spawn so streaming prioritizes the landing column.
	if voxel_world.has_method("attach_viewer_to_player"):
		voxel_world.attach_viewer_to_player(player)

	var loaded_ok: bool = false
	var on_load_status := func(message: String) -> void:
		if build_hud != null and build_hud.has_method("set_loading_overlay"):
			build_hud.set_loading_overlay(true, message)
	if voxel_world.has_signal("terrain_loading_status"):
		voxel_world.terrain_loading_status.connect(on_load_status)
	var probe := Vector3(_session_spawn_xz.x, 56.0, _session_spawn_xz.y)
	if voxel_world.has_method("wait_for_terrain_at"):
		loaded_ok = await voxel_world.wait_for_terrain_at(probe)
	else:
		await voxel_world.force_sync_spawn_chunks(floori(_session_spawn_xz.x) / 16, floori(_session_spawn_xz.y) / 16)
		loaded_ok = true
	if voxel_world.has_signal("terrain_loading_status") and voxel_world.terrain_loading_status.is_connected(on_load_status):
		voxel_world.terrain_loading_status.disconnect(on_load_status)

	var safe_spawn := Vector3.ZERO
	if loaded_ok:
		await get_tree().physics_frame
		var t_spawn_start: int = Time.get_ticks_msec()
		if voxel_world.has_method("try_find_safe_spawn"):
			safe_spawn = await voxel_world.try_find_safe_spawn(16, player)
		elif voxel_world.has_method("get_spawn_position_raycast"):
			safe_spawn = voxel_world.get_spawn_position_raycast(_session_spawn_xz.x, _session_spawn_xz.y)
		var t_spawn_elapsed: int = Time.get_ticks_msec() - t_spawn_start
		print("[StartupTiming] Spawn search took: %d ms, result: %s" % [t_spawn_elapsed, safe_spawn])

	# try_find_safe_spawn already validates physics — no second verify pass needed.
	var verified: bool = safe_spawn != Vector3.ZERO

	if not loaded_ok or safe_spawn == Vector3.ZERO or not verified:
		if build_hud != null and build_hud.has_method("set_loading_overlay"):
			build_hud.set_loading_overlay(true, "Terrain load failed — press Home to retry or Esc to quit")
		if player.has_method("suspend_physics"):
			player.suspend_physics()
		return

	# Confirmed valid spawn surface and collision!
	if player.has_method("resume_at_spawn"):
		player.resume_at_spawn(safe_spawn)
	else:
		player.global_position = safe_spawn
		if player.has_method("resume_physics"):
			player.resume_physics()

	if build_hud != null and build_hud.has_method("set_loading_overlay"):
		build_hud.set_loading_overlay(false)

	# Initialize A* exactly once, centred on the confirmed spawn.
	# initialize_once() is a no-op if called a second time, so late chunk_loaded
	# signals cannot trigger a redundant full rebuild.
	if astar_grid != null:
		astar_grid.initialize_once(safe_spawn)

func _process(_delta: float) -> void:
	## Feed the player's current position to AStarGridManager so the graph stays centred on them.
	if astar_grid != null and player != null and is_instance_valid(player):
		astar_grid.update_center(player.global_position)

func _unhandled_input(event: InputEvent) -> void:
	if build_hud != null and build_hud.has_method("is_modal_open") and build_hud.is_modal_open():
		return

	if event is InputEventKey and event.pressed and not event.echo:
		if event.is_action_pressed(&"debug_camera") or event.keycode == KEY_F1:
			toggle_debug_camera()
		elif event.keycode == KEY_T:
			spawn_test_tower(Vector3i(0, 0, 0))
		elif event.keycode == KEY_B:
			spawn_test_bridge(Vector3i(-5, 0, -5))
		elif event.keycode == KEY_H:
			spawn_test_arch(Vector3i(6, 0, 0))
		elif event.keycode == KEY_C:
			clear_world()
		elif event.keycode == KEY_HOME or event.physical_keycode == KEY_HOME:
			if player != null and player.has_method("respawn_home"):
				player.respawn_home()
		elif event.keycode == KEY_ESCAPE:
			get_tree().quit()

## Toggles the development free-flight camera without corrupting player state.
func toggle_debug_camera() -> void:
	if player == null or build_camera == null:
		return

	_debug_camera_active = not _debug_camera_active
	if _debug_camera_active:
		player.set_state(PlayerControllerScript.State.DEBUG_FLIGHT)
		build_camera.global_transform = player.get_active_camera().global_transform
		build_camera.current = true
		if build_hud != null:
			build_hud.set_player_state(2) # Debug Free Camera
	else:
		build_camera.current = false
		player.set_state(PlayerControllerScript.State.BODY_CONTROL)
		if build_hud != null:
			build_hud.set_player_state(player.current_state)

## Spawns a tall test tower with an overhanging observation platform.
## Automatically calculates natural surface Y coordinate if origin.y is 0.
func spawn_test_tower(origin: Vector3i = Vector3i.ZERO) -> void:
	if grid_system == null:
		return

	if origin.y == 0 and voxel_world != null:
		var spawn_pos := voxel_world.get_spawn_position(origin.x, origin.z)
		if spawn_pos != Vector3.ZERO:
			origin.y = int(floor(spawn_pos.y - 1.2))

	var placed: Array[Vector3i] = []
	# 2x2 Pillar, 7 blocks tall
	for y in range(0, 7):
		for x in range(0, 2):
			for z in range(0, 2):
				var cell := origin + Vector3i(x, y, z)
				grid_system.place_block(cell, &"stone")
				placed.append(cell)

	# 4x4 Overhanging platform at top (y = 7)
	for x in range(-1, 3):
		for z in range(-1, 3):
			var cell := origin + Vector3i(x, 7, z)
			grid_system.place_block(cell, &"wood")
			placed.append(cell)

	# 4 crenellations/parapets on platform rim (y = 8)
	var battlements := [
		origin + Vector3i(-1, 8, -1),
		origin + Vector3i(2, 8, -1),
		origin + Vector3i(-1, 8, 2),
		origin + Vector3i(2, 8, 2)
	]
	for c in battlements:
		grid_system.place_block(c, &"brick")
		placed.append(c)

	_bond_preset_cells(placed)

## Spawns a bridge between two pillars.
func spawn_test_bridge(origin: Vector3i = Vector3i.ZERO) -> void:
	if grid_system == null:
		return

	if origin.y == 0 and voxel_world != null:
		var spawn_pos := voxel_world.get_spawn_position(origin.x, origin.z)
		if spawn_pos != Vector3.ZERO:
			origin.y = int(floor(spawn_pos.y - 1.2))

	var placed: Array[Vector3i] = []
	# Left Pillar (height 5)
	for y in range(0, 5):
		var c := origin + Vector3i(0, y, 0)
		grid_system.place_block(c, &"stone")
		placed.append(c)

	# Right Pillar (height 5, distance 6 blocks away)
	for y in range(0, 5):
		var c := origin + Vector3i(6, y, 0)
		grid_system.place_block(c, &"stone")
		placed.append(c)

	# Walkway spanning between pillars (y = 4)
	for x in range(1, 6):
		var c := origin + Vector3i(x, 4, 0)
		grid_system.place_block(c, &"wood")
		placed.append(c)

	_bond_preset_cells(placed)

## Spawns a rounded stone archway.
func spawn_test_arch(origin: Vector3i = Vector3i.ZERO) -> void:
	if grid_system == null:
		return

	if origin.y == 0 and voxel_world != null:
		var spawn_pos := voxel_world.get_spawn_position(origin.x, origin.z)
		if spawn_pos != Vector3.ZERO:
			origin.y = int(floor(spawn_pos.y - 1.2))

	var placed: Array[Vector3i] = []
	# Left column
	for y in range(0, 4):
		var c := origin + Vector3i(0, y, 0)
		grid_system.place_block(c, &"brick")
		placed.append(c)

	# Right column
	for y in range(0, 4):
		var c := origin + Vector3i(4, y, 0)
		grid_system.place_block(c, &"brick")
		placed.append(c)

	# Arch curves and keystone
	var c1 := origin + Vector3i(1, 4, 0)
	var c2 := origin + Vector3i(2, 5, 0)
	var c3 := origin + Vector3i(3, 4, 0)
	grid_system.place_block(c1, &"stone")
	grid_system.place_block(c2, &"gold") # Keystone
	grid_system.place_block(c3, &"stone")
	placed.append_array([c1, c2, c3])

	_bond_preset_cells(placed)

func _bond_preset_cells(cells: Array[Vector3i]) -> void:
	var joint_sys: Node = null
	if is_inside_tree() and get_tree() != null:
		joint_sys = get_tree().root.get_node_or_null("JointSystem")
	if joint_sys == null:
		var loop = Engine.get_main_loop()
		if loop is SceneTree and loop.root != null:
			joint_sys = loop.root.get_node_or_null("JointSystem")
	if joint_sys != null:
		for c in cells:
			joint_sys.bond_all_adjacent_neighbors(c)

## Clears all blocks and active debris.
func clear_world() -> void:
	if grid_system != null:
		grid_system.clear()
	if collapse_orchestrator != null:
		collapse_orchestrator.clear_all_debris()

# ==============================================================================
# ASTAR GRID PATHFINDING  (replaces failed NavigationRegion3D / NavigationAgent3D)
# ==============================================================================

func _setup_astar_grid() -> void:
	astar_grid = AStarGridManagerScript.new()
	astar_grid.name = "AStarGridManager"
	add_child(astar_grid)

	# Wire VoxelWorld terrain edits so the graph rebuilds when blocks are mined
	if voxel_world != null:
		if not voxel_world.voxel_mined.is_connected(astar_grid._on_voxel_changed):
			voxel_world.voxel_mined.connect(astar_grid._on_voxel_changed)

	# Wire GridSystem block events so the graph rebuilds when player-placed blocks change
	if grid_system != null:
		if grid_system.has_signal("block_placed"):
			grid_system.block_placed.connect(
				func(cell: Vector3i, _data: Variant = null) -> void: astar_grid.notify_block_changed(cell)
			)
		if grid_system.has_signal("block_removed"):
			grid_system.block_removed.connect(
				func(cell: Vector3i, _data: Variant = null) -> void: astar_grid.notify_block_changed(cell)
			)
		if grid_system.has_signal("blocks_removed_batch"):
			grid_system.blocks_removed_batch.connect(
				func(cells: Array, _data_map: Dictionary = {}) -> void:
					if astar_grid.has_method("notify_blocks_changed"):
						astar_grid.notify_blocks_changed(cells)
					else:
						for c in cells:
							astar_grid.notify_block_changed(c)
			)
		if grid_system.has_signal("grid_cleared"):
			grid_system.grid_cleared.connect(
				func() -> void: astar_grid.rebuild_graph()
			)

	# Initial graph built around origin — will shift to player after spawn
	astar_grid.setup(voxel_world)
