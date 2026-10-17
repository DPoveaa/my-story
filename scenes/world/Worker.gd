class_name Worker
extends CharacterBody3D

## Hauler Bot: Autonomous generalist helper entity with AStar3D grid-based pathfinding,
## multi-item carrying, intelligent destination validation, dynamic obstacle awareness,
## reliable route-following, stuck detection with recovery, and F3 debug visualization.

enum State {
	IDLE,
	SEARCH_JOB,
	MOVING_TO_ITEM,
	PICKUP_ITEM,
	MOVING_TO_STATION,
	DEPOSIT_ITEM,
}

@export var move_speed: float = 3.6
@export var search_radius: float = 24.0
@export var gravity: float = 9.8
@export var jump_velocity: float = 5.5
@export var reach_distance: float = 2.5
@export var step_height: float = 1.05

## Heavy gravity multiplier to eliminate moon-gravity feel.
const GRAVITY_MULTIPLIER: float = 2.5
## Jump velocity tuned for heavy gravity, clears 1.2m: sqrt(2 * 9.8 * 2.5 * 1.2) ≈ 7.67
const JUMP_VELOCITY: float = 7.7
## Y threshold above which the bot considers a ledge worth jumping.
const JUMP_THRESHOLD: float = 0.35
## How close to a waypoint before advancing to the next one (metres).
const WAYPOINT_REACH: float = 0.55
## Cooldown after a path/task failure before returning to IDLE (prevents rapid flickering).
const TASK_ABORT_COOLDOWN: float = 1.5

## Helper capacities: 1 log, 2 planks, and up to 25 loose fragment pickups.
const MAX_LOGS: int = 1
const MAX_PLANKS: int = 2
const MAX_FRAGMENTS: int = 25

## Stuck detection & recovery parameters
const MAX_RECOVERY_ATTEMPTS: int = 3
const STUCK_CHECK_INTERVAL: float = 0.75
const MIN_PROGRESS_DIST: float = 0.2
const TARGET_BLACKLIST_COOLDOWN: float = 10.0

@onready var carrier_marker: Marker3D = $CarrierMarker3D
@onready var debug_label: Label3D = $DebugLabel3D
@onready var line: Node = get_node_or_null("Line3D")

var current_state: State = State.IDLE
var target_item: Node3D = null
var carried_items: Array[Node3D] = []
var carried_material: String = ""
var target_station: Node3D = null

var _idle_timer: float = 0.0
var _abort_cooldown: float = 0.0
var _status_text: String = "[IDLE] Looking for work..."
var _status_hold_timer: float = 0.0

## AStar3D path following
var _current_path: PackedVector3Array = PackedVector3Array()
var _path_index: int = 0
var _destination: Vector3 = Vector3.INF
var _last_target_pos: Vector3 = Vector3.INF
var _path_dirty: bool = false
var _last_line_worker_pos: Vector3 = Vector3.INF

## Stuck detection and jumping trackers
var _stuck_timer: float = 0.0
var _last_stuck_check_pos: Vector3 = Vector3.INF
var _recovery_attempts: int = 0
var _jump_cooldown: float = 0.0
var _jump_count_at_waypoint: int = 0
var _last_jump_waypoint_idx: int = -1

## Target blacklist: instance_id -> expiry_ticks_msec
var _blacklisted_targets: Dictionary = {}

## Cached reference to AStarGridManager
var _astar_mgr: Node = null

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------
func _ready() -> void:
	add_to_group("workers")
	add_to_group("npcs")
	collision_layer = 2
	collision_mask = 1
	floor_snap_length = 0.4
	floor_constant_speed = true

	if line != null:
		line.top_level = true
		line.visible = false

	var mgr := _get_astar()
	if mgr != null and mgr.has_signal("graph_rebuilt"):
		if not mgr.graph_rebuilt.is_connected(_on_astar_graph_rebuilt):
			mgr.graph_rebuilt.connect(_on_astar_graph_rebuilt)

	_transition_to(State.IDLE)

func _exit_tree() -> void:
	_release_target_assignments()

func _on_astar_graph_rebuilt() -> void:
	# World geometry changed! Clear blacklist so previously blocked targets can be retried.
	_blacklisted_targets.clear()
	# Recalculate route if moving to respond dynamically to world changes
	if current_state == State.MOVING_TO_ITEM and is_instance_valid(target_item):
		_request_path(target_item.global_position)
	elif current_state == State.MOVING_TO_STATION and is_instance_valid(target_station):
		_request_path(target_station.global_position)

# ---------------------------------------------------------------------------
# AStar Helper & Route Management
# ---------------------------------------------------------------------------
func _get_astar() -> Node:
	if _astar_mgr != null and is_instance_valid(_astar_mgr):
		return _astar_mgr
	var root: Node = get_tree().root if is_inside_tree() else null
	if root != null:
		var gw: Node = root.find_child("GameWorld", true, false)
		if gw != null:
			_astar_mgr = gw.get_node_or_null("AStarGridManager")
			if _astar_mgr != null:
				return _astar_mgr
		_astar_mgr = root.find_child("AStarGridManager", true, false)
	return _astar_mgr

func _request_path(to: Vector3) -> bool:
	_destination = to
	var mgr := _get_astar()
	if mgr == null:
		_current_path = PackedVector3Array([to])
		_path_index = 0
		_path_dirty = true
		return true

	var path: PackedVector3Array = mgr.find_astar_path(global_position, to)
	if path.is_empty():
		_current_path = PackedVector3Array()
		_path_index = 0
		_path_dirty = true
		return false

	_current_path = path
	_path_index = 0
	# If the first waypoint is already behind or very close to the bot, advance to 1
	if _current_path.size() > 1:
		var d0 := Vector2(global_position.x - _current_path[0].x, global_position.z - _current_path[0].z).length()
		if d0 < WAYPOINT_REACH:
			_path_index = 1
	_path_dirty = true
	return true

func _has_valid_path() -> bool:
	return _path_index < _current_path.size()

func _current_waypoint() -> Vector3:
	if _has_valid_path():
		return _current_path[_path_index]
	return _destination

func _advance_waypoint() -> void:
	_path_index += 1
	_path_dirty = true

# ---------------------------------------------------------------------------
# Physics Loop
# ---------------------------------------------------------------------------
func _physics_process(delta: float) -> void:
	if global_position.y < -50.0:
		_release_target_assignments()
		queue_free()
		return

	# Gravity — 2.5x multiplier to eliminate moon-gravity feel
	if not is_on_floor():
		velocity.y -= gravity * GRAVITY_MULTIPLIER * delta
	else:
		if velocity.y < 0.0:
			velocity.y = -0.1

	if _abort_cooldown > 0.0:
		_abort_cooldown -= delta
	if _status_hold_timer > 0.0:
		_status_hold_timer -= delta

	# Jump cooldown tick
	if _jump_cooldown > 0.0:
		_jump_cooldown -= delta

	# Controlled jumping: jump only when approaching a higher ledge, with cooldown and attempt limits
	if is_on_floor() and _has_valid_path() and _jump_cooldown <= 0.0:
		var wp := _current_waypoint()
		var y_diff: float = wp.y - global_position.y
		var xz_dist: float = Vector2(global_position.x - wp.x, global_position.z - wp.z).length()
		if y_diff > JUMP_THRESHOLD and xz_dist < 1.6:
			if _path_index != _last_jump_waypoint_idx:
				_last_jump_waypoint_idx = _path_index
				_jump_count_at_waypoint = 0
			_jump_count_at_waypoint += 1
			if _jump_count_at_waypoint <= 2:
				velocity.y = JUMP_VELOCITY
				_jump_cooldown = 0.6
			else:
				# Cannot clear obstacle after 2 jumps; trigger recovery instead of bouncing in place
				_trigger_stuck_recovery("Obstacle too high / ledge blocked")

	# State execution
	match current_state:
		State.IDLE:
			velocity.x = move_toward(velocity.x, 0.0, move_speed * delta * 5.0)
			velocity.z = move_toward(velocity.z, 0.0, move_speed * delta * 5.0)
			_idle_timer -= delta
			if _idle_timer <= 0.0:
				_transition_to(State.SEARCH_JOB)

		State.SEARCH_JOB:
			velocity.x = move_toward(velocity.x, 0.0, move_speed * delta * 5.0)
			velocity.z = move_toward(velocity.z, 0.0, move_speed * delta * 5.0)
			_process_search_job()

		State.MOVING_TO_ITEM:
			_process_moving_to_item(delta)

		State.PICKUP_ITEM:
			velocity.x = 0.0
			velocity.z = 0.0
			_process_pickup_item()

		State.MOVING_TO_STATION:
			_process_moving_to_station(delta)

		State.DEPOSIT_ITEM:
			velocity.x = 0.0
			velocity.z = 0.0
			_process_deposit_item()

	move_and_slide()

	# Step-up: handle small bumps (up to 1.05m) smoothly without jumping
	if is_on_wall():
		var horiz_vel := Vector2(velocity.x, velocity.z)
		if horiz_vel.length_squared() > 0.01:
			var move_dir := Vector3(velocity.x, 0.0, velocity.z).normalized()
			_try_step_up(move_dir)

func _try_step_up(move_dir: Vector3) -> void:
	if not is_inside_tree() or not is_on_floor():
		return
	var space := get_world_3d().direct_space_state
	if space == null:
		return

	var test_up := global_position + Vector3.UP * step_height
	var test_fwd := test_up + move_dir * 0.4
	var params := PhysicsRayQueryParameters3D.create(test_up, test_fwd)
	params.exclude = [get_rid()]
	params.collision_mask = collision_mask
	var hit := space.intersect_ray(params)
	if not hit.is_empty():
		return

	var check_to := test_fwd + Vector3.DOWN * (step_height + 0.1)
	var floor_params := PhysicsRayQueryParameters3D.create(test_fwd, check_to)
	floor_params.exclude = [get_rid()]
	floor_params.collision_mask = collision_mask
	var floor_hit := space.intersect_ray(floor_params)
	if floor_hit.is_empty():
		return

	var step_y: float = floor_hit.position.y - global_position.y
	if step_y > 0.05 and step_y <= step_height:
		global_position.y += step_y + 0.02
		velocity.y = 0.0

# ---------------------------------------------------------------------------
# Debug & F3 Overlay Visuals
# ---------------------------------------------------------------------------
func _process(_delta: float) -> void:
	var debug_on: bool = _is_debug_overlay_active()

	if debug_label != null:
		debug_label.visible = debug_on
		if debug_on:
			debug_label.text = _status_text

	if line != null:
		if debug_on and _has_valid_path():
			line.visible = true
			var moved_line_dist := global_position.distance_to(_last_line_worker_pos)
			if _path_dirty or moved_line_dist > 0.25:
				_update_debug_line()
		else:
			if line.visible:
				line.visible = false
				if "points" in line:
					line.points = PackedVector3Array()

func _update_debug_line() -> void:
	if line == null:
		return
	var pts: PackedVector3Array = PackedVector3Array()
	# Start at bot's current position
	pts.append(global_position + Vector3(0.0, 0.25, 0.0))
	# Append each remaining waypoint in the AStar path
	for i in range(_path_index, _current_path.size()):
		pts.append(_current_path[i] + Vector3(0.0, 0.25, 0.0))
	# Append final target position for full route visualization
	var final_target_pos := Vector3.INF
	if current_state == State.MOVING_TO_ITEM and is_instance_valid(target_item):
		final_target_pos = target_item.global_position
	elif current_state == State.MOVING_TO_STATION and is_instance_valid(target_station):
		final_target_pos = target_station.global_position

	if final_target_pos != Vector3.INF and pts.size() > 0:
		if pts[pts.size() - 1].distance_to(final_target_pos) > 0.35:
			pts.append(final_target_pos + Vector3(0.0, 0.25, 0.0))

	line.points = pts
	_last_line_worker_pos = global_position
	_path_dirty = false

func _is_debug_overlay_active() -> bool:
	var overlay: Node = get_tree().root.find_child("DebugOverlay", true, false)
	if overlay != null and overlay is CanvasLayer:
		return (overlay as CanvasLayer).visible
	var hud: Node = get_tree().root.find_child("BuildHUD", true, false)
	if hud != null:
		var v = hud.get("_debug_visible")
		if v != null:
			return bool(v)
	var player_node: Node = get_tree().root.find_child("Player", true, false)
	if player_node != null:
		var v = player_node.get("_debug_overlay_enabled")
		if v != null:
			return bool(v)
	return false

# ---------------------------------------------------------------------------
# Status Management & Readable Hold Timers
# ---------------------------------------------------------------------------
func _set_status(text: String, hold_duration: float = 0.0, force: bool = false) -> void:
	if force or _status_hold_timer <= 0.0:
		_status_text = text
		if hold_duration > 0.0:
			_status_hold_timer = hold_duration
		if debug_label != null:
			debug_label.text = _status_text

func _transition_to(new_state: State) -> void:
	current_state = new_state
	match current_state:
		State.IDLE:
			if carried_items.is_empty():
				_set_status("[IDLE] Looking for work...", 0.0, false)
			else:
				_set_status("[IDLE] Waiting for available station for %s..." % carried_material, 0.0, false)
		State.SEARCH_JOB:
			_set_status("[SEARCHING] Scanning for resources...", 0.0, false)
		State.MOVING_TO_ITEM:
			if is_instance_valid(target_item):
				var d: float = global_position.distance_to(target_item.global_position)
				_set_status("[COLLECTING] Moving to %s (%.1fm)" % [target_item.name, d], 0.0, false)
		State.PICKUP_ITEM:
			_set_status("[COLLECTING] Picking up item...", 0.0, false)
		State.MOVING_TO_STATION:
			if is_instance_valid(target_station):
				var d: float = Vector2(global_position.x - target_station.global_position.x, global_position.z - target_station.global_position.z).length()
				_set_status("[CARRYING] Transporting %d %s(s) to %s (%.1fm)" % [carried_items.size(), carried_material, target_station.name, d], 0.0, false)
		State.DEPOSIT_ITEM:
			if is_instance_valid(target_station):
				_set_status("[DELIVERING] Depositing %d %s(s) at %s..." % [carried_items.size(), carried_material, target_station.name], 0.0, false)
			else:
				_set_status("[DELIVERING] Depositing %d item(s)..." % carried_items.size(), 0.0, false)

# ---------------------------------------------------------------------------
# Job Search & Destination Validation
# ---------------------------------------------------------------------------
func _process_search_job() -> void:
	if _abort_cooldown > 0.0:
		_transition_to(State.IDLE)
		return

	# Priority 1: If carrying cargo, always find a destination station first
	if not carried_items.is_empty():
		_go_to_station_or_idle(carried_material)
		return

	_set_status("[SEARCHING] Scanning for resources...", 0.0)

	# 1. Search for nearest reachable unassigned Log or Plank with a valid destination
	var item: Node3D = _find_best_candidate_item(["logs", "planks"])
	# 2. If no logs/planks, search for loose Fragments
	if item == null:
		item = _find_best_candidate_item(["fragments"])

	if item != null:
		target_item = item
		target_item.set_meta("worker_assigned", true)
		_last_target_pos = target_item.global_position
		_request_path(target_item.global_position)
		_recovery_attempts = 0
		_stuck_timer = 0.0
		_last_stuck_check_pos = global_position
		_transition_to(State.MOVING_TO_ITEM)
	else:
		_set_status("[IDLE] Looking for work...", 0.0)
		_idle_timer = 1.0
		_transition_to(State.IDLE)

func _find_best_candidate_item(group_names: Array, same_type: String = "") -> Node3D:
	var best_item: Node3D = null
	var best_dist_sq: float = search_radius * search_radius
	var astar_mgr := _get_astar()

	for grp in group_names:
		var nodes: Array = get_tree().get_nodes_in_group(grp)
		for node in nodes:
			if not (node is Node3D) or not is_instance_valid(node):
				continue
			if node.is_queued_for_deletion():
				continue
			if node.get_parent() is Marker3D:
				continue
			if node.get_meta("worker_assigned", false):
				continue
			if node.get_meta("vacuum_pull", false) or node.get_meta("pallet_craft_block", false):
				continue
			if node is RigidBody3D and (node as RigidBody3D).freeze and not node.is_in_group("fragments"):
				continue
			if _is_target_blacklisted(node):
				continue

			var mat: String = _resolve_item_material(node)
			if not same_type.is_empty() and mat != same_type:
				continue

			# Zero-value visual fragments: ignore for collection
			if node.is_in_group("fragments"):
				var rv: int = _get_item_resource_value(node)
				if rv <= 0:
					continue

			# Validate destination before assigning job
			if carried_items.is_empty():
				var test_station := _find_nearest_station_for_material(mat)
				if test_station == null:
					continue

			var dist_sq: float = global_position.distance_squared_to(node.global_position)
			if dist_sq < best_dist_sq:
				# Check reachability via AStar
				if astar_mgr != null and astar_mgr.has_method("find_astar_path"):
					var test_path: PackedVector3Array = astar_mgr.find_astar_path(global_position, node.global_position)
					if test_path.is_empty():
						_blacklist_target(node, TARGET_BLACKLIST_COOLDOWN)
						continue
				best_dist_sq = dist_sq
				best_item = node as Node3D

	return best_item

func _can_station_accept_material(station: Node3D, mat: String, amount: int = 1) -> bool:
	if station == null or not is_instance_valid(station) or station.is_queued_for_deletion():
		return false
	if station is ChoppingBlock:
		if mat != "log":
			return false
		var cb := station as ChoppingBlock
		if cb.has_log:
			return false
		if cb.has_method("can_accept_log") and not cb.can_accept_log():
			return false
		if station != target_station and station.get_meta("worker_assigned", false):
			return false
		return true
	elif station is Pallet:
		var pallet := station as Pallet
		if pallet.has_method("can_accept_material"):
			return pallet.can_accept_material(mat, amount)
		if pallet.get("_auto_converted") == true:
			return false
		var assigned: String = pallet.assigned_material
		if not assigned.is_empty() and not pallet._materials_compatible(mat, assigned):
			return false
		return true
	return false

func _find_nearest_station_for_material(mat: String, amount: int = 1) -> Node3D:
	var best_station: Node3D = null
	var best_dist_sq: float = INF
	var astar_mgr := _get_astar()

	# Prioritize ChoppingBlock for logs if available
	if mat == "log":
		for block in get_tree().get_nodes_in_group("chopping_blocks"):
			if not (block is Node3D) or not is_instance_valid(block):
				continue
			if _is_target_blacklisted(block):
				continue
			if not _can_station_accept_material(block, "log", amount):
				continue
			if astar_mgr != null and astar_mgr.has_method("find_astar_path"):
				var p: PackedVector3Array = astar_mgr.find_astar_path(global_position, block.global_position)
				if p.is_empty():
					_blacklist_target(block, TARGET_BLACKLIST_COOLDOWN)
					continue
			var d_sq: float = global_position.distance_squared_to(block.global_position)
			if d_sq < best_dist_sq:
				best_dist_sq = d_sq
				best_station = block
		if best_station != null:
			return best_station

	# Pallets
	for pallet in get_tree().get_nodes_in_group("pallets"):
		if not (pallet is Node3D) or not is_instance_valid(pallet):
			continue
		if _is_target_blacklisted(pallet):
			continue
		if not _can_station_accept_material(pallet, mat, amount):
			continue
		if astar_mgr != null and astar_mgr.has_method("find_astar_path"):
			var p: PackedVector3Array = astar_mgr.find_astar_path(global_position, pallet.global_position)
			if p.is_empty():
				_blacklist_target(pallet, TARGET_BLACKLIST_COOLDOWN)
				continue
		var d_sq: float = global_position.distance_squared_to(pallet.global_position)
		if d_sq < best_dist_sq:
			best_dist_sq = d_sq
			best_station = pallet

	return best_station

# ---------------------------------------------------------------------------
# Movement & Stuck Monitoring
# ---------------------------------------------------------------------------
func _process_moving_to_item(delta: float) -> void:
	if target_item == null or not is_instance_valid(target_item) or target_item.is_queued_for_deletion():
		_cancel_job("Target item lost!")
		return
	if target_item.get_parent() is Marker3D and target_item.get_parent() != carrier_marker:
		_cancel_job("Target taken by player/worker!")
		return

	# Recalculate route if target moved significantly (> 0.6m)
	if target_item.global_position.distance_squared_to(_last_target_pos) > 0.36:
		_last_target_pos = target_item.global_position
		if not _request_path(target_item.global_position):
			_cancel_job("Path blocked to moved item!")
			return

	var dist: float = global_position.distance_to(target_item.global_position)
	_set_status("[COLLECTING] Moving to %s (%.1fm)" % [target_item.name, dist], 0.0)

	if dist <= reach_distance:
		_transition_to(State.PICKUP_ITEM)
		return

	_monitor_stuck_progress(delta)
	_follow_path(delta)

func _process_moving_to_station(delta: float) -> void:
	if target_station == null or not is_instance_valid(target_station) or target_station.is_queued_for_deletion():
		var alt_station := _find_nearest_station_for_material(carried_material)
		if alt_station != null:
			_set_target_station(alt_station)
		else:
			# Station lost and no alternative available: wait in IDLE with cargo retained
			_cancel_job("Target station lost!")
			return

	# Check if station became full or incompatible en route
	if not _can_station_accept_material(target_station, carried_material):
		var alt_station := _find_nearest_station_for_material(carried_material)
		if alt_station != null:
			_set_target_station(alt_station)
		else:
			# Retain cargo safely while retrying later
			_cancel_job("Station became unavailable/full")
			return

	if target_station.global_position.distance_squared_to(_last_target_pos) > 0.36:
		_last_target_pos = target_station.global_position
		if not _request_path(target_station.global_position):
			_cancel_job("Path blocked to station!")
			return

	# Use horizontal distance only to prevent height mismatches causing deposit failure
	var horiz_dist: float = Vector2(global_position.x - target_station.global_position.x, global_position.z - target_station.global_position.z).length()
	_set_status("[CARRYING] Transporting %d %s(s) to %s (%.1fm)" % [carried_items.size(), carried_material, target_station.name, horiz_dist], 0.0)

	if horiz_dist <= reach_distance:
		_transition_to(State.DEPOSIT_ITEM)
		return

	_monitor_stuck_progress(delta)
	_follow_path(delta)

func _follow_path(delta: float) -> void:
	if not _has_valid_path():
		velocity.x = move_toward(velocity.x, 0.0, move_speed * delta * 5.0)
		velocity.z = move_toward(velocity.z, 0.0, move_speed * delta * 5.0)
		return

	var wp := _current_waypoint()

	# Advance waypoint when reached in XZ plane
	var xz_dist: float = Vector2(global_position.x - wp.x, global_position.z - wp.z).length()
	var y_diff: float = absf(global_position.y - wp.y)
	if xz_dist < WAYPOINT_REACH and y_diff < 1.2:
		_advance_waypoint()
		_jump_count_at_waypoint = 0
		if not _has_valid_path():
			velocity.x = move_toward(velocity.x, 0.0, move_speed * delta * 5.0)
			velocity.z = move_toward(velocity.z, 0.0, move_speed * delta * 5.0)
			return
		wp = _current_waypoint()

	var dir: Vector3 = wp - global_position
	dir.y = 0.0

	if dir.length_squared() < 0.001:
		velocity.x = move_toward(velocity.x, 0.0, move_speed * delta * 5.0)
		velocity.z = move_toward(velocity.z, 0.0, move_speed * delta * 5.0)
		return

	dir = dir.normalized()

	# Smooth rotation towards movement direction
	var target_yaw: float = atan2(-dir.x, -dir.z)
	rotation.y = lerp_angle(rotation.y, target_yaw, 10.0 * delta)

	velocity.x = dir.x * move_speed
	velocity.z = dir.z * move_speed

func _monitor_stuck_progress(delta: float) -> void:
	_stuck_timer += delta
	if _stuck_timer >= STUCK_CHECK_INTERVAL:
		_stuck_timer = 0.0
		if _last_stuck_check_pos != Vector3.INF:
			var moved_dist := Vector2(
				global_position.x - _last_stuck_check_pos.x,
				global_position.z - _last_stuck_check_pos.z
			).length()
			if moved_dist < MIN_PROGRESS_DIST and _has_valid_path():
				_trigger_stuck_recovery("Movement blocked / stalled")
				return
		_last_stuck_check_pos = global_position

func _trigger_stuck_recovery(reason: String) -> void:
	if _recovery_attempts < MAX_RECOVERY_ATTEMPTS:
		_recovery_attempts += 1
		_set_status("[REPLANNING] Route stalled, finding alternative (%d/%d)..." % [_recovery_attempts, MAX_RECOVERY_ATTEMPTS], 1.5, true)
		var dest := _destination
		if current_state == State.MOVING_TO_ITEM and is_instance_valid(target_item):
			dest = target_item.global_position
		elif current_state == State.MOVING_TO_STATION and is_instance_valid(target_station):
			dest = target_station.global_position

		if dest != Vector3.INF:
			var success := _request_path(dest)
			if success and _has_valid_path():
				_last_stuck_check_pos = global_position
				return

	# Exhausted recovery attempts: abandon target and blacklist temporarily
	var t_node: Node = null
	var t_name: String = "target"
	if current_state == State.MOVING_TO_ITEM and is_instance_valid(target_item):
		t_node = target_item
		t_name = target_item.name
	elif current_state == State.MOVING_TO_STATION and is_instance_valid(target_station):
		t_node = target_station
		t_name = target_station.name

	if t_node != null:
		_blacklist_target(t_node, TARGET_BLACKLIST_COOLDOWN)

	_cancel_job("Stuck / unable to reach %s (%s)" % [t_name, reason])

# ---------------------------------------------------------------------------
# Pickup & Carrying
# ---------------------------------------------------------------------------
func _process_pickup_item() -> void:
	if target_item == null or not is_instance_valid(target_item) or target_item.is_queued_for_deletion():
		_cancel_job("Target item disappeared!")
		return

	var item_mat: String = _resolve_item_material(target_item)

	if not _can_carry_more(item_mat):
		_go_to_station_or_idle(carried_material if not carried_material.is_empty() else item_mat)
		return

	# Disable physics on item while carried
	if target_item is RigidBody3D:
		var rb := target_item as RigidBody3D
		rb.freeze = true
		rb.sleeping = true
		rb.collision_layer = 0
		rb.collision_mask = 0
		rb.linear_velocity = Vector3.ZERO
		rb.angular_velocity = Vector3.ZERO

	# Reparent to carrier marker
	var old_parent: Node = target_item.get_parent()
	if old_parent != null:
		old_parent.remove_child(target_item)
	carrier_marker.add_child(target_item)

	carried_items.append(target_item)
	carried_material = item_mat
	target_item = null
	_refresh_carrier_visuals()

	var max_cap := _get_max_capacity(carried_material)
	_set_status("[COLLECTING] Picked up %s (%d/%d)" % [carried_material, carried_items.size(), max_cap], 0.6)

	# If helper can carry more, look for another nearby item of the same type
	if _can_carry_more(carried_material):
		var next_item: Node3D = _find_best_candidate_item(
			[_material_to_group(carried_material)], carried_material
		)
		if next_item != null:
			target_item = next_item
			target_item.set_meta("worker_assigned", true)
			_request_path(target_item.global_position)
			_last_target_pos = target_item.global_position
			_recovery_attempts = 0
			_stuck_timer = 0.0
			_last_stuck_check_pos = global_position
			_transition_to(State.MOVING_TO_ITEM)
			return

	_go_to_station_or_idle(carried_material)

func _get_max_capacity(mat: String) -> int:
	if mat == "log":
		return MAX_LOGS
	elif mat == "plank":
		return MAX_PLANKS
	return MAX_FRAGMENTS

func _can_carry_more(mat: String) -> bool:
	if not carried_material.is_empty() and mat != carried_material:
		return false
	return carried_items.size() < _get_max_capacity(mat)

func _refresh_carrier_visuals() -> void:
	for i in range(carried_items.size()):
		var item: Node3D = carried_items[i]
		if not is_instance_valid(item):
			continue
		item.rotation = Vector3.ZERO
		if carried_material == "log":
			item.position = Vector3(0.0, 0.0, 0.0)
		elif carried_material == "plank":
			item.position = Vector3(0.0, float(i) * 0.12, 0.0)
		else:
			# Neat 3x3 stacked layer heap for fragments on CarrierMarker3D
			var layer: int = i / 9
			var slot: int = i % 9
			var gx: int = slot % 3
			var gz: int = slot / 3
			var px: float = (float(gx) - 1.0) * 0.14
			var pz: float = (float(gz) - 1.0) * 0.14
			var py: float = float(layer) * 0.12
			item.position = Vector3(px, py, pz)

func _material_to_group(mat: String) -> String:
	match mat:
		"log":   return "logs"
		"plank": return "planks"
		_:       return "fragments"

func _go_to_station_or_idle(mat: String) -> void:
	var station: Node3D = _find_nearest_station_for_material(mat)
	if station != null:
		_set_target_station(station)
		_recovery_attempts = 0
		_stuck_timer = 0.0
		_last_stuck_check_pos = global_position
		_transition_to(State.MOVING_TO_STATION)
	else:
		# Retain cargo safely while retrying later! Never drop cargo merely because station is unavailable.
		_set_status("[IDLE] Waiting for available station for %s..." % mat, 2.5)
		_idle_timer = 2.0
		_transition_to(State.IDLE)

func _set_target_station(station: Node3D) -> void:
	if is_instance_valid(target_station) and target_station != station:
		target_station.set_meta("worker_assigned", false)
	target_station = station
	if is_instance_valid(target_station):
		target_station.set_meta("worker_assigned", true)
		_request_path(target_station.global_position)
		_last_target_pos = target_station.global_position

func _resolve_item_material(item: Node3D) -> String:
	if item == null or not is_instance_valid(item):
		return ""
	if item.has_meta("material"):
		return String(item.get_meta("material"))
	if item.has_meta("carry_type"):
		return String(item.get_meta("carry_type"))
	if item.has_meta("fragment_type"):
		return String(item.get_meta("fragment_type"))
	if item.is_in_group("logs"):
		return "log"
	if item.is_in_group("planks"):
		return "plank"
	if item.is_in_group("fragments"):
		return "stone"
	return "plank"

func _get_item_resource_value(item: Node3D) -> int:
	if item == null or not is_instance_valid(item):
		return 0
	if item is VoxelFragment:
		return (item as VoxelFragment).resource_value
	if item.has_meta("resource_value"):
		return int(item.get_meta("resource_value", 1))
	return 1

# ---------------------------------------------------------------------------
# Deposit & Resource Safety
# ---------------------------------------------------------------------------
func _process_deposit_item() -> void:
	if not is_instance_valid(target_station):
		# Station became invalid: retain cargo and search for another station
		_go_to_station_or_idle(carried_material)
		return

	_set_status("[DELIVERING] Depositing %d %s(s) at %s..." % [carried_items.size(), carried_material, target_station.name], 0.0)

	if target_station is ChoppingBlock and carried_material == "log":
		var cb := target_station as ChoppingBlock
		if cb.try_place_log():
			if not carried_items.is_empty():
				var item: Node3D = carried_items.pop_back()
				if is_instance_valid(item):
					item.queue_free()

	elif target_station is Pallet:
		var pallet := target_station as Pallet
		# Process items backwards so removing successful deposits is safe
		for i in range(carried_items.size() - 1, -1, -1):
			var item: Node3D = carried_items[i]
			if not is_instance_valid(item):
				carried_items.remove_at(i)
				continue

			var rv: int = _get_item_resource_value(item)
			if rv <= 0:
				# Zero-value visual fragment: safely free
				carried_items.remove_at(i)
				item.queue_free()
				continue

			var deposited: bool = false
			if pallet.has_method("refund_material"):
				deposited = pallet.refund_material(carried_material, rv)
			elif pallet.has_method("try_store"):
				deposited = pallet.try_store(carried_material)

			if deposited:
				carried_items.remove_at(i)
				item.queue_free()
			else:
				# Pallet full or rejected — keep remaining items in cargo!
				break

	_refresh_carrier_visuals()

	if carried_items.is_empty():
		# All cargo deposited successfully!
		if is_instance_valid(target_station):
			target_station.set_meta("worker_assigned", false)
		target_station = null
		carried_material = ""
		_set_status("[IDLE] Deposit complete, looking for work...", 1.5)
		_idle_timer = 0.5
		_transition_to(State.SEARCH_JOB)
	else:
		# Station full with cargo remaining — seek next station without dropping cargo!
		if is_instance_valid(target_station):
			target_station.set_meta("worker_assigned", false)
			_blacklist_target(target_station, 6.0)
		target_station = null
		_set_status("[CARRYING] Station full, finding next station...", 2.0, true)
		_go_to_station_or_idle(carried_material)

# ---------------------------------------------------------------------------
# Job Cancellation, Target Blacklisting, & Cleanup
# ---------------------------------------------------------------------------
func _cancel_job(reason: String) -> void:
	_set_status("[BLOCKED] " + reason, 3.0, true)
	if debug_label != null:
		debug_label.text = _status_text

	_release_target_assignments()

	_recovery_attempts = 0
	_stuck_timer = 0.0
	_last_stuck_check_pos = Vector3.INF
	_current_path = PackedVector3Array()
	_path_index = 0
	_path_dirty = true

	velocity.x = 0.0
	velocity.z = 0.0

	# Resource safety: Never drop carried cargo on path/target failure!
	_idle_timer = TASK_ABORT_COOLDOWN
	_abort_cooldown = TASK_ABORT_COOLDOWN
	_transition_to(State.IDLE)

func _release_target_assignments() -> void:
	if is_instance_valid(target_item):
		target_item.set_meta("worker_assigned", false)
		target_item = null
	if is_instance_valid(target_station):
		target_station.set_meta("worker_assigned", false)
		target_station = null

func _blacklist_target(target: Node, duration_sec: float) -> void:
	if target == null or not is_instance_valid(target):
		return
	var expiry: int = Time.get_ticks_msec() + int(duration_sec * 1000.0)
	_blacklisted_targets[target.get_instance_id()] = expiry

func _is_target_blacklisted(target: Node) -> bool:
	if target == null or not is_instance_valid(target):
		return true
	var id: int = target.get_instance_id()
	if _blacklisted_targets.has(id):
		if Time.get_ticks_msec() < _blacklisted_targets[id]:
			return true
		else:
			_blacklisted_targets.erase(id)
	return false

func _drop_all_carried() -> void:
	for item in carried_items:
		_drop_single_item(item)
	carried_items.clear()
	carried_material = ""

func _drop_single_item(item: Node3D) -> void:
	if item == null or not is_instance_valid(item):
		return

	var world_parent: Node = get_parent()
	if world_parent == null and is_inside_tree():
		world_parent = get_tree().current_scene

	if item.get_parent() == carrier_marker:
		carrier_marker.remove_child(item)
	elif item.get_parent() != null:
		item.get_parent().remove_child(item)

	if world_parent != null:
		world_parent.add_child(item)

	item.global_position = global_position + Vector3(
		randf_range(-0.3, 0.3), 0.4, randf_range(-0.3, 0.3)
	)

	if item is RigidBody3D:
		var rb := item as RigidBody3D
		rb.freeze = false
		rb.sleeping = false
		rb.collision_layer = 4  # DEBRIS_LAYER
		rb.collision_mask = 1 | 4
		rb.linear_velocity = Vector3(randf_range(-0.5, 0.5), 0.8, randf_range(-0.5, 0.5))

	item.set_meta("worker_assigned", false)
