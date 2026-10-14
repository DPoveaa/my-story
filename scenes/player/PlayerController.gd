class_name PlayerController
extends CharacterBody3D

## Reusable first-person player controller and Soul Projection state machine.
## M2.1: Fixed mouse capture flow, jump/gravity for 1m block clearance, step-up mechanic,
## debris push via CharacterBody3D contact, and modular grab/carry/recover system.

enum State {
	BODY_CONTROL,
	SOUL_PROJECTION,
	DEBUG_FLIGHT
}

signal state_changed(new_state: State)
signal block_type_changed(type_id: StringName)
signal carried_block_changed(is_carrying: bool, block_type: StringName)
signal cement_changed(current_count: int, max_count: int)
signal target_face_changed(has_target: bool, cell: Vector3i, face_dir: Vector3i, status_text: String)
signal raw_materials_changed(materials: Dictionary)
signal save_blueprint_requested()
signal load_blueprint_requested(anchor: Vector3i)

@export_group("Cement & Bonding")
@export var cement_count: int = 25
@export var max_cement: int = 100
@export var unlimited_cement: bool = false # Explicit debug/test flag

@export_group("First-Person Locomotion")
@export var walk_speed: float = 6.0
@export var sprint_speed_multiplier: float = 1.75
## Peak jump height ≈ jump_velocity² / (2*gravity)
## At 6.5 / 20.0: height ≈ 1.056m — clears a 1m block reliably.
@export var jump_velocity: float = 6.5
@export var gravity: float = 20.0
@export var mouse_sensitivity: float = 0.003
@export var capsule_radius: float = 0.4
@export var capsule_height: float = 1.8
## Step-up: automatically steps over ledges up to this height (voxel stairs / 1-block curbs).
@export var step_up_height: float = 0.45
## Impulse force applied when colliding horizontally with dynamic debris rigid bodies
@export var push_force: float = 120.0

@export_group("Flight Mode")
## Enable free 3D flying mode (toggled via F or double-tapping Space).
@export var is_flying: bool = false
@export var fly_speed: float = 18.0
@export var fly_fast_multiplier: float = 4.0
@export var fly_vertical_speed: float = 14.0

@export_group("Soul Projection")
@export var projection_speed: float = 18.0
@export var projection_fast_multiplier: float = 4.0
@export var projection_mouse_sensitivity: float = 0.003

@export_group("Building Interaction")
@export var max_ray_distance: float = 80.0
@export var available_types: Array[StringName] = [&"grass", &"dirt", &"stone", &"brick", &"wood", &"gold"]
@export var mine_duration_seconds: float = 1.2

# System References
@export var grid_system: Node
@export var stability_system: Node
@export var orchestrator: CollapseOrchestrator
@export var preview_ghost: PreviewGhost
@export var build_hud: Node = null

const DebrisGrabberScript = preload("res://systems/interaction/DebrisGrabber.gd")

# Internal Nodes
@onready var collision_shape: CollisionShape3D = $CollisionShape3D
@onready var body_mesh: MeshInstance3D = $BodyMesh
@onready var head: Node3D = $Head
@onready var body_camera: Camera3D = $Head/BodyCamera
@onready var projection_camera: Camera3D = $ProjectionCamera
@onready var debris_grabber: Node = get_node_or_null("DebrisGrabber")

enum AreaSelectionStep { NONE, CORNER_1, CORNER_2 }
var area_selection_step: AreaSelectionStep = AreaSelectionStep.NONE
var area_corner_1: Vector3i = Vector3i.ZERO
var area_corner_2: Vector3i = Vector3i.ZERO

enum GameMode { SURVIVAL, CREATIVE }
@export var game_mode: GameMode = GameMode.SURVIVAL

# State
var current_state: State = State.BODY_CONTROL
var _mouse_captured: bool = false
var _last_space_press_time: float = -1.0
const DOUBLE_TAP_TIME: float = 0.35

# First-person view angles
var _yaw: float = 0.0
var _pitch: float = 0.0

# Projection view angles
var _proj_yaw: float = 0.0
var _proj_pitch: float = 0.0

# Material inventory selection
var selected_type_index: int = 0

# Raycast targeting state
var has_target: bool = false
var target_place_cell: Vector3i = Vector3i.ZERO
var target_remove_cell: Vector3i = Vector3i.ZERO
var target_face_dir: Vector3i = Vector3i.ZERO
var target_face_status: String = ""
var can_place_target: bool = false

# Debris targeting state
var target_is_debris: bool = false
var target_debris_island: DebrisIsland = null
var target_debris_cell: Variant = null

# Terrain targeting and mining state
var target_is_terrain: bool = false
var target_terrain_cell: Vector3i = Vector3i.ZERO
var target_terrain_type: StringName = &""
var mining_progress: float = 0.0
var target_voxel_pos: Vector3i = Vector3i(99999, 99999, 99999)
var _last_mined_cell: Vector3i = Vector3i(99999, 99999, 99999)
const MINE_TIME: float = 1.0
const _INVALID_VOXEL := Vector3i(99999, 99999, 99999)

## Thin outline + staged crack overlay for the targeted terrain voxel (reused meshes).
var _terrain_outline: MeshInstance3D = null
var _terrain_crack: MeshInstance3D = null
var _outline_mat: StandardMaterial3D = null
var _crack_mat: StandardMaterial3D = null
var _crack_stage: int = -1

## Accumulated raw materials recovered from low-durability debris.
## Dictionary[StringName, int] — block_type -> amount
var raw_materials: Dictionary = {}

## Spawn state — GameWorld drives loading; player stays frozen until resume_at_spawn().
var _is_spawned: bool = false
var _resolved_spawn: Vector3 = Vector3(0.5, 90.0, 0.5)
var _gameplay_input_suspended: bool = true

## Last terrain hit surface (world space) for crack/outline orientation.
var _target_hit_normal: Vector3 = Vector3.UP
var _target_hit_point: Vector3 = Vector3.ZERO
var _debug_overlay_enabled: bool = false

func _ensure_nodes() -> void:
	if collision_shape == null:
		collision_shape = get_node_or_null("CollisionShape3D")
	if body_mesh == null:
		body_mesh = get_node_or_null("BodyMesh")
	if head == null:
		head = get_node_or_null("Head")
	if body_camera == null:
		body_camera = get_node_or_null("Head/BodyCamera")
	if projection_camera == null:
		projection_camera = get_node_or_null("ProjectionCamera")
	if debris_grabber == null:
		debris_grabber = get_node_or_null("DebrisGrabber")

func _ready() -> void:
	floor_max_angle = deg_to_rad(46.0)
	floor_snap_length = 0.3
	_ensure_nodes()
	if grid_system == null and has_node("/root/GridSystem"):
		grid_system = get_node("/root/GridSystem")
	if stability_system == null and has_node("/root/StabilitySystem"):
		stability_system = get_node("/root/StabilitySystem")
	if preview_ghost == null and get_parent() != null and get_parent().has_node("PreviewGhost"):
		preview_ghost = get_parent().get_node("PreviewGhost") as PreviewGhost
	if orchestrator == null and get_parent() != null and get_parent().has_node("CollapseOrchestrator"):
		orchestrator = get_parent().get_node("CollapseOrchestrator") as CollapseOrchestrator

	if debris_grabber == null:
		debris_grabber = get_node_or_null("DebrisGrabber")
		if debris_grabber == null:
			debris_grabber = DebrisGrabberScript.new()
			debris_grabber.name = "DebrisGrabber"
			add_child(debris_grabber)

	if debris_grabber != null:
		debris_grabber.preview_ghost = preview_ghost
		debris_grabber.grid_system = grid_system
		debris_grabber.orchestrator = orchestrator
		if not debris_grabber.grabbed_block.is_connected(_on_grabbed_block):
			debris_grabber.grabbed_block.connect(_on_grabbed_block)
		if not debris_grabber.released_block.is_connected(_on_released_block):
			debris_grabber.released_block.connect(_on_released_block)
		if not debris_grabber.recovered_block_to_grid.is_connected(_on_recovered_block):
			debris_grabber.recovered_block_to_grid.connect(_on_recovered_block)
		if not debris_grabber.recovered_as_raw_material.is_connected(_on_recovered_raw_material):
			debris_grabber.recovered_as_raw_material.connect(_on_recovered_raw_material)

	# Ensure projection camera is top_level so it flies independently of body transform
	if projection_camera != null:
		projection_camera.top_level = true

	# Hold above the island band; GameWorld places us after terrain+collision are ready.
	global_position = Vector3(0.5, 90.0, 0.5)
	_resolved_spawn = global_position
	_is_spawned = false
	_gameplay_input_suspended = true
	is_physics_suspended = true
	velocity = Vector3.ZERO
	_ensure_terrain_target_visuals()

	set_state(State.BODY_CONTROL)
	block_type_changed.emit(get_selected_type())
	cement_changed.emit(cement_count, max_cement)

## Physics suspension state — prevents gravity and movement until terrain finishes generating.
var is_physics_suspended: bool = true

func suspend_physics() -> void:
	is_physics_suspended = true
	_gameplay_input_suspended = true
	velocity = Vector3.ZERO

func resume_physics() -> void:
	is_physics_suspended = false
	_gameplay_input_suspended = false
	velocity = Vector3.ZERO
	set_physics_process(true)

## Place on a resolved spawn point and restore controls (called by GameWorld).
func resume_at_spawn(spawn_pos: Vector3) -> void:
	_resolved_spawn = spawn_pos
	global_position = spawn_pos
	velocity = Vector3.ZERO
	_yaw = 0.0
	_pitch = 0.0
	rotation = Vector3.ZERO
	if head != null:
		head.rotation = Vector3.ZERO
	_reset_mining_state()
	_hide_terrain_target_visuals()
	_is_spawned = true
	resume_physics()
	set_mouse_capture(true)
	set_state(State.BODY_CONTROL)

## Respawn at the last resolved safe spawn; keeps inventory and buildings.
## If initial spawn never completed, retry safe terrain placement via GameWorld.
func respawn_home() -> void:
	if debris_grabber != null and debris_grabber.is_grabbing:
		debris_grabber.release()
	if not _is_spawned:
		var world := get_parent()
		if world != null and world.has_method("_spawn_player_on_terrain"):
			if has_method("suspend_physics"):
				suspend_physics()
			world.call_deferred("_spawn_player_on_terrain")
		return
	global_position = _resolved_spawn
	velocity = Vector3.ZERO
	_yaw = 0.0
	_pitch = 0.0
	rotation = Vector3.ZERO
	if head != null:
		head.rotation = Vector3.ZERO
	if projection_camera != null and body_camera != null:
		projection_camera.global_transform = body_camera.global_transform
	_reset_mining_state()
	_hide_terrain_target_visuals()
	if preview_ghost != null:
		preview_ghost.hide_preview()
	_is_spawned = true
	is_physics_suspended = false
	_gameplay_input_suspended = false
	set_state(State.BODY_CONTROL)
	set_mouse_capture(true)

func get_resolved_spawn() -> Vector3:
	return _resolved_spawn

func get_debug_target_info() -> Dictionary:
	var category := "none"
	var material := "N/A"
	var durability := "N/A"
	var cell := Vector3i.ZERO
	if target_is_terrain:
		category = "terrain"
		material = String(target_terrain_type) if not target_terrain_type.is_empty() else "N/A"
		cell = target_terrain_cell
		durability = "N/A"
	elif target_is_debris:
		category = "debris"
		cell = target_debris_cell if target_debris_cell is Vector3i else Vector3i.ZERO
		if target_debris_island != null and target_debris_cell != null \
		and target_debris_island.constituent_blocks.has(target_debris_cell):
			var bd: BlockData = target_debris_island.constituent_blocks[target_debris_cell]
			material = String(bd.block_type)
			var max_d: float = BlockTypeCatalog.get_max_durability(bd.block_type)
			durability = "%.0f%%" % ((bd.durability / max_d) * 100.0 if max_d > 0.0 else 0.0)
	elif has_target:
		category = "building"
		cell = target_remove_cell
		var grid := grid_system
		if grid != null and grid.has_method("get_block"):
			var b: BlockData = grid.get_block(target_remove_cell)
			if b != null:
				material = String(b.block_type)
				durability = "%.0f%%" % (clampf(b.durability, 0.0, 1.0) * 100.0)
	return {
		"category": category,
		"material": material,
		"cell": cell,
		"durability": durability,
		"mining": "N/A",
		"can_place": can_place_target,
	}

## Waits for terrain directly under player to finish generating, then safely resumes physics.
func await_terrain_and_resume() -> void:
	resume_physics()

func get_cement_count() -> int:
	return cement_count

func add_cement(amount: int) -> void:
	cement_count = clampi(cement_count + amount, 0, max_cement)
	cement_changed.emit(cement_count, max_cement)

func use_cement(amount: int = 1) -> bool:
	if unlimited_cement or game_mode == GameMode.CREATIVE:
		return true
	if cement_count >= amount:
		cement_count -= amount
		cement_changed.emit(cement_count, max_cement)
		return true
	return false

func _on_grabbed_block(_island: DebrisIsland, _cell: Vector3i, data: BlockData) -> void:
	var b_type: StringName = data.block_type if data != null else &""
	carried_block_changed.emit(true, b_type)

func _on_released_block() -> void:
	carried_block_changed.emit(false, &"")

func _on_recovered_block(_cell: Vector3i, _b_type: StringName) -> void:
	carried_block_changed.emit(false, &"")

func _get_inventory_manager() -> Node:
	if is_inside_tree() and has_node("/root/InventoryManager"):
		return get_node("/root/InventoryManager")
	return null

func _on_recovered_raw_material(block_type: StringName, amount: int) -> void:
	var current: int = raw_materials.get(block_type, 0)
	raw_materials[block_type] = current + amount
	carried_block_changed.emit(false, &"")
	raw_materials_changed.emit(raw_materials)
	var inv_mgr := _get_inventory_manager()
	if inv_mgr != null:
		inv_mgr.add_material(block_type, amount)

func get_selected_type() -> StringName:
	return available_types[selected_type_index]

func set_state(new_state: State) -> void:
	_ensure_nodes()
	var old_state := current_state
	current_state = new_state

	match current_state:
		State.BODY_CONTROL:
			if body_camera != null and is_inside_tree():
				body_camera.make_current()
			# Restore body orientation and look
			_pitch = 0.0
			if head != null:
				head.rotation.x = _pitch

		State.SOUL_PROJECTION:
			velocity = Vector3.ZERO
			# Safety: automatically release any carried debris block when soul detaches
			if debris_grabber != null and debris_grabber.is_grabbing:
				debris_grabber.release()
			if projection_camera != null and body_camera != null:
				if is_inside_tree():
					projection_camera.global_transform = body_camera.global_transform
					projection_camera.make_current()
				else:
					projection_camera.transform = body_camera.transform
				_proj_yaw = rotation.y
				if head != null:
					_proj_pitch = head.rotation.x

		State.DEBUG_FLIGHT:
			velocity = Vector3.ZERO
			if debris_grabber != null and debris_grabber.is_grabbing:
				debris_grabber.release()

	if old_state != current_state:
		state_changed.emit(current_state)

func toggle_soul_projection() -> void:
	if current_state == State.BODY_CONTROL:
		set_state(State.SOUL_PROJECTION)
	elif current_state == State.SOUL_PROJECTION:
		set_state(State.BODY_CONTROL)

func toggle_flight() -> void:
	if current_state != State.BODY_CONTROL:
		return
	is_flying = not is_flying
	velocity = Vector3.ZERO
	var hud := _get_build_hud()
	if hud != null and hud.has_method("set_player_mode"):
		if is_flying:
			hud.set_player_mode("Flying (Shift: Fast, F/Space 2x: Land)")
		else:
			hud.set_player_mode("Survival" if game_mode == GameMode.SURVIVAL else "Creative")

func get_active_camera() -> Camera3D:
	_ensure_nodes()
	if current_state == State.SOUL_PROJECTION:
		return projection_camera
	elif current_state == State.BODY_CONTROL:
		return body_camera
	else:
		if is_inside_tree() and get_viewport() != null:
			var cam: Camera3D = get_viewport().get_camera_3d()
			if cam != null:
				return cam
		return body_camera

func set_mouse_capture(captured: bool) -> void:
	_mouse_captured = captured
	if captured:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	else:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func toggle_mouse_capture() -> void:
	set_mouse_capture(not _mouse_captured)

## Returns true if a UI modal (like save/load blueprint) is currently active.
func _is_ui_modal_open() -> bool:
	if build_hud != null and build_hud.has_method("is_modal_open"):
		return build_hud.is_modal_open()
	return false

func _input(event: InputEvent) -> void:
	if _gameplay_input_suspended or not _is_spawned:
		# Allow ESC to free cursor during load; if already free, let GameWorld handle ESC to quit.
		if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
			if _mouse_captured:
				set_mouse_capture(false)
				get_viewport().set_input_as_handled()
		return

	# If a UI modal is active, ESC closes it and clicks do not recapture mouse
	if area_selection_step != AreaSelectionStep.NONE and event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		cancel_area_selection()
		get_viewport().set_input_as_handled()
		return

	if _is_ui_modal_open():
		if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
			if build_hud != null and build_hud.has_method("close_all_modals"):
				build_hud.close_all_modals()
				get_viewport().set_input_as_handled()
		return

	# ESC releases cursor immediately
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			if _mouse_captured:
				set_mouse_capture(false)
				get_viewport().set_input_as_handled()
				return

	# Click anywhere in the viewport while cursor is visible to recapture it
	if not _mouse_captured and event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT or event.button_index == MOUSE_BUTTON_RIGHT:
			if current_state != State.DEBUG_FLIGHT:
				set_mouse_capture(true)
				get_viewport().set_input_as_handled()
				return

## Consume all mouse motion and keyboard gameplay events (but NOT when debug camera is active or modal is open)
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F3:
		_debug_overlay_enabled = not _debug_overlay_enabled
		var hud := _get_build_hud()
		if hud != null and hud.has_method("set_debug_overlay_visible"):
			hud.set_debug_overlay_visible(_debug_overlay_enabled)
		get_viewport().set_input_as_handled()
		return

	if event is InputEventKey and event.pressed and not event.echo \
	and (event.keycode == KEY_HOME or event.physical_keycode == KEY_HOME):
		respawn_home()
		get_viewport().set_input_as_handled()
		return

	if current_state == State.DEBUG_FLIGHT or _is_ui_modal_open():
		return
	if _gameplay_input_suspended or not _is_spawned:
		return

	# Mouse look — requires captured cursor; no middle-mouse dragging in body modes
	if event is InputEventMouseMotion and _mouse_captured:
		_handle_mouse_look(event.relative)
		get_viewport().set_input_as_handled()
		return

	# Mouse clicks for building / recovery (LMB = instant BREAK, RMB = instant PLACE)
	if event is InputEventMouseButton and event.pressed:
		if _mouse_captured:
			if event.button_index == MOUSE_BUTTON_LEFT:
				_handle_minecraft_break_action()
				get_viewport().set_input_as_handled()
				return
			elif event.button_index == MOUSE_BUTTON_RIGHT:
				_handle_minecraft_place_action()
				get_viewport().set_input_as_handled()
				return
			elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
				_cycle_block_type(-1)
				return
			elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				_cycle_block_type(1)
				return

	# Keyboard hotkeys
	if event is InputEventKey and event.pressed and not event.echo:
		if event.is_action_pressed(&"jump") or event.keycode == KEY_SPACE:
			var now: float = Time.get_ticks_msec() / 1000.0
			if _last_space_press_time > 0.0 and (now - _last_space_press_time) <= DOUBLE_TAP_TIME:
				toggle_flight()
				_last_space_press_time = -1.0
				return
			else:
				_last_space_press_time = now

		if event.keycode == KEY_TAB or event.is_action_pressed(&"toggle_mouse_capture"):
			toggle_mouse_capture()
			return
		elif event.is_action_pressed(&"interact") or event.keycode == KEY_E:
			_handle_interact_action()
			return
		elif event.is_action_pressed(&"recover_block") or event.keycode == KEY_R:
			_handle_recover_action()
			return
		elif event.is_action_pressed(&"throw_debris") or event.keycode == KEY_F:
			if debris_grabber != null and debris_grabber.is_grabbing:
				_handle_throw_action()
			else:
				toggle_flight()
			return
		elif event.is_action_pressed(&"apply_cement") or event.keycode == KEY_G:
			_handle_cement_action()
			return
		elif event.is_action_pressed(&"save_blueprint") or event.keycode == KEY_K:
			_handle_save_blueprint_action()
			return
		elif event.is_action_pressed(&"load_blueprint") or event.keycode == KEY_L:
			_handle_load_blueprint_action()
			return
		elif event.is_action_pressed(&"soul_projection") or event.keycode == KEY_V or event.keycode == KEY_P:
			toggle_soul_projection()
		elif event.is_action_pressed(&"select_slot_1") or event.keycode == KEY_1:
			_select_type_by_index(0)
		elif event.is_action_pressed(&"select_slot_2") or event.keycode == KEY_2:
			_select_type_by_index(1)
		elif event.is_action_pressed(&"select_slot_3") or event.keycode == KEY_3:
			_select_type_by_index(2)
		elif event.is_action_pressed(&"select_slot_4") or event.keycode == KEY_4:
			_select_type_by_index(3)

func _get_blueprint_manager() -> Node:
	if is_inside_tree() and has_node("/root/BlueprintManager"):
		return get_node("/root/BlueprintManager")
	return null

func _get_voxel_world() -> Node:
	if is_inside_tree():
		if get_parent() != null and get_parent().has_node("VoxelWorld"):
			return get_parent().get_node("VoxelWorld")
		var root := get_tree().root
		if root != null:
			var found = root.find_child("VoxelWorld", true, false)
			if found != null:
				return found
	return null

func _get_build_hud() -> Node:
	if build_hud != null and is_instance_valid(build_hud):
		return build_hud
	if is_inside_tree():
		if get_parent() != null and get_parent().has_node("BuildHUD"):
			build_hud = get_parent().get_node("BuildHUD")
			return build_hud
		var root := get_tree().root
		if root != null:
			var found = root.find_child("BuildHUD", true, false)
			if found != null:
				build_hud = found
				return build_hud
	return null

func _get_voxel_tool() -> VoxelTool:
	var vox_world := _get_voxel_world()
	if vox_world == null:
		return null
	var terrain: Node = vox_world.get_node_or_null("VoxelTerrain")
	if terrain == null or not terrain.has_method("get_voxel_tool"):
		return null
	var vt: VoxelTool = terrain.get_voxel_tool()
	if vt != null:
		vt.channel = VoxelBuffer.CHANNEL_TYPE
	return vt

func _perform_voxel_raycast() -> Variant:
	var vt := _get_voxel_tool()
	if vt == null:
		return null
	var cam := get_active_camera()
	if cam == null:
		return null
	var ray_dir := -cam.global_transform.basis.z
	var hit = vt.raycast(cam.global_position, ray_dir, max_ray_distance)
	return hit

func _get_selected_block_id() -> int:
	var t := get_selected_type()
	match t:
		&"grass": return 1
		&"dirt":  return 2
		&"stone": return 3
		&"coal":  return 4
		&"iron":  return 5
		&"gold":  return 6
		_:        return 3

func _spawn_mined_terrain_debris(pos: Vector3i, block_type: StringName) -> void:
	if orchestrator == null and get_parent() != null and get_parent().has_node("CollapseOrchestrator"):
		orchestrator = get_parent().get_node("CollapseOrchestrator") as CollapseOrchestrator
	if orchestrator == null:
		return
	var b_data := BlockData.new(block_type)
	var dict: Dictionary = {pos: b_data}
	orchestrator.spawn_debris_for_cells([pos], dict)

func _handle_minecraft_break_action() -> void:
	if area_selection_step != AreaSelectionStep.NONE:
		if area_selection_step == AreaSelectionStep.CORNER_1:
			_confirm_area_corner_1()
		elif area_selection_step == AreaSelectionStep.CORNER_2:
			_confirm_area_corner_2()
		return

	if debris_grabber != null and debris_grabber.is_grabbing:
		debris_grabber.try_place_to_grid()
		return

	# 1. Check if targeting a physics block or debris
	var grid := grid_system
	if grid == null and has_node("/root/GridSystem"):
		grid = get_node("/root/GridSystem")

	if has_target:
		if target_is_debris:
			if is_instance_valid(target_debris_island) and target_debris_cell != null:
				target_debris_island.remove_block(target_debris_cell)
				return
		elif grid != null and grid.has_block(target_remove_cell):
			_handle_remove_action()
			return

	# 2. If looking at voxel terrain, break voxel AND spawn physics debris item
	var vt := _get_voxel_tool()
	var vox_world := _get_voxel_world()
	if vt != null and vox_world != null:
		var hit = _perform_voxel_raycast()
		if hit != null:
			var cell_pos: Vector3i = hit.position
			var mined_type: StringName = vox_world.get_voxel_at(cell_pos)
			if mined_type.is_empty():
				mined_type = &"stone"
			vt.set_voxel(cell_pos, 0)
			_spawn_mined_terrain_debris(cell_pos, mined_type)
			var inv_mgr := _get_inventory_manager()
			if inv_mgr != null:
				inv_mgr.add_material(mined_type, 1)
			return

	if target_is_terrain and vox_world != null:
		var mined_type: StringName = vox_world.get_voxel_at(target_terrain_cell)
		if mined_type.is_empty():
			mined_type = &"stone"
		vox_world.mine_voxel(target_terrain_cell)
		_spawn_mined_terrain_debris(target_terrain_cell, mined_type)
		return

func _handle_minecraft_place_action() -> void:
	if area_selection_step != AreaSelectionStep.NONE:
		cancel_area_selection()
		return

	if debris_grabber != null and debris_grabber.is_grabbing:
		debris_grabber.release()
		return

	# Place physics/structural block via grid_system
	_handle_place_action()

func _handle_save_blueprint_action() -> void:
	save_blueprint_requested.emit()
	if area_selection_step == AreaSelectionStep.NONE:
		area_selection_step = AreaSelectionStep.CORNER_1
		_update_area_selection_prompt()
	elif area_selection_step == AreaSelectionStep.CORNER_1:
		_confirm_area_corner_1()
	elif area_selection_step == AreaSelectionStep.CORNER_2:
		_confirm_area_corner_2()

func _confirm_area_corner_1() -> void:
	var grid := grid_system
	var target_cell := target_place_cell
	if has_target and grid != null and grid.has_block(target_remove_cell):
		target_cell = target_remove_cell
	area_corner_1 = target_cell
	area_selection_step = AreaSelectionStep.CORNER_2
	_update_area_selection_prompt()

func _confirm_area_corner_2() -> void:
	var grid := grid_system
	var target_cell := target_place_cell
	if has_target and grid != null and grid.has_block(target_remove_cell):
		target_cell = target_remove_cell
	area_corner_2 = target_cell

	var min_c := Vector3i(mini(area_corner_1.x, area_corner_2.x), mini(area_corner_1.y, area_corner_2.y), mini(area_corner_1.z, area_corner_2.z))
	var max_c := Vector3i(maxi(area_corner_1.x, area_corner_2.x), maxi(area_corner_1.y, area_corner_2.y), maxi(area_corner_1.z, area_corner_2.z))

	area_selection_step = AreaSelectionStep.NONE
	if preview_ghost != null:
		preview_ghost.hide_preview()

	var hud := _get_build_hud()
	if hud != null and hud.has_method("open_save_blueprint_dialog_bounded"):
		hud.open_save_blueprint_dialog_bounded(min_c, max_c)

func cancel_area_selection() -> void:
	area_selection_step = AreaSelectionStep.NONE
	if preview_ghost != null:
		preview_ghost.hide_preview()

func _update_area_selection_prompt() -> void:
	var hud := _get_build_hud()
	if hud != null and hud.target_info_label != null:
		if area_selection_step == AreaSelectionStep.CORNER_1:
			hud.target_info_label.text = "[AREA SELECTION] Aim crosshair at Corner 1. Press LMB or K to mark. Esc: Cancel."
			hud.target_info_label.visible = true
		elif area_selection_step == AreaSelectionStep.CORNER_2:
			var grid := grid_system
			var curr_target := target_remove_cell if (grid != null and grid.has_block(target_remove_cell)) else target_place_cell
			var dim_x := absi(curr_target.x - area_corner_1.x) + 1
			var dim_y := absi(curr_target.y - area_corner_1.y) + 1
			var dim_z := absi(curr_target.z - area_corner_1.z) + 1
			var vol := dim_x * dim_y * dim_z
			hud.target_info_label.text = "[AREA SELECTION] Corner 1: (%d,%d,%d) | Size: %dx%dx%d (%d cells) | Press LMB/K to confirm. Esc: Cancel." % [
				area_corner_1.x, area_corner_1.y, area_corner_1.z, dim_x, dim_y, dim_z, vol
			]
			hud.target_info_label.visible = true

func _handle_load_blueprint_action() -> void:
	var anchor: Vector3i = target_place_cell if has_target else Vector3i.ZERO
	load_blueprint_requested.emit(anchor)
	var hud := _get_build_hud()
	if hud != null and hud.has_method("open_load_blueprint_dialog"):
		hud.open_load_blueprint_dialog(anchor)

func _handle_mouse_look(relative: Vector2) -> void:
	match current_state:
		State.BODY_CONTROL:
			_yaw -= relative.x * mouse_sensitivity
			_pitch = clampf(_pitch - relative.y * mouse_sensitivity, -1.48, 1.48)
			rotation.y = _yaw
			if head != null:
				head.rotation.x = _pitch

		State.SOUL_PROJECTION:
			if projection_camera != null:
				_proj_yaw -= relative.x * projection_mouse_sensitivity
				_proj_pitch = clampf(_proj_pitch - relative.y * projection_mouse_sensitivity, -1.48, 1.48)
				projection_camera.transform.basis = Basis(Vector3.UP, _proj_yaw) * Basis(Vector3.RIGHT, _proj_pitch)

func _cycle_block_type(delta: int) -> void:
	selected_type_index = (selected_type_index + delta + available_types.size()) % available_types.size()
	block_type_changed.emit(get_selected_type())

func _select_type_by_index(idx: int) -> void:
	if idx >= 0 and idx < available_types.size():
		selected_type_index = idx
		block_type_changed.emit(get_selected_type())

func _physics_process(delta: float) -> void:
	if not _is_spawned or is_physics_suspended or _gameplay_input_suspended:
		velocity = Vector3.ZERO
		# Keep camera/body locked at the hold position while terrain streams in.
		return

	if _is_ui_modal_open():
		velocity.x = 0.0
		velocity.z = 0.0
		_update_raycast()
		return

	match current_state:
		State.BODY_CONTROL:
			_process_body_movement(delta)
		State.SOUL_PROJECTION:
			_process_projection_flight(delta)
		State.DEBUG_FLIGHT:
			pass

	_update_raycast()

	if (Input.is_action_pressed(&"apply_cement") or Input.is_key_pressed(KEY_G)) and current_state != State.DEBUG_FLIGHT:
		if debris_grabber == null or not debris_grabber.is_grabbing:
			_handle_cement_action()

func _reset_mining_state() -> void:
	mining_progress = 0.0
	target_voxel_pos = _INVALID_VOXEL
	_last_mined_cell = _INVALID_VOXEL
	_crack_stage = -1
	if not target_is_terrain:
		_hide_terrain_target_visuals()
	elif target_terrain_cell != _INVALID_VOXEL:
		_update_terrain_target_visuals(target_terrain_cell, 0.0)

func _raycast_terrain_voxel(vox_world: Node) -> Variant:
	if vox_world == null:
		return null
	var terrain: Node = vox_world.get_node_or_null("VoxelTerrain")
	if terrain == null or not terrain.has_method("get_voxel_tool"):
		return null
	var vt: VoxelTool = terrain.get_voxel_tool()
	if vt == null:
		return null
	# Blocky terrain: TYPE channel + model collision drives VoxelTool raycasts.
	vt.channel = VoxelBuffer.CHANNEL_TYPE
	var cam := get_active_camera()
	if cam == null:
		return null
	var hit = vt.raycast(cam.global_position, -cam.global_transform.basis.z, mini(max_ray_distance, 8.0))
	if hit == null:
		return null
	return hit.position as Vector3i

func _complete_mining_action() -> void:
	var vox_world := _get_voxel_world()
	var mine_target := target_voxel_pos if target_voxel_pos != _INVALID_VOXEL else target_terrain_cell
	if vox_world != null and vox_world.has_method("mine_voxel"):
		# Authoritative path: returns original type, clears TYPE+SDF+INDICES, saves, emits once.
		var mined_type: StringName = vox_world.mine_voxel(mine_target)
		if not mined_type.is_empty():
			var inv_mgr := _get_inventory_manager()
			if inv_mgr != null:
				inv_mgr.add_material(mined_type, 1)
			target_face_status = "✓ Mined 1 %s!" % BlockTypeCatalog.get_display_name(mined_type)
			target_face_changed.emit(has_target, mine_target, target_face_dir, target_face_status)
			if build_hud != null and build_hud.has_method("show_mine_feedback"):
				build_hud.show_mine_feedback(mined_type, 1)
	_reset_mining_state()
	_hide_terrain_target_visuals()

var _crack_stage_mats: Array[StandardMaterial3D] = []

func _ensure_terrain_target_visuals() -> void:
	if _terrain_outline != null:
		return
	# Dual-tone outline (light halo + dark core) readable on all terrain materials.
	var outline_light := StandardMaterial3D.new()
	outline_light.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	outline_light.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	outline_light.albedo_color = Color(1.0, 1.0, 1.0, 0.55)
	outline_light.cull_mode = BaseMaterial3D.CULL_DISABLED
	outline_light.no_depth_test = true
	outline_light.render_priority = 9

	_outline_mat = StandardMaterial3D.new()
	_outline_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_outline_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_outline_mat.albedo_color = Color(0.05, 0.05, 0.05, 0.98)
	_outline_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_outline_mat.no_depth_test = true
	_outline_mat.render_priority = 10

	var outline_halo := MeshInstance3D.new()
	outline_halo.name = "TerrainTargetOutlineHalo"
	outline_halo.top_level = true
	outline_halo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	outline_halo.mesh = _build_outline_mesh(0.028)
	outline_halo.material_override = outline_light
	outline_halo.visible = false
	add_child(outline_halo)

	_terrain_outline = MeshInstance3D.new()
	_terrain_outline.name = "TerrainTargetOutline"
	_terrain_outline.top_level = true
	_terrain_outline.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_terrain_outline.mesh = _build_outline_mesh(0.014)
	_terrain_outline.material_override = _outline_mat
	_terrain_outline.set_meta("halo", outline_halo)
	add_child(_terrain_outline)
	_terrain_outline.visible = false

	_crack_stage_mats.clear()
	for stage in range(4):
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mat.no_depth_test = true
		mat.render_priority = 11
		mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
		mat.albedo_texture = _make_crack_texture(stage)
		mat.albedo_color = Color(1, 1, 1, 0.85)
		_crack_stage_mats.append(mat)
	_crack_mat = _crack_stage_mats[0]

	# Surface-aligned quad (not a cube) so cracks follow the hit normal/tangent.
	_terrain_crack = MeshInstance3D.new()
	_terrain_crack.name = "TerrainMineCracks"
	_terrain_crack.top_level = true
	_terrain_crack.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var crack_quad := QuadMesh.new()
	crack_quad.size = Vector2(1.05, 1.05)
	_terrain_crack.mesh = crack_quad
	_terrain_crack.material_override = _crack_mat
	add_child(_terrain_crack)
	_terrain_crack.visible = false

func _make_crack_texture(stage: int) -> ImageTexture:
	## Procedural Minecraft-like crack stages (built once, reused).
	var img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var ink := Color(0.02, 0.02, 0.02, 0.92)
	var patterns: Array = [
		[[3, 2, 5, 4], [8, 3, 10, 7], [4, 9, 7, 12]],
		[[2, 1, 6, 5], [7, 2, 12, 6], [3, 8, 8, 14], [10, 9, 14, 13], [1, 11, 4, 15]],
		[[1, 1, 7, 5], [6, 2, 13, 7], [2, 7, 9, 14], [9, 8, 15, 13], [0, 10, 5, 15], [11, 0, 15, 4], [4, 4, 6, 10]],
		[[0, 0, 8, 6], [5, 1, 14, 8], [1, 6, 10, 15], [8, 7, 15, 14], [0, 9, 6, 15], [10, 0, 15, 5], [3, 3, 7, 11], [12, 9, 15, 15], [2, 12, 5, 15]],
	]
	var segs: Array = patterns[clampi(stage, 0, 3)]
	for seg in segs:
		_draw_crack_line(img, int(seg[0]), int(seg[1]), int(seg[2]), int(seg[3]), ink)
	return ImageTexture.create_from_image(img)

func _draw_crack_line(img: Image, x0: int, y0: int, x1: int, y1: int, col: Color) -> void:
	var dx: int = absi(x1 - x0)
	var dy: int = -absi(y1 - y0)
	var sx: int = 1 if x0 < x1 else -1
	var sy: int = 1 if y0 < y1 else -1
	var err: int = dx + dy
	var x: int = x0
	var y: int = y0
	while true:
		if x >= 0 and y >= 0 and x < 16 and y < 16:
			img.set_pixel(x, y, col)
		if x == x1 and y == y1:
			break
		var e2: int = err * 2
		if e2 >= dy:
			err += dy
			x += sx
		if e2 <= dx:
			err += dx
			y += sy

func _build_outline_mesh(thickness: float = 0.018) -> ArrayMesh:
	# Thin wireframe cube edges — reused every frame, never rebuilt.
	var s := 0.505
	var corners: Array[Vector3] = [
		Vector3(-s, -s, -s), Vector3(s, -s, -s), Vector3(s, -s, s), Vector3(-s, -s, s),
		Vector3(-s, s, -s), Vector3(s, s, -s), Vector3(s, s, s), Vector3(-s, s, s),
	]
	var edges: Array[Vector2i] = [
		Vector2i(0, 1), Vector2i(1, 2), Vector2i(2, 3), Vector2i(3, 0),
		Vector2i(4, 5), Vector2i(5, 6), Vector2i(6, 7), Vector2i(7, 4),
		Vector2i(0, 4), Vector2i(1, 5), Vector2i(2, 6), Vector2i(3, 7),
	]
	var verts := PackedVector3Array()
	for e in edges:
		var a: Vector3 = corners[e.x]
		var b: Vector3 = corners[e.y]
		var dir := (b - a).normalized()
		var abs_dir := Vector3(absf(dir.x), absf(dir.y), absf(dir.z))
		var side := Vector3.UP if abs_dir.y < 0.9 else Vector3.RIGHT
		var n1 := dir.cross(side).normalized() * thickness
		var n2 := dir.cross(n1).normalized() * thickness
		# Two-quad beam along the edge.
		var p0 := a + n1 + n2
		var p1 := a + n1 - n2
		var p2 := a - n1 - n2
		var p3 := a - n1 + n2
		var q0 := b + n1 + n2
		var q1 := b + n1 - n2
		var q2 := b - n1 - n2
		var q3 := b - n1 + n2
		for tri in [
			[p0, p1, q1], [p0, q1, q0], [p1, p2, q2], [p1, q2, q1],
			[p2, p3, q3], [p2, q3, q2], [p3, p0, q0], [p3, q0, q3],
		]:
			verts.append(tri[0])
			verts.append(tri[1])
			verts.append(tri[2])
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

func _basis_from_normal(normal: Vector3) -> Basis:
	var n := normal.normalized()
	if n.length_squared() < 0.0001:
		n = Vector3.UP
	var tangent := Vector3.UP.cross(n)
	if tangent.length_squared() < 0.001:
		tangent = Vector3.RIGHT.cross(n)
	tangent = tangent.normalized()
	var bitangent := n.cross(tangent).normalized()
	# QuadMesh faces +Z locally; map local +Z to world normal.
	return Basis(tangent, bitangent, n)

func _update_terrain_target_visuals(cell: Vector3i, progress01: float) -> void:
	_ensure_terrain_target_visuals()
	var center := Vector3(float(cell.x) + 0.5, float(cell.y) + 0.5, float(cell.z) + 0.5)
	var n := _target_hit_normal.normalized() if _target_hit_normal.length_squared() > 0.0001 else Vector3.UP
	# Subtle voxel outline stays axis-aligned (readable target); independent of player yaw.
	_terrain_outline.global_transform = Transform3D(Basis.IDENTITY, center)
	_terrain_outline.visible = true
	if _terrain_outline.has_meta("halo"):
		var halo: MeshInstance3D = _terrain_outline.get_meta("halo")
		halo.global_transform = Transform3D(Basis.IDENTITY, center)
		halo.visible = true

	var stage: int = clampi(int(floor(progress01 * 4.0)), 0, 3) if progress01 > 0.02 else -1
	if stage < 0:
		_terrain_crack.visible = false
		_crack_stage = -1
		return
	# Crack decal sits on the hit surface, oriented to normal/tangent (not player transform).
	var hitch: Vector3 = _target_hit_point if _target_hit_point != Vector3.ZERO else (center + n * 0.51)
	var crack_pos := hitch + n * 0.02
	_terrain_crack.global_transform = Transform3D(_basis_from_normal(n), crack_pos)
	_terrain_crack.visible = true
	if stage != _crack_stage:
		_crack_stage = stage
		if stage >= 0 and stage < _crack_stage_mats.size():
			_crack_mat = _crack_stage_mats[stage]
			_terrain_crack.material_override = _crack_mat

func _hide_terrain_target_visuals() -> void:
	if _terrain_outline != null:
		_terrain_outline.visible = false
		if _terrain_outline.has_meta("halo"):
			var halo: MeshInstance3D = _terrain_outline.get_meta("halo")
			halo.visible = false
	if _terrain_crack != null:
		_terrain_crack.visible = false
	_crack_stage = -1

func _process_body_movement(delta: float) -> void:
	if not _is_spawned or is_physics_suspended:
		velocity = Vector3.ZERO
		return

	if is_flying:
		_process_flying_movement(delta)
		return

	# Gravity simulation
	if not is_on_floor():
		velocity.y -= gravity * delta
	else:
		velocity.y = maxf(velocity.y, 0.0)
		# Jump
		if Input.is_action_just_pressed(&"jump") or Input.is_key_pressed(KEY_SPACE):
			velocity.y = jump_velocity

	# Planar input vector
	var input_vec := Vector2.ZERO
	if Input.is_action_pressed(&"move_forward") or Input.is_key_pressed(KEY_W):
		input_vec.y -= 1.0
	if Input.is_action_pressed(&"move_backward") or Input.is_key_pressed(KEY_S):
		input_vec.y += 1.0
	if Input.is_action_pressed(&"move_left") or Input.is_key_pressed(KEY_A):
		input_vec.x -= 1.0
	if Input.is_action_pressed(&"move_right") or Input.is_key_pressed(KEY_D):
		input_vec.x += 1.0

	var direction := Vector3.ZERO
	if input_vec.length_squared() > 0.001:
		input_vec = input_vec.normalized()
		direction = (transform.basis * Vector3(input_vec.x, 0, input_vec.y)).normalized()

	var speed := walk_speed
	if Input.is_action_pressed(&"sprint") or Input.is_key_pressed(KEY_SHIFT):
		speed *= sprint_speed_multiplier

	velocity.x = direction.x * speed
	velocity.z = direction.z * speed

	move_and_slide()

	# Push dynamic RigidBody3D (debris) and unbonded grid blocks upon physical contact
	for i in get_slide_collision_count():
		var col := get_slide_collision(i)
		var collider := col.get_collider()
		if collider is RigidBody3D:
			var push_dir := -col.get_normal()
			push_dir.y = 0.0
			if push_dir.length_squared() > 0.001:
				push_dir = push_dir.normalized()
				collider.apply_central_impulse(push_dir * push_force * delta)
		elif collider is StaticBody3D:
			var shape_idx: int = col.get_collider_shape_index()
			var owner_id: int = collider.shape_find_owner(shape_idx)
			if owner_id >= 0:
				var owner_shape = collider.shape_owner_get_owner(owner_id)
				if owner_shape != null and owner_shape.has_meta("grid_cell"):
					var hit_cell: Vector3i = owner_shape.get_meta("grid_cell")
					var is_anchor: bool = (stability_system != null and stability_system.is_anchor_cell(hit_cell)) or (hit_cell.y <= 0)
					var joint_sys: Node = null
					if has_node("/root/JointSystem"):
						joint_sys = get_node("/root/JointSystem")
					if not is_anchor and joint_sys != null and not joint_sys.is_block_bonded(hit_cell):
						if orchestrator != null and orchestrator.has_method("push_unbonded_block"):
							var push_dir := -col.get_normal()
							push_dir.y = 0.0
							if push_dir.length_squared() > 0.001:
								push_dir = push_dir.normalized()
								orchestrator.call_deferred("push_unbonded_block", hit_cell, push_dir * 3.5)

	# Step-up mechanic for voxel terrain: climb ledges up to step_up_height
	if is_on_wall() and direction.length_squared() > 0.001:
		_try_step_up(direction, delta)

func _process_flying_movement(delta: float) -> void:
	var cam := get_active_camera()
	var basis_cam: Basis = cam.global_transform.basis if cam != null else transform.basis

	var fly_vec := Vector3.ZERO
	if Input.is_action_pressed(&"move_forward") or Input.is_key_pressed(KEY_W):
		fly_vec -= basis_cam.z
	if Input.is_action_pressed(&"move_backward") or Input.is_key_pressed(KEY_S):
		fly_vec += basis_cam.z
	if Input.is_action_pressed(&"move_left") or Input.is_key_pressed(KEY_A):
		fly_vec -= basis_cam.x
	if Input.is_action_pressed(&"move_right") or Input.is_key_pressed(KEY_D):
		fly_vec += basis_cam.x

	# Vertical: Space to ascend, Ctrl or Q to descend
	if Input.is_action_pressed(&"fly_up") or Input.is_key_pressed(KEY_SPACE):
		fly_vec += Vector3.UP
	if Input.is_action_pressed(&"fly_down") or Input.is_key_pressed(KEY_CTRL) or Input.is_key_pressed(KEY_Q):
		fly_vec -= Vector3.UP

	var speed := fly_speed
	var is_sprinting: bool = Input.is_action_pressed(&"sprint") or Input.is_key_pressed(KEY_SHIFT)
	if is_sprinting:
		speed *= fly_fast_multiplier

	if fly_vec.length_squared() > 0.001:
		velocity = fly_vec.normalized() * speed
	else:
		velocity = velocity.move_toward(Vector3.ZERO, speed * 8.0 * delta)

	move_and_slide()

func _try_step_up(move_dir: Vector3, _delta: float) -> void:
	if not is_inside_tree():
		return
	var space := get_world_3d().direct_space_state
	if space == null:
		return

	var shape_rid := collision_shape.shape.get_rid() if collision_shape != null else RID()
	if not shape_rid.is_valid():
		return

	var test_up := global_position + Vector3.UP * step_up_height
	var test_fwd := test_up + move_dir * (capsule_radius + 0.05)
	var params := PhysicsRayQueryParameters3D.create(test_up, test_fwd)
	params.exclude = [get_rid()]
	var hit := space.intersect_ray(params)
	if not hit.is_empty():
		return  # Wall too high even at step_up height

	# Floor check below the stepped position
	var check_from := test_fwd
	var check_to := test_fwd + Vector3.DOWN * (step_up_height + 0.1)
	var floor_params := PhysicsRayQueryParameters3D.create(check_from, check_to)
	floor_params.exclude = [get_rid()]
	var floor_hit := space.intersect_ray(floor_params)
	if floor_hit.is_empty():
		return  # No floor to step onto

	var step_y: float = floor_hit.position.y - global_position.y
	if step_y > 0.01 and step_y <= step_up_height:
		global_position.y += step_y + 0.02
		velocity.y = 0.0

func _process_projection_flight(delta: float) -> void:
	if projection_camera == null:
		return

	# Body remains completely stationary in Soul Projection
	velocity = Vector3.ZERO

	var fly_vec := Vector3.ZERO
	var basis_cam := projection_camera.global_transform.basis

	if Input.is_action_pressed(&"move_forward") or Input.is_key_pressed(KEY_W):
		fly_vec -= basis_cam.z
	if Input.is_action_pressed(&"move_backward") or Input.is_key_pressed(KEY_S):
		fly_vec += basis_cam.z
	if Input.is_action_pressed(&"move_left") or Input.is_key_pressed(KEY_A):
		fly_vec -= basis_cam.x
	if Input.is_action_pressed(&"move_right") or Input.is_key_pressed(KEY_D):
		fly_vec += basis_cam.x

	# Space + Q only for vertical flight
	if Input.is_action_pressed(&"fly_up") or Input.is_key_pressed(KEY_SPACE):
		fly_vec += Vector3.UP
	if Input.is_action_pressed(&"fly_down") or Input.is_key_pressed(KEY_CTRL) or Input.is_key_pressed(KEY_Q):
		fly_vec -= Vector3.UP

	if fly_vec.length_squared() > 0.001:
		var speed := projection_speed
		if Input.is_action_pressed(&"sprint") or Input.is_key_pressed(KEY_SHIFT):
			speed *= projection_fast_multiplier
		projection_camera.global_position += fly_vec.normalized() * speed * delta

## Tests whether a grid cell coordinate overlaps the player's physical capsule in world space.
func is_cell_overlapping_player(cell: Vector3i, cell_size: float = 1.0) -> bool:
	var cell_min := Vector3(float(cell.x) * cell_size, float(cell.y) * cell_size, float(cell.z) * cell_size)
	var cell_size_vec := Vector3.ONE * cell_size
	var cell_aabb := AABB(cell_min, cell_size_vec)

	var feet_pos: Vector3 = global_position if is_inside_tree() else position
	var half_r: float = capsule_radius
	var p_min := Vector3(feet_pos.x - half_r, feet_pos.y, feet_pos.z - half_r)
	var p_size := Vector3(half_r * 2.0, capsule_height, half_r * 2.0)
	var player_aabb := AABB(p_min, p_size)

	return cell_aabb.intersects(player_aabb)

func _update_raycast() -> void:
	var grid := grid_system
	if grid == null and has_node("/root/GridSystem"):
		grid = get_node("/root/GridSystem")
	if grid == null:
		return

	var cam := get_active_camera()
	if cam == null or not is_instance_valid(cam):
		return

	var space_state := get_world_3d().direct_space_state
	var ray_origin: Vector3
	var ray_dir: Vector3

	if _mouse_captured:
		ray_origin = cam.global_position
		ray_dir = -cam.global_transform.basis.z
	else:
		var mouse_pos := get_viewport().get_mouse_position()
		ray_origin = cam.project_ray_origin(mouse_pos)
		ray_dir = cam.project_ray_normal(mouse_pos)

	var ray_end := ray_origin + ray_dir * max_ray_distance
	var query := PhysicsRayQueryParameters3D.create(ray_origin, ray_end)
	var excludes: Array[RID] = [get_rid()]
	# Exclude currently carried debris block so it doesn't block player's view/placement raycast
	if debris_grabber != null and debris_grabber.is_grabbing and is_instance_valid(debris_grabber._grabbed_island):
		excludes.append(debris_grabber._grabbed_island.get_rid())
	query.exclude = excludes

	var result := space_state.intersect_ray(query)

	if result.is_empty():
		has_target = false
		target_is_debris = false
		target_debris_island = null
		target_debris_cell = null
		target_is_terrain = false
		target_face_dir = Vector3i.ZERO
		target_face_status = ""
		target_face_changed.emit(false, Vector3i.ZERO, Vector3i.ZERO, "")
		_hide_terrain_target_visuals()
		if build_hud != null and build_hud.has_method("set_mining_progress"):
			build_hud.set_mining_progress(false, "", 0)
		if preview_ghost != null and (debris_grabber == null or not debris_grabber.is_grabbing):
			preview_ghost.hide_preview()
		return

	has_target = true
	var hit_pos: Vector3 = result.position
	var hit_normal: Vector3 = result.normal
	var hit_collider: Object = result.collider
	var shape_idx: int = result.shape
	_target_hit_point = hit_pos
	_target_hit_normal = hit_normal

	if hit_collider is StaticBody3D:
		target_is_debris = false
		target_debris_island = null
		target_debris_cell = null

		var owner_id: int = hit_collider.shape_find_owner(shape_idx)
		var col_shape: CollisionShape3D = null
		if owner_id >= 0:
			col_shape = hit_collider.shape_owner_get_owner(owner_id) as CollisionShape3D

		var vox_world := _get_voxel_world()

		if col_shape != null and col_shape.has_meta("grid_cell"):
			target_is_terrain = false
			var hit_cell: Vector3i = col_shape.get_meta("grid_cell")
			target_remove_cell = hit_cell
			target_face_dir = _normal_to_cell_offset(hit_normal)
			target_place_cell = hit_cell + target_face_dir
		else:
			target_place_cell = grid.world_to_cell(hit_pos + hit_normal * (grid.cell_size * 0.5))
			# Derive hit voxel cell by stepping slightly inside the solid volume
			var interior_point := hit_pos - hit_normal * 0.05
			target_remove_cell = Vector3i(
				int(floor(interior_point.x)),
				int(floor(interior_point.y)),
				int(floor(interior_point.z))
			)
			target_face_dir = _normal_to_cell_offset(hit_normal)

			if vox_world != null and vox_world.has_method("is_solid_block") and vox_world.is_solid_block(target_remove_cell):
				target_is_terrain = true
				target_terrain_cell = target_remove_cell
				target_terrain_type = vox_world.get_voxel_at(target_remove_cell)
			else:
				target_is_terrain = false

		var grid_valid: bool = grid.can_place_block(target_place_cell)
		var blocked_by_debris: bool = false
		if orchestrator != null:
			blocked_by_debris = orchestrator.is_cell_blocked_by_debris(target_place_cell, grid.cell_size)
		var overlaps_player: bool = is_cell_overlapping_player(target_place_cell, grid.cell_size)
		var blocked_by_terrain: bool = false
		if vox_world != null and vox_world.has_method("is_solid_block"):
			blocked_by_terrain = vox_world.is_solid_block(target_place_cell)

		can_place_target = grid_valid and not blocked_by_terrain and not blocked_by_debris and not overlaps_player

		if target_is_terrain:
			var mat_disp := BlockTypeCatalog.get_display_name(target_terrain_type)
			target_face_status = "Natural %s (LMB: Break, RMB: Place)" % mat_disp
		else:
			var joint_sys: Node = null
			if has_node("/root/JointSystem"):
				joint_sys = get_node("/root/JointSystem")

			if joint_sys != null and grid.has_block(target_remove_cell):
				if joint_sys.is_face_coated(target_remove_cell, target_face_dir):
					target_face_status = "Surface Mortared (Reinforced)"
				else:
					target_face_status = "Uncoated Surface (Hold G to Paint Mortar)"
			else:
				target_face_status = ""

			var block_data: BlockData = grid.get_block(target_remove_cell)
			if block_data != null:
				var pct: int = int(clampf(block_data.durability, 0.0, 1.0) * 100.0)
				var dur_label: String
				if pct >= 80:
					dur_label = "%d%% Integrity" % pct
				elif pct >= 40:
					dur_label = "%d%% Integrity (Damaged)" % pct
				else:
					dur_label = "%d%% Integrity (CRITICAL)" % pct
				if target_face_status.is_empty():
					target_face_status = dur_label
				else:
					target_face_status = target_face_status + "  |  " + dur_label

		target_face_changed.emit(true, target_remove_cell, target_face_dir, target_face_status)

	elif hit_collider is DebrisIsland:
		target_is_debris = true
		target_debris_island = hit_collider
		target_debris_cell = hit_collider.get_cell_from_shape_hit(shape_idx, hit_pos)

		if hit_collider.is_moving():
			can_place_target = false
			target_place_cell = Vector3i.ZERO
		else:
			target_place_cell = grid.world_to_cell(hit_pos + hit_normal * (grid.cell_size * 0.5))
			var grid_valid: bool = grid.can_place_block(target_place_cell)
			var held_island: DebrisIsland = debris_grabber.get_grabbed_island() if (debris_grabber != null and debris_grabber.is_grabbing) else null
			var blocked: bool = false
			if orchestrator != null:
				blocked = orchestrator.is_cell_blocked_by_debris(target_place_cell, grid.cell_size, held_island)
			var overlaps_player: bool = is_cell_overlapping_player(target_place_cell, grid.cell_size)

			can_place_target = grid_valid and not blocked and not overlaps_player

		# Display material and integrity percentage for the individual targeted debris block
		if target_debris_cell != null and hit_collider.constituent_blocks.has(target_debris_cell):
			var block_data: BlockData = hit_collider.constituent_blocks[target_debris_cell]
			var mat_name := BlockTypeCatalog.get_display_name(block_data.block_type)
			var max_dur: float = BlockTypeCatalog.get_max_durability(block_data.block_type)
			var ratio: float = block_data.durability / max_dur if max_dur > 0.0 else 0.0
			var pct: int = int(clampf(ratio, 0.0, 1.0) * 100.0)
			var dur_label: String
			if pct >= 80:
				dur_label = "%d%% Integrity" % pct
			elif pct >= 40:
				dur_label = "%d%% Integrity (Damaged)" % pct
			else:
				dur_label = "%d%% Integrity (CRITICAL)" % pct

			target_face_status = "Debris (%s)  |  %s" % [mat_name, dur_label]
			target_face_changed.emit(true, Vector3i.ZERO, Vector3i.ZERO, target_face_status)
		else:
			target_face_status = ""
			target_face_changed.emit(false, Vector3i.ZERO, Vector3i.ZERO, "")

	else:
		# Non-StaticBody hit (e.g. engine terrain collider) — classify natural terrain.
		target_is_debris = false
		target_debris_island = null
		target_debris_cell = null
		target_place_cell = grid.world_to_cell(hit_pos + hit_normal * (grid.cell_size * 0.5))
		var interior_pt := hit_pos - hit_normal * 0.05
		target_remove_cell = Vector3i(
			int(floor(interior_pt.x)),
			int(floor(interior_pt.y)),
			int(floor(interior_pt.z))
		)
		target_face_dir = _normal_to_cell_offset(hit_normal)
		var vox_world2 := _get_voxel_world()
		if vox_world2 != null and vox_world2.has_method("is_solid_block") \
		and vox_world2.is_solid_block(target_remove_cell):
			target_is_terrain = true
			target_terrain_cell = target_remove_cell
			target_terrain_type = vox_world2.get_voxel_at(target_remove_cell)
			can_place_target = false
			var mat_disp2 := BlockTypeCatalog.get_display_name(target_terrain_type)
			target_face_status = "Natural %s (LMB: Break, RMB: Place)" % mat_disp2
			_update_terrain_target_visuals(target_terrain_cell, 0.0)
			target_face_changed.emit(true, target_remove_cell, target_face_dir, target_face_status)
		else:
			target_is_terrain = false
			var grid_valid: bool = grid.can_place_block(target_place_cell)
			var blocked_by_debris: bool = false
			if orchestrator != null:
				blocked_by_debris = orchestrator.is_cell_blocked_by_debris(target_place_cell, grid.cell_size)
			var overlaps_player: bool = is_cell_overlapping_player(target_place_cell, grid.cell_size)
			var blocked_by_terrain2: bool = false
			if vox_world2 != null and vox_world2.has_method("is_solid_block"):
				blocked_by_terrain2 = vox_world2.is_solid_block(target_place_cell)
			can_place_target = grid_valid and not blocked_by_debris and not overlaps_player and not blocked_by_terrain2

	if preview_ghost != null:
		if area_selection_step == AreaSelectionStep.CORNER_2:
			var curr_target := target_remove_cell if (grid != null and grid.has_block(target_remove_cell)) else target_place_cell
			var min_c := Vector3i(mini(area_corner_1.x, curr_target.x), mini(area_corner_1.y, curr_target.y), mini(area_corner_1.z, curr_target.z))
			var max_c := Vector3i(maxi(area_corner_1.x, curr_target.x), maxi(area_corner_1.y, curr_target.y), maxi(area_corner_1.z, curr_target.z))
			preview_ghost.update_area_preview(min_c, max_c, grid.cell_size)
		elif debris_grabber != null and debris_grabber.is_grabbing:
			pass # DebrisGrabber updates the preview ghost for recovery
		elif target_is_terrain:
			# Natural terrain uses the subtle outline only — no green placement cube.
			preview_ghost.hide_preview()
		elif target_is_debris and target_debris_island != null and target_debris_island.is_moving():
			preview_ghost.hide_preview()
		elif can_place_target:
			preview_ghost.update_preview(target_place_cell, true, grid.cell_size)
		else:
			preview_ghost.hide_preview()

func _normal_to_cell_offset(normal: Vector3) -> Vector3i:
	var abs_norm := normal.abs()
	if abs_norm.y >= abs_norm.x and abs_norm.y >= abs_norm.z:
		return Vector3i(0, 1 if normal.y > 0 else -1, 0)
	elif abs_norm.x >= abs_norm.y and abs_norm.x >= abs_norm.z:
		return Vector3i(1 if normal.x > 0 else -1, 0, 0)
	else:
		return Vector3i(0, 0, 1 if normal.z > 0 else -1)

func _handle_interact_action() -> void:
	if debris_grabber == null:
		return
	if current_state != State.BODY_CONTROL:
		return

	if debris_grabber.is_grabbing:
		debris_grabber.release()
	else:
		if target_is_debris and is_instance_valid(target_debris_island) and target_debris_cell != null:
			var block_data: BlockData = null
			if target_debris_island.constituent_blocks.has(target_debris_cell):
				block_data = target_debris_island.constituent_blocks[target_debris_cell]
			debris_grabber.try_grab(target_debris_island, target_debris_cell, block_data)

func _handle_recover_action() -> void:
	if debris_grabber != null and debris_grabber.is_grabbing:
		debris_grabber.try_recover()

func _handle_place_action() -> void:
	_ensure_nodes()
	if area_selection_step != AreaSelectionStep.NONE:
		if area_selection_step == AreaSelectionStep.CORNER_1:
			_confirm_area_corner_1()
		elif area_selection_step == AreaSelectionStep.CORNER_2:
			_confirm_area_corner_2()
		return

	if debris_grabber != null and debris_grabber.is_grabbing:
		debris_grabber.try_place_to_grid()
		return

	if not has_target:
		return
	if target_is_debris and is_instance_valid(target_debris_island) and target_debris_island.is_moving():
		return
	if not can_place_target:
		return

	var grid := grid_system
	if grid == null and has_node("/root/GridSystem"):
		grid = get_node("/root/GridSystem")

	if grid != null:
		if is_cell_overlapping_player(target_place_cell, grid.cell_size):
			return
		if orchestrator != null and orchestrator.is_cell_blocked_by_debris(target_place_cell, grid.cell_size):
			return
		var vox := _get_voxel_world()
		if vox != null and vox.has_method("is_solid_block") and vox.is_solid_block(target_place_cell):
			return

		var b_type := get_selected_type()
		var cost := BlockTypeCatalog.get_cost(b_type)
		var inv_mgr := _get_inventory_manager()

		# Enforce material inventory cost checks strictly in Survival mode
		if game_mode == GameMode.SURVIVAL and inv_mgr != null and not inv_mgr.has_materials(cost):
			target_face_status = "Insufficient %s! (Need 1)" % BlockTypeCatalog.get_display_name(b_type)
			target_face_changed.emit(has_target, target_remove_cell, target_face_dir, target_face_status)
			return

		if grid.place_block(target_place_cell, b_type):
			if game_mode == GameMode.SURVIVAL and inv_mgr != null:
				inv_mgr.consume_materials(cost)
			var bp_mgr := _get_blueprint_manager()
			if bp_mgr != null and bp_mgr.has_method("notify_intentional_block_placed"):
				var placed_b: BlockData = grid.get_block(target_place_cell)
				if placed_b != null:
					bp_mgr.notify_intentional_block_placed(target_place_cell, placed_b)

## Instant creative mine helper kept for tests / debug. Always routes through mine_voxel().
func _mine_terrain_with_voxel_tool() -> void:
	var vox_world := _get_voxel_world()
	if vox_world == null or not vox_world.has_method("mine_voxel"):
		return
	var hit_pos: Vector3i = target_terrain_cell
	var resolved: Variant = _raycast_terrain_voxel(vox_world)
	if resolved != null:
		hit_pos = resolved as Vector3i
	if hit_pos == _INVALID_VOXEL:
		return
	var mined_type: StringName = vox_world.mine_voxel(hit_pos)
	if mined_type.is_empty():
		return
	var inv_mgr := _get_inventory_manager()
	if inv_mgr != null:
		inv_mgr.add_material(mined_type, 1)
	target_face_status = "✓ Mined 1 %s!" % BlockTypeCatalog.get_display_name(mined_type)
	target_face_changed.emit(has_target, hit_pos, target_face_dir, target_face_status)
	if build_hud != null and build_hud.has_method("show_mine_feedback"):
		build_hud.show_mine_feedback(mined_type, 1)

func _handle_remove_action() -> void:
	if area_selection_step != AreaSelectionStep.NONE:
		cancel_area_selection()
		return

	if debris_grabber != null and debris_grabber.is_grabbing:
		debris_grabber.release()
		return

	if not has_target:
		return

	if target_is_debris:
		if is_instance_valid(target_debris_island) and target_debris_cell != null:
			target_debris_island.remove_block(target_debris_cell)
	elif target_is_terrain:
		pass # Mining is handled via hold-to-mine progress in _physics_process
	else:
		var grid := grid_system
		if grid == null and has_node("/root/GridSystem"):
			grid = get_node("/root/GridSystem")
		if grid != null and grid.has_block(target_remove_cell):
			var bp_mgr := _get_blueprint_manager()
			if bp_mgr != null and bp_mgr.has_method("notify_intentional_block_removed"):
				bp_mgr.notify_intentional_block_removed(target_remove_cell)
			grid.remove_block(target_remove_cell)

func _handle_throw_action() -> void:
	if debris_grabber == null:
		return
	if current_state != State.BODY_CONTROL:
		return
	if debris_grabber.is_grabbing:
		debris_grabber.try_throw()

func _handle_cement_action() -> void:
	if not has_target or target_is_debris:
		return
	if target_face_dir == Vector3i.ZERO:
		return

	var grid := grid_system
	if grid == null and has_node("/root/GridSystem"):
		grid = get_node("/root/GridSystem")
	if grid == null or not grid.has_block(target_remove_cell):
		return

	var joint_sys: Node = null
	if has_node("/root/JointSystem"):
		joint_sys = get_node("/root/JointSystem")
	if joint_sys == null:
		return

	if joint_sys.is_face_coated(target_remove_cell, target_face_dir):
		target_face_status = "Surface Mortared (Reinforced)"
		target_face_changed.emit(has_target, target_remove_cell, target_face_dir, target_face_status)
		return

	if game_mode == GameMode.SURVIVAL and not unlimited_cement and cement_count <= 0:
		target_face_status = "Mortar Depleted! (0 left)"
		target_face_changed.emit(has_target, target_remove_cell, target_face_dir, target_face_status)
		return

	if use_cement(1):
		var res: Dictionary = joint_sys.apply_mortar_brush(target_remove_cell, target_face_dir)
		var reinforced: Array = res.get("reinforced_joints", [])
		if not reinforced.is_empty():
			target_face_status = "Surface Mortared! (%d joints reinforced, %d left)" % [reinforced.size(), cement_count]
		else:
			target_face_status = "Surface Mortared! (Ready, %d left)" % cement_count
		target_face_changed.emit(has_target, target_remove_cell, target_face_dir, target_face_status)
