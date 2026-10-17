class_name AStarGridManager
extends Node

## Deterministic, lightweight, signal-driven AStar3D pathfinder for voxel terrain.
## Restricts graph nodes strictly to walkable surface voxels, decouples AStar baking
## from voxel generation using a debounced pending queue consumed 1 chunk per frame,
## eliminates GDScript hash maps, and relies on native C++ AStar3D edge deduplication.
##
## Usage:
##   var path: PackedVector3Array = astar_mgr.find_astar_path(from_world_pos, to_world_pos)
##
## Workers fetch it via get_node("/root/GameWorld/AStarGridManager") or GameWorld.astar_grid.

signal graph_rebuilt

const BLOCK_SIZE: float = 1.0
const STEP_UP_MAX: int = 1
const WALK_CLEARANCE: int = 1  ## Only 1 block clearance: walk_cell and head_cell only (2-block tunnel support)
const CHUNK_SIZE: int = 16

## Bounded initial generation volume around player/base spawn (max 64x32x64 blocks)
const BOUNDS_XZ: int = 64
const BOUNDS_Y: int = 32

## Immediate orthogonal adjacent neighbor offsets (cardinal directions only)
const ADJACENT_OFFSETS: Array[Vector2i] = [
	Vector2i(1, 0),
	Vector2i(-1, 0),
	Vector2i(0, 1),
	Vector2i(0, -1),
]

var _astar: AStar3D = AStar3D.new()
var _voxel_world: Node = null
var _point_ids: Dictionary = {}        ## Vector3i cell -> int AStar point id
var _id_cells: Dictionary = {}         ## int id -> Vector3i cell
var _column_to_cell: Dictionary = {}   ## Vector2i(x, z) -> Vector3i cell
var _chunk_points: Dictionary = {}     ## Vector2i chunk_coord -> Array[Vector3i]
var _baked_chunks: Dictionary = {}     ## Vector2i chunk_coord -> bool
var _pending_chunks: Array = []        ## Debounced chunk queue for lazy baking
var _next_id: int = 0
var _center: Vector3 = Vector3.ZERO
## True after the initial startup bake queue has been fully drained once.
## Physics-intersection rejection is only applied AFTER this point (post-startup edits).
var _initial_bake_done: bool = false
## Whether a graph_rebuilt signal is pending to be emitted once the queue drains.
var _graph_rebuilt_pending: bool = false

# ---------------------------------------------------------------------------
# Setup & Lifecycle
# ---------------------------------------------------------------------------
func setup(voxel_world: Node) -> void:
	_voxel_world = voxel_world
	if _voxel_world == null:
		return

	if _voxel_world.has_signal("voxel_mined"):
		if not _voxel_world.voxel_mined.is_connected(_on_voxel_changed):
			_voxel_world.voxel_mined.connect(_on_voxel_changed)

	if _voxel_world.has_signal("spawn_chunks_ready"):
		if not _voxel_world.spawn_chunks_ready.is_connected(rebuild_graph):
			_voxel_world.spawn_chunks_ready.connect(rebuild_graph)

	if _voxel_world.has_signal("chunk_loaded"):
		if not _voxel_world.chunk_loaded.is_connected(_on_chunk_loaded):
			_voxel_world.chunk_loaded.connect(_on_chunk_loaded)

## Per-frame wall-clock budget in milliseconds. Processes as many queued chunks as
## possible within this window, then yields back to the engine to avoid frame spikes.
const FRAME_BUDGET_MS: float = 2.0

func _ready() -> void:
	pass  ## No startup delay needed — physics queries are skipped during initial bake.

func _process(_delta: float) -> void:
	if _pending_chunks.is_empty():
		# Queue just drained — emit graph_rebuilt once and mark initial bake complete.
		if _graph_rebuilt_pending:
			_graph_rebuilt_pending = false
			_initial_bake_done = true
			graph_rebuilt.emit()
		return

	# Consume as many chunks as possible within the per-frame time budget.
	var frame_start_ms: int = Time.get_ticks_msec()
	while not _pending_chunks.is_empty():
		var current_chunk = _pending_chunks.pop_front()
		_bake_single_chunk(current_chunk)
		# Check wall-clock budget; yield if over limit to keep frame time bounded.
		if float(Time.get_ticks_msec() - frame_start_ms) >= FRAME_BUDGET_MS:
			break

func _is_position_blocked_by_physics(cell: Vector3i) -> bool:
	if not is_inside_tree():
		return false
	var viewport := get_viewport()
	if viewport == null:
		return false
	var world_3d: World3D = viewport.find_world_3d()
	if world_3d == null or not world_3d.space.is_valid():
		return false
	var direct_state: PhysicsDirectSpaceState3D = PhysicsServer3D.space_get_direct_state(world_3d.space)
	if direct_state == null:
		return false

	var center := Vector3(float(cell.x) + 0.5, float(cell.y) + 0.5, float(cell.z) + 0.5)
	# Raycast within the cell interior to avoid detecting ground/ceiling boundaries
	var ray_query := PhysicsRayQueryParameters3D.create(
		center + Vector3(0.0, 0.4, 0.0),
		center - Vector3(0.0, 0.4, 0.0)
	)
	# Mask 1 = World/Stations/Buildings, Mask 4 = Debris, Mask 8 = Placed Blocks / Resources
	ray_query.collision_mask = 1 | 4 | 8
	var ray_hit := direct_state.intersect_ray(ray_query)
	return not ray_hit.is_empty()

func update_center(world_pos: Vector3) -> void:
	## Stores current center without polling chunks or triggering heavy rebuilds.
	_center = world_pos

# ---------------------------------------------------------------------------
# Graph Construction & Queue Debouncing
# ---------------------------------------------------------------------------
func queue_chunk(target: Variant) -> void:
	var cp: Vector2i
	if target is Vector2i:
		cp = target
	elif target is Vector3i:
		cp = Vector2i(floori(float(target.x) / float(CHUNK_SIZE)), floori(float(target.z) / float(CHUNK_SIZE)))
	elif target is Vector3:
		cp = Vector2i(floori(target.x / float(CHUNK_SIZE)), floori(target.z / float(CHUNK_SIZE)))
	elif target is Vector2:
		cp = Vector2i(floori(target.x / float(CHUNK_SIZE)), floori(target.y / float(CHUNK_SIZE)))
	else:
		return

	if not _pending_chunks.has(cp):
		_pending_chunks.append(cp)

func rebuild_graph() -> void:
	if _voxel_world == null:
		return

	_astar.clear()
	_point_ids.clear()
	_id_cells.clear()
	_column_to_cell.clear()
	_chunk_points.clear()
	_baked_chunks.clear()
	_next_id = 0
	_pending_chunks.clear()

	var cx: int = roundi(_center.x)
	var cz: int = roundi(_center.z)
	var half_xz: int = BOUNDS_XZ / 2

	var min_cx: int = floori(float(cx - half_xz) / float(CHUNK_SIZE))
	var max_cx: int = floori(float(cx + half_xz) / float(CHUNK_SIZE))
	var min_cz: int = floori(float(cz - half_xz) / float(CHUNK_SIZE))
	var max_cz: int = floori(float(cz + half_xz) / float(CHUNK_SIZE))

	for cz_idx in range(min_cz, max_cz + 1):
		for cx_idx in range(min_cx, max_cx + 1):
			var cp := Vector2i(cx_idx, cz_idx)
			queue_chunk(cp)

func _bake_single_chunk(current_chunk: Variant) -> void:
	if _voxel_world == null:
		return

	var cp: Vector2i
	if current_chunk is Vector2i:
		cp = current_chunk
	elif current_chunk is Vector3i:
		cp = Vector2i(floori(float(current_chunk.x) / float(CHUNK_SIZE)), floori(float(current_chunk.z) / float(CHUNK_SIZE)))
	elif current_chunk is Vector3:
		cp = Vector2i(floori(current_chunk.x / float(CHUNK_SIZE)), floori(current_chunk.z / float(CHUNK_SIZE)))
	elif current_chunk is Vector2:
		cp = Vector2i(floori(current_chunk.x / float(CHUNK_SIZE)), floori(current_chunk.y / float(CHUNK_SIZE)))
	else:
		return

	if _voxel_world.has_method("is_chunk_loaded") and not _voxel_world.is_chunk_loaded(cp):
		return

	_baked_chunks[cp] = true

	# Clean up any previously baked points in this chunk before re-baking
	if _chunk_points.has(cp):
		for old_cell in _chunk_points[cp]:
			if _point_ids.has(old_cell):
				var old_id: int = _point_ids[old_cell]
				_astar.remove_point(old_id)
				_point_ids.erase(old_cell)
				_id_cells.erase(old_id)
				var col := Vector2i(old_cell.x, old_cell.z)
				if _column_to_cell.get(col) == old_cell:
					_column_to_cell.erase(col)
		_chunk_points[cp].clear()

	var half_y: int = BOUNDS_Y / 2
	var min_y: int = roundi(_center.y) - half_y if _center != Vector3.ZERO else 0
	var max_y: int = roundi(_center.y) + half_y if _center != Vector3.ZERO else 128

	var new_cells: Array[Vector3i] = []
	var start_x: int = cp.x * CHUNK_SIZE
	var start_z: int = cp.y * CHUNK_SIZE

	# Strictly surface voxels only: 1 query per column (256 columns per chunk)
	for x in range(start_x, start_x + CHUNK_SIZE):
		for z in range(start_z, start_z + CHUNK_SIZE):
			var surf_y: int = -1
			if _voxel_world.has_method("get_highest_solid_y"):
				surf_y = _voxel_world.get_highest_solid_y(x, z)

			if surf_y < min_y or surf_y > max_y:
				continue

			var ground_cell := Vector3i(x, surf_y, z)
			var walk_cell := Vector3i(x, surf_y + 1, z)
			var head_cell := Vector3i(x, surf_y + 2, z)

			# Only add point if ground is SOLID and headroom is AIR/EMPTY
			if _voxel_world.has_method("is_solid_block"):
				if not _voxel_world.is_solid_block(ground_cell):
					continue
				if _voxel_world.is_solid_block(walk_cell) or _voxel_world.is_solid_block(head_cell):
					continue

			# Physics intersection checks (for placed objects / pallets / stations) are
			# SKIPPED during the initial startup bake to avoid thousands of synchronous
			# PhysicsServer3D queries flooding the main thread before gameplay begins.
			# After startup (_initial_bake_done = true), these checks run normally so
			# that dynamically placed blocks correctly invalidate walkable cells.
			if _initial_bake_done:
				if _is_position_blocked_by_physics(walk_cell) or _is_position_blocked_by_physics(head_cell):
					continue

			new_cells.append(walk_cell)

	# Register points into AStar3D
	for cell in new_cells:
		var world_pos := Vector3(float(cell.x) + 0.5, float(cell.y), float(cell.z) + 0.5)
		var id: int = _next_id
		_next_id += 1
		_astar.add_point(id, world_pos)
		_point_ids[cell] = id
		_id_cells[id] = cell
		_column_to_cell[Vector2i(cell.x, cell.z)] = cell

	if not _chunk_points.has(cp):
		_chunk_points[cp] = []
	_chunk_points[cp].append_array(new_cells)

	# Connect immediate adjacent orthogonal neighbors (4 cardinal + step-ups)
	# Native C++ AStar3D handles edge deduplication directly
	for cell in new_cells:
		var from_id: int = _point_ids[cell]
		for off in ADJACENT_OFFSETS:
			for dy in range(-STEP_UP_MAX, STEP_UP_MAX + 1):
				var neighbor := Vector3i(cell.x + off.x, cell.y + dy, cell.z + off.y)
				if not _point_ids.has(neighbor):
					continue
				var to_id: int = _point_ids[neighbor]
				if from_id == to_id:
					continue
				var pos_a: Vector3 = _astar.get_point_position(from_id)
				var pos_b: Vector3 = _astar.get_point_position(to_id)
				if absf(pos_a.y - pos_b.y) > 1.1:
					continue
				_astar.connect_points(from_id, to_id, true)
				if dy > 0:
					_astar.set_point_weight_scale(to_id, 1.5)

	# Mark that a signal should fire once the full queue drains (not per-chunk).
	_graph_rebuilt_pending = true

# ---------------------------------------------------------------------------
# Signal-Driven Dynamic Expansion & Voxel Edits
# ---------------------------------------------------------------------------
func bake_chunk_if_needed(cp: Vector2i) -> void:
	if _baked_chunks.has(cp) and not _pending_chunks.has(cp):
		return
	queue_chunk(cp)

func notify_block_changed(world_cell: Vector3i) -> void:
	_update_local_column(world_cell.x, world_cell.z)
	for off in ADJACENT_OFFSETS:
		_reconnect_column(world_cell.x + off.x, world_cell.z + off.y)

func _update_local_column(x: int, z: int) -> void:
	if _voxel_world == null:
		return
	var col := Vector2i(x, z)
	if _column_to_cell.has(col):
		var old_cell: Vector3i = _column_to_cell[col]
		_remove_point_at(old_cell)

	var surf_y: int = -1
	if _voxel_world.has_method("get_highest_solid_y"):
		surf_y = _voxel_world.get_highest_solid_y(x, z)

	var half_y: int = BOUNDS_Y / 2
	var min_y: int = roundi(_center.y) - half_y if _center != Vector3.ZERO else 0
	var max_y: int = roundi(_center.y) + half_y if _center != Vector3.ZERO else 128

	if surf_y < min_y or surf_y > max_y:
		return

	var ground_cell := Vector3i(x, surf_y, z)
	var walk_cell := Vector3i(x, surf_y + 1, z)
	var head_cell := Vector3i(x, surf_y + 2, z)

	if _voxel_world.has_method("is_solid_block"):
		if not _voxel_world.is_solid_block(ground_cell):
			return
		if _voxel_world.is_solid_block(walk_cell) or _voxel_world.is_solid_block(head_cell):
			return

	if _initial_bake_done:
		if _is_position_blocked_by_physics(walk_cell) or _is_position_blocked_by_physics(head_cell):
			return

	_add_and_connect_point(walk_cell)

func _reconnect_column(x: int, z: int) -> void:
	var col := Vector2i(x, z)
	if not _column_to_cell.has(col):
		return
	var cell: Vector3i = _column_to_cell[col]
	if not _point_ids.has(cell):
		return
	var id: int = _point_ids[cell]
	for off in ADJACENT_OFFSETS:
		for dy in range(-STEP_UP_MAX, STEP_UP_MAX + 1):
			var neighbor := Vector3i(cell.x + off.x, cell.y + dy, cell.z + off.y)
			if not _point_ids.has(neighbor):
				continue
			var to_id: int = _point_ids[neighbor]
			if id == to_id:
				continue
			var pos_a: Vector3 = _astar.get_point_position(id)
			var pos_b: Vector3 = _astar.get_point_position(to_id)
			if absf(pos_a.y - pos_b.y) <= 1.1:
				_astar.connect_points(id, to_id, true)
				if dy > 0:
					_astar.set_point_weight_scale(to_id, 1.5)

func _on_voxel_changed(world_cell: Vector3i, _block_type: StringName = &"") -> void:
	notify_block_changed(world_cell)

func _on_chunk_loaded(chunk_pos: Variant) -> void:
	queue_chunk(chunk_pos)

func _update_local_voxel_edit(world_cell: Vector3i) -> void:
	notify_block_changed(world_cell)

func _remove_point_at(cell: Vector3i) -> void:
	if not _point_ids.has(cell):
		return
	var id: int = _point_ids[cell]
	_astar.remove_point(id)
	_point_ids.erase(cell)
	_id_cells.erase(id)
	var col := Vector2i(cell.x, cell.z)
	if _column_to_cell.get(col) == cell:
		_column_to_cell.erase(col)
	var cp := Vector2i(floori(float(cell.x) / float(CHUNK_SIZE)), floori(float(cell.z) / float(CHUNK_SIZE)))
	if _chunk_points.has(cp):
		_chunk_points[cp].erase(cell)

func _add_and_connect_point(cell: Vector3i) -> int:
	if _point_ids.has(cell):
		return _point_ids[cell]
	if _is_position_blocked_by_physics(cell):
		return -1
	var id: int = _next_id
	_next_id += 1
	var world_pos := Vector3(float(cell.x) + 0.5, float(cell.y), float(cell.z) + 0.5)
	_astar.add_point(id, world_pos)
	_point_ids[cell] = id
	_id_cells[id] = cell
	_column_to_cell[Vector2i(cell.x, cell.z)] = cell

	var cp := Vector2i(floori(float(cell.x) / float(CHUNK_SIZE)), floori(float(cell.z) / float(CHUNK_SIZE)))
	if not _chunk_points.has(cp):
		_chunk_points[cp] = []
	_chunk_points[cp].append(cell)

	for off in ADJACENT_OFFSETS:
		for dy in range(-STEP_UP_MAX, STEP_UP_MAX + 1):
			var neighbor := Vector3i(cell.x + off.x, cell.y + dy, cell.z + off.y)
			if not _point_ids.has(neighbor):
				continue
			var to_id: int = _point_ids[neighbor]
			if id == to_id:
				continue
			var pos_a: Vector3 = _astar.get_point_position(id)
			var pos_b: Vector3 = _astar.get_point_position(to_id)
			if absf(pos_a.y - pos_b.y) > 1.1:
				continue
			_astar.connect_points(id, to_id, true)
			if dy > 0:
				_astar.set_point_weight_scale(to_id, 1.5)
	return id

# ---------------------------------------------------------------------------
# Public Query API
# ---------------------------------------------------------------------------
func find_astar_path(from_world: Vector3, to_world: Vector3) -> PackedVector3Array:
	## Returns the world-space waypoint array from AStar3D.
	## Returns empty array if either endpoint is off-graph.
	var from_id := _closest_point_id(from_world)
	var to_id   := _closest_point_id(to_world)
	if from_id < 0 or to_id < 0:
		return PackedVector3Array()
	return _astar.get_point_path(from_id, to_id)

func get_astar_path(from_world: Vector3, to_world: Vector3) -> PackedVector3Array:
	return find_astar_path(from_world, to_world)

func get_closest_walkable_pos(world_pos: Vector3) -> Vector3:
	## Snaps a world position to the nearest walkable AStar node.
	var id := _closest_point_id(world_pos)
	if id < 0:
		return world_pos
	return _astar.get_point_position(id)

func _closest_point_id(world_pos: Vector3) -> int:
	## Find the closest graph point within 3 blocks; returns -1 if none.
	if _astar.get_point_count() == 0:
		return -1
	var id: int = _astar.get_closest_point(world_pos)
	if id < 0 or not _id_cells.has(id):
		return -1
	if _astar.get_point_position(id).distance_squared_to(world_pos) > 9.0:
		return -1
	return id
