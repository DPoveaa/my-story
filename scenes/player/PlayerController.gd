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
@export var max_ray_distance: float = 5.0
@export var available_types: Array[StringName] = [&"grass", &"dirt", &"stone", &"brick", &"wood", &"gold"]
## Hold duration on the same voxel before SDF carve (Pickaxe / slot 3).
@export var mine_duration_seconds: float = 0.8
## Legacy cooldown retained for compatibility (gradual hold uses mine_duration_seconds).
@export var mine_cooldown: float = 0.3
## Radius (in voxels) of the SDF boolean sphere carved on each completed mine tick.
## Slightly oversized so microscopic SDF shells (black lighting artifacts) are fully cleared.
@export var mine_sdf_radius: float = 0.65
## Vacuum Bag cone distance (meters) while holding LMB on slot 2.
@export var vacuum_radius: float = 4.0
## Distance at which a vacuumed fragment is collected into the bag.
@export var vacuum_collect_distance: float = 0.8
## Forward cone threshold: basis.z.dot(to_frag) must be below this (looking toward -Z).
@export var vacuum_cone_dot: float = -0.7
## Legacy crumble grid size (unused — shards are now Voronoi-lite irregular).
@export_range(2, 3, 1) var fragment_grid_size: int = 3
## Legacy impulse (unused — shards spawn with zero velocity and crumble via gravity).
@export var fragment_crumble_impulse: float = 0.35
## Maximum fragments the Vacuum Bag can hold.
@export var bag_max_capacity: int = 50

# System References
@export var grid_system: Node
@export var stability_system: Node
@export var orchestrator: CollapseOrchestrator
@export var preview_ghost: PreviewGhost
@export var build_hud: Node = null

const DebrisGrabberScript = preload("res://systems/interaction/DebrisGrabber.gd")
const VoxelFragmentScript = preload("res://systems/interaction/VoxelFragment.gd")
const RadialMenuScene = preload("res://scenes/ui/RadialMenu.tscn")
const ChoppingBlockScene = preload("res://scenes/world/ChoppingBlock.tscn")
const PalletScene = preload("res://scenes/world/Pallet.tscn")
const WorkerScene = preload("res://scenes/world/Worker.tscn")
## Physics layer bit values:
## Layer 1 = World/Terrain (value 1)
## Layer 2 = Player/Character (value 2)
## Layer 3 = Resources (Logs / Planks) (value 4)
## Layer 4 = Debris (Shards / Fragments) (value 8)
const RESOURCE_LAYER: int = 4
const DEBRIS_LAYER: int = 8
const RESOURCE_COLLISION_MASK: int = 1 | RESOURCE_LAYER | DEBRIS_LAYER
const DEBRIS_COLLISION_MASK: int = 1 | RESOURCE_LAYER | DEBRIS_LAYER

# Internal Nodes
@onready var collision_shape: CollisionShape3D = $CollisionShape3D
@onready var body_mesh: MeshInstance3D = $BodyMesh
@onready var head: Node3D = $Head
@onready var body_camera: Camera3D = $Head/BodyCamera
@onready var projection_camera: Camera3D = $ProjectionCamera
@onready var debris_grabber: Node = get_node_or_null("DebrisGrabber")
@onready var vacuum_zone: Area3D = $Head/BodyCamera/VacuumZone

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
## Choppable prop under the crosshair (PineTree / "tree" group / take_damage).
var target_tree: Node = null
## Carryable item under the crosshair (manual E grab, not bag vacuum).
var target_log: RigidBody3D = null
## Alias used by newer carry helpers (same as target_log).
var target_carryable: RigidBody3D = null
## Chopping block under the crosshair.
var target_chopping_block: Node = null
## Pallet under the crosshair.
var target_pallet: Node = null
## Held carryables parented to camera markers (logs max 2, planks/blocks max 4; no mixing).
var _held_logs: Array[RigidBody3D] = []
var _log_hold_markers: Array[Marker3D] = []
const MAX_HELD_LOGS: int = 2
const MAX_HELD_PLANKS: int = 4
const MAX_HELD_BLOCKS: int = 1
const MAX_HOLD_MARKERS: int = 4
## Craft radial menu (hold RMB while carrying a log + aiming at floor / pallet).
var _radial_menu: Node = null
var _craft_floor_valid: bool = false
## Hologram station placement (after radial confirms an option).
var is_placing_station: bool = false
var station_to_place: String = ""
var station_ghost_mesh: Node3D = null
## Hold-G progress to dismantle stations (Chopping Block / Pallet) and Workers.
var _station_dismantle_hold: float = 0.0
const STATION_DISMANTLE_TIME: float = 1.0
## Worker under the crosshair (for G-hold dismantling).
var target_worker: Node = null
var _foot_pusher: Area3D = null
var _debug_overlay_enabled: bool = false

## Vacuum acceleration: elapsed time LMB held continuously (resets on release).
var _vacuum_hold_time: float = 0.0
## Dump acceleration: elapsed time RMB held continuously (resets on release).
var _dump_hold_time: float = 0.0
var mining_progress: float = 0.0
var target_voxel_pos: Vector3i = Vector3i(99999, 99999, 99999)
var _last_mined_cell: Vector3i = Vector3i(99999, 99999, 99999)
const MINE_TIME: float = 1.0
const _INVALID_VOXEL := Vector3i(99999, 99999, 99999)

## Hotbar: 1–9. Slot 3 = Pickaxe (mine), Slot 2 = Bag (vacuum).
var current_slot: int = 3
## Multi-material bag: material_name -> fragment count.
var bag_contents: Dictionary = {}
## Material currently selected for dumping (mouse-wheel cycle).
var selected_material: String = ""
## Keys in bag_contents that currently have count > 0 (wheel cycle order).
var available_materials: Array = []
## Cached sum of bag_contents values (capacity / UI).
var bag_count: int = 0

## LMB hold-to-mine state (gradual: accumulate mine_duration_seconds on same voxel).
var _lmb_held: bool = false
var _mine_cooldown_timer: float = 0.0
var _lmb_mine_progress: float = 0.0   # 0.0 → 1.0 hold progress on current voxel
var _lmb_mine_target: Vector3i = Vector3i(99999, 99999, 99999)  # world-voxel being mined

## Fragments currently being vacuum-sucked (restored on button release).
var _vacuum_pulled: Array[Node3D] = []
## RMB dump cooldown (slot 2) — rapid-fire spit while held.
var _dump_cooldown: float = 0.0
## Base and max rates for dump acceleration (items/sec).
const DUMP_RATE_MIN: float = 5.0
const DUMP_RATE_MAX: float = 25.0
const DUMP_ACCEL_TIME: float = 3.0
## Base and max rates for vacuum pull acceleration (items/sec).
const VACUUM_RATE_MIN: float = 5.0
const VACUUM_RATE_MAX: float = 20.0
const VACUUM_ACCEL_TIME: float = 3.0
const THROW_FORCE: float = 12.0
const DROP_FORCE: float = 2.5

## Slot / bag HUD + first-person bag placeholder.
var _slot_hud_layer: CanvasLayer = null
var _slot_hud_label: Label = null
var _bag_progress: ProgressBar = null
var _bag_contents_label: Label = null
var _carry_hint_label: Label = null
var _bag_mesh: MeshInstance3D = null
var _last_ui_slot: int = -1
var _last_ui_bag_count: int = -1
var _last_ui_selected: String = ""

## Thin outline + world-space crack Decal on the mined surface.
var _terrain_outline: MeshInstance3D = null
var _terrain_crack: Decal = null
var _outline_mat: StandardMaterial3D = null
var _crack_textures: Array[Texture2D] = []
var _crack_stage: int = -1

## Accumulated raw materials recovered from low-durability debris.
## Dictionary[StringName, int] — block_type -> amount
var raw_materials: Dictionary = {}

## Direct player resource inventory (Castle Story style).
var inventory: Dictionary = {}

## Legacy alias for bag_contents (pallet radial / older callers).
var bag: Dictionary:
	get:
		return bag_contents
	set(value):
		bag_contents = value
		_sync_bag_count()
var current_volume: int = 0
var max_volume: int = 30

## Removes `amount` of resource `type` from the bag to be used later in the Pallet radial menu.
func dump_resource(type: String, amount: int) -> int:
	if not bag_contents.has(type):
		return 0
	var dump_count: int = mini(int(bag_contents[type]), amount)
	bag_contents[type] = int(bag_contents[type]) - dump_count
	current_volume = maxi(0, current_volume - dump_count)
	_sync_bag_count()
	_refresh_available_materials()
	_update_slot_hud(true)
	return dump_count

## Sum of all material counts in bag_contents.
func _bag_total() -> int:
	var total: int = 0
	for key in bag_contents.keys():
		total += int(bag_contents[key])
	return total

func _sync_bag_count() -> void:
	bag_count = _bag_total()
	current_volume = bag_count

## Rebuild available_materials from bag_contents keys with count > 0.
## Does NOT auto-switch selected_material when it empties — player must scroll.
func _refresh_available_materials() -> void:
	available_materials.clear()
	for key in bag_contents.keys():
		if int(bag_contents[key]) > 0:
			available_materials.append(String(key))
	available_materials.sort()
	if available_materials.is_empty():
		selected_material = ""
	elif selected_material.is_empty():
		# Only auto-pick when nothing was selected yet (e.g. first vacuum pickup).
		selected_material = String(available_materials[0])

## Cycle selected dump material (slot 2 mouse wheel). direction: -1 prev, +1 next.
func _cycle_selected_material(direction: int) -> void:
	_refresh_available_materials()
	if available_materials.is_empty():
		selected_material = ""
		_update_slot_hud(true)
		return
	var idx: int = available_materials.find(selected_material)
	if idx < 0:
		idx = 0
	else:
		idx = (idx + direction + available_materials.size()) % available_materials.size()
	selected_material = String(available_materials[idx])
	_update_slot_hud(true)


## Spawn state — GameWorld drives loading; player stays frozen until resume_at_spawn().
var _is_spawned: bool = false
var _resolved_spawn: Vector3 = Vector3(0.5, 90.0, 0.5)
var _gameplay_input_suspended: bool = true

## Last terrain hit surface (world space) for crack/outline orientation.
var _target_hit_normal: Vector3 = Vector3.UP
var _target_hit_point: Vector3 = Vector3.ZERO

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

func _ensure_foot_pusher() -> void:
	if has_node("FootPusher"):
		_foot_pusher = get_node("FootPusher") as Area3D
		return
	var foot_pusher := Area3D.new()
	foot_pusher.name = "FootPusher"
	# Positioned at foot height — slightly above ground so shards are pushed sideways.
	foot_pusher.position = Vector3(0.0, 0.25, 0.0)
	foot_pusher.collision_layer = 0
	foot_pusher.collision_mask = DEBRIS_LAYER
	foot_pusher.monitoring = true
	foot_pusher.monitorable = false
	# Left foot sphere.
	var col_left := CollisionShape3D.new()
	var sphere_left := SphereShape3D.new()
	sphere_left.radius = 0.28
	col_left.shape = sphere_left
	col_left.position = Vector3(-0.18, 0.0, 0.0)
	foot_pusher.add_child(col_left)
	# Right foot sphere.
	var col_right := CollisionShape3D.new()
	var sphere_right := SphereShape3D.new()
	sphere_right.radius = 0.28
	col_right.shape = sphere_right
	col_right.position = Vector3(0.18, 0.0, 0.0)
	foot_pusher.add_child(col_right)
	add_child(foot_pusher)
	_foot_pusher = foot_pusher

func _ready() -> void:
	_ensure_cached_shard_resources()
	floor_max_angle = deg_to_rad(46.0)
	floor_snap_length = 0.3
	if "debug_navigation_hint" in get_tree():
		get_tree().debug_navigation_hint = false
	if NavigationServer3D.has_method("set_debug_enabled"):
		NavigationServer3D.set_debug_enabled(false)
	_ensure_nodes()
	# Collide with World (1) and Resources (Layer 3 / Logs, Planks).
	# Exclude Layer 4 so fragment rigidbodies cannot apply physical velocity impulse to the player.
	collision_mask = (collision_mask | 1 | RESOURCE_LAYER) & ~DEBRIS_LAYER
	_ensure_foot_pusher()
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

	_ensure_log_hold_markers()

	# Ensure projection camera is top_level so it flies independently of body transform
	if projection_camera != null:
		projection_camera.top_level = true

	_setup_slot_hud()
	_setup_bag_visual()
	_ensure_vacuum_zone()
	_ensure_cached_shard_resources()
	_warmup_particle_pool()

	# Massive XZ shift each session for a fresh landscape without reseeding the generator.
	# Hold Y stays within collision viewer range; GameWorld finalizes spawn on terrain.
	randomize()
	global_position = Vector3(
		float(randi_range(-10000, 10000)),
		90.0,
		float(randi_range(-10000, 10000))
	)
	_resolved_spawn = global_position
	_is_spawned = false
	_gameplay_input_suspended = true
	is_physics_suspended = true
	velocity = Vector3.ZERO
	_ensure_terrain_target_visuals()

	set_state(State.BODY_CONTROL)
	block_type_changed.emit(get_selected_type())
	cement_changed.emit(cement_count, max_cement)
	_update_slot_hud(true)
	_update_bag_visual()

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
			_drop_all_held_logs()
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
			_drop_all_held_logs()

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
		if "debug_navigation_hint" in get_tree():
			get_tree().debug_navigation_hint = _debug_overlay_enabled
		if NavigationServer3D.has_method("set_debug_enabled"):
			NavigationServer3D.set_debug_enabled(_debug_overlay_enabled)
		if _slot_hud_label != null:
			_slot_hud_label.visible = _debug_overlay_enabled
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

	# Station hologram: LMB confirm / RMB cancel (before normal look & build input).
	if is_placing_station and event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT or event.is_action_pressed(&"remove_block"):
			_confirm_station_placement()
			get_viewport().set_input_as_handled()
			return
		if event.button_index == MOUSE_BUTTON_RIGHT:
			_cancel_station_placement()
			get_viewport().set_input_as_handled()
			return

	# While radial is open, skip look — menu consumes relative motion as virtual cursor.
	var radial_open: bool = _radial_menu != null and is_instance_valid(_radial_menu)

	# Mouse look — requires captured cursor; no middle-mouse dragging in body modes
	if event is InputEventMouseMotion and _mouse_captured and not radial_open:
		_handle_mouse_look(event.relative)
		get_viewport().set_input_as_handled()
		return

	# Mouse — exclusive roles:
	# LMB = BREAK/VACUUM | MMB = PLACE | RMB = construction / craft radial
	if event is InputEventMouseButton and _mouse_captured and not radial_open and not is_placing_station:
		if event.pressed:
			if event.button_index == MOUSE_BUTTON_WHEEL_UP:
				if current_slot == 2:
					_cycle_selected_material(-1)
				else:
					_cycle_block_type(-1)
				get_viewport().set_input_as_handled()
				return
			if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				if current_slot == 2:
					_cycle_selected_material(1)
				else:
					_cycle_block_type(1)
				get_viewport().set_input_as_handled()
				return
			if event.button_index == MOUSE_BUTTON_LEFT:
				if _is_holding_building_block() and has_target:
					_place_held_craft_block()
				elif area_selection_step != AreaSelectionStep.NONE:
					_handle_minecraft_break_action()
				elif debris_grabber != null and debris_grabber.is_grabbing:
					_handle_minecraft_break_action()
				elif has_target and target_is_debris and current_slot != 2:
					_handle_minecraft_break_action()
				else:
					_lmb_held = true
				get_viewport().set_input_as_handled()
				return
			elif event.button_index == MOUSE_BUTTON_MIDDLE or event.is_action_pressed(&"place_block"):
				if current_slot != 2:
					_handle_minecraft_place_action()
				get_viewport().set_input_as_handled()
				return
			elif event.button_index == MOUSE_BUTTON_RIGHT:
				# Slot 2 bag dump is hold-driven in _physics_process; stations/hands open radial.
				if current_slot != 2 and _can_open_craft_radial():
					_open_craft_radial_menu()
				elif current_slot == 2 and (is_instance_valid(target_pallet) or is_instance_valid(target_chopping_block)):
					if _can_open_craft_radial():
						_open_craft_radial_menu()
				get_viewport().set_input_as_handled()
				return
		else:
			# Button released — cancel mine progress and drop vacuumed fragments.
			if event.button_index == MOUSE_BUTTON_LEFT:
				_lmb_held = false
				_release_vacuum_fragments()
				if _lmb_mine_progress > 0.0:
					_lmb_mine_progress = 0.0
					_lmb_mine_target = _INVALID_VOXEL
					_hide_terrain_target_visuals()
					if build_hud != null and build_hud.has_method("set_mining_progress"):
						build_hud.set_mining_progress(false, "", 0)
				get_viewport().set_input_as_handled()
				return
			if event.button_index == MOUSE_BUTTON_RIGHT:
				_dump_cooldown = 0.0
				_release_vacuum_fragments()
				get_viewport().set_input_as_handled()
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
		elif event.is_action_pressed(&"drop_carried") or event.keycode == KEY_G:
			# G: drop carried item (log, plank, building block) if holding one; otherwise mortar brush.
			if not _held_logs.is_empty():
				_drop_one_held_item()
			else:
				_handle_cement_action()
			return
		elif event.is_action_pressed(&"recover_block") or event.keycode == KEY_R:
			_handle_recover_action()
			return
		elif event.is_action_pressed(&"throw_debris") or event.keycode == KEY_F:
			_handle_throw_action()
			return
		elif event.is_action_pressed(&"apply_cement"):
			if _held_logs.is_empty():
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
		elif event.is_action_pressed(&"select_slot_1") or event.keycode == KEY_1 or event.physical_keycode == KEY_1:
			_set_current_slot(1)
		elif event.is_action_pressed(&"select_slot_2") or event.keycode == KEY_2 or event.physical_keycode == KEY_2:
			_set_current_slot(2)
		elif event.is_action_pressed(&"select_slot_3") or event.keycode == KEY_3 or event.physical_keycode == KEY_3:
			_set_current_slot(3)
		elif event.is_action_pressed(&"select_slot_4") or event.keycode == KEY_4 or event.physical_keycode == KEY_4:
			_set_current_slot(4)
		elif event.is_action_pressed(&"select_slot_5") or event.keycode == KEY_5 or event.physical_keycode == KEY_5:
			_set_current_slot(5)
		elif event.is_action_pressed(&"select_slot_6") or event.keycode == KEY_6 or event.physical_keycode == KEY_6:
			_set_current_slot(6)
		elif event.is_action_pressed(&"select_slot_7") or event.keycode == KEY_7 or event.physical_keycode == KEY_7:
			_set_current_slot(7)
		elif event.is_action_pressed(&"select_slot_8") or event.keycode == KEY_8 or event.physical_keycode == KEY_8:
			_set_current_slot(8)
		elif event.is_action_pressed(&"select_slot_9") or event.keycode == KEY_9 or event.physical_keycode == KEY_9:
			_set_current_slot(9)

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

## Walk up from a physics collider to a "tree" group or take_damage() node.
func _resolve_tree_target(collider: Object) -> Node:
	var node: Node = collider as Node
	while node != null:
		if node.is_in_group("tree") or node.has_method("take_damage"):
			return node
		node = node.get_parent()
	return null

## Walk up from a physics collider to a Worker node.
func _resolve_worker(collider: Object) -> Node:
	var node: Node = collider as Node
	while node != null:
		if node.is_in_group("workers"):
			return node
		node = node.get_parent()
	return null

## Walk up from a physics collider to a chopping block / crafting station stump.
func _resolve_chopping_block(collider: Object) -> Node:
	var node: Node = collider as Node
	while node != null:
		if node.is_in_group("chopping_blocks") or node.has_method("try_chop"):
			return node
		node = node.get_parent()
	return null

## Walk up from a physics collider to a crafting pallet.
func _resolve_pallet(collider: Object) -> Node:
	# Crafted blocks sitting on a pallet are grabbable — do not treat them as the station.
	if collider is RigidBody3D:
		var rb := collider as RigidBody3D
		if rb.is_in_group("craft_blocks") or bool(rb.get_meta("is_craft_block", false)):
			return null
	var node: Node = collider as Node
	while node != null:
		if node.is_in_group("pallets") or node.has_method("try_store"):
			return node
		node = node.get_parent()
	return null

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
	var cell_arr: Array[Vector3i] = [pos]
	orchestrator.spawn_debris_for_cells(cell_arr, dict)

func _handle_minecraft_break_action() -> void:
	## Called only for non-terrain targets (grid blocks, debris).
	## Terrain mining is handled exclusively via the LMB hold-to-mine system in _physics_process.
	if area_selection_step != AreaSelectionStep.NONE:
		if area_selection_step == AreaSelectionStep.CORNER_1:
			_confirm_area_corner_1()
		elif area_selection_step == AreaSelectionStep.CORNER_2:
			_confirm_area_corner_2()
		return

	if debris_grabber != null and debris_grabber.is_grabbing:
		debris_grabber.release()
		return

	# Debris block → instant destroy.
	if has_target and target_is_debris:
		if is_instance_valid(target_debris_island) and target_debris_cell != null:
			target_debris_island.remove_block(target_debris_cell)
		return

	# Grid (player-placed) blocks are not destroyed instantly here.
	# They are now unified with natural terrain in the gradual SDF mining system (_process_lmb_mining).
	# Terrain is NOT handled here — hold-to-mine drives terrain and block removal.



func _handle_minecraft_place_action() -> void:
	if area_selection_step != AreaSelectionStep.NONE:
		cancel_area_selection()
		return

	if debris_grabber != null and debris_grabber.is_grabbing:
		debris_grabber.try_place_to_grid()
		return

	# ALL block types (natural and structural) are placed as physics grid blocks.
	# vt.set_voxel() is NEVER used for placement — only for breaking (set to 0).
	var grid := grid_system
	if grid == null and has_node("/root/GridSystem"):
		grid = get_node("/root/GridSystem")
	if grid == null:
		return

	var place_cell: Vector3i = target_place_cell
	var resolved := false

	if has_target and not target_is_terrain:
		var n := _target_hit_normal
		if n.length_squared() < 0.0001:
			n = Vector3.UP
		else:
			n = n.normalized()
		# Exact integer grid center then convert to cell.
		var place_pos: Vector3 = TerrainBlockyLibrary.snap_world_to_grid_center(
			_target_hit_point + (n * 0.5)
		)
		place_cell = Vector3i(
			int(floor(place_pos.x)),
			int(floor(place_pos.y)),
			int(floor(place_pos.z))
		)
		resolved = true
	else:
		var hit = _perform_voxel_raycast()
		if hit != null:
			place_cell = hit.previous_position as Vector3i
			resolved = true
		elif has_target:
			var n2 := _target_hit_normal
			if n2.length_squared() < 0.0001:
				n2 = Vector3.UP
			else:
				n2 = n2.normalized()
			var place_pos2: Vector3 = TerrainBlockyLibrary.snap_world_to_grid_center(
				_target_hit_point + (n2 * 0.5)
			)
			place_cell = Vector3i(
				int(floor(place_pos2.x)),
				int(floor(place_pos2.y)),
				int(floor(place_pos2.z))
			)
			resolved = true

	if not resolved and not has_target:
		return

	has_target = true
	target_place_cell = place_cell
	can_place_target = true

	# Holding crafted 1x1x1 building block: place from hand (consumes one held block).
	if _is_holding_building_block():
		var held_type: String = _current_held_type()
		if not held_type.is_empty():
			_try_place_held_craft_block(grid, place_cell, StringName(held_type))
			return

	# Empty hands: blocks CANNOT be placed out of thin air.
	return

func _try_place_held_craft_block(grid: Node, place_cell: Vector3i, b_type: StringName) -> bool:
	if grid == null or not grid.can_place_block(place_cell):
		return false
	if is_cell_overlapping_player(place_cell, grid.cell_size):
		return false
	if orchestrator != null and orchestrator.is_cell_blocked_by_debris(place_cell, grid.cell_size):
		return false
	var vox := _get_voxel_world()
	if vox != null and vox.has_method("is_solid_block") and vox.is_solid_block(place_cell):
		return false
	if not grid.place_block(place_cell, b_type):
		return false
	_consume_one_held_item()
	var bp_mgr := _get_blueprint_manager()
	if bp_mgr != null and bp_mgr.has_method("notify_intentional_block_placed"):
		var placed_b: BlockData = grid.get_block(place_cell)
		if placed_b != null:
			bp_mgr.notify_intentional_block_placed(place_cell, placed_b)
	return true



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
	if not _held_logs.is_empty() and current_state == State.BODY_CONTROL:
		_process_held_item_snagging(delta)
	if is_placing_station:
		_update_station_ghost()

	# Hold LMB via action (continuous) or mouse-button latch. Vacuum runs in _physics_process().
	var lmb_held: bool = _lmb_held or Input.is_action_pressed(&"remove_block")
	if is_placing_station:
		lmb_held = false
	if lmb_held and current_state == State.BODY_CONTROL:
		if current_slot == 3:
			_process_lmb_mining(delta)
	else:
		if _lmb_mine_progress > 0.0 and not lmb_held:
			_lmb_mine_progress = 0.0
			_lmb_mine_target = _INVALID_VOXEL
			_hide_terrain_target_visuals()
			if build_hud != null and build_hud.has_method("set_mining_progress"):
				build_hud.set_mining_progress(false, "", 0)

	# Vacuum Bag (Slot 2) strictly in _physics_process
	var vacuum_active: bool = (
		current_slot == 2
		and current_state == State.BODY_CONTROL
		and not is_placing_station
		and not _gameplay_input_suspended
		and _is_spawned
		and (lmb_held or Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT))
	)
	if vacuum_active:
		_vacuum_hold_time += delta
		_process_vacuum_bag(delta)
	else:
		_vacuum_hold_time = 0.0
		_release_vacuum_fragments()

	# Slot 2: hold RMB for rapid-fire bag dump (stations still open radial on press).
	var dump_rmb_active: bool = (
		current_slot == 2
		and current_state == State.BODY_CONTROL
		and _radial_menu == null
		and not is_placing_station
		and not is_instance_valid(target_chopping_block)
		and not is_instance_valid(target_pallet)
		and (Input.is_action_pressed(&"construction_menu") or Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT))
	)
	if dump_rmb_active:
		_dump_hold_time += delta
		_dump_selected_material(delta)
	else:
		_dump_hold_time = 0.0
		if current_slot != 2:
			_dump_cooldown = 0.0
		else:
			_dump_cooldown = 0.0

	# Hold-G station/worker dismantling: accumulate hold timer when aiming at a station or worker with empty hands.
	var g_held: bool = Input.is_key_pressed(KEY_G) or Input.is_action_pressed(&"drop_carried")
	var aiming_station: bool = is_instance_valid(target_chopping_block) or is_instance_valid(target_pallet)
	var aiming_worker: bool = is_instance_valid(target_worker)
	if g_held and _held_logs.is_empty() and (aiming_station or aiming_worker) and current_state != State.DEBUG_FLIGHT:
		_station_dismantle_hold += delta
		var pct: int = clampi(int((_station_dismantle_hold / STATION_DISMANTLE_TIME) * 100.0), 0, 100)
		if build_hud != null and build_hud.has_method("set_mining_progress"):
			build_hud.set_mining_progress(true, "Dismantling...", pct)
		if _station_dismantle_hold >= STATION_DISMANTLE_TIME:
			_station_dismantle_hold = 0.0
			if build_hud != null and build_hud.has_method("set_mining_progress"):
				build_hud.set_mining_progress(false, "", 0)
			if is_instance_valid(target_chopping_block) and target_chopping_block.has_method("dismantle"):
				target_chopping_block.call("dismantle")
				target_chopping_block = null
			elif is_instance_valid(target_pallet) and target_pallet.has_method("dismantle"):
				target_pallet.call("dismantle")
				target_pallet = null
			elif is_instance_valid(target_worker):
				_dismantle_worker(target_worker)
				target_worker = null
	else:
		if _station_dismantle_hold > 0.0:
			_station_dismantle_hold = 0.0
			if build_hud != null and build_hud.has_method("set_mining_progress"):
				build_hud.set_mining_progress(false, "", 0)
		if _held_logs.is_empty() \
		and (Input.is_action_pressed(&"apply_cement") or (g_held and not aiming_station)) \
		and current_state != State.DEBUG_FLIGHT:
			if debris_grabber == null or not debris_grabber.is_grabbing:
				_handle_cement_action()

	_process_fragment_lifecycle(delta)

func _reset_mining_state() -> void:
	mining_progress = 0.0
	target_voxel_pos = _INVALID_VOXEL
	_last_mined_cell = _INVALID_VOXEL
	_crack_stage = -1
	_lmb_mine_progress = 0.0
	_lmb_mine_target = _INVALID_VOXEL
	_mine_cooldown_timer = 0.0
	_lmb_held = false
	if not target_is_terrain:
		_hide_terrain_target_visuals()
	elif target_terrain_cell != _INVALID_VOXEL:
		_update_terrain_target_visuals(target_terrain_cell, 0.0)

## Gradual hold-to-mine: must hold LMB for mine_duration_seconds on the same voxel (slot 3).
## Trees are damaged first (discrete hits on mine_cooldown) — never SDF-carved.
func _process_lmb_mining(delta: float) -> void:
	if current_slot != 3:
		return
	if not (_lmb_held or Input.is_action_pressed(&"remove_block")):
		return

	_mine_cooldown_timer = maxf(0.0, _mine_cooldown_timer - delta)

	# Chopping block with a placed log: LMB chops into planks.
	if is_instance_valid(target_chopping_block) and target_chopping_block.has_method("try_chop"):
		_lmb_mine_progress = 0.0
		_lmb_mine_target = _INVALID_VOXEL
		_hide_terrain_target_visuals()
		if build_hud != null and build_hud.has_method("set_mining_progress"):
			build_hud.set_mining_progress(false, "", 0)
		if _mine_cooldown_timer > 0.0:
			return
		if bool(target_chopping_block.get("has_log")):
			_mine_cooldown_timer = mine_cooldown
			target_chopping_block.call("try_chop")
			_spawn_mining_particles(_target_hit_point, &"wood")
		return

	# Prefer trees / take_damage targets over voxel terrain subtraction.
	if is_instance_valid(target_tree) and (
		target_tree.is_in_group("tree") or target_tree.has_method("take_damage")
	):
		_lmb_mine_progress = 0.0
		_lmb_mine_target = _INVALID_VOXEL
		_hide_terrain_target_visuals()
		if build_hud != null and build_hud.has_method("set_mining_progress"):
			build_hud.set_mining_progress(false, "", 0)
		if _mine_cooldown_timer > 0.0:
			return
		_mine_cooldown_timer = mine_cooldown
		var hit_pos: Vector3 = _target_hit_point if _target_hit_point != Vector3.ZERO else (
			(target_tree as Node3D).global_position + Vector3(0.0, 1.0, 0.0)
			if target_tree is Node3D else Vector3.ZERO
		)
		if target_tree.has_method("take_damage"):
			var hit_dir: Vector3 = Vector3.ZERO
			if target_tree is Node3D:
				hit_dir = (target_tree as Node3D).global_position - global_position
				hit_dir.y = 0.0
				if hit_dir.length_squared() > 0.0001:
					hit_dir = hit_dir.normalized()
			target_tree.call("take_damage", 1, hit_dir)
		_spawn_mining_particles(hit_pos, &"wood")
		return

	var grid := grid_system
	if grid == null and has_node("/root/GridSystem"):
		grid = get_node("/root/GridSystem")

	var is_grid_block: bool = false
	if grid != null:
		is_grid_block = bool(grid.has_block(target_remove_cell))
	if not target_is_terrain and not is_grid_block:
		_lmb_mine_progress = 0.0
		_lmb_mine_target = _INVALID_VOXEL
		_hide_terrain_target_visuals()
		if build_hud != null and build_hud.has_method("set_mining_progress"):
			build_hud.set_mining_progress(false, "", 0)
		return

	var mine_cell: Vector3i = target_terrain_cell if target_is_terrain else target_remove_cell
	if _lmb_mine_target != _INVALID_VOXEL and _lmb_mine_target != mine_cell:
		_lmb_mine_progress = 0.0
	_lmb_mine_target = mine_cell

	var duration: float = maxf(mine_duration_seconds, 0.05)
	_lmb_mine_progress = minf(1.0, _lmb_mine_progress + delta / duration)

	var current_type: StringName = &""
	if target_is_terrain:
		current_type = target_terrain_type
	elif is_grid_block:
		var b_data: BlockData = grid.get_block(mine_cell)
		if b_data != null:
			current_type = b_data.block_type
			b_data.durability = clampf(1.0 - _lmb_mine_progress, 0.0, 1.0)
			grid.block_damaged.emit(mine_cell, b_data.durability)

	var mat_name := BlockTypeCatalog.get_display_name(current_type) if not current_type.is_empty() else "Block"
	var pct: int = clampi(int(_lmb_mine_progress * 100.0), 0, 100)
	_update_terrain_target_visuals(mine_cell, _lmb_mine_progress)
	if build_hud != null and build_hud.has_method("set_mining_progress"):
		build_hud.set_mining_progress(true, mat_name, pct)

	# Inexpensive trickle of particles while mining
	_mine_trickle_timer += delta
	if _mine_trickle_timer >= 0.12:
		_mine_trickle_timer = 0.0
		var trickle_pos: Vector3 = _target_hit_point if _target_hit_point != Vector3.ZERO else (Vector3(mine_cell) + Vector3(0.5, 0.5, 0.5))
		_spawn_mining_trickle(trickle_pos, current_type)

	if _lmb_mine_progress < 1.0:
		return

	# ── Hold complete → SDF carve + crumble ───────────────────────────────────
	_lmb_mine_progress = 0.0
	_lmb_mine_target = _INVALID_VOXEL
	_mine_trickle_timer = 0.0

	var vox_world := _get_voxel_world()
	var mined_type: StringName = &""
	if target_is_terrain:
		if vox_world != null and vox_world.has_method("mine_voxel"):
			# Capture the raw model ID BEFORE mine_voxel() clears the voxel type.
			# After mine_voxel the cell is AIR, so get_block_type_id would return 0 (cube).
			var raw_id: int = vox_world.get_block_type_id(mine_cell) if vox_world.has_method("get_block_type_id") else 0
			mined_type = vox_world.mine_voxel(mine_cell)
			if not mined_type.is_empty():
				_apply_mine_sdf_sphere(mine_cell)
				var res_key := String(mined_type)
				inventory[res_key] = inventory.get(res_key, 0) + 1
				var voxel_center: Vector3 = Vector3(mine_cell) + Vector3(0.5, 0.5, 0.5)
				_spawn_mining_particles(voxel_center, mined_type)
				_spawn_voxel_fragments_burst(voxel_center, mined_type, raw_id)
				_wake_nearby_fragments(voxel_center, 1.5)
				var inv_mgr := _get_inventory_manager()
				if inv_mgr != null:
					inv_mgr.add_material(mined_type, 1)
				var status := "✓ Mined 1 %s!" % BlockTypeCatalog.get_display_name(mined_type)
				target_face_changed.emit(has_target, mine_cell, target_face_dir, status)
				if build_hud != null and build_hud.has_method("show_mine_feedback"):
					build_hud.show_mine_feedback(mined_type, 1)
				if build_hud != null and build_hud.has_method("set_mining_progress"):
					build_hud.set_mining_progress(false, "", 0)
				_hide_terrain_target_visuals()
			else:
				_hide_terrain_target_visuals()
				if build_hud != null and build_hud.has_method("set_mining_progress"):
					build_hud.set_mining_progress(false, "", 0)
			return
	elif is_grid_block:
		var b_data2: BlockData = grid.get_block(mine_cell)
		if b_data2 != null:
			mined_type = b_data2.block_type
		var bp_mgr := _get_blueprint_manager()
		if bp_mgr != null and bp_mgr.has_method("notify_intentional_block_removed"):
			bp_mgr.notify_intentional_block_removed(mine_cell)
		if not grid.apply_damage(mine_cell, 1.0):
			grid.remove_block(mine_cell)

	if mined_type.is_empty():
		_hide_terrain_target_visuals()
		if build_hud != null and build_hud.has_method("set_mining_progress"):
			build_hud.set_mining_progress(false, "", 0)
		return

	_apply_mine_sdf_sphere(mine_cell)

	var res_key := String(mined_type)
	inventory[res_key] = inventory.get(res_key, 0) + 1

	var voxel_center: Vector3 = Vector3(mine_cell) + Vector3(0.5, 0.5, 0.5)
	_spawn_mining_particles(voxel_center, mined_type)
	_spawn_voxel_fragments_burst(voxel_center, mined_type, 0)
	_wake_nearby_fragments(voxel_center, 1.5)

	var inv_mgr := _get_inventory_manager()
	if inv_mgr != null:
		inv_mgr.add_material(mined_type, 1)
	var status := "✓ Mined 1 %s!" % BlockTypeCatalog.get_display_name(mined_type)
	target_face_changed.emit(has_target, mine_cell, target_face_dir, status)
	if build_hud != null and build_hud.has_method("show_mine_feedback"):
		build_hud.show_mine_feedback(mined_type, 1)
	if build_hud != null and build_hud.has_method("set_mining_progress"):
		build_hud.set_mining_progress(false, "", 0)
	_hide_terrain_target_visuals()

func _ensure_vacuum_zone() -> void:
	if vacuum_zone != null and is_instance_valid(vacuum_zone):
		vacuum_zone.monitoring = true
		vacuum_zone.monitorable = false
		vacuum_zone.collision_layer = 0
		vacuum_zone.collision_mask = DEBRIS_LAYER
		return
	var cam := body_camera
	if cam == null:
		cam = get_node_or_null("Head/BodyCamera") as Camera3D
	if cam == null:
		return
	vacuum_zone = cam.get_node_or_null("VacuumZone") as Area3D
	if vacuum_zone == null:
		vacuum_zone = Area3D.new()
		vacuum_zone.name = "VacuumZone"
		var shape := BoxShape3D.new()
		shape.size = Vector3(vacuum_radius * 0.7, vacuum_radius * 0.7, vacuum_radius)
		var col := CollisionShape3D.new()
		col.shape = shape
		vacuum_zone.add_child(col)
		cam.add_child(vacuum_zone)
		vacuum_zone.position = Vector3(0.0, 0.0, -vacuum_radius * 0.5)
	vacuum_zone.monitoring = true
	vacuum_zone.monitorable = false
	vacuum_zone.collision_layer = 0
	vacuum_zone.collision_mask = DEBRIS_LAYER

func _process(_delta: float) -> void:
	pass

## Vacuum Bag (slot 2): Area3D local overlap — only the closest in-sight fragment is pulled.
func _process_vacuum_bag(delta: float) -> void:
	if current_slot != 2:
		_release_vacuum_fragments()
		return
	if not (_lmb_held or Input.is_action_pressed(&"remove_block") or Input.is_action_pressed(&"interact")):
		_release_vacuum_fragments()
		return
	if not is_inside_tree():
		return
	if _bag_total() >= bag_max_capacity:
		_release_vacuum_fragments()
		return

	_ensure_vacuum_zone()
	var cam := get_active_camera()
	if cam == null or vacuum_zone == null:
		return
	var cam_pos: Vector3 = cam.global_position
	var cam_forward_z: Vector3 = cam.global_transform.basis.z

	# Local spatial query only — never scan the global "fragments" group.
	var closest: Node3D = null
	var closest_dist: float = INF
	for body in vacuum_zone.get_overlapping_bodies():
		if not is_instance_valid(body) or not (body is Node3D):
			continue
		if not body.is_in_group("fragments"):
			continue
		var frag := body as Node3D
		var to_frag: Vector3 = frag.global_position - cam_pos
		var dist: float = to_frag.length()
		if dist > vacuum_radius:
			continue
		if dist > 0.0001:
			var dir_n: Vector3 = to_frag / dist
			if cam_forward_z.dot(dir_n) >= vacuum_cone_dot:
				continue
		if dist < closest_dist:
			closest_dist = dist
			closest = frag

	if closest == null:
		_release_vacuum_fragments()
		return

	var target: Node3D = closest
	var target_dist: float = closest_dist

	for i in range(_vacuum_pulled.size() - 1, -1, -1):
		var prev: Node3D = _vacuum_pulled[i]
		if not is_instance_valid(prev) or prev == target:
			continue
		_restore_vacuum_fragment(prev)
		_vacuum_pulled.remove_at(i)

	if target_dist < vacuum_collect_distance:
		var mat_key: String = String(target.get_meta("material", target.get_meta("fragment_type", "stone")))
		# Read resource_value so merged/overflow fragments yield correct amounts.
		var rv: int = 1
		if target is VoxelFragment:
			rv = (target as VoxelFragment).resource_value
		elif target.has_meta("resource_value"):
			rv = int(target.get_meta("resource_value", 1))
		# Clamp to remaining bag space so we never exceed capacity silently.
		var space: int = bag_max_capacity - _bag_total()
		var collect: int = mini(rv, maxi(space, 0))
		if collect > 0:
			bag_contents[mat_key] = int(bag_contents.get(mat_key, 0)) + collect
			inventory[mat_key] = inventory.get(mat_key, 0) + collect
			_sync_bag_count()
			_refresh_available_materials()
		if collect >= rv:
			_vacuum_pulled.erase(target)
			target.queue_free()
		else:
			var remainder: int = rv - collect
			if target is VoxelFragment:
				(target as VoxelFragment).resource_value = remainder
			target.set_meta("resource_value", remainder)
			_restore_vacuum_fragment(target)
			_vacuum_pulled.erase(target)
		_update_slot_hud(true)
		return

	if not bool(target.get_meta("vacuum_pull", false)):
		target.set_meta("vacuum_pull", true)
		_disable_fragment_collision(target)
		if target is RigidBody3D:
			var rb := target as RigidBody3D
			rb.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
			rb.freeze = true
			rb.gravity_scale = 0.0
			rb.linear_damp = 0.0
			rb.sleeping = false
			rb.linear_velocity = Vector3.ZERO
			rb.angular_velocity = Vector3.ZERO
			# Keep shards fully opaque while vacuumed (never fade/transparent).
			for child in rb.get_children():
				if child is MeshInstance3D:
					var mi := child as MeshInstance3D
					var ov: Material = mi.material_override
					if ov is StandardMaterial3D:
						var sm := ov as StandardMaterial3D
						sm.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
						sm.albedo_color.a = 1.0
		if not _vacuum_pulled.has(target):
			_vacuum_pulled.append(target)

	# Accelerating pull speed: ramp from VACUUM_RATE_MIN to VACUUM_RATE_MAX over VACUUM_ACCEL_TIME.
	var vacuum_accel_t: float = clampf(_vacuum_hold_time / VACUUM_ACCEL_TIME, 0.0, 1.0)
	var pull_speed: float = lerpf(VACUUM_RATE_MIN, VACUUM_RATE_MAX, vacuum_accel_t)
	var pull_t: float = clampf(delta * pull_speed, 0.0, 1.0)
	var next_pos: Vector3 = target.global_position.lerp(cam_pos, pull_t)
	if target is RigidBody3D:
		(target as RigidBody3D).global_position = next_pos
	else:
		target.global_position = next_pos

## Hold RMB on slot 2: accelerating spit of selected_material (Slime Rancher style).
## Rate ramps from DUMP_RATE_MIN to DUMP_RATE_MAX as RMB is held.
## Stops immediately when selected_material reaches 0 — no auto-switch to next type.
func _dump_selected_material(delta: float) -> void:
	_dump_cooldown -= delta
	if _dump_cooldown > 0.0:
		return
	if selected_material.is_empty() or int(bag_contents.get(selected_material, 0)) <= 0:
		return
	# Accelerating interval: ramp dump rate from MIN to MAX over DUMP_ACCEL_TIME seconds.
	var dump_t: float = clampf(_dump_hold_time / DUMP_ACCEL_TIME, 0.0, 1.0)
	var dump_rate: float = lerpf(DUMP_RATE_MIN, DUMP_RATE_MAX, dump_t)
	var interval: float = 1.0 / maxf(dump_rate, 0.5)
	_dump_cooldown = interval

	var ftype: String = selected_material
	bag_contents[ftype] = int(bag_contents[ftype]) - 1
	if int(bag_contents[ftype]) <= 0:
		bag_contents[ftype] = 0
	_sync_bag_count()
	available_materials.clear()
	for key in bag_contents.keys():
		if int(bag_contents[key]) > 0:
			available_materials.append(String(key))
	available_materials.sort()

	var cam := get_active_camera()
	if cam == null:
		_update_bag_hud_preserving_selection()
		return
	var spawn_pos: Vector3 = cam.global_position - cam.global_transform.basis.z * 0.6
	var toss_vel: Vector3 = -cam.global_transform.basis.z * 8.0
	_spawn_single_shard_fragment(spawn_pos, toss_vel, ftype)
	_update_bag_hud_preserving_selection()

func _process_bag_dump(delta: float) -> void:
	_dump_selected_material(delta)

func _restore_vacuum_fragment(frag: Node3D) -> void:
	if frag == null or not is_instance_valid(frag):
		return
	_enable_fragment_collision(frag)
	if frag is RigidBody3D:
		var rb := frag as RigidBody3D
		rb.freeze = false
		rb.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
		rb.gravity_scale = 1.2
		rb.linear_damp = 0.5
		rb.angular_damp = 0.8
		rb.sleeping = false
		# Downward velocity so gravity immediately takes over without mid-air freeze
		rb.linear_velocity = Vector3(0.0, -0.2, 0.0)
		rb.angular_velocity = Vector3.ZERO
		PhysicsServer3D.body_set_state(
			rb.get_rid(),
			PhysicsServer3D.BODY_STATE_TRANSFORM,
			rb.global_transform
		)
		PhysicsServer3D.body_set_state(
			rb.get_rid(),
			PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY,
			rb.linear_velocity
		)
		PhysicsServer3D.body_set_state(
			rb.get_rid(),
			PhysicsServer3D.BODY_STATE_SLEEPING,
			false
		)
	frag.set_meta("vacuum_pull", false)

func _release_vacuum_fragments() -> void:
	if _vacuum_pulled.is_empty():
		return
	for frag in _vacuum_pulled:
		_restore_vacuum_fragment(frag)
	_vacuum_pulled.clear()

## Applies a small SDF sphere boolean subtraction at `center_cell` using VoxelTool.
## Skipped on VoxelMesherBlocky / missing tool targets (avoids Multimesh null errors).
func _apply_mine_sdf_sphere(center_cell: Vector3i) -> void:
	var vox_world := _get_voxel_world()
	if vox_world == null:
		return
	var terrain: Node = vox_world.get_node_or_null("VoxelTerrain")
	if terrain == null or not terrain.has_method("get_voxel_tool"):
		return
	# Blocky + VoxelInstancer: SDF do_sphere triggers "multimesh item to be null".
	if "mesher" in terrain:
		var mesher: Object = terrain.get("mesher") as Object
		if mesher == null:
			return
		if mesher.get_class().find("Blocky") >= 0:
			return
	var vt: VoxelTool = terrain.get_voxel_tool()
	if vt == null:
		return
	if vt.has_method("is_area_editable"):
		var area := AABB(Vector3(center_cell), Vector3.ONE)
		if not bool(vt.is_area_editable(area)):
			return
	# Use SDF channel for smooth boolean sphere subtraction
	vt.channel = VoxelBuffer.CHANNEL_SDF
	vt.mode = VoxelTool.MODE_REMOVE
	var sphere_center: Vector3 = Vector3(center_cell) + Vector3(0.5, 0.5, 0.5)
	var radius: float = mine_sdf_radius
	# Ramp SDF Black Shell Fix (Task 9): increase subtraction radius offset near slopes/ramps
	var is_ramp := false
	if vox_world != null and vox_world.has_method("get_voxel_at"):
		for offset in [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]:
			var neighbor_above: StringName = vox_world.get_voxel_at(center_cell + offset + Vector3i(0, 1, 0))
			var neighbor_below: StringName = vox_world.get_voxel_at(center_cell + offset + Vector3i(0, -1, 0))
			if not neighbor_above.is_empty() or neighbor_below.is_empty():
				is_ramp = true
				break
	if is_ramp:
		radius += 0.20
	else:
		radius += 0.08
	vt.do_sphere(sphere_center, radius)

func _fragment_albedo(block_type: StringName) -> Color:
	match block_type:
		&"stone":  return Color(0.50, 0.50, 0.52)
		&"dirt":   return Color(0.49, 0.35, 0.22)
		&"grass":  return Color(0.30, 0.55, 0.20)
		&"coal":   return Color(0.20, 0.20, 0.20)
		&"iron":   return Color(0.72, 0.58, 0.50)
		&"gold":   return Color(0.85, 0.78, 0.15)
		&"wood":   return Color(0.55, 0.38, 0.20)
		&"log":    return Color(0.42, 0.28, 0.14)
		&"brick":  return Color(0.70, 0.30, 0.20)
		_:         return Color(0.55, 0.50, 0.45)

## ── Voronoi Procedural Mining-Fragment System ──────────────────────────────────
## 1. Reusable Pre-Baked Geometry: Voronoi shattered meshes and convex collision shapes
##    loaded from res://assets/generated/fractures/ (cubes, ramps, inner/outer corners).
## 2. Shape & Orientation Preservation: Relative transforms reconstruct original voxel
##    geometry; directional variants rotate around voxel center without recalculating.
## 3. Two-Tone Materials: Outer faces retain the voxel's exterior surface material,
##    interior cleavage faces receive an authentic chiseled/earthy interior appearance.
## 4. Physics Cost Control: 30-body active physics cap. Overflow fragments spawn as
##    frozen zero-cost collectibles. Exact total yield of 12 resource units preserved.
## 5. No Merging / No Fusion / No Scaling: Pieces never scale or fuse into giant bodies.
## 6. Full Vacuum Collection & Void Recovery: Fragments are vacuumed into inventory.
##    Out-of-bounds fragments recover to safe terrain so no resources are ever lost.

const TOTAL_VOXEL_RESOURCE_YIELD: int = ResourceBalance.VOXEL_RESOURCE_YIELD
const MAX_PHYSICAL_FRAGMENTS: int = 30

## Cached Voronoi templates: Dictionary[String, Array[Dictionary]]
## Keys: "cube", "ramp", "corner", "inner_corner"
## Value items: {"mesh": ArrayMesh, "shape": ConvexPolygonShape3D, "offset": Vector3}
static var _cached_voronoi_templates: Dictionary = {}

## Fallback primitive meshes & shapes (if pre-baked assets are missing)
static var _cached_phys_meshes: Array = []
static var _cached_phys_shapes: Array = []

## Material caches for physical fragments
static var _cached_phys_materials: Dictionary = {}
static var _cached_interior_materials: Dictionary = {}

## Cached resources for visual particle bursts (3 draw passes matching test assertions)
static var _cached_particle_passes: Array = []
static var _cached_particle_materials: Dictionary = {}
static var _cached_particle_process_mat: ParticleProcessMaterial = null

## GPUParticles3D emitter pool & trickle emitter
var _particle_pool: Array[GPUParticles3D] = []
var _particle_pool_idx: int = 0
const PARTICLE_POOL_SIZE: int = 6

var _trickle_emitter: GPUParticles3D = null
var _mine_trickle_timer: float = 0.0

## Centralized tracking of physical fragments for void recovery and 30-body limit
var _tracked_fragments: Array = []
var _fragment_lifecycle_timer: float = 0.0

func _ensure_cached_shard_resources() -> void:
	if not _cached_voronoi_templates.is_empty():
		return

	# 1. Load pre-baked Voronoi templates from manifest
	const MANIFEST_PATH := "res://assets/generated/fractures/manifest.json"
	if FileAccess.file_exists(MANIFEST_PATH):
		var t_asset_start: int = Time.get_ticks_msec()
		var file := FileAccess.open(MANIFEST_PATH, FileAccess.READ)
		if file != null:
			var json_text := file.get_as_text()
			file.close()
			var json := JSON.new()
			if json.parse(json_text) == OK and json.data is Dictionary:
				var manifest: Dictionary = json.data
				for sname in manifest.keys():
					var pieces_data: Array = manifest[sname]
					var loaded_pieces: Array = []
					for pdata in pieces_data:
						var m_path: String = pdata.get("mesh_path", "")
						var s_path: String = pdata.get("shape_path", "")
						var offset_arr: Array = pdata.get("offset", [0.0, 0.0, 0.0])
						var offset_vec := Vector3(float(offset_arr[0]), float(offset_arr[1]), float(offset_arr[2]))
						var mesh_res = load(m_path)
						var shape_res = load(s_path)
						if mesh_res != null and shape_res != null:
							loaded_pieces.append({
								"mesh": mesh_res,
								"shape": shape_res,
								"offset": offset_vec
							})
					if not loaded_pieces.is_empty():
						_cached_voronoi_templates[sname] = loaded_pieces
		var t_asset_elapsed: int = Time.get_ticks_msec() - t_asset_start
		print("[StartupTiming] Fragment asset loading took: %d ms, shapes: %s" % [t_asset_elapsed, _cached_voronoi_templates.keys()])

	# 2. Fallback primitive archetypes if pre-baked assets are unavailable
	if _cached_phys_meshes.is_empty():
		var pm1 := PrismMesh.new()
		pm1.size = Vector3(0.18, 0.14, 0.18)
		pm1.left_to_right = 0.35
		_cached_phys_meshes.append(pm1)
		var ps1 := BoxShape3D.new()
		ps1.size = Vector3(0.18, 0.14, 0.18)
		_cached_phys_shapes.append(ps1)

		var pm2 := PrismMesh.new()
		pm2.size = Vector3(0.16, 0.10, 0.22)
		pm2.left_to_right = 0.85
		_cached_phys_meshes.append(pm2)
		var ps2 := SphereShape3D.new()
		ps2.radius = 0.10
		_cached_phys_shapes.append(ps2)

		var bm := BoxMesh.new()
		bm.size = Vector3(0.20, 0.13, 0.16)
		_cached_phys_meshes.append(bm)
		var bs := BoxShape3D.new()
		bs.size = Vector3(0.20, 0.13, 0.16)
		_cached_phys_shapes.append(bs)

	# 3. Particle burst meshes (3 draw passes: BoxMesh, PrismMesh, SphereMesh)
	if _cached_particle_passes.is_empty():
		var p_bm := BoxMesh.new()
		p_bm.size = Vector3(0.08, 0.05, 0.07)
		_cached_particle_passes.append(p_bm)

		var p_pm := PrismMesh.new()
		p_pm.size = Vector3(0.07, 0.06, 0.07)
		p_pm.left_to_right = 0.35
		_cached_particle_passes.append(p_pm)

		var p_sm := SphereMesh.new()
		p_sm.radius = 0.04
		p_sm.height = 0.08
		p_sm.radial_segments = 6
		p_sm.rings = 3
		_cached_particle_passes.append(p_sm)

	if _cached_particle_process_mat == null:
		var pmat := ParticleProcessMaterial.new()
		pmat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
		pmat.emission_sphere_radius = 0.25
		pmat.direction = Vector3(0.0, 1.0, 0.0)
		pmat.spread = 75.0
		pmat.initial_velocity_min = 1.0
		pmat.initial_velocity_max = 2.4
		pmat.radial_velocity_min = 0.3
		pmat.radial_velocity_max = 1.1
		pmat.gravity = Vector3(0.0, -8.0, 0.0)
		pmat.angle_min = -180.0
		pmat.angle_max = 180.0
		pmat.angular_velocity_min = -180.0
		pmat.angular_velocity_max = 180.0
		pmat.scale_min = 0.7
		pmat.scale_max = 1.3
		var scale_curve := Curve.new()
		scale_curve.add_point(Vector2(0.0, 1.0))
		scale_curve.add_point(Vector2(0.7, 0.9))
		scale_curve.add_point(Vector2(1.0, 0.0))
		var scale_tex := CurveTexture.new()
		scale_tex.curve = scale_curve
		pmat.scale_curve = scale_tex
		_cached_particle_process_mat = pmat

## Returns exterior surface material matching the mined voxel.
## Prefers the exact shared terrain ShaderMaterial so fragments visually match
## the natural terrain surface (grass, dirt, stone shader & colors).
func _get_phys_material(block_type: StringName) -> Material:
	if _cached_phys_materials.has(block_type):
		return _cached_phys_materials[block_type] as Material
	var mat: Material = TerrainBlockyLibrary.get_shared_material(block_type)
	if mat == null:
		# Fallback StandardMaterial3D for unknown block types
		var fb := StandardMaterial3D.new()
		fb.albedo_color = _fragment_albedo(block_type)
		fb.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
		fb.roughness = 0.85
		fb.metallic = 0.0
		fb.cull_mode = BaseMaterial3D.CULL_BACK
		fb.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
		mat = fb
	_cached_phys_materials[block_type] = mat
	return mat

## Returns interior cleavage material with an authentic cross-section appearance.
func _get_interior_material(block_type: StringName) -> StandardMaterial3D:
	if _cached_interior_materials.has(block_type):
		return _cached_interior_materials[block_type] as StandardMaterial3D
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	mat.roughness = 0.95
	mat.metallic = 0.0
	mat.cull_mode = BaseMaterial3D.CULL_BACK
	mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED

	match block_type:
		&"grass":
			# Interior of grass is rich earthy subsoil / loam
			mat.albedo_color = Color(0.48, 0.32, 0.18)
		&"dirt":
			# Darker compact earth
			mat.albedo_color = Color(0.42, 0.28, 0.16)
		&"stone":
			# Fresh fractured chiseled rock
			mat.albedo_color = Color(0.42, 0.39, 0.35)
			mat.roughness = 0.92
		&"coal":
			# Matte dark charcoal seam
			mat.albedo_color = Color(0.12, 0.12, 0.13)
			mat.roughness = 0.85
		&"iron":
			# Raw iron ore vein in rock
			mat.albedo_color = Color(0.55, 0.52, 0.48)
			mat.metallic = 0.35
			mat.roughness = 0.70
		&"gold":
			# Rich gold flecked quartz vein
			mat.albedo_color = Color(0.78, 0.62, 0.15)
			mat.metallic = 0.55
			mat.roughness = 0.50
		_:
			var base_col := _fragment_albedo(block_type)
			mat.albedo_color = base_col.darkened(0.15)

	_cached_interior_materials[block_type] = mat
	return mat

func _get_particle_material(block_type: StringName) -> StandardMaterial3D:
	if _cached_particle_materials.has(block_type):
		return _cached_particle_materials[block_type] as StandardMaterial3D
	var mat := StandardMaterial3D.new()
	mat.albedo_color = _fragment_albedo(block_type)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	mat.roughness = 0.85
	mat.metallic = 0.0
	mat.cull_mode = BaseMaterial3D.CULL_BACK
	_cached_particle_materials[block_type] = mat
	return mat

## Maps terrain block type ID to fracture template shape name and Y-rotation angle.
func _get_fracture_template_info(block_type_id: int) -> Dictionary:
	match block_type_id:
		# Ramps: low edge faces the drop axis
		TerrainBlockyLibrary.BLOCK_GRASS_RAMP_PX:
			return {"shape": "ramp", "angle": 0.0}
		TerrainBlockyLibrary.BLOCK_GRASS_RAMP_NX:
			return {"shape": "ramp", "angle": PI}
		TerrainBlockyLibrary.BLOCK_GRASS_RAMP_PZ:
			return {"shape": "ramp", "angle": -PI * 0.5}
		TerrainBlockyLibrary.BLOCK_GRASS_RAMP_NZ:
			return {"shape": "ramp", "angle": PI * 0.5}
		# Outer corners: low corner toward (dir_x, dir_z)
		TerrainBlockyLibrary.BLOCK_GRASS_CORNER_PX_PZ:
			return {"shape": "corner", "angle": 0.0}
		TerrainBlockyLibrary.BLOCK_GRASS_CORNER_PX_NZ:
			return {"shape": "corner", "angle": PI * 0.5}
		TerrainBlockyLibrary.BLOCK_GRASS_CORNER_NX_PZ:
			return {"shape": "corner", "angle": -PI * 0.5}
		TerrainBlockyLibrary.BLOCK_GRASS_CORNER_NX_NZ:
			return {"shape": "corner", "angle": PI}
		# Inner corners: single low corner toward (dir_x, dir_z)
		TerrainBlockyLibrary.BLOCK_GRASS_INNER_PX_PZ:
			return {"shape": "inner_corner", "angle": 0.0}
		TerrainBlockyLibrary.BLOCK_GRASS_INNER_PX_NZ:
			return {"shape": "inner_corner", "angle": PI * 0.5}
		TerrainBlockyLibrary.BLOCK_GRASS_INNER_NX_PZ:
			return {"shape": "inner_corner", "angle": -PI * 0.5}
		TerrainBlockyLibrary.BLOCK_GRASS_INNER_NX_NZ:
			return {"shape": "inner_corner", "angle": PI}
		_:
			return {"shape": "cube", "angle": 0.0}

## Pre-warms particle pool and trickle emitters to eliminate main-thread shader compilation freezes.
func _warmup_particle_pool() -> void:
	var parent: Node = _get_debris_parent()
	if parent == null:
		return
	_ensure_cached_shard_resources()
	while _particle_pool.size() < PARTICLE_POOL_SIZE:
		var emitter := GPUParticles3D.new()
		emitter.amount = 12
		emitter.lifetime = 0.55
		emitter.one_shot = true
		emitter.explosiveness = 0.85
		emitter.draw_passes = 3
		emitter.draw_pass_1 = _cached_particle_passes[0] as Mesh
		emitter.draw_pass_2 = _cached_particle_passes[1] as Mesh
		emitter.draw_pass_3 = _cached_particle_passes[2] as Mesh
		emitter.process_material = _cached_particle_process_mat
		parent.add_child(emitter)
		emitter.emitting = false
		_particle_pool.append(emitter)

	if _trickle_emitter == null or not is_instance_valid(_trickle_emitter):
		_trickle_emitter = GPUParticles3D.new()
		_trickle_emitter.name = "MiningTrickleEmitter"
		_trickle_emitter.amount = 4
		_trickle_emitter.lifetime = 0.35
		_trickle_emitter.one_shot = true
		_trickle_emitter.explosiveness = 0.4
		_trickle_emitter.draw_passes = 1
		_trickle_emitter.draw_pass_1 = _cached_particle_passes[0] as Mesh
		_trickle_emitter.process_material = _cached_particle_process_mat
		parent.add_child(_trickle_emitter)
		_trickle_emitter.emitting = false

## Emits an inexpensive trickle of particles at hit point while holding LMB to mine.
func _spawn_mining_trickle(hit_pos: Vector3, block_type: StringName) -> void:
	if _trickle_emitter == null or not is_instance_valid(_trickle_emitter):
		_warmup_particle_pool()
	if _trickle_emitter == null:
		return
	var pmat := _get_particle_material(block_type)
	_trickle_emitter.material_override = pmat
	_trickle_emitter.global_position = hit_pos
	_trickle_emitter.restart()
	_trickle_emitter.emitting = true

## Visual burst: pooled reusable GPUParticles3D with 3 low-poly draw passes.
func _spawn_mining_particles(center: Vector3, block_type: StringName) -> void:
	_ensure_cached_shard_resources()
	var emitter: GPUParticles3D = _get_pooled_particle_emitter()
	if emitter == null:
		return

	var pmat := _get_particle_material(block_type)
	emitter.draw_pass_1 = _cached_particle_passes[0] as Mesh
	emitter.draw_pass_2 = _cached_particle_passes[1] as Mesh
	emitter.draw_pass_3 = _cached_particle_passes[2] as Mesh
	emitter.material_override = pmat
	emitter.global_position = center
	emitter.restart()
	emitter.emitting = true

func _get_pooled_particle_emitter() -> GPUParticles3D:
	var parent: Node = _get_debris_parent()
	if parent == null:
		return null

	for em in _particle_pool:
		if is_instance_valid(em) and not em.emitting:
			return em

	if _particle_pool.size() < PARTICLE_POOL_SIZE:
		var emitter := GPUParticles3D.new()
		emitter.amount = 12
		emitter.lifetime = 0.55
		emitter.one_shot = true
		emitter.explosiveness = 0.85
		emitter.draw_passes = 3
		emitter.draw_pass_1 = _cached_particle_passes[0] as Mesh
		emitter.draw_pass_2 = _cached_particle_passes[1] as Mesh
		emitter.draw_pass_3 = _cached_particle_passes[2] as Mesh
		emitter.process_material = _cached_particle_process_mat
		parent.add_child(emitter)
		_particle_pool.append(emitter)
		return emitter

	_particle_pool_idx = (_particle_pool_idx + 1) % _particle_pool.size()
	var recycled := _particle_pool[_particle_pool_idx]
	if is_instance_valid(recycled):
		return recycled
	return null

func _get_debris_parent() -> Node:
	if has_node("/root/GameWorld/DebrisContainer"):
		return get_node("/root/GameWorld/DebrisContainer")
	if get_parent() != null and get_parent().has_node("DebrisContainer"):
		return get_parent().get_node("DebrisContainer")
	if get_parent() != null:
		return get_parent()
	if is_inside_tree() and get_tree().current_scene != null:
		return get_tree().current_scene
	return get_tree().root if get_tree() != null else null

## Checks whether a fragment has solid voxel support beneath it.
func _is_fragment_supported(frag: Node3D) -> bool:
	var vox_world := _get_voxel_world()
	if vox_world == null:
		return false
	var pos := frag.global_position
	var below_cell := Vector3i(floori(pos.x), floori(pos.y - 0.2), floori(pos.z))
	if vox_world.has_method("is_solid_block"):
		return bool(vox_world.is_solid_block(below_cell))
	elif vox_world.has_method("get_voxel_at"):
		var v: StringName = vox_world.get_voxel_at(below_cell)
		return v != &"" and v != &"air"
	return false

## Counts actively moving physical rigid bodies towards the 30-body physics cap.
## Supported fragments that sleep naturally as dynamic rigid bodies do not consume active cap.
func _count_active_physical_fragments() -> int:
	var count: int = 0
	var i: int = _tracked_fragments.size() - 1
	while i >= 0:
		var ref: WeakRef = _tracked_fragments[i]
		var node: Node = ref.get_ref() as Node if ref != null else null
		if node == null or not is_instance_valid(node) or node.is_queued_for_deletion():
			_tracked_fragments.remove_at(i)
		elif node is RigidBody3D:
			var rb := node as RigidBody3D
			if not rb.freeze and not rb.sleeping:
				if rb.has_method("is_settled"):
					if not rb.is_settled():
						count += 1
				elif rb.linear_velocity.length_squared() > 0.04 or rb.angular_velocity.length_squared() > 0.04:
					count += 1
		i -= 1
	return count

## Spawns Voronoi fracture pieces inside the mined voxel, preserving original shape geometry.
## Preserves relative transforms, applies two-tone materials, and caps active physics at 30.
## Yields exactly TOTAL_VOXEL_RESOURCE_YIELD (12) total resource units across the pieces.
func _spawn_voxel_fragments_burst(center: Vector3, block_type: StringName, block_type_id: int = 0) -> void:
	var parent: Node = _get_debris_parent()
	if parent == null:
		return
	_ensure_cached_shard_resources()

	var ftype := String(block_type)
	var outer_mat := _get_phys_material(block_type)
	var inner_mat := _get_interior_material(block_type)

	var t_info := _get_fracture_template_info(block_type_id)
	var shape_name: String = t_info.get("shape", "cube")
	var angle_y: float = float(t_info.get("angle", 0.0))

	var pieces: Array = []
	if shape_name == "cube":
		var cube_variants: Array[String] = []
		for vname in ["cube", "cube_var1", "cube_var2"]:
			if _cached_voronoi_templates.has(vname) and not _cached_voronoi_templates[vname].is_empty():
				cube_variants.append(vname)
		if not cube_variants.is_empty():
			var picked_var: String = cube_variants[randi() % cube_variants.size()]
			pieces = _cached_voronoi_templates[picked_var]
	elif _cached_voronoi_templates.has(shape_name):
		pieces = _cached_voronoi_templates[shape_name]
	elif _cached_voronoi_templates.has("cube"):
		pieces = _cached_voronoi_templates["cube"]
		angle_y = 0.0

	var now_ms := Time.get_ticks_msec()
	var active_phys_count: int = _count_active_physical_fragments()

	if not pieces.is_empty():
		var piece_count: int = pieces.size()
		var base_val: int = TOTAL_VOXEL_RESOURCE_YIELD / piece_count
		var rem_val: int = TOTAL_VOXEL_RESOURCE_YIELD % piece_count

		for i in range(piece_count):
			var pdata: Dictionary = pieces[i]
			var p_mesh: Mesh = pdata["mesh"]
			var p_shape: Shape3D = pdata["shape"]
			var base_offset: Vector3 = pdata["offset"]
			var rotated_offset: Vector3 = base_offset.rotated(Vector3.UP, angle_y)

			var piece_val: int = base_val + (1 if i < rem_val else 0)

			var body: VoxelFragment = VoxelFragmentScript.new() as VoxelFragment
			body.add_to_group("fragments")
			body.set_meta("mined_fragment", true)
			body.set_meta("preserve_rotation", true)
			body.set_meta("material", ftype)
			body.set_meta("fragment_type", ftype)
			body.set_meta("spawn_time", now_ms)
			body.resource_value = piece_val

			body.collision_layer = DEBRIS_LAYER
			body.collision_mask = DEBRIS_COLLISION_MASK

			var mesh_inst := MeshInstance3D.new()
			mesh_inst.mesh = p_mesh
			mesh_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			if p_mesh.get_surface_count() > 1:
				mesh_inst.set_surface_override_material(0, inner_mat)
				mesh_inst.set_surface_override_material(1, outer_mat)
			else:
				mesh_inst.set_surface_override_material(0, inner_mat)

			var col := CollisionShape3D.new()
			col.shape = p_shape

			body.add_child(mesh_inst)
			body.add_child(col)
			parent.add_child(body)

			# Reconstruct original shape in voxel volume
			body.scale = Vector3.ONE
			body.rotation = Vector3(0.0, angle_y, 0.0)
			body.global_position = center + rotated_offset

			# Physics limit enforcement: 30 active bodies maximum
			if active_phys_count < MAX_PHYSICAL_FRAGMENTS:
				active_phys_count += 1
				body.freeze = false
				body.sleeping = false
				var outward_dir: Vector3 = (rotated_offset.normalized() + Vector3(randf_range(-0.15, 0.15), randf_range(0.1, 0.35), randf_range(-0.15, 0.15))).normalized()
				body.linear_velocity = outward_dir * randf_range(0.35, 0.8)
				body.angular_velocity = Vector3(randf_range(-1.2, 1.2), randf_range(-1.2, 1.2), randf_range(-1.2, 1.2))
			else:
				# Frozen overflow collectible (zero physics cost, fully vacuum collectible)
				body.freeze = true
				body.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
				body.sleeping = true
				body.linear_velocity = Vector3.ZERO
				body.angular_velocity = Vector3.ZERO

			_tracked_fragments.append(weakref(body))
	else:
		# Procedural fallback if pre-baked assets are unavailable
		var to_spawn: int = 6
		var base_val: int = TOTAL_VOXEL_RESOURCE_YIELD / to_spawn
		var rem_val: int = TOTAL_VOXEL_RESOURCE_YIELD % to_spawn
		for i in range(to_spawn):
			var arch_idx: int = i % _cached_phys_meshes.size()
			var piece_val: int = base_val + (rem_val if i == 0 else 0)
			var body: VoxelFragment = VoxelFragmentScript.new() as VoxelFragment
			body.add_to_group("fragments")
			body.set_meta("mined_fragment", true)
			body.set_meta("material", ftype)
			body.set_meta("fragment_type", ftype)
			body.set_meta("spawn_time", now_ms)
			body.resource_value = piece_val
			body.collision_layer = DEBRIS_LAYER
			body.collision_mask = DEBRIS_COLLISION_MASK

			var mesh_inst := MeshInstance3D.new()
			mesh_inst.mesh = _cached_phys_meshes[arch_idx] as Mesh
			mesh_inst.material_override = outer_mat
			mesh_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

			var col := CollisionShape3D.new()
			col.shape = _cached_phys_shapes[arch_idx] as Shape3D

			body.add_child(mesh_inst)
			body.add_child(col)
			parent.add_child(body)

			body.scale = Vector3.ONE
			body.global_position = center + Vector3(randf_range(-0.25, 0.25), randf_range(-0.25, 0.25), randf_range(-0.25, 0.25))
			if active_phys_count < MAX_PHYSICAL_FRAGMENTS:
				active_phys_count += 1
				body.freeze = false
				body.sleeping = false
				body.linear_velocity = Vector3(randf_range(-0.5, 0.5), randf_range(0.2, 0.6), randf_range(-0.5, 0.5))
			else:
				body.freeze = true
				body.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
				body.sleeping = true

			_tracked_fragments.append(weakref(body))

## Spawns one shard at pos with toss velocity (bag dump toss).
func _spawn_single_shard_fragment(pos: Vector3, toss_velocity: Vector3, ftype: String) -> void:
	var parent: Node = _get_debris_parent()
	if parent == null:
		return
	_ensure_cached_shard_resources()

	var btype := StringName(ftype)
	var outer_mat := _get_phys_material(btype)
	var inner_mat := _get_interior_material(btype)

	var p_mesh: Mesh = null
	var p_shape: Shape3D = null

	if _cached_voronoi_templates.has("cube") and not _cached_voronoi_templates["cube"].is_empty():
		var cube_pieces: Array = _cached_voronoi_templates["cube"]
		var pdata: Dictionary = cube_pieces[randi() % cube_pieces.size()]
		p_mesh = pdata["mesh"]
		p_shape = pdata["shape"]
	elif not _cached_phys_meshes.is_empty():
		var arch_idx: int = randi() % _cached_phys_meshes.size()
		p_mesh = _cached_phys_meshes[arch_idx] as Mesh
		p_shape = _cached_phys_shapes[arch_idx] as Shape3D

	if p_mesh == null or p_shape == null:
		return

	var body: VoxelFragment = VoxelFragmentScript.new() as VoxelFragment
	body.add_to_group("fragments")
	body.set_meta("mined_fragment", true)
	body.set_meta("material", ftype)
	body.set_meta("fragment_type", ftype)
	body.set_meta("spawn_time", Time.get_ticks_msec())
	body.resource_value = 1
	body.collision_layer = DEBRIS_LAYER
	body.collision_mask = DEBRIS_COLLISION_MASK

	var mesh_inst := MeshInstance3D.new()
	mesh_inst.mesh = p_mesh
	mesh_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if p_mesh.get_surface_count() > 1:
		mesh_inst.set_surface_override_material(0, inner_mat)
		mesh_inst.set_surface_override_material(1, outer_mat)
	else:
		mesh_inst.set_surface_override_material(0, inner_mat)

	var col := CollisionShape3D.new()
	col.shape = p_shape

	body.add_child(mesh_inst)
	body.add_child(col)
	parent.add_child(body)

	body.global_position = pos
	body.scale = Vector3.ONE
	body.linear_velocity = toss_velocity
	body.angular_velocity = Vector3(
		randf_range(-2.0, 2.0),
		randf_range(-2.0, 2.0),
		randf_range(-2.0, 2.0)
	)

	_tracked_fragments.append(weakref(body))

## Compatibility wrapper — single fragment delegates to burst spawner.
func _spawn_voxel_fragment(center: Vector3, block_type: StringName) -> void:
	_spawn_voxel_fragments_burst(center, block_type, 0)

## Detects resting fragments that have lost support when a voxel is mined and reactivates them.
## Wakes fragments in columns above mined cells so they can fall naturally under gravity.
func _wake_nearby_fragments(center: Vector3, _radius: float = 1.5) -> void:
	var x_min := center.x - 0.6
	var x_max := center.x + 0.6
	var z_min := center.z - 0.6
	var z_max := center.z + 0.6
	var y_min := center.y - 0.5
	var y_max := center.y + 64.0

	for ref in _tracked_fragments:
		if ref == null:
			continue
		var node: Node = ref.get_ref() as Node
		if node == null or not is_instance_valid(node) or node.is_queued_for_deletion():
			continue
		if not (node is RigidBody3D):
			continue
		var rb := node as RigidBody3D
		var pos := rb.global_position
		if pos.x >= x_min and pos.x <= x_max and pos.z >= z_min and pos.z <= z_max and pos.y >= y_min and pos.y <= y_max:
			rb.freeze = false
			rb.sleeping = false
			# Minimal downward nudge to immediately engage gravity if air is beneath
			rb.apply_central_impulse(Vector3(0.0, -0.01, 0.0))

## Prevents fragment scaling: preserves true Voronoi geometric shape scale.
func _update_fragment_scale(frag: Node3D) -> void:
	if is_instance_valid(frag):
		frag.scale = Vector3.ONE

func _find_safe_recovery_position(pos: Vector3) -> Vector3:
	var vox_world := _get_voxel_world()
	if vox_world != null and vox_world.has_method("get_highest_solid_y"):
		var ix := roundi(pos.x)
		var iz := roundi(pos.z)
		var sy := int(vox_world.get_highest_solid_y(ix, iz))
		if sy > 0:
			return Vector3(float(ix) + 0.5, float(sy) + 1.2, float(iz) + 0.5)
	return global_position + Vector3(0.0, 0.5, 0.0)

## Centralized lifecycle and void cleanup.
## Deletes fragments below void threshold (-35.0), unfreezes unsupported fragments so they never stay frozen in air,
## and lets supported fragments rest naturally as dynamic sleeping bodies.
func _process_fragment_lifecycle(delta: float) -> void:
	_fragment_lifecycle_timer += delta
	if _fragment_lifecycle_timer < 0.5:
		return
	_fragment_lifecycle_timer = 0.0

	var active_moving: int = _count_active_physical_fragments()

	# Prune dead weak references and manage support-aware activation
	var i: int = _tracked_fragments.size() - 1
	while i >= 0:
		var ref: WeakRef = _tracked_fragments[i]
		var node: Node = ref.get_ref() as Node if ref != null else null
		if node == null or not is_instance_valid(node) or node.is_queued_for_deletion():
			_tracked_fragments.remove_at(i)
		elif node is VoxelFragment:
			var frag := node as VoxelFragment
			if frag.global_position.y < -35.0:
				frag.queue_free()
				_tracked_fragments.remove_at(i)
			elif frag.freeze:
				if not _is_fragment_supported(frag):
					# Unsupported fragment floating in air: must fall
					if active_moving < MAX_PHYSICAL_FRAGMENTS:
						active_moving += 1
						frag.freeze = false
						frag.sleeping = false
						frag.apply_central_impulse(Vector3(0.0, -0.01, 0.0))
				else:
					# Supported fragment on ground: let it sleep naturally as dynamic body
					frag.freeze = false
					frag.sleeping = true
		i -= 1

# ── end Voronoi Procedural Mining-Fragment System ─────────────────────────────

func _disable_fragment_collision(frag: Node3D) -> void:
	if frag is CollisionObject3D:
		var co := frag as CollisionObject3D
		co.collision_layer = 0
		co.collision_mask = 0
	for child in frag.get_children():
		if child is CollisionShape3D:
			(child as CollisionShape3D).set_deferred("disabled", true)

func _enable_fragment_collision(frag: Node3D) -> void:
	if frag is CollisionObject3D:
		var co := frag as CollisionObject3D
		co.collision_layer = DEBRIS_LAYER
		co.collision_mask = DEBRIS_COLLISION_MASK
	for child in frag.get_children():
		if child is CollisionShape3D:
			(child as CollisionShape3D).set_deferred("disabled", false)

func _set_current_slot(slot: int) -> void:
	current_slot = clampi(slot, 1, 9)
	_update_bag_visual()
	if _bag_progress != null:
		_bag_progress.visible = (current_slot == 2)
	if _bag_contents_label != null:
		_bag_contents_label.visible = (current_slot == 2)
	if current_slot == 2:
		_refresh_available_materials()
	_update_slot_hud(true)

func _slot_display_name() -> String:
	match current_slot:
		2: return "Bag"
		3: return "Pickaxe"
		_: return "Slot %d" % current_slot

func _setup_slot_hud() -> void:
	if _slot_hud_layer != null:
		return
	_slot_hud_layer = CanvasLayer.new()
	_slot_hud_layer.name = "SlotBagHUD"
	_slot_hud_layer.layer = 20
	add_child(_slot_hud_layer)

	_slot_hud_label = Label.new()
	_slot_hud_label.name = "SlotBagLabel"
	_slot_hud_label.position = Vector2(16, 16)
	_slot_hud_label.add_theme_font_size_override("font_size", 18)
	_slot_hud_label.add_theme_color_override("font_color", Color(0.92, 0.95, 0.88))
	_slot_hud_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_slot_hud_label.add_theme_constant_override("outline_size", 4)
	_slot_hud_label.visible = false
	_slot_hud_layer.add_child(_slot_hud_label)

	_bag_progress = ProgressBar.new()
	_bag_progress.name = "BagProgressBar"
	_bag_progress.min_value = 0.0
	_bag_progress.max_value = float(bag_max_capacity)
	_bag_progress.value = float(bag_count)
	_bag_progress.show_percentage = false
	_bag_progress.visible = (current_slot == 2)
	_bag_progress.custom_minimum_size = Vector2(280, 14)
	_bag_progress.anchor_left = 0.5
	_bag_progress.anchor_right = 0.5
	_bag_progress.anchor_top = 0.5
	_bag_progress.anchor_bottom = 0.5
	_bag_progress.offset_left = -140.0
	_bag_progress.offset_right = 140.0
	_bag_progress.offset_top = 28.0
	_bag_progress.offset_bottom = 42.0
	_bag_progress.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color(0.55, 0.78, 0.42, 0.92)
	fill.set_corner_radius_all(3)
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.08, 0.09, 0.10, 0.55)
	bg.set_corner_radius_all(3)
	_bag_progress.add_theme_stylebox_override("fill", fill)
	_bag_progress.add_theme_stylebox_override("background", bg)
	_slot_hud_layer.add_child(_bag_progress)

	_bag_contents_label = Label.new()
	_bag_contents_label.name = "BagContentsLabel"
	_bag_contents_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_bag_contents_label.add_theme_font_size_override("font_size", 15)
	_bag_contents_label.add_theme_color_override("font_color", Color(0.92, 0.95, 0.88))
	_bag_contents_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_bag_contents_label.add_theme_constant_override("outline_size", 4)
	_bag_contents_label.anchor_left = 0.5
	_bag_contents_label.anchor_right = 0.5
	_bag_contents_label.anchor_top = 0.5
	_bag_contents_label.anchor_bottom = 0.5
	_bag_contents_label.offset_left = -220.0
	_bag_contents_label.offset_right = 220.0
	_bag_contents_label.offset_top = 46.0
	_bag_contents_label.offset_bottom = 72.0
	_bag_contents_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bag_contents_label.visible = (current_slot == 2)
	_slot_hud_layer.add_child(_bag_contents_label)

	_carry_hint_label = Label.new()
	_carry_hint_label.name = "CarryHintLabel"
	_carry_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_carry_hint_label.add_theme_font_size_override("font_size", 16)
	_carry_hint_label.add_theme_color_override("font_color", Color(0.95, 0.96, 0.88))
	_carry_hint_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_carry_hint_label.add_theme_constant_override("outline_size", 4)
	_carry_hint_label.anchor_left = 0.5
	_carry_hint_label.anchor_right = 0.5
	_carry_hint_label.anchor_top = 1.0
	_carry_hint_label.anchor_bottom = 1.0
	_carry_hint_label.offset_left = -280.0
	_carry_hint_label.offset_right = 280.0
	_carry_hint_label.offset_top = -72.0
	_carry_hint_label.offset_bottom = -44.0
	_carry_hint_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_carry_hint_label.visible = false
	_carry_hint_label.text = "[E] Station | [G] Drop | [F] Throw"
	_slot_hud_layer.add_child(_carry_hint_label)

func _format_bag_contents_label() -> String:
	# Rebuild list only — do not call _refresh_available_materials (would clear
	# selected_material when the bag empties mid-dump / mid-hold).
	available_materials.clear()
	for key in bag_contents.keys():
		if int(bag_contents[key]) > 0:
			available_materials.append(String(key))
	available_materials.sort()
	if available_materials.is_empty():
		return "(empty)"
	var parts: PackedStringArray = PackedStringArray()
	for key in available_materials:
		var count: int = int(bag_contents.get(key, 0))
		var display: String = String(key).capitalize()
		if String(key) == selected_material:
			parts.append(">[%s: %d]<" % [display.to_upper(), count])
		else:
			parts.append("%s: %d" % [display, count])
	# Show emptied-but-still-selected material so the player knows to scroll.
	if not selected_material.is_empty() and int(bag_contents.get(selected_material, 0)) <= 0:
		parts.append(">[%s: 0]<" % selected_material.capitalize().to_upper())
	return " | ".join(parts)

func _update_bag_hud_preserving_selection() -> void:
	var keep_sel: String = selected_material
	_update_slot_hud(true)
	# Slot HUD must not auto-pick another material after a dump empties one.
	if not keep_sel.is_empty():
		selected_material = keep_sel

func _update_slot_hud(force: bool = false) -> void:
	_sync_bag_count()
	if _bag_progress != null:
		_bag_progress.max_value = float(bag_max_capacity)
		_bag_progress.value = float(bag_count)
		_bag_progress.visible = (current_slot == 2)
	if _bag_contents_label != null:
		_bag_contents_label.visible = (current_slot == 2)
		_bag_contents_label.text = _format_bag_contents_label()
	if _slot_hud_label == null:
		return
	if not force and current_slot == _last_ui_slot and bag_count == _last_ui_bag_count \
	and selected_material == _last_ui_selected:
		return
	_last_ui_slot = current_slot
	_last_ui_bag_count = bag_count
	_last_ui_selected = selected_material
	_slot_hud_label.visible = _debug_overlay_enabled
	_slot_hud_label.text = "Active Slot: [%s]\nBag: [%d/%d]" % [
		_slot_display_name(), bag_count, bag_max_capacity
	]

func _setup_bag_visual() -> void:
	if _bag_mesh != null:
		return
	var cam := body_camera
	if cam == null:
		cam = get_node_or_null("Head/BodyCamera") as Camera3D
	if cam == null:
		return

	_bag_mesh = MeshInstance3D.new()
	_bag_mesh.name = "PlaceholderBag"
	var bag_box := BoxMesh.new()
	bag_box.size = Vector3(0.28, 0.34, 0.18)
	var bag_mat := StandardMaterial3D.new()
	bag_mat.albedo_color = Color(0.35, 0.22, 0.12)
	bag_mat.roughness = 0.85
	bag_box.material = bag_mat
	_bag_mesh.mesh = bag_box
	_bag_mesh.position = Vector3(0.32, -0.28, -0.55)
	_bag_mesh.rotation_degrees = Vector3(12.0, -18.0, 8.0)
	cam.add_child(_bag_mesh)
	_update_bag_visual()

func _update_bag_visual() -> void:
	if _bag_mesh == null:
		return
	_bag_mesh.visible = (current_slot == 2)

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
	var hit = vt.raycast(cam.global_position, -cam.global_transform.basis.z, max_ray_distance)
	if hit == null:
		return null
	return hit.position as Vector3i

func _complete_mining_action() -> void:
	var vox_world := _get_voxel_world()
	var mine_target := target_voxel_pos if target_voxel_pos != _INVALID_VOXEL else target_terrain_cell
	if vox_world != null and vox_world.has_method("mine_voxel"):
		# Authoritative path: returns original type, clears TYPE+SDF+INDICES, saves, emits once.
		var raw_block_id: int = vox_world.get_block_type_id(mine_target) if vox_world.has_method("get_block_type_id") else 0
		var mined_type: StringName = vox_world.mine_voxel(mine_target)
		if not mined_type.is_empty():
			var res_key := String(mined_type)
			inventory[res_key] = inventory.get(res_key, 0) + 1
			_apply_mine_sdf_sphere(mine_target)
			var voxel_center: Vector3 = Vector3(mine_target) + Vector3(0.5, 0.5, 0.5)
			_spawn_mining_particles(voxel_center, mined_type)
			_spawn_voxel_fragments_burst(voxel_center, mined_type, raw_block_id)
			_wake_nearby_fragments(voxel_center, 1.5)
			var inv_mgr := _get_inventory_manager()
			if inv_mgr != null:
				inv_mgr.add_material(mined_type, 1)
			target_face_status = "✓ Mined 1 %s!" % BlockTypeCatalog.get_display_name(mined_type)
			target_face_changed.emit(has_target, mine_target, target_face_dir, target_face_status)
			if build_hud != null and build_hud.has_method("show_mine_feedback"):
				build_hud.show_mine_feedback(mined_type, 1)
	_reset_mining_state()
	_hide_terrain_target_visuals()

func _ensure_terrain_target_visuals() -> void:
	if _terrain_outline != null:
		return
	# Clean, thin, semi-transparent subtle box highlight (Task 4: alpha = 0.25, thin lines)
	_outline_mat = StandardMaterial3D.new()
	_outline_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_outline_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_outline_mat.albedo_color = Color(1.0, 1.0, 1.0, 0.25)
	_outline_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_outline_mat.no_depth_test = true
	_outline_mat.render_priority = 10

	_terrain_outline = MeshInstance3D.new()
	_terrain_outline.name = "TerrainTargetOutline"
	_terrain_outline.top_level = true
	_terrain_outline.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_terrain_outline.mesh = _build_outline_mesh(0.005)
	_terrain_outline.material_override = _outline_mat
	add_child(_terrain_outline)
	_terrain_outline.visible = false

	_crack_textures.clear()
	for stage in range(4):
		_crack_textures.append(_make_crack_texture(stage))

	# World-space Decal stuck to the mined surface (hit point + normal).
	_terrain_crack = Decal.new()
	_terrain_crack.name = "TerrainMineCrackDecal"
	_terrain_crack.top_level = true
	_terrain_crack.size = Vector3(1.05, 1.05, 0.22)
	_terrain_crack.cull_mask = 0xFFFFF
	if not _crack_textures.is_empty():
		_terrain_crack.texture_albedo = _crack_textures[0]
	_terrain_crack.modulate = Color(1, 1, 1, 0.9)
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

func _build_outline_mesh(thickness: float = 0.005) -> ArrayMesh:
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
	# Decal projects along local -Y; align +Y with surface normal so it sticks to the face.
	return Basis(tangent, n, bitangent)

func _update_terrain_target_visuals(cell: Vector3i, progress01: float) -> void:
	_ensure_terrain_target_visuals()
	var center := Vector3(float(cell.x) + 0.5, float(cell.y) + 0.5, float(cell.z) + 0.5)
	var n := _target_hit_normal.normalized() if _target_hit_normal.length_squared() > 0.0001 else Vector3.UP
	# Subtle voxel outline stays axis-aligned (readable target); independent of player yaw.
	_terrain_outline.global_transform = Transform3D(Basis.IDENTITY, center)
	_terrain_outline.visible = true

	var stage: int = clampi(int(floor(progress01 * 4.0)), 0, 3) if progress01 > 0.02 else -1
	if stage < 0:
		_terrain_crack.visible = false
		_crack_stage = -1
		return
	# Crack Decal at raycast hit point, aligned to hit_normal.
	var hitch: Vector3 = _target_hit_point if _target_hit_point != Vector3.ZERO else (center + n * 0.51)
	var crack_pos := hitch + n * 0.01
	_terrain_crack.global_transform = Transform3D(_basis_from_normal(n), crack_pos)
	_terrain_crack.visible = true
	if stage != _crack_stage:
		_crack_stage = stage
		if stage >= 0 and stage < _crack_textures.size():
			_terrain_crack.texture_albedo = _crack_textures[stage]

func _hide_terrain_target_visuals() -> void:
	if _terrain_outline != null:
		_terrain_outline.visible = false
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
	var wish_planar := Vector3(velocity.x, 0.0, velocity.z)

	move_and_slide()

	# FootPusher Area3D: push nearby fragment rigidbodies outward/forward without
	# applying any impulse back to the player's CharacterBody3D.
	# MUST ONLY affect small fragments (Collision Layer 4 / Debris).
	# Logs and Planks (Collision Layer 3 / Resources) must NOT be pushed by the foot area.
	if _foot_pusher != null and is_instance_valid(_foot_pusher):
		for overlap_body in _foot_pusher.get_overlapping_bodies():
			if not is_instance_valid(overlap_body):
				continue
			if not (overlap_body is RigidBody3D):
				continue
			var rb_fp := overlap_body as RigidBody3D
			# Logs and Planks must NEVER be pushed by the foot area
			if rb_fp.is_in_group("logs") or rb_fp.is_in_group("planks") or rb_fp.is_in_group("debris_resources"):
				continue
			if rb_fp.collision_layer & RESOURCE_LAYER != 0:
				continue
			if not (rb_fp.is_in_group("fragments") or (rb_fp.collision_layer & DEBRIS_LAYER != 0) or rb_fp.mass <= 0.15):
				continue
			var push_dir_fp: Vector3 = rb_fp.global_position - global_position
			push_dir_fp.y = 0.0
			if push_dir_fp.length_squared() < 0.0001:
				# Directly underfoot: push forward.
				push_dir_fp = -global_transform.basis.z
			else:
				push_dir_fp = push_dir_fp.normalized()

			var p_planar := Vector3(velocity.x, 0.0, velocity.z)
			var p_speed := p_planar.length()
			var push_dir: Vector3
			if p_speed > 0.1:
				push_dir = (push_dir_fp * 0.65 + p_planar.normalized() * 0.35).normalized()
			else:
				push_dir = push_dir_fp
			push_dir.y = 0.08
			rb_fp.sleeping = false
			if rb_fp.freeze and rb_fp.freeze_mode == RigidBody3D.FREEZE_MODE_STATIC:
				rb_fp.freeze = false
			var push_impulse: float = maxf(p_speed * 0.8, 1.4) * rb_fp.mass * 8.0 * delta
			rb_fp.apply_central_impulse(push_dir * push_impulse)

	# Push dynamic RigidBody3D (debris) and unbonded grid blocks upon physical contact
	var hit_light_debris := false
	for i in get_slide_collision_count():
		var col := get_slide_collision(i)
		var collider := col.get_collider()
		if collider is RigidBody3D:
			var rb := collider as RigidBody3D
			var push_dir := -col.get_normal()
			push_dir.y = 0.0
			if push_dir.length_squared() > 0.001:
				push_dir = push_dir.normalized()
				# Light fragments: sweep with feet — strong push, no reverse player force.
				# Logs/Planks (Collision Layer 3 / Resources) remain solid and interact with player's body normally.
				var is_frag: bool = rb.is_in_group("fragments") or (rb.collision_layer & DEBRIS_LAYER != 0)
				var is_resource: bool = rb.is_in_group("logs") or rb.is_in_group("planks") or (rb.collision_layer & RESOURCE_LAYER != 0)
				var is_light: bool = is_frag and not is_resource and (rb.mass <= 0.15)
				var impulse_scale: float = 3.5 if is_light else 1.0
				rb.sleeping = false
				rb.apply_central_impulse(push_dir * push_force * impulse_scale * delta)
				if is_light:
					hit_light_debris = true
					# Cancel any reverse velocity the light body might impart via contact.
					rb.linear_velocity = Vector3(
						push_dir.x * maxf(rb.linear_velocity.length(), walk_speed * 0.85),
						rb.linear_velocity.y,
						push_dir.z * maxf(rb.linear_velocity.length(), walk_speed * 0.85)
					)
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

	# Light debris must never stop player locomotion (feet-sweep feel).
	if hit_light_debris and wish_planar.length_squared() > 0.001:
		velocity.x = wish_planar.x
		velocity.z = wish_planar.z

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
	for held in _held_logs:
		if is_instance_valid(held):
			excludes.append(held.get_rid())
	query.exclude = excludes
	# World + selectable placed craft blocks (layer 1). Pure debris fragments stay on layer 4 only
	# and are ignored here so fragment piles don't block voxel mining aim.
	query.collision_mask = 1

	var result := space_state.intersect_ray(query)

	# Separate debris-only ray for log pickup / debris-island interact (does not block mining aim).
	var debris_query := PhysicsRayQueryParameters3D.create(ray_origin, ray_end)
	debris_query.exclude = excludes
	debris_query.collision_mask = RESOURCE_LAYER | DEBRIS_LAYER
	var debris_result := space_state.intersect_ray(debris_query)
	target_log = null
	target_carryable = null
	if not debris_result.is_empty():
		var debris_col: Object = debris_result.collider
		if debris_col is RigidBody3D and _is_carryable_item(debris_col as RigidBody3D):
			target_log = debris_col as RigidBody3D
			target_carryable = target_log

	if result.is_empty():
		has_target = false
		_craft_floor_valid = false
		target_is_debris = false
		target_debris_island = null
		target_debris_cell = null
		target_is_terrain = false
		target_tree = null
		target_chopping_block = null
		target_pallet = null
		target_worker = null
		# Keep carryable from debris ray so E-grab still works through empty air→item.
		if is_instance_valid(target_carryable):
			has_target = true
			can_place_target = false
			target_face_status = _carryable_status_text(target_carryable)
			target_face_changed.emit(true, Vector3i.ZERO, Vector3i.ZERO, target_face_status)
			_hide_terrain_target_visuals()
			if preview_ghost != null and (debris_grabber == null or not debris_grabber.is_grabbing):
				preview_ghost.hide_preview()
			return
		# Debris island via debris ray when world ray missed.
		if not debris_result.is_empty() and debris_result.collider is DebrisIsland:
			_apply_debris_island_hit(grid, debris_result)
			return
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
	_craft_floor_valid = hit_normal.dot(Vector3.UP) > 0.55
	target_tree = _resolve_tree_target(hit_collider)
	target_chopping_block = _resolve_chopping_block(hit_collider)
	target_pallet = _resolve_pallet(hit_collider)
	target_worker = _resolve_worker(hit_collider)

	# Trees / choppable props: skip voxel targeting so mining never SDF-subtracts them.
	if target_tree != null:
		_craft_floor_valid = false
		target_chopping_block = null
		target_pallet = null
		target_is_debris = false
		target_debris_island = null
		target_debris_cell = null
		target_is_terrain = false
		target_face_dir = _normal_to_cell_offset(hit_normal)
		target_place_cell = grid.world_to_cell(hit_pos + hit_normal * (grid.cell_size * 0.5))
		target_remove_cell = target_place_cell
		can_place_target = false
		target_face_status = "Pine Tree (LMB: Chop)"
		target_face_changed.emit(true, target_remove_cell, target_face_dir, target_face_status)
		_hide_terrain_target_visuals()
		if preview_ghost != null and (debris_grabber == null or not debris_grabber.is_grabbing):
			preview_ghost.hide_preview()
		return
	# Worker targeting — must come before chopping block / pallet so workers are identifiable.
	if is_instance_valid(target_worker):
		_craft_floor_valid = false
		target_tree = null
		target_chopping_block = null
		target_pallet = null
		target_is_debris = false
		target_debris_island = null
		target_debris_cell = null
		target_is_terrain = false
		can_place_target = false
		target_face_status = "Hauler Worker (Hold G: Dismantle)"
		target_face_changed.emit(true, Vector3i.ZERO, Vector3i.ZERO, target_face_status)
		_hide_terrain_target_visuals()
		if preview_ghost != null and (debris_grabber == null or not debris_grabber.is_grabbing):
			preview_ghost.hide_preview()
		return

	# Chopping block station targeting.
	if is_instance_valid(target_chopping_block):
		_craft_floor_valid = false
		target_tree = null
		target_pallet = null
		target_is_debris = false
		target_debris_island = null
		target_debris_cell = null
		target_is_terrain = false
		can_place_target = false
		var has_placed_log: bool = bool(target_chopping_block.get("has_log"))
		if has_placed_log:
			target_face_status = "Chopping Block (Hold RMB: Chop / Dismantle)"
		elif _held_is_type("log"):
			target_face_status = "Chopping Block (E: Place Log | Hold RMB: Menu)"
		else:
			target_face_status = "Chopping Block (Hold RMB: Menu)"
		target_face_changed.emit(true, Vector3i.ZERO, Vector3i.ZERO, target_face_status)
		_hide_terrain_target_visuals()
		if preview_ghost != null and (debris_grabber == null or not debris_grabber.is_grabbing):
			preview_ghost.hide_preview()
		return

	# Player-placed / pallet-crafted 1x1x1 rigidbodies — before pallet so E can harvest.
	if hit_collider is RigidBody3D and _is_selectable_placed_block(hit_collider as RigidBody3D):
		_apply_placed_craft_block_hit(grid, hit_collider as RigidBody3D, hit_pos, hit_normal)
		return

	# Pallet station targeting.
	if is_instance_valid(target_pallet):
		_craft_floor_valid = false
		target_tree = null
		target_chopping_block = null
		target_is_debris = false
		target_debris_island = null
		target_debris_cell = null
		target_is_terrain = false
		can_place_target = false
		if _held_is_type("plank") or _held_is_type("log"):
			target_face_status = "Pallet (E: Store | Hold RMB: Craft)"
		elif is_instance_valid(target_carryable) and _can_pick_up_carryable(target_carryable):
			target_face_status = _carryable_status_text(target_carryable)
		else:
			target_face_status = "Pallet (E: Withdraw | Hold RMB: Craft)"
		target_face_changed.emit(true, Vector3i.ZERO, Vector3i.ZERO, target_face_status)
		_hide_terrain_target_visuals()
		if preview_ghost != null and (debris_grabber == null or not debris_grabber.is_grabbing):
			preview_ghost.hide_preview()
		return

	if hit_collider is StaticBody3D:
		target_tree = null
		target_chopping_block = null
		target_pallet = null
		# Keep target_log from debris ray (aim passes through logs).
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
			if _held_is_type("log") and _craft_floor_valid:
				target_face_status = "Natural %s (Hold RMB: Craft)" % mat_disp
			elif is_instance_valid(target_carryable) and _can_pick_up_carryable(target_carryable):
				target_face_status = "%s | %s underneath" % [
					_carryable_status_text(target_carryable), mat_disp
				]
			else:
				target_face_status = "Natural %s (LMB: Break, RMB: Place)" % mat_disp
			_update_terrain_target_visuals(target_terrain_cell, 0.0)
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
			# Same selection outline as natural terrain when aiming at player-placed grid blocks.
			if grid.has_block(target_remove_cell):
				_update_terrain_target_visuals(target_remove_cell, 0.0)
			else:
				_hide_terrain_target_visuals()

		target_face_changed.emit(true, target_remove_cell, target_face_dir, target_face_status)

	elif hit_collider is DebrisIsland:
		# Debris islands live on layer 4; main aim ray normally misses them.
		_apply_debris_island_hit(grid, result)

	else:
		# Non-StaticBody hit (e.g. engine terrain collider) — classify natural terrain.
		target_tree = null
		target_chopping_block = null
		target_pallet = null
		# Keep target_log from debris ray.
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
			# Placement cell is outside the hit face (already offset above).
			var grid_valid_t: bool = grid.can_place_block(target_place_cell)
			var blocked_debris_t: bool = false
			if orchestrator != null:
				blocked_debris_t = orchestrator.is_cell_blocked_by_debris(target_place_cell, grid.cell_size)
			var overlaps_t: bool = is_cell_overlapping_player(target_place_cell, grid.cell_size)
			var blocked_terrain_t: bool = vox_world2.is_solid_block(target_place_cell)
			can_place_target = grid_valid_t and not blocked_debris_t and not overlaps_t and not blocked_terrain_t
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

	# Overlay DebrisIsland targeting from debris ray (main aim ignores layer 4).
	if not target_is_debris and not debris_result.is_empty() and debris_result.collider is DebrisIsland:
		_apply_debris_island_hit(grid, debris_result, false)

	if preview_ghost != null:
		if is_placing_station:
			preview_ghost.hide_preview()
		elif area_selection_step == AreaSelectionStep.CORNER_2:
			var curr_target := target_remove_cell if (grid != null and grid.has_block(target_remove_cell)) else target_place_cell
			var min_c := Vector3i(mini(area_corner_1.x, curr_target.x), mini(area_corner_1.y, curr_target.y), mini(area_corner_1.z, curr_target.z))
			var max_c := Vector3i(maxi(area_corner_1.x, curr_target.x), maxi(area_corner_1.y, curr_target.y), maxi(area_corner_1.z, curr_target.z))
			preview_ghost.update_area_preview(min_c, max_c, grid.cell_size)
		elif debris_grabber != null and debris_grabber.is_grabbing:
			pass # DebrisGrabber updates the preview ghost for recovery
		elif _is_holding_building_block() and has_target:
			# Task 4: PreviewGhost visible ONLY while holding a 1x1x1 building block.
			var hit_pt: Vector3 = _target_hit_point + _target_hit_normal * 0.05
			var snap_c := Vector3i(int(floor(hit_pt.x)), int(floor(hit_pt.y)), int(floor(hit_pt.z)))
			preview_ghost.update_preview(snap_c, true, grid.cell_size if grid != null else 1.0)
		elif not _is_holding_building_block():
			# Not holding a building block — always hide hologram.
			preview_ghost.hide_preview()
		elif target_is_debris and target_debris_island != null and target_debris_island.is_moving():
			preview_ghost.hide_preview()
		else:
			preview_ghost.hide_preview()

func _apply_debris_island_hit(grid: Node, hit: Dictionary, replace_status: bool = true) -> void:
	var hit_collider: DebrisIsland = hit.collider as DebrisIsland
	if hit_collider == null:
		return
	var hit_pos: Vector3 = hit.position
	var hit_normal: Vector3 = hit.normal
	var shape_idx: int = hit.shape
	has_target = true
	target_tree = null
	target_chopping_block = null
	target_pallet = null
	target_is_terrain = false if replace_status else target_is_terrain
	target_is_debris = true
	target_debris_island = hit_collider
	target_debris_cell = hit_collider.get_cell_from_shape_hit(shape_idx, hit_pos)
	_craft_floor_valid = false

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

	if not replace_status:
		return

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
		# Outline on the integer cell under the hit (same visual as terrain/grid).
		var outline_cell := Vector3i(
			int(floor(hit_pos.x)),
			int(floor(hit_pos.y)),
			int(floor(hit_pos.z))
		)
		_update_terrain_target_visuals(outline_cell, 0.0)
		target_face_changed.emit(true, Vector3i.ZERO, Vector3i.ZERO, target_face_status)
	else:
		target_face_status = ""
		_hide_terrain_target_visuals()
		target_face_changed.emit(false, Vector3i.ZERO, Vector3i.ZERO, "")

func _normal_to_cell_offset(normal: Vector3) -> Vector3i:
	var abs_norm := normal.abs()
	if abs_norm.y >= abs_norm.x and abs_norm.y >= abs_norm.z:
		return Vector3i(0, 1 if normal.y > 0 else -1, 0)
	elif abs_norm.x >= abs_norm.y and abs_norm.x >= abs_norm.z:
		return Vector3i(1 if normal.x > 0 else -1, 0, 0)
	else:
		return Vector3i(0, 0, 1 if normal.z > 0 else -1)

func _is_selectable_placed_block(body: RigidBody3D) -> bool:
	if body == null or not is_instance_valid(body):
		return false
	if _held_logs.has(body):
		return false
	if body.is_in_group("fragments"):
		return false
	return body.is_in_group("craft_blocks") or bool(body.get_meta("is_craft_block", false))

func _apply_placed_craft_block_hit(grid: Node, body: RigidBody3D, hit_pos: Vector3, hit_normal: Vector3) -> void:
	has_target = true
	target_tree = null
	target_chopping_block = null
	target_pallet = null
	target_log = body
	target_carryable = body
	target_is_debris = false
	target_debris_island = null
	target_debris_cell = null
	target_is_terrain = false
	_craft_floor_valid = hit_normal.dot(Vector3.UP) > 0.55
	var center: Vector3 = TerrainBlockyLibrary.snap_world_to_grid_center(body.global_position)
	target_remove_cell = Vector3i(int(floor(center.x)), int(floor(center.y)), int(floor(center.z)))
	target_face_dir = _normal_to_cell_offset(hit_normal)
	target_place_cell = grid.world_to_cell(hit_pos + hit_normal * (grid.cell_size * 0.5))
	# Keep exact integer alignment for adjacent placement.
	var place_center := TerrainBlockyLibrary.snap_world_to_grid_center(
		Vector3(float(target_place_cell.x) + 0.5, float(target_place_cell.y) + 0.5, float(target_place_cell.z) + 0.5)
	)
	target_place_cell = Vector3i(
		int(floor(place_center.x)),
		int(floor(place_center.y)),
		int(floor(place_center.z))
	)
	var grid_valid: bool = grid.can_place_block(target_place_cell)
	var blocked_by_debris: bool = false
	if orchestrator != null:
		blocked_by_debris = orchestrator.is_cell_blocked_by_debris(target_place_cell, grid.cell_size)
	var overlaps_player: bool = is_cell_overlapping_player(target_place_cell, grid.cell_size)
	var blocked_by_terrain: bool = false
	var vox_world := _get_voxel_world()
	if vox_world != null and vox_world.has_method("is_solid_block"):
		blocked_by_terrain = vox_world.is_solid_block(target_place_cell)
	can_place_target = grid_valid and not blocked_by_terrain and not blocked_by_debris and not overlaps_player
	target_face_status = _carryable_status_text(body)
	_update_terrain_target_visuals(target_remove_cell, 0.0)
	target_face_changed.emit(true, target_remove_cell, target_face_dir, target_face_status)
	if preview_ghost != null and (debris_grabber == null or not debris_grabber.is_grabbing):
		if can_place_target:
			preview_ghost.update_preview(target_place_cell, true, grid.cell_size)
		else:
			preview_ghost.hide_preview()

func _ensure_log_hold_markers() -> void:
	if _log_hold_markers.size() >= MAX_HOLD_MARKERS:
		return
	var cam := body_camera
	if cam == null:
		cam = get_node_or_null("Head/BodyCamera") as Camera3D
	if cam == null:
		return
	# Vertical stack in front of camera (index 0 bottom-most); 4 slots for planks/blocks.
	while _log_hold_markers.size() < MAX_HOLD_MARKERS:
		var i: int = _log_hold_markers.size()
		var marker := Marker3D.new()
		marker.name = "HoldMarker_%d" % i
		cam.add_child(marker)
		_log_hold_markers.append(marker)
	_layout_hold_markers()

func _hold_stack_spacing() -> float:
	# After hand rotation, planks are thin in Y; logs use diameter; blocks use full height.
	if _held_is_type("plank"):
		return ChoppingBlock.PLANK_SIZE.x + 0.06
	if _held_is_type("log"):
		return ChoppingBlock.LOG_RADIUS * 2.0 + 0.08
	return 0.28

func _layout_hold_markers(pull_z: float = 0.0) -> void:
	var spacing: float = _hold_stack_spacing()
	for i in range(_log_hold_markers.size()):
		var marker: Marker3D = _log_hold_markers[i]
		if is_instance_valid(marker):
			# Craft blocks use a lower-right position so they don't obstruct the crosshair.
			# Logs/planks keep the original offset; building blocks shift to (0.5, -0.6, -1.0).
			if _is_holding_building_block():
				marker.position = Vector3(0.5, -0.6 + (float(i) * spacing), -1.0 + pull_z)
			else:
				marker.position = Vector3(0.35, -0.4 + (float(i) * spacing), -0.6 + pull_z)

func _process_held_item_snagging(_delta: float) -> void:
	if _held_logs.is_empty():
		return
	var cam := body_camera
	if cam == null:
		cam = get_node_or_null("Head/BodyCamera") as Camera3D
	if cam == null:
		return

	var cam_pos: Vector3 = cam.global_position
	var fwd: Vector3 = -cam.global_transform.basis.z
	var right: Vector3 = cam.global_transform.basis.x
	var up: Vector3 = cam.global_transform.basis.y
	var hold_target: Vector3 = cam_pos + right * 0.35 - up * 0.4 + fwd * 0.65

	var space_state := get_world_3d().direct_space_state
	if space_state == null:
		return

	var query := PhysicsRayQueryParameters3D.create(cam_pos, hold_target, 1)
	var excl: Array[RID] = [self.get_rid()]
	for item in _held_logs:
		if is_instance_valid(item):
			excl.append(item.get_rid())
	query.exclude = excl

	var hit := space_state.intersect_ray(query)
	if not hit.is_empty():
		var hit_pos: Vector3 = hit.position as Vector3
		var dist: float = (hit_pos - cam_pos).length()
		if dist < 0.25:
			_drop_one_held_item()
		else:
			var pull: float = clampf(0.65 - dist, 0.0, 0.45)
			_layout_hold_markers(pull)
	else:
		_layout_hold_markers(0.0)

func _update_carry_hint_ui() -> void:
	if _carry_hint_label == null:
		return
	if _held_logs.is_empty():
		_carry_hint_label.visible = false
		return
	_carry_hint_label.text = "[E] Station | [G] Drop | [F] Throw"
	_carry_hint_label.visible = true

func _restack_held_items() -> void:
	_ensure_log_hold_markers()
	_layout_hold_markers()
	for i in range(_held_logs.size()):
		var item: RigidBody3D = _held_logs[i]
		if not is_instance_valid(item) or i >= _log_hold_markers.size():
			continue
		var marker: Marker3D = _log_hold_markers[i]
		var cur_parent: Node = item.get_parent()
		if cur_parent != marker:
			if cur_parent != null:
				cur_parent.remove_child(item)
			marker.add_child(item)
		item.position = Vector3.ZERO
		_apply_held_item_visual(item, _get_carry_type(item))
	_update_carry_hint_ui()

func _apply_held_item_visual(item: RigidBody3D, ctype: String) -> void:
	if item == null or not is_instance_valid(item):
		return
	# Logs (Y-up cylinder): roll onto side so length runs L-R across the view.
	# Planks (tall Y box): lay flat/horizontal L-R, stacked in Y.
	# Craft blocks: axis-aligned in hand, scaled down so they don't obstruct the crosshair.
	if ctype == "log":
		item.rotation_degrees = Vector3(0.0, 0.0, 90.0)
		item.scale = Vector3.ONE
	elif ctype == "plank":
		item.rotation_degrees = Vector3(0.0, 0.0, 90.0)
		item.scale = Vector3.ONE
	else:
		item.rotation_degrees = Vector3.ZERO
		# Scale building blocks down while held so they only cover the bottom-right corner.
		item.scale = Vector3(0.5, 0.5, 0.5)

func _apply_drop_orientation(item: RigidBody3D, ctype: String) -> void:
	if item == null or not is_instance_valid(item):
		return
	# Resting pose on the ground: logs lie flat; planks lie flat; blocks stay upright.
	if ctype == "log":
		item.rotation_degrees = Vector3(0.0, randf_range(0.0, 360.0), 90.0)
	elif ctype == "plank":
		item.rotation_degrees = Vector3(90.0, randf_range(0.0, 360.0), 0.0)
	else:
		item.rotation_degrees = Vector3.ZERO

func _get_carry_type(body: RigidBody3D) -> String:
	if body == null or not is_instance_valid(body):
		return ""
	if body.has_meta("carry_type"):
		return String(body.get_meta("carry_type"))
	if body.is_in_group("logs") or bool(body.get_meta("is_log", false)):
		return "log"
	if body.is_in_group("planks") or bool(body.get_meta("is_plank", false)):
		return "plank"
	if body.is_in_group("craft_blocks") or bool(body.get_meta("is_craft_block", false)):
		return String(body.get_meta("material", "stone"))
	return ""

func _max_for_carry_type(carry_type: String) -> int:
	match carry_type:
		"log":
			return MAX_HELD_LOGS
		"plank":
			return MAX_HELD_PLANKS
		"dirt", "stone", "grass", "brick", "wood":
			return MAX_HELD_BLOCKS
		_:
			return 0

func _current_held_type() -> String:
	if _held_logs.is_empty():
		return ""
	return _get_carry_type(_held_logs[0])

func _held_is_type(carry_type: String) -> bool:
	return not _held_logs.is_empty() and _current_held_type() == carry_type

func _held_count_of(carry_type: String) -> int:
	if not _held_is_type(carry_type):
		return 0
	return _held_logs.size()

func _is_holding_building_block() -> bool:
	if not _held_logs.is_empty():
		var ctype := _current_held_type()
		if BlockTypeCatalog.has_type(StringName(ctype)) or ctype == "dirt" or ctype == "stone" or ctype == "grass" or ctype == "brick" or ctype == "wood":
			return true
		if _held_logs[0].is_in_group("craft_blocks") or bool(_held_logs[0].get_meta("is_craft_block", false)):
			return true
	return false

func _get_held_building_block_type() -> StringName:
	if not _held_logs.is_empty():
		var ctype := _current_held_type()
		if not ctype.is_empty():
			return StringName(ctype)
	return &""

func _is_carryable_item(body: RigidBody3D) -> bool:
	if body == null or not is_instance_valid(body):
		return false
	if _held_logs.has(body):
		return false
	if body.is_in_group("tree") or body is DebrisIsland:
		return false
	if body.is_in_group("fragments"):
		return false
	return not _get_carry_type(body).is_empty()

func _is_carryable_log(body: RigidBody3D) -> bool:
	return _is_carryable_item(body) and _get_carry_type(body) == "log"

func _can_pick_up_carryable(body: RigidBody3D) -> bool:
	if not _is_carryable_item(body):
		return false
	var ctype: String = _get_carry_type(body)
	var max_n: int = _max_for_carry_type(ctype)
	if max_n <= 0:
		return false
	if _held_logs.is_empty():
		return true
	if _current_held_type() != ctype:
		return false
	return _held_logs.size() < max_n

func _carryable_status_text(body: RigidBody3D) -> String:
	var ctype: String = _get_carry_type(body)
	var max_n: int = _max_for_carry_type(ctype)
	var held_n: int = _held_count_of(ctype)
	var label: String = ctype.capitalize()
	if ctype == "log":
		label = "Log"
	elif ctype == "plank":
		label = "Plank"
	elif ctype == "dirt":
		label = "Dirt Block"
	elif ctype == "stone":
		label = "Stone Block"
	elif ctype == "grass":
		label = "Grass Block"
	return "%s (E: Carry %d/%d | G: Drop | F: Throw)" % [label, held_n, max_n]

func _pick_up_log(log_body: RigidBody3D) -> void:
	_pick_up_carryable(log_body)

func _pick_up_carryable(item: RigidBody3D) -> void:
	_ensure_log_hold_markers()
	if not _can_pick_up_carryable(item):
		return
	if _log_hold_markers.is_empty():
		return
	var ctype: String = _get_carry_type(item)
	var slot: int = _held_logs.size()
	if slot >= _log_hold_markers.size():
		return
	var pickup_pos: Vector3 = item.global_position
	var is_resource: bool = item.is_in_group("logs") or item.is_in_group("planks") or ctype == "log" or ctype == "plank"
	_layout_hold_markers()
	var marker: Marker3D = _log_hold_markers[slot]
	item.freeze = true
	item.sleeping = true
	item.collision_layer = 0
	item.collision_mask = 0
	item.linear_velocity = Vector3.ZERO
	item.angular_velocity = Vector3.ZERO
	var parent_node: Node = item.get_parent()
	if parent_node != null:
		parent_node.remove_child(item)
	marker.add_child(item)
	item.position = Vector3.ZERO
	_apply_held_item_visual(item, ctype)
	_held_logs.append(item)
	target_log = null
	target_carryable = null
	_restack_held_items()
	# Whenever a Log/Resource is picked up, wake nearby bodies to prevent floating stacks:
	if is_resource and is_inside_tree():
		ChoppingBlock.wake_nearby_bodies(get_tree(), pickup_pos, 2.5)

func _release_held_item_to_world(item: RigidBody3D, throw_speed: float) -> void:
	if throw_speed <= 3.0:
		_drop_one_held_item_instance(item)
	else:
		_throw_one_held_item_instance(item)

func _drop_one_held_item_instance(item: RigidBody3D) -> void:
	if item == null or not is_instance_valid(item):
		return
	var world_parent: Node = get_parent() if get_parent() != null else (get_tree().current_scene if is_inside_tree() else null)
	if world_parent == null:
		item.queue_free()
		return
	var holder: Node = item.get_parent()
	if holder != null:
		holder.remove_child(item)
	world_parent.add_child(item)

	var ctype: String = _get_carry_type(item)
	var cam := get_active_camera()
	var cam_pos: Vector3 = cam.global_position if cam != null else (global_position + Vector3(0.0, 1.5, 0.0))
	var aim_dir: Vector3 = -cam.global_transform.basis.z if cam != null else -global_transform.basis.z
	var drop_pos: Vector3 = cam_pos + aim_dir * 1.5

	# Clamp to raycast hit if obstacle/floor is closer than 1.5m (Task 4)
	var space_state := get_world_3d().direct_space_state
	if space_state != null:
		var ray_query := PhysicsRayQueryParameters3D.create(cam_pos, cam_pos + aim_dir * 1.5, 1)
		ray_query.exclude = [self.get_rid()]
		var res := space_state.intersect_ray(ray_query)
		if not res.is_empty():
			drop_pos = (res.position as Vector3) - aim_dir * 0.15

	# Reset scale to full size before returning to the world.
	item.scale = Vector3.ONE

	if ctype == "dirt" or ctype == "stone" or ctype == "grass":
		item.global_transform = Transform3D(Basis.IDENTITY, drop_pos)
		item.collision_layer = 1 | RESOURCE_LAYER
		item.collision_mask = RESOURCE_COLLISION_MASK
	elif ctype == "log" or ctype == "plank":
		item.global_position = drop_pos
		_apply_drop_orientation(item, ctype)
		item.collision_layer = RESOURCE_LAYER
		item.collision_mask = RESOURCE_COLLISION_MASK
	else:
		item.global_position = drop_pos
		_apply_drop_orientation(item, ctype)
		item.collision_layer = DEBRIS_LAYER
		item.collision_mask = DEBRIS_COLLISION_MASK

	item.freeze = false
	item.sleeping = false
	item.continuous_cd = true
	item.linear_velocity = Vector3.ZERO
	item.angular_velocity = Vector3.ZERO
	if (ctype == "log" or ctype == "plank") and is_inside_tree():
		ChoppingBlock.wake_nearby_bodies(get_tree(), drop_pos, 2.5)

func _throw_one_held_item_instance(item: RigidBody3D) -> void:
	if item == null or not is_instance_valid(item):
		return
	var world_parent: Node = get_parent() if get_parent() != null else (get_tree().current_scene if is_inside_tree() else null)
	if world_parent == null:
		item.queue_free()
		return
	var holder: Node = item.get_parent()
	if holder != null:
		holder.remove_child(item)
	world_parent.add_child(item)

	var ctype: String = _get_carry_type(item)
	var cam := get_active_camera()
	var throw_dir: Vector3 = -cam.global_transform.basis.z if cam != null else -global_transform.basis.z
	var spawn_pos: Vector3 = (cam.global_position + throw_dir * 0.8) if cam != null else (global_position + Vector3(0.0, 1.2, 0.0) + throw_dir * 0.8)

	# Reset scale to full size before throwing.
	item.scale = Vector3.ONE

	if ctype == "dirt" or ctype == "stone" or ctype == "grass":
		item.global_transform = Transform3D(Basis.IDENTITY, spawn_pos)
		item.collision_layer = 1 | RESOURCE_LAYER
		item.collision_mask = RESOURCE_COLLISION_MASK
	elif ctype == "log" or ctype == "plank":
		item.global_position = spawn_pos
		_apply_drop_orientation(item, ctype)
		item.collision_layer = RESOURCE_LAYER
		item.collision_mask = RESOURCE_COLLISION_MASK
	else:
		item.global_position = spawn_pos
		_apply_drop_orientation(item, ctype)
		item.collision_layer = DEBRIS_LAYER
		item.collision_mask = DEBRIS_COLLISION_MASK

	item.freeze = false
	item.sleeping = false
	item.continuous_cd = true
	# Throw key ('F'): strictly -camera.global_transform.basis.z * 12.0
	item.linear_velocity = throw_dir * 12.0
	item.angular_velocity = Vector3.ZERO
	if (ctype == "log" or ctype == "plank") and is_inside_tree():
		ChoppingBlock.wake_nearby_bodies(get_tree(), spawn_pos, 2.5)

func _drop_one_held_item() -> void:
	if _held_logs.is_empty():
		return
	var item: RigidBody3D = _held_logs.pop_back()
	if not is_instance_valid(item):
		_restack_held_items()
		return
	_drop_one_held_item_instance(item)
	_restack_held_items()

func _drop_one_held_log() -> void:
	_drop_one_held_item()

func _throw_one_held_item() -> void:
	if _held_logs.is_empty():
		return
	var item: RigidBody3D = _held_logs.pop_back()
	if not is_instance_valid(item):
		_restack_held_items()
		return
	_throw_one_held_item_instance(item)
	_restack_held_items()

func _consume_one_held_item() -> RigidBody3D:
	if _held_logs.is_empty():
		return null
	var item: RigidBody3D = _held_logs.pop_back()
	if is_instance_valid(item):
		# Reset scale before consuming/placing to avoid the placed block spawning at 0.5×.
		item.scale = Vector3.ONE
		var holder: Node = item.get_parent()
		if holder != null:
			holder.remove_child(item)
		item.queue_free()
	_restack_held_items()
	return item

func _drop_all_held_logs() -> void:
	while not _held_logs.is_empty():
		_drop_one_held_item()

## Places a crafted 1x1x1 building block on the world grid at floor(hit_pos) + Vector3(0.5, 0.5, 0.5) (Task 3).
func _place_held_craft_block() -> void:
	var grid := grid_system
	if grid == null and has_node("/root/GridSystem"):
		grid = get_node("/root/GridSystem")
	if grid == null:
		return

	var hit_p := _target_hit_point
	var hit_n := _target_hit_normal
	var place_pt := hit_p + hit_n * 0.05
	var snap_cell := Vector3i(
		int(floor(place_pt.x)),
		int(floor(place_pt.y)),
		int(floor(place_pt.z))
	)

	if not grid.can_place_block(snap_cell):
		return
	if is_cell_overlapping_player(snap_cell, grid.cell_size):
		return
	if orchestrator != null and orchestrator.is_cell_blocked_by_debris(snap_cell, grid.cell_size):
		return
	var vox := _get_voxel_world()
	if vox != null and vox.has_method("is_solid_block") and vox.is_solid_block(snap_cell):
		return

	var b_type := _get_held_building_block_type()
	if not grid.place_block(snap_cell, b_type):
		return

	# Lightly-cemented: bond adjacent touching neighbors
	var joint_sys: Node = null
	if has_node("/root/JointSystem"):
		joint_sys = get_node("/root/JointSystem")
	if joint_sys != null and joint_sys.has_method("bond_all_adjacent_neighbors"):
		joint_sys.bond_all_adjacent_neighbors(snap_cell)

	# Consumes 1 held block
	if not _held_logs.is_empty():
		_consume_one_held_item()
	else:
		var inv_mgr := _get_inventory_manager()
		if inv_mgr != null:
			inv_mgr.set_material_count(b_type, inv_mgr.get_material_count(b_type) - 1)

	var bp_mgr := _get_blueprint_manager()
	if bp_mgr != null and bp_mgr.has_method("notify_intentional_block_placed"):
		var placed_b: BlockData = grid.get_block(snap_cell)
		if placed_b != null:
			bp_mgr.notify_intentional_block_placed(snap_cell, placed_b)

func _can_open_craft_radial() -> bool:
	if current_state != State.BODY_CONTROL:
		return false
	if is_placing_station:
		return false
	if _radial_menu != null and is_instance_valid(_radial_menu):
		return false
	# Aiming at a station → station radial (craft / chop / dismantle).
	if is_instance_valid(target_pallet) or is_instance_valid(target_chopping_block):
		return true
	# Slot 2 dumps on RMB; don't open construction radial unless on a station (above).
	if current_slot == 2:
		return false
	# Slot 1 (empty hands / tool) OR currently holding carryables → construction radial.
	if current_slot == 1 or not _held_logs.is_empty():
		return true
	return false

func _craft_radial_option_count() -> int:
	return _build_craft_radial_options().size()

func _pallet_craft_required_count() -> int:
	if is_instance_valid(target_pallet) and target_pallet.has_method("get_craft_required_count"):
		return int(target_pallet.call("get_craft_required_count"))
	return 8 * 8

func _build_pallet_craft_options() -> Array:
	var options: Array = []
	if not is_instance_valid(target_pallet):
		return options
	var stored: Dictionary = {}
	var stored_variant: Variant = target_pallet.get("stored_materials")
	if stored_variant is Dictionary:
		stored = stored_variant
	var assigned: String = str(target_pallet.get("assigned_material"))
	var required_count: int = _pallet_craft_required_count()
	var stone_n: int = int(stored.get("stone", 0))
	var dirt_n: int = int(stored.get("dirt", 0))
	if assigned == "" or assigned == "stone":
		options.append({
			"id": "Craft Stone Blocks",
			"text": "Craft Stone Blocks (Cost: %d)" % required_count,
			"enabled": assigned == "stone" and stone_n >= required_count,
		})
	if assigned == "" or assigned == "dirt":
		options.append({
			"id": "Craft Dirt Blocks",
			"text": "Craft Dirt Blocks (Cost: %d)" % required_count,
			"enabled": assigned == "dirt" and dirt_n >= required_count,
		})
	return options

func _build_chopping_block_options() -> Array:
	var has_log_on_block: bool = false
	if is_instance_valid(target_chopping_block):
		has_log_on_block = bool(target_chopping_block.get("has_log"))
	return [
		{
			"id": "Chop Log",
			"text": "Chop Log → 2 Planks",
			"enabled": has_log_on_block,
		},
		{
			"id": "Dismantle Station",
			"text": "Dismantle Station",
			"enabled": true,
		},
	]

func _build_craft_radial_options() -> Array:
	# Station radials take priority when aiming at a crafting station.
	if is_instance_valid(target_chopping_block):
		return _build_chopping_block_options()
	if is_instance_valid(target_pallet):
		var pallet_opts: Array = _build_pallet_craft_options()
		if not pallet_opts.is_empty():
			return pallet_opts
	# Universal Construction Menu: always list stations with costs; disable if unaffordable.
	var can_chop: bool = _held_is_type("log")
	var can_pallet: bool = _held_count_of("plank") >= 4
	var can_worker: bool = _held_is_type("log") or _held_count_of("plank") >= 2
	return [
		{
			"id": "Chopping Block",
			"text": "Chopping Block (Cost: 1 Log)",
			"enabled": can_chop,
		},
		{
			"id": "Pallet",
			"text": "Pallet (Cost: 4 Planks)",
			"enabled": can_pallet,
		},
		{
			"id": "Spawn Worker",
			"text": "Spawn Worker (Cost: 2 Planks or 1 Log)",
			"enabled": can_worker,
		},
	]

func _open_craft_radial_menu() -> void:
	if not _can_open_craft_radial():
		return
	var options: Array = _build_craft_radial_options()
	if options.is_empty():
		return
	# Keep MOUSE_MODE_CAPTURED — RadialMenu aims via virtual_mouse + relative motion.
	# Disabled slices still render (reduced opacity); only enabled picks enter hologram mode.
	_radial_menu = RadialMenuScene.instantiate()
	add_child(_radial_menu)
	if _radial_menu.has_method("open"):
		_radial_menu.open(options)
	if _radial_menu.has_signal("option_selected"):
		_radial_menu.option_selected.connect(_on_craft_option_selected)
	if _radial_menu.has_signal("cancelled"):
		_radial_menu.cancelled.connect(_on_craft_radial_cancelled)
	_radial_menu.tree_exiting.connect(_on_craft_radial_closed)

func _on_craft_option_selected(option_name: String) -> void:
	if option_name == "Craft Stone Blocks":
		if is_instance_valid(target_pallet) and target_pallet.has_method("craft_batch"):
			target_pallet.call("craft_batch", "stone")
		return
	if option_name == "Craft Dirt Blocks":
		if is_instance_valid(target_pallet) and target_pallet.has_method("craft_batch"):
			target_pallet.call("craft_batch", "dirt")
		return
	if option_name == "Chop Log":
		if is_instance_valid(target_chopping_block) and target_chopping_block.has_method("try_chop"):
			target_chopping_block.call("try_chop")
		return
	if option_name == "Dismantle Station":
		if is_instance_valid(target_chopping_block) and target_chopping_block.has_method("dismantle"):
			target_chopping_block.call("dismantle")
			target_chopping_block = null
		return
	if option_name == "Chopping Block" or option_name == "Pallet" or option_name == "Spawn Worker":
		_begin_station_placement(option_name)

func _on_craft_radial_cancelled() -> void:
	pass

func _on_craft_radial_closed() -> void:
	_radial_menu = null

func _begin_station_placement(station_name: String) -> void:
	if station_name == "Chopping Block" and not _held_is_type("log"):
		return
	if station_name == "Pallet" and _held_count_of("plank") < 4:
		return
	if station_name == "Spawn Worker" and not (_held_is_type("log") or _held_count_of("plank") >= 2):
		return
	is_placing_station = true
	station_to_place = station_name
	_clear_station_ghost()
	if preview_ghost != null:
		preview_ghost.hide_preview()

	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.25, 0.95, 0.4, 0.38)
	mat.roughness = 1.0
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	var ghost_instance: Node3D = null
	if station_name == "Pallet":
		ghost_instance = PalletScene.instantiate() as Node3D
	elif station_name == "Spawn Worker":
		ghost_instance = WorkerScene.instantiate() as Node3D
	else:
		ghost_instance = ChoppingBlockScene.instantiate() as Node3D

	if ghost_instance == null:
		is_placing_station = false
		return

	ghost_instance.name = "StationGhost"
	_strip_for_hologram(ghost_instance, mat)

	station_ghost_mesh = ghost_instance
	var parent_node: Node = get_parent() if get_parent() != null else (get_tree().current_scene if is_inside_tree() else null)
	if parent_node == null:
		station_ghost_mesh.queue_free()
		station_ghost_mesh = null
		is_placing_station = false
		return
	parent_node.add_child(station_ghost_mesh)
	station_ghost_mesh.visible = false
	_update_station_ghost()

func _strip_for_hologram(node: Node, mat: StandardMaterial3D) -> void:
	node.set_script(null)
	node.set_process(false)
	node.set_physics_process(false)
	node.set_process_input(false)
	node.set_process_unhandled_input(false)
	if node is CollisionShape3D:
		(node as CollisionShape3D).disabled = true
	elif node is CollisionPolygon3D:
		(node as CollisionPolygon3D).disabled = true
	if node is CollisionObject3D:
		(node as CollisionObject3D).collision_layer = 0
		(node as CollisionObject3D).collision_mask = 0
	if node is Area3D:
		(node as Area3D).monitoring = false
		(node as Area3D).monitorable = false
	if node is NavigationObstacle3D:
		(node as NavigationObstacle3D).avoidance_enabled = false
	if node is Label3D:
		(node as Label3D).visible = false
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for child in node.get_children():
		_strip_for_hologram(child, mat)

func _station_ghost_half_height() -> float:
	return 0.0

func _align_station_transform(hit_point: Vector3, hit_normal: Vector3) -> Transform3D:
	var n: Vector3 = hit_normal.normalized()
	if n.length_squared() < 0.0001:
		n = Vector3.UP
	var fwd: Vector3 = -global_transform.basis.z
	fwd.y = 0.0
	if fwd.length_squared() < 0.0001:
		fwd = Vector3.FORWARD
	fwd = fwd.normalized()
	var x_axis: Vector3 = fwd.cross(n).normalized()
	if x_axis.length_squared() < 0.0001:
		x_axis = Vector3.RIGHT
	var z_axis: Vector3 = x_axis.cross(n).normalized()
	# Real scenes have floor-aligned origins at y=0
	var origin: Vector3 = hit_point
	return Transform3D(Basis(x_axis, n, z_axis), origin)

func _update_station_ghost() -> void:
	if not is_placing_station or station_ghost_mesh == null or not is_instance_valid(station_ghost_mesh):
		return
	if has_target and _craft_floor_valid:
		station_ghost_mesh.visible = true
		station_ghost_mesh.global_transform = _align_station_transform(_target_hit_point, _target_hit_normal)
	else:
		station_ghost_mesh.visible = false

func _clear_station_ghost() -> void:
	if station_ghost_mesh != null and is_instance_valid(station_ghost_mesh):
		station_ghost_mesh.queue_free()
	station_ghost_mesh = null

func _confirm_station_placement() -> void:
	if not is_placing_station:
		return
	if station_to_place != "Chopping Block" and station_to_place != "Pallet" and station_to_place != "Spawn Worker":
		_cancel_station_placement()
		return
	if station_ghost_mesh == null or not is_instance_valid(station_ghost_mesh) or not station_ghost_mesh.visible:
		return

	var place_xform: Transform3D = station_ghost_mesh.global_transform
	var parent_node: Node = get_parent() if get_parent() != null else (get_tree().current_scene if is_inside_tree() else null)

	if station_to_place == "Chopping Block":
		if not _held_is_type("log"):
			_cancel_station_placement()
			return
		_consume_one_held_item()
		if parent_node != null:
			var block: Node3D = ChoppingBlockScene.instantiate() as Node3D
			parent_node.add_child(block)
			block.global_transform = place_xform
	elif station_to_place == "Pallet":
		if _held_count_of("plank") < 4:
			_cancel_station_placement()
			return
		for _i in range(4):
			_consume_one_held_item()
		if parent_node != null:
			var pallet: Node3D = PalletScene.instantiate() as Node3D
			parent_node.add_child(pallet)
			pallet.global_transform = place_xform
	elif station_to_place == "Spawn Worker":
		if _held_is_type("log"):
			_consume_one_held_item()
		elif _held_count_of("plank") >= 2:
			_consume_one_held_item()
			_consume_one_held_item()
		else:
			_cancel_station_placement()
			return
		if parent_node != null:
			var worker: Node3D = WorkerScene.instantiate() as Node3D
			parent_node.add_child(worker)
			var w_xform: Transform3D = place_xform
			var nav_map: RID = get_world_3d().navigation_map if get_world_3d() != null else RID()
			if nav_map.is_valid():
				var closest: Vector3 = NavigationServer3D.map_get_closest_point(nav_map, w_xform.origin)
				if closest != Vector3.ZERO and closest.distance_squared_to(w_xform.origin) < 16.0:
					w_xform.origin = closest + Vector3.UP * 0.05
			worker.global_transform = w_xform

	_clear_station_ghost()
	is_placing_station = false
	station_to_place = ""

func spawn_worker_at_cursor() -> Node3D:
	var parent_node: Node = get_parent() if get_parent() != null else (get_tree().current_scene if is_inside_tree() else null)
	if parent_node == null:
		return null
	var spawn_pos: Vector3 = global_position + (-global_transform.basis.z * 2.0)
	if has_target and _target_hit_point != Vector3.ZERO:
		spawn_pos = _target_hit_point + Vector3.UP * 0.1
	var nav_map: RID = get_world_3d().navigation_map if get_world_3d() != null else RID()
	if nav_map.is_valid():
		var closest: Vector3 = NavigationServer3D.map_get_closest_point(nav_map, spawn_pos)
		if closest != Vector3.ZERO and closest.distance_squared_to(spawn_pos) < 16.0:
			spawn_pos = closest + Vector3.UP * 0.05
	var worker: Node3D = WorkerScene.instantiate() as Node3D
	parent_node.add_child(worker)
	worker.global_position = spawn_pos
	return worker

func _cancel_station_placement() -> void:
	_clear_station_ghost()
	is_placing_station = false
	station_to_place = ""

func _handle_interact_action() -> void:
	if current_state != State.BODY_CONTROL:
		return

	# Manual carry grab (E) first — pallet craft blocks must be harvestable before withdraw.
	if is_instance_valid(target_carryable) and _can_pick_up_carryable(target_carryable):
		_pick_up_carryable(target_carryable)
		return
	if is_instance_valid(target_log) and _can_pick_up_carryable(target_log):
		_pick_up_carryable(target_log)
		return

	# Manual store onto pallet (plank, log, or ANY 1x1x1 building block).
	if is_instance_valid(target_pallet) and target_pallet.has_method("try_store"):
		if not _held_logs.is_empty():
			var store_type: String = _current_held_type()
			if bool(target_pallet.call("try_store", store_type)):
				_consume_one_held_item()
				return
		# Empty hands / bag space: withdraw assigned material from pallet.
		if _try_withdraw_from_pallet():
			return

	# Place a held log onto a chopping block.
	if is_instance_valid(target_chopping_block) and _held_is_type("log") \
	and target_chopping_block.has_method("try_place_log") \
	and not bool(target_chopping_block.get("has_log")):
		_consume_one_held_item()
		target_chopping_block.call("try_place_log")
		return

	if debris_grabber == null:
		return

	if debris_grabber.is_grabbing:
		debris_grabber.release()
	else:
		if target_is_debris and is_instance_valid(target_debris_island) and target_debris_cell != null:
			var block_data: BlockData = null
			if target_debris_island.constituent_blocks.has(target_debris_cell):
				block_data = target_debris_island.constituent_blocks[target_debris_cell]
			# ── Top-down dismantling rule ─────────────────────────────────────────
			# A block can only be grabbed if there is NO solid block directly above it.
			# This enforces top-down removal order for structural dismantling.
			if _is_block_covered_above(target_debris_cell):
				var hud := _get_build_hud()
				if hud != null and hud.has_method("show_mine_feedback"):
					hud.show_mine_feedback(&"stone", 0)  # visual feedback pulse
				target_face_status = "Blocked! Remove the block above first."
				target_face_changed.emit(true, target_debris_cell, target_face_dir, target_face_status)
				return
			# ─────────────────────────────────────────────────────────────────────
			debris_grabber.try_grab(target_debris_island, target_debris_cell, block_data)

func _try_withdraw_from_pallet() -> bool:
	if not is_instance_valid(target_pallet) or not target_pallet.has_method("try_withdraw"):
		return false
	if not bool(target_pallet.call("can_withdraw")):
		return false
	var result: Variant = target_pallet.call("try_withdraw")
	if not (result is Dictionary) or result.is_empty():
		return false
	var mat: String = str(result.get("material", ""))
	var kind: String = str(result.get("kind", ""))
	var count: int = int(result.get("count", 0))
	if mat.is_empty() or count <= 0:
		return false
	if kind == "fragments":
		if _bag_total() >= bag_max_capacity:
			if target_pallet.has_method("refund_material"):
				target_pallet.call("refund_material", mat, count)
			return false
		var space: int = bag_max_capacity - _bag_total()
		var take: int = mini(count, space)
		bag_contents[mat] = int(bag_contents.get(mat, 0)) + take
		_sync_bag_count()
		_refresh_available_materials()
		_update_bag_hud_preserving_selection()
		if take < count and target_pallet.has_method("refund_material"):
			target_pallet.call("refund_material", mat, count - take)
		return true
	# kind == "item": spawn a physical log/plank and pick it up if carry space allows.
	var body: RigidBody3D = null
	if mat == "log":
		body = ChoppingBlock.make_log_body()
	elif mat == "plank":
		body = ChoppingBlock.make_plank_body()
	else:
		body = Pallet.make_craft_block_body(mat)
	if body == null:
		return false
	var parent_node: Node = get_parent() if get_parent() != null else get_tree().current_scene
	if parent_node == null:
		body.queue_free()
		return false
	parent_node.add_child(body)
	var cam := get_active_camera()
	if cam != null:
		body.global_position = cam.global_position - cam.global_transform.basis.z * 1.2
	else:
		body.global_position = global_position + Vector3(0, 1.2, -1.0)
	body.linear_velocity = Vector3.ZERO
	body.angular_velocity = Vector3.ZERO
	if _can_pick_up_carryable(body):
		_pick_up_carryable(body)
	return true

## Returns true if there is a solid block or collision shape directly above `cell`
## (1 grid unit up). Used to enforce the top-down structural dismantling rule.
func _is_block_covered_above(cell: Variant) -> bool:
	if not is_inside_tree():
		return false
	# Accept Vector3i or Vector3
	var cell_v3i: Vector3i
	if cell is Vector3i:
		cell_v3i = cell as Vector3i
	elif cell is Vector3:
		cell_v3i = Vector3i(int(floor((cell as Vector3).x)), int(floor((cell as Vector3).y)), int(floor((cell as Vector3).z)))
	else:
		return false

	# First: fast VoxelTool check for natural terrain one cell above.
	var vox_world := _get_voxel_world()
	if vox_world != null and vox_world.has_method("is_solid_block"):
		var above_cell: Vector3i = cell_v3i + Vector3i(0, 1, 0)
		if bool(vox_world.is_solid_block(above_cell)):
			return true

	# Second: fast GridSystem check for player-placed blocks above.
	var grid := grid_system
	if grid == null and has_node("/root/GridSystem"):
		grid = get_node("/root/GridSystem")
	if grid != null and grid.has_method("has_block"):
		var above_cell: Vector3i = cell_v3i + Vector3i(0, 1, 0)
		if bool(grid.has_block(above_cell)):
			return true

	# Third: physics ray from cell center upward by 1.02 units (catches debris islands & statics).
	var world_3d: World3D = get_world_3d()
	if world_3d == null or not world_3d.space.is_valid():
		return false
	var direct_state: PhysicsDirectSpaceState3D = PhysicsServer3D.space_get_direct_state(world_3d.space)
	if direct_state == null:
		return false
	var cell_center: Vector3 = Vector3(float(cell_v3i.x) + 0.5, float(cell_v3i.y) + 0.5, float(cell_v3i.z) + 0.5)
	var ray_from: Vector3 = cell_center + Vector3(0.0, 0.51, 0.0)
	var ray_to: Vector3 = cell_center + Vector3(0.0, 1.52, 0.0)
	var params := PhysicsRayQueryParameters3D.create(ray_from, ray_to)
	params.exclude = [get_rid()]
	# Check world (layer 1), resources (layer 3), and debris (layer 4).
	params.collision_mask = 1 | RESOURCE_LAYER | DEBRIS_LAYER
	var hit := direct_state.intersect_ray(params)
	return not hit.is_empty()

func _handle_recover_action() -> void:
	# Legacy 'R' stash mechanic removed — pressing R while holding a block does nothing.
	pass

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
		var b_type := get_selected_type()
		# All block types (natural and structural alike) are placed as grid physics blocks.

		if is_cell_overlapping_player(target_place_cell, grid.cell_size):
			return
		if orchestrator != null and orchestrator.is_cell_blocked_by_debris(target_place_cell, grid.cell_size):
			return
		var vox := _get_voxel_world()
		if vox != null and vox.has_method("is_solid_block") and vox.is_solid_block(target_place_cell):
			return

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
	var voxel_center: Vector3 = Vector3(hit_pos) + Vector3(0.5, 0.5, 0.5)
	_wake_nearby_fragments(voxel_center, 2.0)
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
	if current_state != State.BODY_CONTROL:
		return
	# Prefer throwing carried logs/planks/blocks.
	if not _held_logs.is_empty():
		_throw_one_held_item()
		return
	if debris_grabber != null and debris_grabber.is_grabbing:
		debris_grabber.try_throw()
		return

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

## Task 3: Dismantle a Worker — drops its carried items and removes it from the world.
func _dismantle_worker(worker_node: Node) -> void:
	if not is_instance_valid(worker_node):
		return

	var world_parent: Node = get_parent() if get_parent() != null else (get_tree().current_scene if is_inside_tree() else null)

	# Drop any items the worker is carrying back into the world as loose rigidbodies.
	# Access via the worker's carried_items array (defined on Worker class).
	var items_var: Variant = worker_node.get("carried_items")
	if items_var is Array:
		var carrier: Node = worker_node.get_node_or_null("CarrierMarker3D")
		for item in (items_var as Array):
			if not is_instance_valid(item):
				continue
			var item_parent: Node = item.get_parent()
			if item_parent != null:
				item_parent.remove_child(item)
			if world_parent != null:
				world_parent.add_child(item)
			item.global_position = worker_node.global_position + Vector3(
				randf_range(-0.4, 0.4), 0.5, randf_range(-0.4, 0.4)
			)
			if item is RigidBody3D:
				var rb := item as RigidBody3D
				rb.freeze = false
				rb.sleeping = false
				rb.collision_layer = RESOURCE_LAYER
				rb.collision_mask = RESOURCE_COLLISION_MASK
				rb.linear_velocity = Vector3(randf_range(-1.0, 1.0), 1.5, randf_range(-1.0, 1.0))
				ChoppingBlock.wake_nearby_bodies(get_tree(), rb.global_position, 2.5)
			item.set_meta("worker_assigned", false)

	worker_node.queue_free()
