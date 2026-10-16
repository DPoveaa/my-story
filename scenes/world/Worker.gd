class_name Worker
extends CharacterBody3D

## Hauler Bot: Autonomous helper entity with 3D Navigation, multi-item carrying,
## jumping over ledges, structure avoidance, and full-route F3 Debug visualizer.

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
@export var gravity: float = 19.6
@export var reach_distance: float = 2.5
@export var step_height: float = 1.05
## Match player jump strength (approx 5.0) to clear 1-block ledges.
const JUMP_VELOCITY: float = 5.0
## Y threshold above which the worker considers a ledge worth jumping.
const JUMP_THRESHOLD: float = 0.35

## Capacity limits (mirrors player).
const MAX_LOGS: int = 2
const MAX_PLANKS: int = 4

@onready var nav_agent: NavigationAgent3D = $NavigationAgent3D
@onready var carrier_marker: Marker3D = $CarrierMarker3D
@onready var debug_label: Label3D = $DebugLabel3D
@onready var line: Node = get_node_or_null("Line3D")

var current_state: State = State.IDLE
var target_item: Node3D = null
var carried_items: Array = []         # Array of Node3D – replaces single carried_item
var carried_material: String = ""
var target_station: Node3D = null

var _idle_timer: float = 0.0
var _safe_velocity: Vector3 = Vector3.ZERO
var _last_target_pos: Vector3 = Vector3.INF
var _thought_text: String = "[IDLE] Looking for work..."

func _ready() -> void:
	add_to_group("workers")
	add_to_group("npcs")
	collision_layer = 2
	collision_mask = 1
	floor_snap_length = 0.4
	floor_constant_speed = true

	if nav_agent != null:
		nav_agent.path_desired_distance = 0.5
		nav_agent.target_desired_distance = reach_distance
		if "path_height_offset" in nav_agent:
			nav_agent.path_height_offset = 0.0
		if "agent_height_offset" in nav_agent:
			nav_agent.set("agent_height_offset", 0.0)
		nav_agent.avoidance_enabled = true
		if "use_3d_avoidance" in nav_agent:
			nav_agent.use_3d_avoidance = false
		if not nav_agent.velocity_computed.is_connected(_on_velocity_computed):
			nav_agent.velocity_computed.connect(_on_velocity_computed)

	if line != null:
		line.top_level = true

	# Ensure agent starts placed on a valid NavMesh point upon spawn
	_snap_to_navmesh_deferred.call_deferred()

	_transition_to(State.IDLE)

func _snap_to_navmesh_deferred() -> void:
	await get_tree().physics_frame
	if not is_inside_tree():
		return
	var nav_map: RID = get_world_3d().navigation_map if get_world_3d() != null else (nav_agent.get_navigation_map() if nav_agent != null else RID())
	if nav_map.is_valid():
		var closest: Vector3 = NavigationServer3D.map_get_closest_point(nav_map, global_position)
		if closest != Vector3.ZERO and closest.distance_squared_to(global_position) < 36.0:
			global_position = closest + Vector3.UP * 0.05

func _set_nav_target(target_pos: Vector3) -> void:
	_last_target_pos = target_pos
	if nav_agent == null:
		return
	var nav_map: RID = nav_agent.get_navigation_map()
	if nav_map.is_valid():
		var closest: Vector3 = NavigationServer3D.map_get_closest_point(nav_map, target_pos)
		if closest != Vector3.ZERO and closest.distance_squared_to(target_pos) < 36.0:
			nav_agent.target_position = closest
			return
	nav_agent.target_position = target_pos

func _on_velocity_computed(safe_velocity: Vector3) -> void:
	_safe_velocity = safe_velocity

func _physics_process(delta: float) -> void:
	if global_position.y < -50.0:
		queue_free()
		return

	# Gravity & floor contact
	if not is_on_floor():
		velocity.y -= gravity * delta
	else:
		if velocity.y < 0.0:
			velocity.y = -0.1

	# Worker Jumping & Ramp Navigation:
	# Only evaluate ledge jump when actively traversing to item or station
	if is_on_floor() and nav_agent != null and (current_state == State.MOVING_TO_ITEM or current_state == State.MOVING_TO_STATION):
		var next_p: Vector3 = nav_agent.get_next_path_position()
		var y_diff: float = next_p.y - global_position.y
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

	# Step height: handle small bumps/stairs automatically without jumping
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

func _process(_delta: float) -> void:
	var debug_on: bool = _is_debug_overlay_active()

	if debug_label != null:
		debug_label.visible = debug_on
		if debug_on:
			debug_label.text = _thought_text

	if line != null:
		if debug_on and nav_agent != null:
			line.visible = true
			var raw_path: PackedVector3Array = nav_agent.get_current_navigation_path()
			var points: PackedVector3Array = PackedVector3Array()
			if not raw_path.is_empty():
				points.append(global_position + Vector3(0.0, 0.25, 0.0))
				for p in raw_path:
					points.append(p + Vector3(0.0, 0.25, 0.0))
			else:
				var tgt: Vector3 = nav_agent.target_position
				if tgt != Vector3.INF and tgt != Vector3.ZERO:
					points.append(global_position + Vector3(0.0, 0.25, 0.0))
					points.append(tgt + Vector3(0.0, 0.25, 0.0))
			line.points = points
		else:
			line.visible = false

func _transition_to(new_state: State) -> void:
	current_state = new_state
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
	# 1. Search for nearest loose, unassigned Log or Plank within 20m radius
	var item: Node3D = _find_nearest_loose_item(["logs", "planks"])
	# 2. If no logs/planks exist, search for loose Fragments (Dirt/Stone)
	if item == null:
		item = _find_nearest_loose_item(["fragments"])

	if item != null:
		target_item = item
		target_item.set_meta("worker_assigned", true)
		_set_nav_target(target_item.global_position)
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
			# Carried by player or another worker
			if node.get_parent() is Marker3D:
				continue
			# Already assigned to a worker
			if node.get_meta("worker_assigned", false):
				continue
			# Pulled by vacuum or part of pallet craft block
			if node.get_meta("vacuum_pull", false) or node.get_meta("pallet_craft_block", false):
				continue
			# RigidBody check: ignore if frozen inside player hands or other non-loose storage
			if node is RigidBody3D and (node as RigidBody3D).freeze and not node.is_in_group("fragments"):
				continue
			# Optional same-type filter (for multi-pickup pass)
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
	# Validate target item
	if target_item == null or not is_instance_valid(target_item) or target_item.is_queued_for_deletion():
		_cancel_job("Target item lost!")
		return
	if target_item.get_parent() is Marker3D:
		_cancel_job("Target taken by player/worker!")
		return

	# Dynamic target recalculation if item moves
	if target_item.global_position.distance_squared_to(_last_target_pos) > 0.4:
		_set_nav_target(target_item.global_position)

	var dist: float = global_position.distance_to(target_item.global_position)
	_thought_text = "[MOVING] Target: %s | Dist: %.1fm" % [target_item.name, dist]

	# Check arrival (reach distance threshold)
	if (nav_agent != null and nav_agent.is_target_reached()) or dist <= reach_distance:
		_transition_to(State.PICKUP_ITEM)
		return

	_steer_towards(target_item.global_position, delta)

func _process_pickup_item() -> void:
	if target_item == null or not is_instance_valid(target_item) or target_item.is_queued_for_deletion():
		_cancel_job("Target item disappeared!")
		return

	# Determine this item's material
	var item_mat: String = _resolve_item_material(target_item)

	# Capacity check — if already full, skip to station now
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

	# Visual stack offset: each additional item sits 0.28 units above the last
	var stack_index: int = carried_items.size()
	var y_offset: float = float(stack_index) * 0.28

	# Reparent / attach to carrier marker
	var old_parent: Node = target_item.get_parent()
	if old_parent != null:
		old_parent.remove_child(target_item)
	carrier_marker.add_child(target_item)
	target_item.position = Vector3(0.0, y_offset, 0.0)
	target_item.rotation = Vector3.ZERO

	carried_items.append(target_item)
	carried_material = item_mat
	target_item = null

	# If not yet at capacity, look for another nearby item of the SAME type
	if _can_carry_more(carried_material):
		var next_item: Node3D = _find_nearest_loose_item(
			[_material_to_group(carried_material)], carried_material
		)
		if next_item != null:
			target_item = next_item
			target_item.set_meta("worker_assigned", true)
			_set_nav_target(target_item.global_position)
			_transition_to(State.MOVING_TO_ITEM)
			return

	# At capacity or no more nearby items of same type — head to station
	_go_to_station_or_idle(carried_material)

## Returns true when the worker can take another item of this material type.
func _can_carry_more(mat: String) -> bool:
	if mat == "log":
		return carried_items.size() < MAX_LOGS
	elif mat == "plank":
		return carried_items.size() < MAX_PLANKS
	# Fragments / other: single-item capacity
	return carried_items.is_empty()

## Map a material string to its node group name.
func _material_to_group(mat: String) -> String:
	match mat:
		"log":   return "logs"
		"plank": return "planks"
		_:       return "fragments"

## Find nearest station then transition, or cancel if none available.
func _go_to_station_or_idle(mat: String) -> void:
	var station: Node3D = _find_nearest_station_for_material(mat)
	if station != null:
		target_station = station
		_set_nav_target(target_station.global_position)
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

	# If log, check Chopping Blocks that don't have a log
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

	# Check Pallets accepting this material
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
		# Try re-evaluating another station
		var alt_station := _find_nearest_station_for_material(carried_material)
		if alt_station != null:
			target_station = alt_station
			_set_nav_target(target_station.global_position)
		else:
			_cancel_job("Target station lost!")
			return

	# Dynamic target recalculation if station moves
	if target_station.global_position.distance_squared_to(_last_target_pos) > 0.4:
		_set_nav_target(target_station.global_position)

	var dist: float = global_position.distance_to(target_station.global_position)
	_thought_text = "[CARRYING %d] Transporting to %s | Dist: %.1fm" % [carried_items.size(), target_station.name, dist]

	# Check arrival at station (reach distance threshold)
	if (nav_agent != null and nav_agent.is_target_reached()) or dist <= reach_distance:
		_transition_to(State.DEPOSIT_ITEM)
		return

	_steer_towards(target_station.global_position, delta)

func _process_deposit_item() -> void:
	if not is_instance_valid(target_station):
		# Station gone — drop everything
		_drop_all_carried()
		target_station = null
		carried_material = ""
		_transition_to(State.SEARCH_JOB)
		return

	# Deposit items iteratively from the carried_items array
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

	# Drop any items that could not be deposited back into the world
	for leftover in remaining:
		_drop_single_item(leftover)

	carried_items.clear()
	target_station = null
	carried_material = ""
	_transition_to(State.SEARCH_JOB)

func _steer_towards(target_pos: Vector3, delta: float) -> void:
	var next_pos: Vector3 = target_pos
	if nav_agent != null:
		var np: Vector3 = nav_agent.get_next_path_position()
		if np != Vector3.ZERO:
			next_pos = np

	var dir: Vector3 = next_pos - global_position
	dir.y = 0.0
	if dir.length_squared() < 0.001:
		dir = target_pos - global_position
		dir.y = 0.0

	if dir.length_squared() > 0.001:
		dir = dir.normalized()
		var target_yaw: float = atan2(-dir.x, -dir.z)
		rotation.y = lerp_angle(rotation.y, target_yaw, 10.0 * delta)

		var desired_vel: Vector3 = dir * move_speed
		if nav_agent != null and nav_agent.avoidance_enabled:
			nav_agent.set_velocity(desired_vel)
			if _safe_velocity.length_squared() > 0.01:
				velocity.x = _safe_velocity.x
				velocity.z = _safe_velocity.z
			else:
				velocity.x = desired_vel.x
				velocity.z = desired_vel.z
		else:
			velocity.x = desired_vel.x
			velocity.z = desired_vel.z
	else:
		velocity.x = move_toward(velocity.x, 0.0, move_speed * delta * 5.0)
		velocity.z = move_toward(velocity.z, 0.0, move_speed * delta * 5.0)

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
	_idle_timer = 1.0
	_transition_to(State.IDLE)

## Drop all currently carried items back into the world.
func _drop_all_carried() -> void:
	for item in carried_items:
		_drop_single_item(item)
	carried_items.clear()

## Detach a single item from carrier_marker and restore its physics.
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
		rb.collision_layer = 4 # DEBRIS_LAYER
		rb.collision_mask = 1 | 4 # DEBRIS_COLLISION_MASK
		rb.linear_velocity = Vector3(randf_range(-0.5, 0.5), 0.8, randf_range(-0.5, 0.5))

	item.set_meta("worker_assigned", false)


func _has_navigation_mesh() -> bool:
	if nav_agent == null:
		return false
	var nav_map: RID = nav_agent.get_navigation_map()
	return not NavigationServer3D.map_get_regions(nav_map).is_empty()

func _is_debug_overlay_active() -> bool:
	# 1. Check for CanvasLayer named DebugOverlay
	var overlay: Node = get_tree().root.find_child("DebugOverlay", true, false)
	if overlay != null and overlay is CanvasLayer:
		return (overlay as CanvasLayer).visible
	# 2. Check BuildHUD
	var hud: Node = get_tree().root.find_child("BuildHUD", true, false)
	if hud != null:
		var v = hud.get("_debug_visible")
		if v != null:
			return bool(v)
	# 3. Check Player
	var player_node: Node = get_tree().root.find_child("Player", true, false)
	if player_node != null:
		var v = player_node.get("_debug_overlay_enabled")
		if v != null:
			return bool(v)
	return false
