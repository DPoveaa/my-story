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
@export var search_radius: float = 36.0
@export var gravity: float = 9.8
@export var jump_velocity: float = 5.5
@export var reach_distance: float = 2.5
@export var step_height: float = 0.35

## Interaction tolerances: separate loose pickups from stations and validate approach
const ITEM_PICKUP_HORIZ_TOLERANCE: float = 1.75
const ITEM_PICKUP_VERT_TOLERANCE: float = 1.55
const STATION_DEPOSIT_HORIZ_TOLERANCE: float = 1.65
const STATION_DEPOSIT_VERT_TOLERANCE: float = 1.4
const PALLET_DEPOSIT_HORIZ_TOLERANCE: float = 2.0
const APPROACH_POINT_REACH: float = 0.75

## Heavy gravity multiplier to eliminate moon-gravity feel.
const GRAVITY_MULTIPLIER: float = 2.5
## Jump velocity tuned for heavy gravity, clears 1.2m: sqrt(2 * 9.8 * 2.5 * 1.2) ≈ 7.67
const JUMP_VELOCITY: float = 7.7
## Y threshold above which the bot considers a ledge worth jumping.
const JUMP_THRESHOLD: float = 0.35
## How close to a waypoint before advancing to the next one (metres).
const WAYPOINT_REACH: float = 0.55
## Cooldown after a path/task failure before returning to IDLE (prevents rapid flickering).
const TASK_ABORT_COOLDOWN: float = 0.6

## Helper capacities: 1 log, 2 planks, and up to 25 loose fragment pickups.
const MAX_LOGS: int = 1
const MAX_PLANKS: int = 2
const MAX_FRAGMENTS: int = 25

## Stuck detection & recovery parameters
const MAX_RECOVERY_ATTEMPTS: int = 3
const STUCK_CHECK_INTERVAL: float = 0.75
const MIN_PROGRESS_DIST: float = 0.2
const TARGET_BLACKLIST_COOLDOWN: float = 2.5

## Deterministic palette for helper identity
const HELPER_PALETTE: Array[Color] = [
	Color(0.18, 0.90, 1.0),   # Cyan
	Color(1.0, 0.60, 0.15),   # Amber Orange
	Color(0.30, 0.95, 0.45),  # Lime Green
	Color(1.0, 0.28, 0.60),   # Magenta Rose
	Color(0.80, 0.45, 1.0),   # Purple Violet
	Color(1.0, 0.92, 0.20),   # Golden Yellow
	Color(0.25, 0.70, 1.0),   # Azure Blue
	Color(1.0, 0.40, 0.25),   # Coral Red
]

static var _next_worker_id: int = 1
var helper_id: int = 0
var helper_name: String = ""
var helper_color: Color = Color.WHITE

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
var _status_text: String = "[IDLE] Waiting for work..."
var _status_hold_timer: float = 0.0

## Target tracking & rolling damp trackers
var _target_repath_cooldown: float = 0.0
var _rolling_settle_timer: float = 0.0

## Idle wander trackers
var _is_wandering: bool = false
var _wander_timer: float = 0.0
var _wander_cooldown: float = 3.0
var _home_position: Vector3 = Vector3.INF

## AStar3D path following
var _current_path: PackedVector3Array = PackedVector3Array()
var _path_index: int = 0
var _destination: Vector3 = Vector3.INF
var _approach_target_point: Vector3 = Vector3.INF
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
var _wall_stuck_timer: float = 0.0
var _replan_pending: bool = false
var _replan_delay: float = 0.0

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
	floor_snap_length = 1.1
	floor_constant_speed = true

	# Assign unique helper identity and deterministic color
	helper_id = _next_worker_id
	_next_worker_id += 1
	helper_name = "Helper #%d" % helper_id
	helper_color = HELPER_PALETTE[(helper_id - 1) % HELPER_PALETTE.size()]

	# Apply identity color to VisorMesh accent (duplicate material to avoid shared mutation)
	var visor_mesh: MeshInstance3D = get_node_or_null("MeshInstance3D/VisorMesh") as MeshInstance3D
	if visor_mesh != null:
		var orig_mat: Material = visor_mesh.get_active_material(0)
		var new_mat: StandardMaterial3D = null
		if orig_mat is StandardMaterial3D:
			new_mat = (orig_mat as StandardMaterial3D).duplicate() as StandardMaterial3D
		else:
			new_mat = StandardMaterial3D.new()
		new_mat.albedo_color = helper_color
		new_mat.emission_enabled = true
		new_mat.emission = helper_color
		new_mat.emission_energy_multiplier = 2.5
		visor_mesh.material_override = new_mat

	if debug_label != null:
		debug_label.modulate = helper_color
		debug_label.visible = false

	if line != null:
		line.top_level = true
		line.visible = false
		if line.has_method("set_route_color"):
			line.set_route_color(helper_color)
		elif "line_color" in line:
			line.line_color = helper_color

	var mgr := _get_astar()
	if mgr != null and mgr.has_signal("graph_rebuilt"):
		if not mgr.graph_rebuilt.is_connected(_on_astar_graph_rebuilt):
			mgr.graph_rebuilt.connect(_on_astar_graph_rebuilt)

	# Stagger initial search timer to avoid all helpers searching simultaneously
	_idle_timer = randf_range(0.2, 0.6) + (float(helper_id) * 0.15)
	_home_position = global_position
	_wander_cooldown = randf_range(2.5, 5.0) + (float(helper_id % 4) * 0.75)
	_transition_to(State.IDLE)

func _exit_tree() -> void:
	_release_target_assignments()

func _on_astar_graph_rebuilt() -> void:
	# World geometry changed! Clear blacklist so previously blocked targets can be retried.
	_blacklisted_targets.clear()
	# Stagger/throttle replanning across helpers instead of all bots computing at once
	if not _replan_pending:
		_replan_pending = true
		_replan_delay = randf_range(0.1, 0.3) + (float(helper_id % 6) * 0.12)

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

func _get_target_approach_tolerances(target_node: Node3D) -> Dictionary:
	if target_node is ChoppingBlock:
		return {
			"half_extents": Vector2(0.58, 0.58),
			"min_dist": 0.25,
			"max_dist": 0.95,
			"max_vert": 1.3,
			"horiz_tol": 1.15,
			"vert_tol": STATION_DEPOSIT_VERT_TOLERANCE
		}
	elif target_node is Pallet:
		return {
			"half_extents": Vector2(1.1, 1.1),
			"min_dist": 0.3,
			"max_dist": 1.05,
			"max_vert": 1.3,
			"horiz_tol": 1.25,
			"vert_tol": STATION_DEPOSIT_VERT_TOLERANCE
		}
	else:
		return {
			"half_extents": Vector2.ZERO,
			"min_dist": 0.1,
			"max_dist": 1.6,
			"max_vert": 1.5,
			"horiz_tol": ITEM_PICKUP_HORIZ_TOLERANCE,
			"vert_tol": ITEM_PICKUP_VERT_TOLERANCE
		}

func _get_distance_to_station_edge(station: Node3D, pos: Vector3) -> float:
	if station == null or not is_instance_valid(station):
		return INF
	var tol := _get_target_approach_tolerances(station)
	var he: Vector2 = tol.get("half_extents", Vector2.ZERO)
	if he == Vector2.ZERO:
		return Vector2(pos.x - station.global_position.x, pos.z - station.global_position.z).length()
	var dx := maxf(0.0, absf(pos.x - station.global_position.x) - he.x)
	var dz := maxf(0.0, absf(pos.z - station.global_position.z) - he.y)
	return Vector2(dx, dz).length()

func _request_path(to: Vector3, target_node: Node3D = null) -> bool:
	var mgr := _get_astar()
	if mgr == null:
		_destination = to
		_approach_target_point = to
		_current_path = PackedVector3Array([to])
		_path_index = 0
		_path_dirty = true
		return true

	var t_node: Node3D = target_node
	if t_node == null:
		if current_state == State.MOVING_TO_ITEM:
			t_node = target_item
		elif current_state == State.MOVING_TO_STATION:
			t_node = target_station

	var path: PackedVector3Array = PackedVector3Array()
	if t_node != null and mgr.has_method("find_approach_path"):
		var tol := _get_target_approach_tolerances(t_node)
		path = mgr.find_approach_path(global_position, to, tol["min_dist"], tol["max_dist"], tol["max_vert"], tol.get("half_extents", Vector2.ZERO))
	elif mgr.has_method("find_approach_path"):
		path = mgr.find_approach_path(global_position, to, 0.4, 1.3, 1.0)

	# Do not fall back to routing directly to an object's origin when find_approach_path() fails!
	if path.is_empty():
		_current_path = PackedVector3Array()
		_path_index = 0
		_destination = Vector3.INF
		_approach_target_point = Vector3.INF
		_path_dirty = true
		return false

	var final_wp: Vector3 = path[path.size() - 1]
	var v_dist: float = absf(final_wp.y - to.y)
	if t_node != null:
		var tol := _get_target_approach_tolerances(t_node)
		var h_dist: float
		if tol.get("half_extents", Vector2.ZERO) != Vector2.ZERO:
			h_dist = _get_distance_to_station_edge(t_node, final_wp)
		else:
			h_dist = Vector2(final_wp.x - to.x, final_wp.z - to.z).length()

		if h_dist > tol["horiz_tol"] or v_dist > tol["vert_tol"]:
			_current_path = PackedVector3Array()
			_path_index = 0
			_destination = Vector3.INF
			_approach_target_point = Vector3.INF
			_path_dirty = true
			return false

	_current_path = path
	# Destination is the reachable approach point beside the obstacle, NOT the inside of the object
	_destination = final_wp
	_approach_target_point = _destination
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
	if _replan_pending:
		_replan_delay -= delta
		if _replan_delay <= 0.0:
			_replan_pending = false
			if current_state == State.MOVING_TO_ITEM and is_instance_valid(target_item):
				_request_path(target_item.global_position, target_item)
			elif current_state == State.MOVING_TO_STATION and is_instance_valid(target_station):
				_request_path(target_station.global_position, target_station)

	# Jump cooldown tick
	if _jump_cooldown > 0.0:
		_jump_cooldown -= delta

	# Controlled jumping: detect upcoming one-block elevation transition and initiate takeoff early enough
	if is_on_floor() and _has_valid_path() and _jump_cooldown <= 0.0:
		var target_elevated_wp: Vector3 = Vector3.INF
		var elev_y_diff: float = 0.0
		var wp := _current_waypoint()
		var y_diff_cur: float = wp.y - global_position.y
		if y_diff_cur > JUMP_THRESHOLD and y_diff_cur <= 1.35:
			target_elevated_wp = wp
			elev_y_diff = y_diff_cur
		elif _path_index + 1 < _current_path.size():
			var nxt := _current_path[_path_index + 1]
			var y_diff_nxt: float = nxt.y - global_position.y
			if y_diff_nxt > JUMP_THRESHOLD and y_diff_nxt <= 1.35:
				target_elevated_wp = nxt
				elev_y_diff = y_diff_nxt

		if target_elevated_wp != Vector3.INF:
			var xz_to_elev: float = Vector2(global_position.x - target_elevated_wp.x, global_position.z - target_elevated_wp.z).length()
			var dir_to_elev := Vector3(target_elevated_wp.x - global_position.x, 0.0, target_elevated_wp.z - global_position.z).normalized()
			var horiz_vel := Vector3(velocity.x, 0.0, velocity.z)
			var moving_towards: bool = (horiz_vel.length() < 0.5) or (horiz_vel.normalized().dot(dir_to_elev) > 0.25)

			# Takeoff window: initiate jump when approaching ledge (between 0.45m and 1.45m) with forward movement
			if moving_towards and xz_to_elev >= 0.45 and xz_to_elev <= 1.45:
				if _has_jump_headroom():
					if _path_index != _last_jump_waypoint_idx:
						_last_jump_waypoint_idx = _path_index
						_jump_count_at_waypoint = 0
					_jump_count_at_waypoint += 1
					if _jump_count_at_waypoint <= 2:
						velocity.y = JUMP_VELOCITY
						# Maintain/boost forward momentum in elevation direction during takeoff
						velocity.x = dir_to_elev.x * move_speed
						velocity.z = dir_to_elev.z * move_speed
						_jump_cooldown = 0.65
					else:
						# Cannot clear obstacle after 2 jumps; trigger recovery instead of bouncing in place
						_trigger_stuck_recovery("Obstacle too high / ledge blocked")

	# State execution
	match current_state:
		State.IDLE:
			if _is_wandering and _has_valid_path():
				_wander_timer -= delta
				if _wander_timer <= 0.0:
					_stop_wandering()
				else:
					_follow_path(delta, 0.4)
					if not _has_valid_path():
						_stop_wandering()
			else:
				velocity.x = move_toward(velocity.x, 0.0, move_speed * delta * 5.0)
				velocity.z = move_toward(velocity.z, 0.0, move_speed * delta * 5.0)

			_idle_timer -= delta
			if _idle_timer <= 0.0 and _abort_cooldown <= 0.0:
				_process_search_job()

			if not _is_wandering and carried_items.is_empty():
				_wander_cooldown -= delta
				if _wander_cooldown <= 0.0:
					_try_idle_wander()

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

	# Step-up: handle small bumps (up to 1.05m) smoothly without jumping; replan if blocked
	if is_on_wall():
		var horiz_vel := Vector2(velocity.x, velocity.z)
		if horiz_vel.length_squared() > 0.01:
			var move_dir := Vector3(velocity.x, 0.0, velocity.z).normalized()
			var stepped: bool = _try_step_up(move_dir)
			if not stepped and _has_valid_path():
				_wall_stuck_timer += delta
				if _wall_stuck_timer >= 0.4:
					_wall_stuck_timer = 0.0
					_trigger_stuck_recovery("Path obstructed by wall/obstacle")
			else:
				_wall_stuck_timer = 0.0
	else:
		_wall_stuck_timer = 0.0

func _get_direct_space_state() -> PhysicsDirectSpaceState3D:
	if not is_inside_tree():
		return null
	var world := get_world_3d()
	if world == null or not world.space.is_valid():
		return null
	return world.direct_space_state

func _has_jump_headroom() -> bool:
	var space := _get_direct_space_state()
	if space == null:
		return false
	var ray := PhysicsRayQueryParameters3D.create(
		global_position + Vector3(0.0, 1.0, 0.0),
		global_position + Vector3(0.0, 2.2, 0.0)
	)
	ray.collision_mask = collision_mask
	ray.exclude = [get_rid()]
	if space == null:
		return false
	return space.intersect_ray(ray).is_empty()

func _try_step_up(move_dir: Vector3) -> bool:
	if not is_inside_tree() or not is_on_floor():
		return false
	var space := _get_direct_space_state()
	if space == null:
		return false

	var test_up := global_position + Vector3.UP * step_height
	var test_fwd := test_up + move_dir * 0.4
	var params := PhysicsRayQueryParameters3D.create(test_up, test_fwd)
	params.exclude = [get_rid()]
	params.collision_mask = collision_mask
	if space == null:
		return false
	var hit := space.intersect_ray(params)
	if not hit.is_empty():
		return false

	var check_to := test_fwd + Vector3.DOWN * (step_height + 0.1)
	var floor_params := PhysicsRayQueryParameters3D.create(test_fwd, check_to)
	floor_params.exclude = [get_rid()]
	floor_params.collision_mask = collision_mask
	if space == null:
		return false
	var floor_hit := space.intersect_ray(floor_params)
	if floor_hit.is_empty():
		return false

	var step_y: float = floor_hit.position.y - global_position.y
	if step_y > 0.05 and step_y <= step_height:
		global_position.y += step_y + 0.02
		velocity.y = 0.0
		return true

	return false

# ---------------------------------------------------------------------------
# Debug & F3 Overlay Visuals
# ---------------------------------------------------------------------------
func _process(_delta: float) -> void:
	var debug_on: bool = _is_debug_overlay_active()

	if debug_label != null:
		debug_label.visible = debug_on
		if debug_on:
			debug_label.text = "[%s] %s" % [helper_name, _status_text]

	if line != null:
		if debug_on and _has_valid_path():
			line.visible = true
			var moved_line_dist := global_position.distance_to(_last_line_worker_pos)
			if _path_dirty or moved_line_dist > 0.4:
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
			debug_label.text = "[%s] %s" % [helper_name, _status_text]

func _transition_to(new_state: State) -> void:
	current_state = new_state
	match current_state:
		State.IDLE:
			if _status_hold_timer <= 0.0:
				if carried_items.is_empty():
					_set_status("[IDLE] Waiting for work...", 0.0, false)
				else:
					_set_status("[IDLE] Waiting for station for %s..." % carried_material, 0.0, false)
		State.SEARCH_JOB:
			if _status_hold_timer <= 0.0:
				_set_status("[SEARCHING] Scanning for resources...", 0.0, false)
		State.MOVING_TO_ITEM:
			if is_instance_valid(target_item):
				var d: float = global_position.distance_to(target_item.global_position)
				_set_status("[COLLECTING] Moving to %s (%.1fm)" % [target_item.name, d], 0.0, true)
		State.PICKUP_ITEM:
			_set_status("[COLLECTING] Picking up %s..." % carried_material, 0.0, true)
		State.MOVING_TO_STATION:
			if is_instance_valid(target_station):
				var d: float = Vector2(global_position.x - target_station.global_position.x, global_position.z - target_station.global_position.z).length()
				_set_status("[CARRYING] Transporting %d %s(s) to %s (%.1fm)" % [carried_items.size(), carried_material, target_station.name, d], 0.0, true)
		State.DEPOSIT_ITEM:
			if is_instance_valid(target_station):
				_set_status("[DELIVERING] Depositing %d %s(s) at %s..." % [carried_items.size(), carried_material, target_station.name], 0.0, true)
			else:
				_set_status("[DELIVERING] Depositing %d item(s)..." % carried_items.size(), 0.0, true)

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

	# 1. Search for nearest reachable unassigned Log or Plank with a valid destination
	var item: Node3D = _find_best_candidate_item(["logs", "planks"])
	# 2. If no logs/planks, search for loose Fragments
	if item == null:
		item = _find_best_candidate_item(["fragments"])

	if item != null:
		_stop_wandering()
		target_item = item
		target_item.set_meta("worker_reserved_by", self)
		target_item.set_meta("worker_assigned", true)
		_last_target_pos = target_item.global_position
		_target_repath_cooldown = 0.0
		_rolling_settle_timer = 0.0
		_request_path(target_item.global_position, target_item)
		_recovery_attempts = 0
		_stuck_timer = 0.0
		_last_stuck_check_pos = global_position
		_transition_to(State.MOVING_TO_ITEM)
	else:
		if _status_hold_timer <= 0.0:
			_set_status("[IDLE] Waiting for work...", 0.0)
		_idle_timer = randf_range(0.35, 0.65) + (float(helper_id % 4) * 0.1)
		_transition_to(State.IDLE)

func _has_any_compatible_station_for(mat: String) -> bool:
	if mat == "log":
		for block in get_tree().get_nodes_in_group("chopping_blocks"):
			if is_instance_valid(block) and not _is_target_blacklisted(block):
				if _can_station_accept_material(block, "log", 1):
					return true
	for pallet in get_tree().get_nodes_in_group("pallets"):
		if is_instance_valid(pallet) and not _is_target_blacklisted(pallet):
			if _can_station_accept_material(pallet, mat, 1):
				return true
	return false

func _find_best_candidate_item(group_names: Array, same_type: String = "") -> Node3D:
	var best_dist_sq: float = search_radius * search_radius
	var astar_mgr := _get_astar()
	var candidate_list: Array[Dictionary] = []
	var station_exists_cache: Dictionary = {}

	for grp in group_names:
		var nodes: Array = get_tree().get_nodes_in_group(grp)
		for node in nodes:
			if not (node is Node3D) or not is_instance_valid(node):
				continue
			if node.is_queued_for_deletion():
				continue
			if node.get_parent() is Marker3D:
				continue

			# Respect per-worker reservations
			var res_worker = null
			if node.has_meta("worker_reserved_by"):
				res_worker = node.get_meta("worker_reserved_by")
			if res_worker != null:
				if is_instance_valid(res_worker) and res_worker != self:
					continue
			elif node.has_meta("worker_assigned"):
				if bool(node.get_meta("worker_assigned")) and node != target_item:
					continue

			var is_vac: bool = false
			if node.has_meta("vacuum_pull"):
				is_vac = bool(node.get_meta("vacuum_pull"))
			var is_craft: bool = false
			if node.has_meta("pallet_craft_block"):
				is_craft = bool(node.get_meta("pallet_craft_block"))
			if is_vac or is_craft:
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

			# Fast broad check: ensure a destination station exists (cached per material)
			if carried_items.is_empty():
				if not station_exists_cache.has(mat):
					station_exists_cache[mat] = _has_any_compatible_station_for(mat)
				if not station_exists_cache[mat]:
					continue

			var dist_sq: float = global_position.distance_squared_to(node.global_position)
			if dist_sq < best_dist_sq:
				candidate_list.append({"node": node, "dist_sq": dist_sq})

	if candidate_list.is_empty():
		return null

	candidate_list.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["dist_sq"] < b["dist_sq"]
	)

	var station_route_cache: Dictionary = {}
	# Verify path and valid approach endpoint for a shortlist of closest candidates
	var max_candidates_to_eval: int = mini(4, candidate_list.size())
	for i in range(max_candidates_to_eval):
		var node: Node3D = candidate_list[i]["node"]
		var mat: String = _resolve_item_material(node)

		# If node is outside current baked navigation graph, request lazy baking and skip without blacklisting
		if astar_mgr != null and astar_mgr.has_method("is_position_in_baked_graph"):
			if not astar_mgr.is_position_in_baked_graph(node.global_position):
				if astar_mgr.has_method("request_chunk_for_position"):
					astar_mgr.request_chunk_for_position(node.global_position)
				continue

		if astar_mgr != null and astar_mgr.has_method("find_approach_path"):
			var tol := _get_target_approach_tolerances(node)
			var test_path: PackedVector3Array = astar_mgr.find_approach_path(global_position, node.global_position, tol["min_dist"], tol["max_dist"], tol["max_vert"], tol.get("half_extents", Vector2.ZERO))
			if test_path.is_empty():
				_blacklist_target(node, TARGET_BLACKLIST_COOLDOWN)
				continue
			var final_pt: Vector3 = test_path[test_path.size() - 1]
			var f_h: float
			if tol.get("half_extents", Vector2.ZERO) != Vector2.ZERO:
				f_h = _get_distance_to_station_edge(node, final_pt)
			else:
				f_h = Vector2(final_pt.x - node.global_position.x, final_pt.z - node.global_position.z).length()
			var f_v: float = absf(final_pt.y - node.global_position.y)
			if f_h > tol["horiz_tol"] or f_v > tol["vert_tol"]:
				_blacklist_target(node, TARGET_BLACKLIST_COOLDOWN)
				continue

		# Confirm destination station route exists for this material (cached across candidates)
		if carried_items.is_empty():
			if not station_route_cache.has(mat):
				station_route_cache[mat] = _find_nearest_station_for_material(mat)
			if station_route_cache[mat] == null:
				continue

		return node

	return null

func _get_carried_resource_value() -> int:
	if carried_items.is_empty():
		return 1
	if carried_material == "log":
		return carried_items.size()
	if carried_material == "plank":
		return carried_items.size()
	var total: int = 0
	for item in carried_items:
		if is_instance_valid(item):
			total += _get_item_resource_value(item)
	return maxi(total, 1)

func _can_station_accept_material(station: Node3D, mat: String, amount: int = -1) -> bool:
	if station == null or not is_instance_valid(station) or station.is_queued_for_deletion():
		return false
	if amount <= 0:
		amount = _get_carried_resource_value()

	if station is ChoppingBlock:
		if mat != "log":
			return false
		var cb := station as ChoppingBlock
		if cb.has_method("can_accept_log"):
			return cb.can_accept_log(self)
		if cb.has_log:
			return false
		var rw = cb.reserved_worker if "reserved_worker" in cb else null
		if rw != null and is_instance_valid(rw) and rw != self:
			return false
		return true
	elif station is Pallet:
		var pallet := station as Pallet
		if pallet.has_method("can_accept_material"):
			return pallet.can_accept_material(mat, amount, self)
		if pallet.get("_auto_converted") == true:
			return false
		var assigned: String = pallet.assigned_material
		if not assigned.is_empty() and not pallet._materials_compatible(mat, assigned):
			return false
		return true
	return false

func _get_candidate_stations_for_material(mat: String, amount: int = -1) -> Array[Node3D]:
	if amount <= 0:
		amount = _get_carried_resource_value()

	var result: Array[Node3D] = []

	# Priority 1 for logs: Chopping blocks as crafting task
	if mat == "log":
		var cb_candidates: Array[Dictionary] = []
		for block in get_tree().get_nodes_in_group("chopping_blocks"):
			if not (block is Node3D) or not is_instance_valid(block) or block.is_queued_for_deletion():
				continue
			if _is_target_blacklisted(block):
				continue
			if not _can_station_accept_material(block, "log", amount):
				continue
			var d_sq: float = global_position.distance_squared_to(block.global_position)
			cb_candidates.append({"station": block, "dist_sq": d_sq})

		cb_candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return a["dist_sq"] < b["dist_sq"]
		)
		for cand in cb_candidates:
			result.append(cand["station"])

	# Pallets (fallback for logs, primary for other resources)
	var pallet_candidates: Array[Dictionary] = []
	for pallet in get_tree().get_nodes_in_group("pallets"):
		if not (pallet is Node3D) or not is_instance_valid(pallet) or pallet.is_queued_for_deletion():
			continue
		if _is_target_blacklisted(pallet):
			continue
		if not _can_station_accept_material(pallet, mat, amount):
			continue
		var d_sq: float = global_position.distance_squared_to(pallet.global_position)
		pallet_candidates.append({"station": pallet, "dist_sq": d_sq})

	pallet_candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["dist_sq"] < b["dist_sq"]
	)
	for cand in pallet_candidates:
		result.append(cand["station"])

	return result

func _find_nearest_station_for_material(mat: String, amount: int = -1) -> Node3D:
	var astar_mgr := _get_astar()
	var candidates: Array[Node3D] = _get_candidate_stations_for_material(mat, amount)
	for station in candidates:
		if astar_mgr != null and astar_mgr.has_method("find_approach_path"):
			var tol := _get_target_approach_tolerances(station)
			var p: PackedVector3Array = astar_mgr.find_approach_path(global_position, station.global_position, tol["min_dist"], tol["max_dist"], tol["max_vert"], tol.get("half_extents", Vector2.ZERO))
			if p.is_empty():
				continue
			var final_pt: Vector3 = p[p.size() - 1]
			var f_h: float
			if tol.get("half_extents", Vector2.ZERO) != Vector2.ZERO:
				f_h = _get_distance_to_station_edge(station, final_pt)
			else:
				f_h = Vector2(final_pt.x - station.global_position.x, final_pt.z - station.global_position.z).length()
			var f_v: float = absf(final_pt.y - station.global_position.y)
			if f_h > tol["horiz_tol"] or f_v > tol["vert_tol"]:
				continue
		return station
	return null

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

	# Handle moving target with debouncing
	if _target_repath_cooldown > 0.0:
		_target_repath_cooldown -= delta

	var target_pos: Vector3 = target_item.global_position
	var target_moved_dist_sq: float = target_pos.distance_squared_to(_last_target_pos)
	if target_moved_dist_sq > 0.64 and _target_repath_cooldown <= 0.0:
		_target_repath_cooldown = 0.45
		_last_target_pos = target_pos
		var repath_ok := _request_path(target_pos, target_item)
		if not repath_ok:
			var is_rolling := (target_item is RigidBody3D) and ((target_item as RigidBody3D).linear_velocity.length_squared() > 0.04)
			if not is_rolling:
				_cancel_job("Path blocked to moved item!")
				return

	var horiz_dist: float = Vector2(global_position.x - target_pos.x, global_position.z - target_pos.z).length()
	var vert_dist: float = absf(global_position.y - target_pos.y)
	var dist_to_approach: float = Vector2(global_position.x - _approach_target_point.x, global_position.z - _approach_target_point.z).length() if _approach_target_point != Vector3.INF else INF

	_set_status("[COLLECTING] Moving to %s (%.1fm)" % [target_item.name, horiz_dist], 0.0)

	# Proximity damping for rolling bodies: help rolling items settle naturally when near
	if horiz_dist <= 2.2 and vert_dist <= 1.8 and (target_item is RigidBody3D):
		var rb := target_item as RigidBody3D
		if not rb.freeze and not rb.sleeping:
			var spd := rb.linear_velocity.length()
			if spd > 0.02 and spd < 4.0:
				rb.linear_velocity = rb.linear_velocity.move_toward(Vector3.ZERO, delta * 4.0)
				rb.angular_velocity = rb.angular_velocity.move_toward(Vector3.ZERO, delta * 5.0)

	var in_pickup_range: bool = (horiz_dist <= ITEM_PICKUP_HORIZ_TOLERANCE) and (vert_dist <= ITEM_PICKUP_VERT_TOLERANCE)

	# If within pickup range and physically reachable, pick up!
	if in_pickup_range:
		if _is_item_physically_reachable(target_item):
			var rb_speed: float = (target_item as RigidBody3D).linear_velocity.length() if (target_item is RigidBody3D) else 0.0
			if rb_speed < 1.0:
				_transition_to(State.PICKUP_ITEM)
				return
			else:
				_rolling_settle_timer += delta
				if _rolling_settle_timer >= 0.5:
					_rolling_settle_timer = 0.0
					_transition_to(State.PICKUP_ITEM)
					return
		else:
			_rolling_settle_timer = 0.0
	else:
		_rolling_settle_timer = 0.0

	# When path has ended (or bot reached destination)
	if not _has_valid_path():
		if in_pickup_range and _is_item_physically_reachable(target_item):
			_transition_to(State.PICKUP_ITEM)
			return
		elif horiz_dist <= ITEM_PICKUP_HORIZ_TOLERANCE + 0.8 and vert_dist <= ITEM_PICKUP_VERT_TOLERANCE + 0.5:
			# Close to item: try to replan a direct approach path before declaring stuck
			if _recovery_attempts < MAX_RECOVERY_ATTEMPTS:
				_trigger_stuck_recovery("Fine-tuning approach to item")
				return
			else:
				_trigger_stuck_recovery("Item unreachable at approach point")
				return
		else:
			_trigger_stuck_recovery("Item unreachable at approach point")
			return

	_monitor_stuck_progress(delta)
	_follow_path(delta)

func _is_item_physically_reachable(item: Node3D) -> bool:
	if item == null or not is_inside_tree() or not is_instance_valid(item) or item.is_queued_for_deletion():
		return false
	var space := _get_direct_space_state()
	if space == null:
		return false

	var excludes: Array[RID] = [get_rid()]
	if item is CollisionObject3D:
		excludes.append((item as CollisionObject3D).get_rid())
	for child in item.get_children():
		if child is CollisionObject3D:
			excludes.append((child as CollisionObject3D).get_rid())

	# 1. Try direct line of sight from helper's torso/hands to item center
	var from_chest := global_position + Vector3(0.0, 0.75, 0.0)
	var to_center := item.global_position + Vector3(0.0, 0.2, 0.0)
	var direct_ray := PhysicsRayQueryParameters3D.create(from_chest, to_center, 1)  # Mask 1 = solid terrain/structures
	direct_ray.exclude = excludes
	var direct_hit := space.intersect_ray(direct_ray)
	if direct_hit.is_empty():
		return true

	# 2. If direct ray hit terrain, test if this is a reach-over-step scenario:
	# Ray from helper's chest outward to reach height above the item, then down to the item.
	# This allows reaching down (or up) a step while blocking items behind actual walls or through solid floors.
	var high_y: float = maxf(global_position.y + 0.75, item.global_position.y + 0.5)
	var reach_above := Vector3(item.global_position.x, high_y, item.global_position.z)

	var ray1 := PhysicsRayQueryParameters3D.create(from_chest, reach_above, 1)
	ray1.exclude = excludes
	var hit1 := space.intersect_ray(ray1)
	if hit1.is_empty():
		var ray2 := PhysicsRayQueryParameters3D.create(reach_above, to_center, 1)
		ray2.exclude = excludes
		var hit2 := space.intersect_ray(ray2)
		if hit2.is_empty():
			return true

	# 3. Near-field ground touch: If helper is very close horizontally (<= 1.2m) and within 1.5m vertically,
	# check if the obstruction was merely the ground surface near helper's feet (hit position is below helper's waist).
	var h_dist := Vector2(global_position.x - item.global_position.x, global_position.z - item.global_position.z).length()
	var v_diff := absf(global_position.y - item.global_position.y)
	if h_dist <= 1.2 and v_diff <= 1.5:
		if direct_hit.position.y <= global_position.y + 0.15:
			var eye_from := global_position + Vector3(0.0, 1.2, 0.0)
			var eye_to := item.global_position + Vector3(0.0, 1.2, 0.0)
			var wall_ray := PhysicsRayQueryParameters3D.create(eye_from, eye_to, 1)
			wall_ray.exclude = excludes
			if space.intersect_ray(wall_ray).is_empty():
				return true

	return false

func _is_station_physically_reachable(station: Node3D) -> bool:
	if station == null or not is_inside_tree() or not is_instance_valid(station) or station.is_queued_for_deletion():
		return false
	var space := _get_direct_space_state()
	if space == null:
		return false

	# Ray travels at an interaction height above terrain to avoid floor clipping
	var from_pt := global_position + Vector3(0.0, 0.85, 0.0)
	var target_y_offset: float = 0.55 if (station is Pallet) else 0.65
	var to_pt := station.global_position + Vector3(0.0, target_y_offset, 0.0)
	var ray := PhysicsRayQueryParameters3D.create(from_pt, to_pt, 1)  # Mask 1 = solid terrain/structures

	var excludes: Array[RID] = [get_rid()]
	if station is CollisionObject3D:
		excludes.append((station as CollisionObject3D).get_rid())
	for child in station.get_children():
		if child is CollisionObject3D:
			excludes.append((child as CollisionObject3D).get_rid())
	ray.exclude = excludes

	if space == null:
		return false
	var hit := space.intersect_ray(ray)
	return hit.is_empty()

func _process_moving_to_station(delta: float) -> void:
	if target_station == null or not is_instance_valid(target_station) or target_station.is_queued_for_deletion():
		_go_to_station_or_idle(carried_material)
		return

	# Check if station became full or incompatible en route
	if not _can_station_accept_material(target_station, carried_material):
		_blacklist_target(target_station, 4.0)
		_release_station_reservation(target_station)
		target_station = null
		_go_to_station_or_idle(carried_material)
		return

	if target_station.global_position.distance_squared_to(_last_target_pos) > 0.36:
		_last_target_pos = target_station.global_position
		if not _request_path(target_station.global_position, target_station):
			_blacklist_target(target_station, 4.0)
			_release_station_reservation(target_station)
			target_station = null
			_set_status("[REPLANNING] Station path blocked, seeking alternative...", 2.0, true)
			_go_to_station_or_idle(carried_material)
			return

	var edge_dist: float = _get_distance_to_station_edge(target_station, global_position)
	var vert_dist: float = absf(global_position.y - target_station.global_position.y)
	var dist_to_approach: float = Vector2(global_position.x - _approach_target_point.x, global_position.z - _approach_target_point.z).length() if _approach_target_point != Vector3.INF else INF

	_set_status("[CARRYING] Transporting %d %s(s) to %s (%.1fm)" % [carried_items.size(), carried_material, target_station.name, edge_dist], 0.0)

	var tol := _get_target_approach_tolerances(target_station)
	var in_station_range: bool = (edge_dist <= tol["horiz_tol"]) and (vert_dist <= tol["vert_tol"])

	if in_station_range:
		if _is_station_physically_reachable(target_station):
			_transition_to(State.DEPOSIT_ITEM)
			return

	if not _has_valid_path():
		if in_station_range and _is_station_physically_reachable(target_station):
			_transition_to(State.DEPOSIT_ITEM)
			return
		else:
			_trigger_stuck_recovery("Station unreachable at approach point")
			return

	_monitor_stuck_progress(delta)
	_follow_path(delta)

func _follow_path(delta: float, speed_mult: float = 1.0) -> void:
	if not _has_valid_path():
		velocity.x = move_toward(velocity.x, 0.0, move_speed * delta * 8.0)
		velocity.z = move_toward(velocity.z, 0.0, move_speed * delta * 8.0)
		return

	var wp := _current_waypoint()

	# Advance waypoint when reached in XZ plane with sensible vertical tolerance for ascending/descending
	var xz_dist: float = Vector2(global_position.x - wp.x, global_position.z - wp.z).length()
	var y_diff: float = wp.y - global_position.y
	if xz_dist < WAYPOINT_REACH:
		if y_diff > JUMP_THRESHOLD:
			if global_position.y >= wp.y - 0.25 or is_on_floor():
				_advance_waypoint()
				_jump_count_at_waypoint = 0
				if not _has_valid_path():
					velocity.x = move_toward(velocity.x, 0.0, move_speed * delta * 8.0)
					velocity.z = move_toward(velocity.z, 0.0, move_speed * delta * 8.0)
					return
				wp = _current_waypoint()
		else:
			if absf(y_diff) < 1.9:
				_advance_waypoint()
				_jump_count_at_waypoint = 0
				if not _has_valid_path():
					velocity.x = move_toward(velocity.x, 0.0, move_speed * delta * 8.0)
					velocity.z = move_toward(velocity.z, 0.0, move_speed * delta * 8.0)
					return
				wp = _current_waypoint()

	var dir: Vector3 = wp - global_position
	dir.y = 0.0

	if dir.length_squared() < 0.001:
		velocity.x = move_toward(velocity.x, 0.0, move_speed * delta * 8.0)
		velocity.z = move_toward(velocity.z, 0.0, move_speed * delta * 8.0)
		return

	dir = dir.normalized()

	# Smooth steering when approaching current waypoint towards next waypoint
	if _path_index + 1 < _current_path.size() and xz_dist < 0.8:
		var next_wp := _current_path[_path_index + 1]
		var dir_next := next_wp - global_position
		dir_next.y = 0.0
		if dir_next.length_squared() > 0.001:
			var blend: float = clampf(1.0 - (xz_dist / 0.8), 0.0, 0.45)
			dir = dir.lerp(dir_next.normalized(), blend).normalized()

	# Smooth rotation towards movement direction
	var target_yaw: float = atan2(-dir.x, -dir.z)
	rotation.y = lerp_angle(rotation.y, target_yaw, 10.0 * delta)

	var effective_speed: float = move_speed * speed_mult
	var target_vx := dir.x * effective_speed
	var target_vz := dir.z * effective_speed
	velocity.x = move_toward(velocity.x, target_vx, effective_speed * delta * 10.0)
	velocity.z = move_toward(velocity.z, target_vz, effective_speed * delta * 10.0)

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
		var t_dest_node: Node3D = null
		if current_state == State.MOVING_TO_ITEM and is_instance_valid(target_item):
			dest = target_item.global_position
			t_dest_node = target_item
		elif current_state == State.MOVING_TO_STATION and is_instance_valid(target_station):
			dest = target_station.global_position
			t_dest_node = target_station

		if dest != Vector3.INF:
			var success := _request_path(dest, t_dest_node)
			if success and _has_valid_path():
				_last_stuck_check_pos = global_position
				return
			if is_instance_valid(t_dest_node):
				var nudge_dir := (t_dest_node.global_position - global_position)
				nudge_dir.y = 0.0
				if nudge_dir.length_squared() > 0.01:
					velocity.x = nudge_dir.normalized().x * (move_speed * 0.6)
					velocity.z = nudge_dir.normalized().z * (move_speed * 0.6)
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

func _try_idle_wander() -> void:
	_wander_cooldown = randf_range(4.0, 7.5) + (float(helper_id % 4) * 0.8)
	if not carried_items.is_empty() or target_item != null or target_station != null:
		return
	var mgr := _get_astar()
	if mgr == null or not mgr.has_method("get_nearby_walkable_points"):
		return
	var points: Array[Vector3] = mgr.get_nearby_walkable_points(global_position, 1.0, 2.2, 0.35)
	if points.is_empty():
		return
	var safe_points: Array[Vector3] = []
	for pt in points:
		if _home_position == Vector3.INF or pt.distance_squared_to(_home_position) <= 64.0:
			safe_points.append(pt)
	if safe_points.is_empty():
		return
	var chosen: Vector3 = safe_points[randi() % safe_points.size()]
	var wander_path: PackedVector3Array = mgr.find_astar_path(global_position, chosen)
	if wander_path.size() >= 2:
		_is_wandering = true
		_current_path = wander_path
		_path_index = 0
		_destination = chosen
		_approach_target_point = chosen
		_wander_timer = randf_range(2.0, 3.5)
		_path_dirty = true

func _stop_wandering() -> void:
	if _is_wandering:
		_is_wandering = false
		_current_path = PackedVector3Array()
		_path_index = 0
		_destination = Vector3.INF
		_approach_target_point = Vector3.INF
		_path_dirty = true

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
			target_item.set_meta("worker_reserved_by", self)
			target_item.set_meta("worker_assigned", true)
			_request_path(target_item.global_position, target_item)
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
	var needed_amount: int = _get_carried_resource_value()
	var candidates: Array[Node3D] = _get_candidate_stations_for_material(mat, needed_amount)
	for station in candidates:
		if _set_target_station(station):
			_recovery_attempts = 0
			_stuck_timer = 0.0
			_last_stuck_check_pos = global_position
			_transition_to(State.MOVING_TO_STATION)
			return

	# Retain cargo safely while retrying later! Never drop cargo merely because station is unavailable.
	_set_status("[IDLE] Waiting for station for %s..." % mat, 2.5)
	_idle_timer = 2.0
	_transition_to(State.IDLE)

func _set_target_station(station: Node3D) -> bool:
	if not is_instance_valid(station):
		return false
	if is_instance_valid(target_station) and target_station != station:
		_release_station_reservation(target_station)

	var reserved_ok: bool = false
	var needed_amount: int = _get_carried_resource_value()
	if station.has_method("reserve"):
		if station is Pallet:
			reserved_ok = (station as Pallet).reserve(self, carried_material, needed_amount)
		elif station is ChoppingBlock:
			reserved_ok = (station as ChoppingBlock).reserve(self)
	else:
		station.set_meta("worker_reserved_by", self)
		station.set_meta("worker_assigned", true)
		reserved_ok = true

	if not reserved_ok:
		return false

	target_station = station
	_last_target_pos = target_station.global_position
	if not _request_path(target_station.global_position, target_station):
		_release_station_reservation(target_station)
		target_station = null
		return false

	return true

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
		return int(item.get_meta("resource_value"))
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
		var placed: bool = cb.try_place_log()
		if placed:
			if not carried_items.is_empty():
				var item: Node3D = carried_items.pop_back()
				if is_instance_valid(item):
					item.queue_free()
		else:
			# try_place_log() failed! Retain the log and replan!
			_blacklist_target(cb, 5.0)
			_release_station_reservation(target_station)
			target_station = null
			_set_status("[REPLANNING] Chopping block rejected log, replanning...", 2.0, true)
			_go_to_station_or_idle(carried_material)
			return

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
	else:
		# Station has no valid deposit handler for this material: retain cargo and replan
		_blacklist_target(target_station, 5.0)
		_release_station_reservation(target_station)
		target_station = null
		_set_status("[REPLANNING] Station cannot accept %s, replanning..." % carried_material, 2.0, true)
		_go_to_station_or_idle(carried_material)
		return

	_refresh_carrier_visuals()

	# Release reservation on target station
	_release_station_reservation(target_station)

	if carried_items.is_empty():
		# All cargo deposited successfully!
		target_station = null
		carried_material = ""
		_set_status("[IDLE] Deposit complete, looking for work...", 1.5)
		_idle_timer = 0.5
		_transition_to(State.IDLE)
	else:
		# Station full with cargo remaining — seek next station without dropping cargo!
		_blacklist_target(target_station, 6.0)
		target_station = null
		_set_status("[CARRYING] Station full, finding next station...", 2.0, true)
		_go_to_station_or_idle(carried_material)

# ---------------------------------------------------------------------------
# Job Cancellation, Target Blacklisting, & Cleanup
# ---------------------------------------------------------------------------
func _cancel_job(reason: String) -> void:
	_set_status("[BLOCKED] " + reason, 2.5, true)
	if debug_label != null:
		debug_label.text = "[%s] %s" % [helper_name, _status_text]

	_release_target_assignments()

	_recovery_attempts = 0
	_stuck_timer = 0.0
	_last_stuck_check_pos = Vector3.INF
	_current_path = PackedVector3Array()
	_path_index = 0
	_path_dirty = true
	_is_wandering = false

	velocity.x = 0.0
	velocity.z = 0.0

	# Resource safety: Never drop carried cargo on path/target failure!
	_idle_timer = TASK_ABORT_COOLDOWN
	_abort_cooldown = TASK_ABORT_COOLDOWN
	_transition_to(State.IDLE)

func _release_target_assignments() -> void:
	_release_item_reservation()
	_release_station_reservation()

func _release_item_reservation(item: Node3D = null) -> void:
	var it := item if item != null else target_item
	if is_instance_valid(it):
		if it.has_meta("worker_reserved_by") and it.get_meta("worker_reserved_by") == self:
			it.set_meta("worker_reserved_by", null)
		it.set_meta("worker_assigned", false)
	if item == null or item == target_item:
		target_item = null

func _release_station_reservation(st: Node3D = null) -> void:
	var station_to_release: Node3D = st if st != null else target_station
	if is_instance_valid(station_to_release):
		if station_to_release.has_method("release_reservation"):
			station_to_release.release_reservation(self)
		else:
			if station_to_release.has_meta("worker_reserved_by") and station_to_release.get_meta("worker_reserved_by") == self:
				station_to_release.set_meta("worker_reserved_by", null)
			station_to_release.set_meta("worker_assigned", false)
	if st == null or st == target_station:
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
	if item.has_meta("worker_reserved_by") and item.get_meta("worker_reserved_by") == self:
		item.set_meta("worker_reserved_by", null)
