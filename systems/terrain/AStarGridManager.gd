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
var _column_to_cells: Dictionary = {}  ## Vector2i(x, z) -> Array[Vector3i]
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
var _initialized: bool = false
var _t_bake_start: int = 0
var _is_chunk_active: bool = false
var _active_chunk: Vector2i = Vector2i.ZERO
var _active_col_idx: int = 0
var _active_chunk_new_cells: Array[Vector3i] = []

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

	if _voxel_world.has_signal("chunk_loaded"):
		if not _voxel_world.chunk_loaded.is_connected(_on_chunk_loaded):
			_voxel_world.chunk_loaded.connect(_on_chunk_loaded)

func initialize_once(spawn_pos: Vector3) -> void:
	if _initialized:
		return
	_initialized = true
	_t_bake_start = Time.get_ticks_msec()
	update_center(spawn_pos)
	rebuild_graph()

## Per-frame wall-clock budget in milliseconds. Processes column batches within
## this window, then yields back to the engine to avoid frame spikes.
const FRAME_BUDGET_MS: float = 2.0

func _ready() -> void:
	pass  ## No startup delay needed — physics queries are skipped during initial bake.

func _process(_delta: float) -> void:
	if not _is_chunk_active and _pending_chunks.is_empty():
		# Queue just drained — emit graph_rebuilt once and mark initial bake complete.
		if _graph_rebuilt_pending:
			_graph_rebuilt_pending = false
			if not _initial_bake_done:
				_initial_bake_done = true
				if _t_bake_start > 0:
					var elapsed: int = Time.get_ticks_msec() - _t_bake_start
					print("[StartupTiming] A* baking took: %d ms" % elapsed)
			graph_rebuilt.emit()
		return

	# Incrementally consume columns within the per-frame time budget.
	var frame_start_ms: int = Time.get_ticks_msec()
	while true:
		if not _is_chunk_active:
			if _pending_chunks.is_empty():
				break
			var next_chunk = _pending_chunks.pop_front()
			_begin_chunk_bake(next_chunk)
			if not _is_chunk_active:
				continue

		var half_y: int = BOUNDS_Y / 2
		var min_y: int = roundi(_center.y) - half_y if _center != Vector3.ZERO else 0
		var max_y: int = roundi(_center.y) + half_y if _center != Vector3.ZERO else 128
		var start_x: int = _active_chunk.x * CHUNK_SIZE
		var start_z: int = _active_chunk.y * CHUNK_SIZE

		while _active_col_idx < 256:
			var lx: int = _active_col_idx % CHUNK_SIZE
			var lz: int = _active_col_idx / CHUNK_SIZE
			_active_col_idx += 1
			var x: int = start_x + lx
			var z: int = start_z + lz

			var surf_y: int = -1
			if _voxel_world.has_method("get_highest_solid_y"):
				surf_y = _voxel_world.get_highest_solid_y(x, z)

			if surf_y >= min_y:
				var scan_top: int = mini(max_y, surf_y)
				var y: int = min_y - 1
				while y <= scan_top:
					if _voxel_world.has_method("is_solid_block") and _voxel_world.is_solid_block(Vector3i(x, y, z)):
						var walk_cell := Vector3i(x, y + 1, z)
						var head_cell := Vector3i(x, y + 2, z)
						if not _voxel_world.is_solid_block(walk_cell) and not _voxel_world.is_solid_block(head_cell):
							var valid := true
							if _initial_bake_done:
								if _is_position_blocked_by_physics(walk_cell) or _is_position_blocked_by_physics(head_cell):
									valid = false
							if valid:
								_active_chunk_new_cells.append(walk_cell)
							y += 2
						else:
							y += 1
					else:
						y += 1

			if _active_col_idx % 8 == 0:
				if float(Time.get_ticks_msec() - frame_start_ms) >= FRAME_BUDGET_MS:
					return

		_finish_chunk_bake()

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
	# Mask 1 = World/Stations/Buildings/Placed Blocks (excludes loose layer 4 pickups)
	ray_query.collision_mask = 1
	var ray_hit := direct_state.intersect_ray(ray_query)
	if ray_hit.is_empty():
		return false

	var collider = ray_hit.get("collider", null)
	if collider != null:
		# Exclude terrain mesh: terrain solidity is already verified directly by voxel data
		if collider == _voxel_world:
			return false
		if collider is Node and (collider == _voxel_world or collider.get_parent() == _voxel_world):
			return false
		if collider.is_class("VoxelTerrain") or (collider is Node and (collider as Node).is_in_group("voxel_terrain")):
			return false
		if "generator" in collider and "generate_collisions" in collider:
			return false

	return true

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
	_column_to_cells.clear()
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

## Begin an incremental chunk bake (used by _process for the 2ms budget loop).
func _begin_chunk_bake(current_chunk: Variant) -> void:
	if _voxel_world == null:
		_is_chunk_active = false
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
		_is_chunk_active = false
		return

	if _voxel_world.has_method("is_chunk_loaded") and not _voxel_world.is_chunk_loaded(cp):
		_is_chunk_active = false
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
				if _column_to_cells.has(col):
					_column_to_cells[col].erase(old_cell)
					if _column_to_cells[col].is_empty():
						_column_to_cells.erase(col)
		_chunk_points[cp].clear()

	_active_chunk = cp
	_active_col_idx = 0
	_active_chunk_new_cells.clear()
	_is_chunk_active = true

## Finish registering points collected so far and wiring edges for _active_chunk.
func _finish_chunk_bake() -> void:
	if not _is_chunk_active:
		return
	_is_chunk_active = false

	var new_cells: Array[Vector3i] = _active_chunk_new_cells.duplicate()
	_active_chunk_new_cells.clear()
	var cp: Vector2i = _active_chunk

	# Register points into AStar3D
	for cell in new_cells:
		var world_pos := Vector3(float(cell.x) + 0.5, float(cell.y), float(cell.z) + 0.5)
		var id: int = _next_id
		_next_id += 1
		_astar.add_point(id, world_pos)
		_point_ids[cell] = id
		_id_cells[id] = cell
		var col := Vector2i(cell.x, cell.z)
		if not _column_to_cells.has(col):
			_column_to_cells[col] = []
		_column_to_cells[col].append(cell)

	if not _chunk_points.has(cp):
		_chunk_points[cp] = []
	_chunk_points[cp].append_array(new_cells)

	# Connect immediate adjacent orthogonal neighbors (4 cardinal + step-ups)
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

	_graph_rebuilt_pending = true

## Synchronous full-chunk bake — used only for post-startup dynamic edits.
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

	if _chunk_points.has(cp):
		for old_cell in _chunk_points[cp]:
			if _point_ids.has(old_cell):
				var old_id: int = _point_ids[old_cell]
				_astar.remove_point(old_id)
				_point_ids.erase(old_cell)
				_id_cells.erase(old_id)
				var col := Vector2i(old_cell.x, old_cell.z)
				if _column_to_cells.has(col):
					_column_to_cells[col].erase(old_cell)
					if _column_to_cells[col].is_empty():
						_column_to_cells.erase(col)
		_chunk_points[cp].clear()

	var half_y: int = BOUNDS_Y / 2
	var min_y: int = roundi(_center.y) - half_y if _center != Vector3.ZERO else 0
	var max_y: int = roundi(_center.y) + half_y if _center != Vector3.ZERO else 128

	var new_cells: Array[Vector3i] = []
	var start_x: int = cp.x * CHUNK_SIZE
	var start_z: int = cp.y * CHUNK_SIZE

	for x in range(start_x, start_x + CHUNK_SIZE):
		for z in range(start_z, start_z + CHUNK_SIZE):
			var surf_y: int = -1
			if _voxel_world.has_method("get_highest_solid_y"):
				surf_y = _voxel_world.get_highest_solid_y(x, z)

			if surf_y >= min_y:
				var scan_top: int = mini(max_y, surf_y)
				var y: int = min_y - 1
				while y <= scan_top:
					if _voxel_world.has_method("is_solid_block") and _voxel_world.is_solid_block(Vector3i(x, y, z)):
						var walk_cell := Vector3i(x, y + 1, z)
						var head_cell := Vector3i(x, y + 2, z)
						if not _voxel_world.is_solid_block(walk_cell) and not _voxel_world.is_solid_block(head_cell):
							var valid := true
							if _initial_bake_done:
								if _is_position_blocked_by_physics(walk_cell) or _is_position_blocked_by_physics(head_cell):
									valid = false
							if valid:
								new_cells.append(walk_cell)
							y += 2
						else:
							y += 1
					else:
						y += 1

	for cell in new_cells:
		var world_pos := Vector3(float(cell.x) + 0.5, float(cell.y), float(cell.z) + 0.5)
		var id: int = _next_id
		_next_id += 1
		_astar.add_point(id, world_pos)
		_point_ids[cell] = id
		_id_cells[id] = cell
		var col := Vector2i(cell.x, cell.z)
		if not _column_to_cells.has(col):
			_column_to_cells[col] = []
		_column_to_cells[col].append(cell)

	if not _chunk_points.has(cp):
		_chunk_points[cp] = []
	_chunk_points[cp].append_array(new_cells)

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
	graph_rebuilt.emit()

func notify_bounds_changed(aabb: AABB) -> void:
	var min_cell := Vector3i(floori(aabb.position.x), floori(aabb.position.y), floori(aabb.position.z))
	var max_cell := Vector3i(ceili(aabb.end.x), ceili(aabb.end.y), ceili(aabb.end.z))
	for x in range(min_cell.x, max_cell.x + 1):
		for z in range(min_cell.z, max_cell.z + 1):
			_update_local_column(x, z)
			for off in ADJACENT_OFFSETS:
				_reconnect_column(x + off.x, z + off.y)
	graph_rebuilt.emit()

func _update_local_column(x: int, z: int) -> void:
	if _voxel_world == null:
		return
	var col := Vector2i(x, z)
	if _column_to_cells.has(col):
		var old_cells: Array = _column_to_cells[col].duplicate()
		for old_cell in old_cells:
			_remove_point_at(old_cell)

	var surf_y: int = -1
	if _voxel_world.has_method("get_highest_solid_y"):
		surf_y = _voxel_world.get_highest_solid_y(x, z)

	var half_y: int = BOUNDS_Y / 2
	var min_y: int = roundi(_center.y) - half_y if _center != Vector3.ZERO else 0
	var max_y: int = roundi(_center.y) + half_y if _center != Vector3.ZERO else 128

	if surf_y < min_y:
		return

	var scan_top: int = mini(max_y, surf_y)
	var y: int = min_y - 1
	while y <= scan_top:
		if _voxel_world.has_method("is_solid_block") and _voxel_world.is_solid_block(Vector3i(x, y, z)):
			var walk_cell := Vector3i(x, y + 1, z)
			var head_cell := Vector3i(x, y + 2, z)
			if not _voxel_world.is_solid_block(walk_cell) and not _voxel_world.is_solid_block(head_cell):
				var valid := true
				if _initial_bake_done:
					if _is_position_blocked_by_physics(walk_cell) or _is_position_blocked_by_physics(head_cell):
						valid = false
				if valid:
					_add_and_connect_point(walk_cell)
				y += 2
			else:
				y += 1
		else:
			y += 1

func _reconnect_column(x: int, z: int) -> void:
	var col := Vector2i(x, z)
	if not _column_to_cells.has(col):
		return
	for cell in _column_to_cells[col]:
		if not _point_ids.has(cell):
			continue
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
	if _column_to_cells.has(col):
		_column_to_cells[col].erase(cell)
		if _column_to_cells[col].is_empty():
			_column_to_cells.erase(col)
	var cp := Vector2i(floori(float(cell.x) / float(CHUNK_SIZE)), floori(float(cell.z) / float(CHUNK_SIZE)))
	if _chunk_points.has(cp):
		_chunk_points[cp].erase(cell)

func _add_and_connect_point(cell: Vector3i) -> int:
	if _point_ids.has(cell):
		return _point_ids[cell]
	if _initial_bake_done and _is_position_blocked_by_physics(cell):
		return -1
	var id: int = _next_id
	_next_id += 1
	var world_pos := Vector3(float(cell.x) + 0.5, float(cell.y), float(cell.z) + 0.5)
	_astar.add_point(id, world_pos)
	_point_ids[cell] = id
	_id_cells[id] = cell
	var col := Vector2i(cell.x, cell.z)
	if not _column_to_cells.has(col):
		_column_to_cells[col] = []
	_column_to_cells[col].append(cell)

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

func find_approach_path(from_world: Vector3, target_world: Vector3, min_dist: float = 0.5, max_dist: float = 2.4) -> PackedVector3Array:
	## Finds a path from from_world to a valid, walkable approach node beside target_world.
	var from_id := _closest_point_id(from_world)
	if from_id < 0:
		return PackedVector3Array()

	var target_col := Vector2i(floori(target_world.x), floori(target_world.z))
	var candidates: Array[Dictionary] = []

	# Check columns in a 5x5 grid around target (up to 2 blocks away horizontally)
	for dx in range(-2, 3):
		for dz in range(-2, 3):
			var col := Vector2i(target_col.x + dx, target_col.y + dz)
			if not _column_to_cells.has(col):
				continue
			for cell in _column_to_cells[col]:
				if not _point_ids.has(cell):
					continue
				var cand_id: int = _point_ids[cell]
				var cand_pos: Vector3 = _astar.get_point_position(cand_id)
				var d_target: float = cand_pos.distance_to(target_world)
				var y_diff: float = absf(cand_pos.y - target_world.y)
				if d_target <= max_dist and y_diff <= 1.8:
					var d_from: float = cand_pos.distance_squared_to(from_world)
					candidates.append({"id": cand_id, "dist_target": d_target, "dist_from": d_from})

	if candidates.is_empty():
		var direct_to_id := _closest_point_id(target_world)
		if direct_to_id >= 0:
			return _astar.get_point_path(from_id, direct_to_id)
		return PackedVector3Array()

	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["dist_from"] < b["dist_from"]
	)

	for i in range(mini(4, candidates.size())):
		var cand_id: int = candidates[i]["id"]
		var path: PackedVector3Array = _astar.get_point_path(from_id, cand_id)
		if not path.is_empty():
			return path

	return PackedVector3Array()

func get_closest_walkable_pos(world_pos: Vector3) -> Vector3:
	## Snaps a world position to the nearest walkable AStar node.
	var id := _closest_point_id(world_pos)
	if id < 0:
		return world_pos
	return _astar.get_point_position(id)

func _closest_point_id(world_pos: Vector3) -> int:
	if _astar.get_point_count() == 0:
		return -1

	var target_col := Vector2i(floori(world_pos.x), floori(world_pos.z))
	var best_id: int = -1
	var best_dist_sq: float = INF

	# 1. Search local 3x3 columns around world_pos to find closest 3D match without skipping tunnel levels
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			var col := Vector2i(target_col.x + dx, target_col.y + dz)
			if not _column_to_cells.has(col):
				continue
			for cell in _column_to_cells[col]:
				if not _point_ids.has(cell):
					continue
				var id: int = _point_ids[cell]
				var pt_pos: Vector3 = _astar.get_point_position(id)
				var d_sq: float = pt_pos.distance_squared_to(world_pos)
				if d_sq < 16.0 and absf(pt_pos.y - world_pos.y) <= 2.2:
					if d_sq < best_dist_sq:
						best_dist_sq = d_sq
						best_id = id

	if best_id >= 0:
		return best_id

	# 2. Fallback to global closest point within 4m
	var global_id: int = _astar.get_closest_point(world_pos)
	if global_id >= 0 and _id_cells.has(global_id):
		if _astar.get_point_position(global_id).distance_squared_to(world_pos) <= 16.0:
			return global_id

	return -1
