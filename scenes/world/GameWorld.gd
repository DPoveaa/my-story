class_name GameWorld
extends Node3D

## Main test world scene for Milestone 1 / Milestone 2 / Milestone 3.
## Demonstrates grid-based block building, support calculations, presets, physics collapse,
## physical first-person character, Soul Projection, mortar face visuals, and
## block durability recovery classification.

const PlayerControllerScript = preload("res://scenes/player/PlayerController.gd")
const MortarOverlayRendererScript = preload("res://systems/rendering/MortarOverlayRenderer.gd")
const VoxelWorldScript = preload("res://systems/terrain/VoxelWorld.gd")

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
var _debug_camera_active: bool = false
var _mortar_overlay_renderer: Node3D = null

func _ready() -> void:
	if grid_system == null and has_node("/root/GridSystem"):
		grid_system = get_node("/root/GridSystem")
	if stability_system == null and has_node("/root/StabilitySystem"):
		stability_system = get_node("/root/StabilitySystem")

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

		# Move player far below terrain while we await physics registration, preventing
		# any first-frame partial-overlap that the engine might solve incorrectly.
		player.global_position = Vector3(0.5, -100.0, 0.5)
		if player.has_method("set_physics_process"):
			player.set_physics_process(false)

		# Deferred async spawn: awaits one physics_frame inside force_sync_spawn_chunks.
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

## Async coroutine: awaits voxel_world.force_sync_spawn_chunks() which yields one physics_frame,
## guaranteeing that all VoxelChunk StaticBody3D collision shapes are registered in PhysicsServer3D
## before we query a spawn position and set player.global_position.
## This is the ONLY correct way to spawn the player — never position in the same _ready() frame
## as add_child(voxel_world).
func _spawn_player_on_terrain() -> void:
	if player == null or voxel_world == null:
		return

	# Synchronously generate spawn-area chunks and wait one physics frame for collision registration
	await voxel_world.force_sync_spawn_chunks(0, 0)

	# Derive safe spawn position from real solid surface voxel data (not an arbitrary offset)
	var safe_spawn := voxel_world.get_spawn_position(0, 0)
	player.global_position = safe_spawn

	# Attach viewer to player so Zylann VoxelTerrain streams around player movement
	if voxel_world.has_method("attach_viewer_to_player"):
		voxel_world.attach_viewer_to_player(player)

	# Re-enable physics_process now that terrain collision is committed
	player.set_physics_process(true)

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
