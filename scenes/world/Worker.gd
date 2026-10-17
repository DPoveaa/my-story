class_name Worker
extends CharacterBody3D

## Hauler Bot: Autonomous helper entity with AStar3D grid-based pathfinding,
## multi-item carrying, jumping over 1-block ledges, and full-route F3 Debug line.
## NavigationAgent3D has been completely removed in favour of AStarGridManager.

enum State {
	IDLE,
	SEARCH_JOB,
	MOVING_TO_ITEM,
	PICKUP_ITEM,
	MOVING_TO_STATION,
	DEPOSIT_ITEM,
}

@export var move_speed: float = 3.6
@export var search_radius: float = 20.0
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
## Cooldown after a path/task failure before returning to IDLE (prevents flickering).
const TASK_ABORT_COOLDOWN: float = 1.5

## Capacity limits (mirrors player).
const MAX_LOGS: int = 2
const MAX_PLANKS: int = 4

@onready var carrier_marker: Marker3D = $CarrierMarker3D
@onready var debug_label: Label3D = $DebugLabel3D
@onready var line: Node = get_node_or_null("Line3D")

var current_state: State = State.IDLE
var target_item: Node3D = null
var carried_items: Array = []
var carried_material: String = ""
var target_station: Node3D = null

var _idle_timer: float = 0.0
var _last_target_pos: Vector3 = Vector3.INF
var _thought_text: String = "[IDLE] Looking for work..."

## AStar3D path currently being followed.
var _current_path: PackedVector3Array = PackedVector3Array()
var _path_index: int = 0
var _destination: Vector3 = Vector3.INF
var _repath_timer: float = 0.0
const REPATH_INTERVAL: float = 0.5
## Abort cooldown: prevents rapid task flicker after path failure.
var _abort_cooldown: float = 0.0

## Cached reference to AStarGridManager — resolved lazily.
var _astar_mgr: Node = null

func _ready() -> void:
	add_to_group("workers")
	add_to_group("npcs")
	collision_layer = 2
	collision_mask = 1
	floor_snap_length = 0.4
	floor_constant_speed = true

	if line != null:
		line.top_level = true

	_transition_to(State.IDLE)

# ---------------------------------------------------------------------------
# AStar helper — lazy lookup
# ---------------------------------------------------------------------------
func _get_astar() -> Node:
	if _astar_mgr != null and is_instance_valid(_astar_mgr):
		return _astar_mgr
	# Try GameWorld child first
	var root: Node = get_tree().root if is_inside_tree() else null
	if root != null:
		var gw: Node = root.find_child("GameWorld", true, false)
		if gw != null:
			_astar_mgr = gw.get_node_or_null("AStarGridManager")
			if _astar_mgr != null:
				return _astar_mgr
		# Fallback: anywhere in tree
		_astar_mgr = root.find_child("AStarGridManager", true, false)
	return _astar_mgr

func _request_path(to: Vector3) -> void:
	_destination = to
	var mgr := _get_astar()
	if mgr == null:
		# No graph yet — fall back to direct steering
		_current_path = PackedVector3Array([to])
		_path_index = 0
		return
	var path: PackedVector3Array = mgr.find_astar_path(global_position, to)
	_current_path = path
	_path_index = 0

func _has_valid_path() -> bool:
	return _path_index < _current_path.size()

func _current_waypoint() -> Vector3:
	if _has_valid_path():
		return _current_path[_path_index]
	return _destination

func _advance_waypoint() -> void:
	_path_index += 1

func _recalculate_moving_path() -> void:
	var target_pos := Vector3.INF
	if current_state == State.MOVING_TO_ITEM and is_instance_valid(target_item):
		target_pos = target_item.global_position
	elif current_state == State.MOVING_TO_STATION and is_instance_valid(target_station):
		target_pos = target_station.global_position

	if target_pos != Vector3.INF:
		var astar_manager := _get_astar()
		if astar_manager != null and astar_manager.has_method("find_astar_path"):
			var new_path: PackedVector3Array = astar_manager.find_astar_path(global_position, target_pos)
			if not new_path.is_empty():
				_current_path = new_path
				_path_index = 0
				_destination = target_pos
				_last_target_pos = target_pos
			else:
				if current_state == State.MOVING_TO_ITEM:
					_cancel_job("Path blocked to item!")
				elif current_state == State.MOVING_TO_STATION:
					_cancel_job("Path blocked to station!")

# ---------------------------------------------------------------------------
# Physics loop
# ---------------------------------------------------------------------------
func _physics_process(delta: float) -> void:
	if global_position.y < -50.0:
		queue_free()
		return

	# Gravity — 2.5x multiplier to eliminate moon-gravity feel
	if not is_on_floor():
		velocity.y -= gravity * GRAVITY_MULTIPLIER * delta
	else:
		if velocity.y < 0.0:
			velocity.y = -0.1

	# Abort cooldown tick
	if _abort_cooldown > 0.0:
		_abort_cooldown -= delta

	# Dynamic route recalculation while moving
	if current_state == State.MOVING_TO_ITEM or current_state == State.MOVING_TO_STATION:
		_repath_timer += delta
		if _repath_timer >= REPATH_INTERVAL:
			_repath_timer = 0.0
			_recalculate_moving_path()

	# Jump to clear the next waypoint if it is higher than current position
	if is_on_floor() and _has_valid_path():
		var wp := _current_waypoint()
		var y_diff: float = wp.y - global_position.y
		if y_diff > JUMP_THRESHOLD:
			velocity.y = JUMP_VELOCITY

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

	# Step-up: handle small bumps without jumping
	if is_on_wall():
		var horiz_vel := Vector3(velocity.x, 0.0, velocity.z)
		if horiz_vel.length_squared() > 0.01:
			_try_step_up(horiz_vel.normalized())

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
# _process — debug label + AStar path line
# ---------------------------------------------------------------------------
func _process(_delta: float) -> void:
	var debug_on: bool = _is_debug_overlay_active()

	if debug_label != null:
		debug_label.visible = debug_on
		if debug_on:
			debug_label.text = _thought_text

	# Draw the live AStar path as a 3D line every frame
	if line != null:
		if debug_on and _has_valid_path():
			line.visible = true
			var pts: PackedVector3Array = PackedVector3Array()
			# Start at bot's current position
			pts.append(global_position + Vector3(0.0, 0.3, 0.0))
			# Append each remaining waypoint in the AStar path
			for i in range(_path_index, _current_path.size()):
				pts.append(_current_path[i] + Vector3(0.0, 0.3, 0.0))
			line.points = pts
		else:
			line.visible = false
			if line.has_method("_update_mesh") or "points" in line:
				line.points = PackedVector3Array()

# ---------------------------------------------------------------------------
# State machine
# ---------------------------------------------------------------------------
func _transition_to(new_state: State) -> void:
	current_state = new_state
	_repath_timer = 0.0
	match current_state:
		State.IDLE:
			_thought_text = "[IDLE] Looking for work..."
		State.SEARCH_JOB:
			_thought_text = "[SEARCH] Scanning for loose resources..."
		State.MOVING_TO_ITEM:
			if is_instance_valid(target_item):
				var d: float = global_position.distance_to(target_item.global_position)
				_thought_text = "[MOVING] Target: %s | Dist: %.1fm" % [target_item.name, d]
		State.PICKUP_ITEM:
			_thought_text = "[PICKUP] Picking up item..."
		State.MOVING_TO_STATION:
			if is_instance_valid(target_station):
				var d: float = global_position.distance_to(target_station.global_position)
				_thought_text = "[CARRYING %d] Transporting to %s | Dist: %.1fm" % [carried_items.size(), target_station.name, d]
		State.DEPOSIT_ITEM:
			_thought_text = "[DEPOSIT] Depositing %d item(s)..." % carried_items.size()

func _process_search_job() -> void:
	# Guard: wait until abort cooldown expires to prevent rapid flickering
	if _abort_cooldown > 0.0:
		_transition_to(State.IDLE)
		return
	# 1. Search for nearest loose, unassigned Log or Plank within search_radius
	var item: Node3D = _find_nearest_loose_item(["logs", "planks"])
	# 2. If no logs/planks exist, search for loose Fragments (Dirt/Stone)
	if item == null:
		item = _find_nearest_loose_item(["fragments"])

	if item != null:
		var astar_manager := _get_astar()
		if astar_manager != null and astar_manager.has_method("find_astar_path"):
			var path: PackedVector3Array = astar_manager.find_astar_path(global_position, item.global_position)
			if path.is_empty():
				_idle_timer = TASK_ABORT_COOLDOWN
				_abort_cooldown = TASK_ABORT_COOLDOWN
				_transition_to(State.IDLE)
				return
			_current_path = path
			_path_index = 0
			_destination = item.global_position
		else:
			_request_path(item.global_position)

		target_item = item
		target_item.set_meta("worker_assigned", true)
		_last_target_pos = target_item.global_position
		_transition_to(State.MOVING_TO_ITEM)
	else:
		_idle_timer = 1.0
		_transition_to(State.IDLE)

func _find_nearest_loose_item(group_names: Array, same_type: String = "") -> Node3D:
	var best_item: Node3D = null
	var best_dist_sq: float = search_radius * search_radius

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
			if not same_type.is_empty():
				var mat: String = _resolve_item_material(node)
				if mat != same_type:
					continue

			var dist_sq: float = global_position.distance_squared_to(node.global_position)
			if dist_sq < best_dist_sq:
				best_dist_sq = dist_sq
				best_item = node as Node3D

	return best_item

func _process_moving_to_item(delta: float) -> void:
	if target_item == null or not is_instance_valid(target_item) or target_item.is_queued_for_deletion():
		_cancel_job("Target item lost!")
		return
	if target_item.get_parent() is Marker3D:
		_cancel_job("Target taken by player/worker!")
		return

	# Dynamic target recalculation if item moves significantly
	if target_item.global_position.distance_squared_to(_last_target_pos) > 0.4:
		_request_path(target_item.global_position)
		_last_target_pos = target_item.global_position

	var dist: float = global_position.distance_to(target_item.global_position)
	_thought_text = "[MOVING] Target: %s | Dist: %.1fm" % [target_item.name, dist]

	if dist <= reach_distance:
		_transition_to(State.PICKUP_ITEM)
		return

	_follow_path(delta)

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

	# Visual stack offset
	var stack_index: int = carried_items.size()
	var y_offset: float = float(stack_index) * 0.28

	# Reparent to carrier marker
	var old_parent: Node = target_item.get_parent()
	if old_parent != null:
		old_parent.remove_child(target_item)
	carrier_marker.add_child(target_item)
	target_item.position = Vector3(0.0, y_offset, 0.0)
	target_item.rotation = Vector3.ZERO

	carried_items.append(target_item)
	carried_material = item_mat
	target_item = null

	# Look for another nearby item of the same type
	if _can_carry_more(carried_material):
		var next_item: Node3D = _find_nearest_loose_item(
			[_material_to_group(carried_material)], carried_material
		)
		if next_item != null:
			var astar_mgr := _get_astar()
			var valid_path := true
			var next_path := PackedVector3Array()
			if astar_mgr != null and astar_mgr.has_method("find_astar_path"):
				next_path = astar_mgr.find_astar_path(global_position, next_item.global_position)
				if next_path.is_empty():
					valid_path = false
			if valid_path:
				target_item = next_item
				target_item.set_meta("worker_assigned", true)
				if not next_path.is_empty():
					_current_path = next_path
					_path_index = 0
					_destination = next_item.global_position
				else:
					_request_path(target_item.global_position)
				_last_target_pos = target_item.global_position
				_transition_to(State.MOVING_TO_ITEM)
				return

	_go_to_station_or_idle(carried_material)

func _can_carry_more(mat: String) -> bool:
	if mat == "log":
		return carried_items.size() < MAX_LOGS
	elif mat == "plank":
		return carried_items.size() < MAX_PLANKS
	return carried_items.is_empty()

func _material_to_group(mat: String) -> String:
	match mat:
		"log":   return "logs"
		"plank": return "planks"
		_:       return "fragments"

func _go_to_station_or_idle(mat: String) -> void:
	var station: Node3D = _find_nearest_station_for_material(mat)
	if station != null:
		target_station = station
		_request_path(target_station.global_position)
		_last_target_pos = target_station.global_position
		_transition_to(State.MOVING_TO_STATION)
	else:
		_cancel_job("No valid station for %s!" % mat)

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

func _find_nearest_station_for_material(mat: String) -> Node3D:
	var best_station: Node3D = null
	var best_dist_sq: float = INF

	if mat == "log":
		for block in get_tree().get_nodes_in_group("chopping_blocks"):
			if not (block is ChoppingBlock) or not is_instance_valid(block):
				continue
			if block.is_queued_for_deletion() or block.has_log:
				continue
			var d_sq: float = global_position.distance_squared_to(block.global_position)
			if d_sq < best_dist_sq:
				best_dist_sq = d_sq
				best_station = block

	for pallet in get_tree().get_nodes_in_group("pallets"):
		if not (pallet is Pallet) or not is_instance_valid(pallet):
			continue
		if pallet.is_queued_for_deletion():
			continue

		var assigned: String = pallet.assigned_material
		var compatible: bool = false
		if assigned.is_empty():
			compatible = true
		elif pallet.has_method("_materials_compatible"):
			compatible = pallet._materials_compatible(mat, assigned)
		elif assigned == mat:
			compatible = true
		elif (mat == "dirt" or mat == "grass") and (assigned == "dirt" or assigned == "grass"):
			compatible = true

		if compatible:
			var d_sq: float = global_position.distance_squared_to(pallet.global_position)
			if d_sq < best_dist_sq:
				best_dist_sq = d_sq
				best_station = pallet

	return best_station

func _process_moving_to_station(delta: float) -> void:
	if target_station == null or not is_instance_valid(target_station) or target_station.is_queued_for_deletion():
		var alt_station := _find_nearest_station_for_material(carried_material)
		if alt_station != null:
			target_station = alt_station
			_request_path(target_station.global_position)
			_last_target_pos = target_station.global_position
		else:
			_cancel_job("Target station lost!")
			return

	if target_station.global_position.distance_squared_to(_last_target_pos) > 0.4:
		_request_path(target_station.global_position)
		_last_target_pos = target_station.global_position

	# Use horizontal distance only to avoid height mismatches causing deposit failure
	var horiz_dist: float = Vector2(global_position.x - target_station.global_position.x, global_position.z - target_station.global_position.z).length()
	_thought_text = "[CARRYING %d] Transporting to %s | Dist: %.1fm" % [carried_items.size(), target_station.name, horiz_dist]

	if horiz_dist <= reach_distance:
		_transition_to(State.DEPOSIT_ITEM)
		return

	_follow_path(delta)

func _process_deposit_item() -> void:
	if not is_instance_valid(target_station):
		_drop_all_carried()
		target_station = null
		carried_material = ""
		_transition_to(State.SEARCH_JOB)
		return

	var remaining: Array = []
	for item in carried_items:
		if not is_instance_valid(item):
			continue
		var deposited: bool = false
		if target_station is ChoppingBlock and carried_material == "log":
			if (target_station as ChoppingBlock).try_place_log():
				deposited = true
		elif target_station is Pallet:
			var pallet := target_station as Pallet
			if pallet.has_method("refund_material"):
				pallet.refund_material(carried_material, 1)
				deposited = true
			elif pallet.has_method("try_store"):
				deposited = pallet.try_store(carried_material)
			if not deposited and "stored_materials" in pallet:
				pallet.stored_materials[carried_material] = int(pallet.stored_materials.get(carried_material, 0)) + 1
				if pallet.has_method("_refresh_visuals"):
					pallet._refresh_visuals()
				deposited = true

		if deposited:
			item.queue_free()
		else:
			remaining.append(item)

	for leftover in remaining:
		_drop_single_item(leftover)

	carried_items.clear()
	target_station = null
	carried_material = ""
	_transition_to(State.SEARCH_JOB)

# ---------------------------------------------------------------------------
# AStar path-following locomotion
# ---------------------------------------------------------------------------
func _follow_path(delta: float) -> void:
	if not _has_valid_path():
		# No path — coast to a stop
		velocity.x = move_toward(velocity.x, 0.0, move_speed * delta * 5.0)
		velocity.z = move_toward(velocity.z, 0.0, move_speed * delta * 5.0)
		return

	var wp := _current_waypoint()

	# Advance waypoint when close enough (XZ plane only so jump arcs don't skip nodes)
	var xz_dist: float = Vector2(global_position.x - wp.x, global_position.z - wp.z).length()
	if xz_dist < WAYPOINT_REACH:
		_advance_waypoint()
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

# ---------------------------------------------------------------------------
# Job cancellation / item dropping
# ---------------------------------------------------------------------------
func _cancel_job(reason: String) -> void:
	_thought_text = "[BLOCKED] %s" % reason
	if debug_label != null:
		debug_label.text = _thought_text

	if is_instance_valid(target_item):
		target_item.set_meta("worker_assigned", false)
		target_item = null

	_drop_all_carried()

	target_station = null
	carried_material = ""
	_idle_timer = TASK_ABORT_COOLDOWN
	_abort_cooldown = TASK_ABORT_COOLDOWN
	_current_path = PackedVector3Array()
	_path_index = 0
	_transition_to(State.IDLE)

func _drop_all_carried() -> void:
	for item in carried_items:
		_drop_single_item(item)
	carried_items.clear()

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

# ---------------------------------------------------------------------------
# Debug overlay check
# ---------------------------------------------------------------------------
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
