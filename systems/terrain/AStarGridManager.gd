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

## Cardinal orthogonal adjacent neighbor offsets
const CARDINAL_OFFSETS: Array[Vector2i] = [
	Vector2i(1, 0),
	Vector2i(-1, 0),
	Vector2i(0, 1),
	Vector2i(0, -1),
]

## Diagonal neighbor offsets
const DIAGONAL_OFFSETS: Array[Vector2i] = [
	Vector2i(1, 1),
	Vector2i(1, -1),
	Vector2i(-1, 1),
	Vector2i(-1, -1),
]

## All 8 adjacent horizontal neighbor offsets
const ADJACENT_OFFSETS: Array[Vector2i] = [
	Vector2i(1, 0),
	Vector2i(-1, 0),
	Vector2i(0, 1),
	Vector2i(0, -1),
	Vector2i(1, 1),
	Vector2i(1, -1),
	Vector2i(-1, 1),
	Vector2i(-1, -1),
]

var _clearance_shape: CapsuleShape3D = null
var _clearance_query: PhysicsShapeQueryParameters3D = null

func _get_clearance_query() -> PhysicsShapeQueryParameters3D:
	if _clearance_query == null:
		_clearance_shape = CapsuleShape3D.new()
		_clearance_shape.radius = 0.32
		_clearance_shape.height = 1.45
		_clearance_query = PhysicsShapeQueryParameters3D.new()
		_clearance_query.shape = _clearance_shape
		_clearance_query.collision_mask = 1
	return _clearance_query

func _is_cell_solid(cell: Vector3i) -> bool:
	if _voxel_world != null and _voxel_world.has_method("is_solid_block"):
		if _voxel_world.is_solid_block(cell):
			return true
	var gs := get_node_or_null("/root/GridSystem")
	if gs != null and gs.has_block(cell):
		return true
	return false

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

enum BakeStage {
	SCANNING_COLUMNS,
	REGISTERING_POINTS,
	CONNECTING_EDGES,
}

var _is_chunk_active: bool = false
var _active_chunk: Vector2i = Vector2i.ZERO
var _active_col_idx: int = 0
var _active_node_idx: int = 0
var _bake_stage: BakeStage = BakeStage.SCANNING_COLUMNS
var _active_chunk_new_cells: Array[Vector3i] = []
var _physics_blocked_cache: Dictionary = {}

var _sweep_shape: CapsuleShape3D = null
var _sweep_query: PhysicsShapeQueryParameters3D = null
var _ray_query: PhysicsRayQueryParameters3D = null

func _get_sweep_query() -> PhysicsShapeQueryParameters3D:
	if _sweep_query == null:
		_sweep_shape = CapsuleShape3D.new()
		_sweep_shape.radius = 0.32
		_sweep_shape.height = 1.45
		_sweep_query = PhysicsShapeQueryParameters3D.new()
		_sweep_query.shape = _sweep_shape
		_sweep_query.collision_mask = 1
	return _sweep_query

func _get_ray_query(from_pt: Vector3, to_pt: Vector3) -> PhysicsRayQueryParameters3D:
	if _ray_query == null:
		_ray_query = PhysicsRayQueryParameters3D.new()
		_ray_query.collision_mask = 1
	_ray_query.from = from_pt
	_ray_query.to = to_pt
	return _ray_query

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

## Per-frame wall-clock budget in milliseconds. Processes chunk stages within
## this window, then yields back to the engine to avoid frame spikes.
const FRAME_BUDGET_MS: float = 2.0

func _ready() -> void:
	pass  ## No startup delay needed — physics queries are skipped during initial bake.

var _rebuild_emit_pending: bool = false

func _notify_graph_changed() -> void:
	if _rebuild_emit_pending:
		return
	_rebuild_emit_pending = true
	call_deferred("_do_emit_graph_rebuilt")

func _do_emit_graph_rebuilt() -> void:
	_rebuild_emit_pending = false
	graph_rebuilt.emit()

func ensure_nearby_graph_ready(spawn_pos: Vector3) -> void:
	var center_cp := Vector2i(floori(spawn_pos.x / float(CHUNK_SIZE)), floori(spawn_pos.z / float(CHUNK_SIZE)))
	# Incrementally bake chunks until the center spawn chunk is complete
	var max_wait_frames: int = 120
	while max_wait_frames > 0:
		if _baked_chunks.has(center_cp) and not (_is_chunk_active and _active_chunk == center_cp):
			break
		_step_bake_slice(6.0)
		if is_inside_tree():
			await get_tree().process_frame
		max_wait_frames -= 1

func _physics_process(_delta: float) -> void:
	if not _is_chunk_active and _pending_chunks.is_empty():
		# Queue just drained — emit graph_rebuilt once and mark initial bake complete.
		if _graph_rebuilt_pending:
			_graph_rebuilt_pending = false
			if not _initial_bake_done:
				_initial_bake_done = true
				if _t_bake_start > 0:
					var elapsed: int = Time.get_ticks_msec() - _t_bake_start
					print("[StartupTiming] A* baking took: %d ms" % elapsed)
			_notify_graph_changed()
		return

	# Incrementally process chunk baking stages within the per-frame time budget.
	_step_bake_slice(FRAME_BUDGET_MS)

func _step_bake_slice(budget_ms: float) -> bool:
	var frame_start_ms: int = Time.get_ticks_msec()
	while true:
		if not _is_chunk_active:
			if _pending_chunks.is_empty():
				return false
			var next_chunk = _pending_chunks.pop_front()
			_begin_chunk_bake(next_chunk)
			if not _is_chunk_active:
				continue

		# Stage 1: Column scanning
		if _bake_stage == BakeStage.SCANNING_COLUMNS:
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
				if _voxel_world != null and _voxel_world.has_method("get_highest_solid_y"):
					surf_y = _voxel_world.get_highest_solid_y(x, z)

				if surf_y >= min_y:
					var scan_top: int = mini(max_y, surf_y)
					var y: int = min_y - 1
					while y <= scan_top:
						if _is_cell_solid(Vector3i(x, y, z)):
							var walk_cell := Vector3i(x, y + 1, z)
							var head_cell := Vector3i(x, y + 2, z)
							if not _is_cell_solid(walk_cell) and not _is_cell_solid(head_cell):
								var valid := true
								if _initial_bake_done:
									if _is_position_blocked_by_physics(walk_cell):
										valid = false
								if valid:
									_active_chunk_new_cells.append(walk_cell)
								y += 2
							else:
								y += 1
						else:
							y += 1

				if _active_col_idx % 2 == 0:
					if float(Time.get_ticks_msec() - frame_start_ms) >= budget_ms:
						return true

			_bake_stage = BakeStage.REGISTERING_POINTS
			_active_node_idx = 0

		# Stage 2: Point registration
		if _bake_stage == BakeStage.REGISTERING_POINTS:
			var num_cells: int = _active_chunk_new_cells.size()
			while _active_node_idx < num_cells:
				var cell: Vector3i = _active_chunk_new_cells[_active_node_idx]
				_active_node_idx += 1

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

				if _active_node_idx % 4 == 0:
					if float(Time.get_ticks_msec() - frame_start_ms) >= budget_ms:
						return true

			var cp: Vector2i = _active_chunk
			if not _chunk_points.has(cp):
				_chunk_points[cp] = []
			_chunk_points[cp].append_array(_active_chunk_new_cells)

			_bake_stage = BakeStage.CONNECTING_EDGES
			_active_node_idx = 0

		# Stage 3: Edge connection
		if _bake_stage == BakeStage.CONNECTING_EDGES:
			var num_cells: int = _active_chunk_new_cells.size()
			while _active_node_idx < num_cells:
				var cell: Vector3i = _active_chunk_new_cells[_active_node_idx]
				_active_node_idx += 1
				_connect_point_neighbors(cell)

				if _active_node_idx % 2 == 0:
					if float(Time.get_ticks_msec() - frame_start_ms) >= budget_ms:
						return true

			# Chunk bake completely finished!
			_is_chunk_active = false
			_active_chunk_new_cells.clear()
			_physics_blocked_cache.clear()
			_graph_rebuilt_pending = true

		if float(Time.get_ticks_msec() - frame_start_ms) >= budget_ms:
			return true

	return false

func _is_position_blocked_by_physics(cell: Vector3i) -> bool:
	if not _initial_bake_done:
		return false
	if _physics_blocked_cache.has(cell):
		return _physics_blocked_cache[cell]
	var res := _query_position_blocked_by_physics(cell)
	_physics_blocked_cache[cell] = res
	return res

func _query_position_blocked_by_physics(cell: Vector3i) -> bool:
	if not is_inside_tree():
		return false
	var viewport := get_viewport()
	if viewport == null:
		return false
	var world_3d: World3D = viewport.find_world_3d()
	if world_3d == null or not world_3d.space.is_valid():
		return false
	var direct_state: PhysicsDirectSpaceState3D = world_3d.direct_space_state
	if direct_state == null:
		return false

	var query := _get_clearance_query()
	var center := Vector3(float(cell.x) + 0.5, float(cell.y) + 0.75, float(cell.z) + 0.5)
	query.transform = Transform3D(Basis.IDENTITY, center)

	var hits := direct_state.intersect_shape(query, 8)
	if hits.is_empty():
		return false

	for hit in hits:
		var collider = hit.get("collider", null)
		if collider == null:
			continue
		# Exclude terrain mesh: terrain solidity is verified directly by voxel data
		if collider == _voxel_world:
			continue
		if collider is Node and (collider == _voxel_world or collider.get_parent() == _voxel_world):
			continue
		if collider.is_class("VoxelTerrain") or (collider is Node and (collider as Node).is_in_group("voxel_terrain")):
			continue
		if "generator" in collider and "generate_collisions" in collider:
			continue
		# Exclude workers and players
		if collider is CharacterBody3D or (collider is Node and (collider as Node).is_in_group("workers")):
			continue
		# Exclude loose pickups (debris layer 8, resource layer 4 fragments/planks/logs)
		if collider is Node and ((collider as Node).is_in_group("fragments") or (collider as Node).is_in_group("planks") or (collider as Node).is_in_group("logs")):
			continue
		return true

	return false

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

	var center_cp := Vector2i(floori(float(cx) / float(CHUNK_SIZE)), floori(float(cz) / float(CHUNK_SIZE)))
	var chunk_list: Array[Vector2i] = []
	for cz_idx in range(min_cz, max_cz + 1):
		for cx_idx in range(min_cx, max_cx + 1):
			chunk_list.append(Vector2i(cx_idx, cz_idx))

	# Radial sort: nearest chunks to player spawn are baked first!
	chunk_list.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		var da: int = (a.x - center_cp.x) * (a.x - center_cp.x) + (a.y - center_cp.y) * (a.y - center_cp.y)
		var db: int = (b.x - center_cp.x) * (b.x - center_cp.x) + (b.y - center_cp.y) * (b.y - center_cp.y)
		return da < db
	)

	for cp in chunk_list:
		queue_chunk(cp)

## Begin an incremental chunk bake (used by _physics_process for the 2ms budget loop).
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
	_active_node_idx = 0
	_bake_stage = BakeStage.SCANNING_COLUMNS
	_active_chunk_new_cells.clear()
	_is_chunk_active = true

## Incremental queue bake — redirects to queue_chunk to prevent main-thread spikes.
func _bake_single_chunk(current_chunk: Variant) -> void:
	queue_chunk(current_chunk)

# ---------------------------------------------------------------------------
# Signal-Driven Dynamic Expansion & Voxel Edits
# ---------------------------------------------------------------------------
func bake_chunk_if_needed(cp: Vector2i) -> void:
	if _baked_chunks.has(cp) and not _pending_chunks.has(cp):
		return
	queue_chunk(cp)

func notify_block_changed(world_cell: Vector3i) -> void:
	notify_blocks_changed([world_cell])

func notify_blocks_changed(cells: Array) -> void:
	if cells.is_empty():
		return
	var unique_cols: Dictionary = {}
	for c in cells:
		var cell: Vector3i
		if c is Vector3i:
			cell = c
		elif c is Vector3:
			cell = Vector3i(floori(c.x), floori(c.y), floori(c.z))
		else:
			continue
		unique_cols[Vector2i(cell.x, cell.z)] = true

	var cols: Array[Vector2i] = []
	for col in unique_cols.keys():
		cols.append(col)
	_update_columns_batch(cols)

func notify_bounds_changed(aabb: AABB) -> void:
	var min_cell := Vector3i(floori(aabb.position.x), floori(aabb.position.y), floori(aabb.position.z))
	var max_cell := Vector3i(ceili(aabb.end.x), ceili(aabb.end.y), ceili(aabb.end.z))
	var cols: Array[Vector2i] = []
	for x in range(min_cell.x, max_cell.x + 1):
		for z in range(min_cell.z, max_cell.z + 1):
			cols.append(Vector2i(x, z))
	_update_columns_batch(cols)

func _update_columns_batch(cols: Array[Vector2i]) -> void:
	if cols.is_empty():
		return
	_physics_blocked_cache.clear()

	for col in cols:
		_update_local_column(col.x, col.y)

	var neighbor_cols: Dictionary = {}
	for col in cols:
		for off in ADJACENT_OFFSETS:
			neighbor_cols[col + off] = true

	for adj_col in neighbor_cols.keys():
		_reconnect_column(adj_col.x, adj_col.y)

	_notify_graph_changed()

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

	# Also check GridSystem placed blocks
	var gs := get_node_or_null("/root/GridSystem")
	var gs_max_y: int = -1
	if gs != null and gs.has_method("get_block"):
		for test_y in range(surf_y - 2, surf_y + 16):
			if gs.has_block(Vector3i(x, test_y, z)):
				gs_max_y = maxi(gs_max_y, test_y)

	var effective_top: int = maxi(surf_y, gs_max_y)

	var half_y: int = BOUNDS_Y / 2
	var min_y: int = roundi(_center.y) - half_y if _center != Vector3.ZERO else 0
	var max_y: int = roundi(_center.y) + half_y if _center != Vector3.ZERO else 128

	if effective_top < min_y:
		return

	var scan_top: int = mini(max_y, effective_top)
	var y: int = min_y - 1
	while y <= scan_top:
		if _is_cell_solid(Vector3i(x, y, z)):
			var walk_cell := Vector3i(x, y + 1, z)
			var head_cell := Vector3i(x, y + 2, z)
			if not _is_cell_solid(walk_cell) and not _is_cell_solid(head_cell):
				var valid := true
				if _is_position_blocked_by_physics(walk_cell):
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
		_connect_point_neighbors(cell)

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
	if _is_position_blocked_by_physics(cell):
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

	_connect_point_neighbors(cell)
	return id

func _connect_point_neighbors(cell: Vector3i) -> void:
	if not _point_ids.has(cell):
		return
	var from_id: int = _point_ids[cell]
	var pos_a: Vector3 = _astar.get_point_position(from_id)

	# 1. Cardinal connections
	for off in CARDINAL_OFFSETS:
		for dy in range(-STEP_UP_MAX, STEP_UP_MAX + 1):
			var neighbor := Vector3i(cell.x + off.x, cell.y + dy, cell.z + off.y)
			if not _point_ids.has(neighbor):
				continue
			var to_id: int = _point_ids[neighbor]
			if from_id == to_id:
				continue
			var pos_b: Vector3 = _astar.get_point_position(to_id)
			if absf(pos_a.y - pos_b.y) > 1.1:
				continue
			_astar.connect_points(from_id, to_id, true)
			if dy > 0:
				_astar.set_point_weight_scale(to_id, 1.4)

	# 2. Diagonal connections with corner-cutting prevention
	for diag in DIAGONAL_OFFSETS:
		# Orthogonal intermediate cells must not be solid/blocked at foot or head level
		var ortho1 := Vector3i(cell.x + diag.x, cell.y, cell.z)
		var ortho2 := Vector3i(cell.x, cell.y, cell.z + diag.y)
		if _is_cell_solid(ortho1) or _is_cell_solid(Vector3i(ortho1.x, ortho1.y + 1, ortho1.z)):
			continue
		if _is_cell_solid(ortho2) or _is_cell_solid(Vector3i(ortho2.x, ortho2.y + 1, ortho2.z)):
			continue
		if _initial_bake_done:
			if _is_position_blocked_by_physics(ortho1) or _is_position_blocked_by_physics(ortho2):
				continue

		for dy in range(-STEP_UP_MAX, STEP_UP_MAX + 1):
			var target := Vector3i(cell.x + diag.x, cell.y + dy, cell.z + diag.y)
			if not _point_ids.has(target):
				continue
			var to_id: int = _point_ids[target]
			if from_id == to_id:
				continue
			var pos_b: Vector3 = _astar.get_point_position(to_id)
			if absf(pos_a.y - pos_b.y) > 1.1:
				continue
			_astar.connect_points(from_id, to_id, true)
			if dy > 0:
				_astar.set_point_weight_scale(to_id, 1.6)

# ---------------------------------------------------------------------------
# Public Query API & Path Optimization
# ---------------------------------------------------------------------------
func find_astar_path(from_world: Vector3, to_world: Vector3) -> PackedVector3Array:
	## Returns the world-space waypoint array from AStar3D, optimized for natural routes.
	var from_id := _closest_point_id(from_world)
	var to_id   := _closest_point_id(to_world)
	if from_id < 0 or to_id < 0:
		return PackedVector3Array()
	var raw := _astar.get_point_path(from_id, to_id)
	if raw.is_empty():
		return raw
	return optimize_path(raw)

func get_astar_path(from_world: Vector3, to_world: Vector3) -> PackedVector3Array:
	return find_astar_path(from_world, to_world)

func find_approach_path(from_world: Vector3, target_world: Vector3, min_dist: float = 0.8, max_dist: float = 1.5, max_vert: float = 1.3) -> PackedVector3Array:
	## Finds an optimized path from from_world to a valid, walkable approach node beside target_world.
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
				var horiz_d: float = Vector2(cand_pos.x - target_world.x, cand_pos.z - target_world.z).length()
				var y_diff: float = absf(cand_pos.y - target_world.y)
				# Ensure candidate is outside the obstacle boundary and within reachable distance
				if horiz_d >= min_dist and horiz_d <= max_dist and y_diff <= max_vert:
					if _is_position_blocked_by_physics(cell):
						continue
					var d_from: float = cand_pos.distance_squared_to(from_world)
					candidates.append({"id": cand_id, "dist_from": d_from, "horiz_d": horiz_d})

	if candidates.is_empty():
		return PackedVector3Array()

	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["dist_from"] < b["dist_from"]
	)

	for i in range(mini(8, candidates.size())):
		var cand_id: int = candidates[i]["id"]
		var raw: PackedVector3Array = _astar.get_point_path(from_id, cand_id)
		if not raw.is_empty():
			var opt: PackedVector3Array = optimize_path(raw)
			if not opt.is_empty():
				var end_pt: Vector3 = opt[opt.size() - 1]
				var end_horiz: float = Vector2(end_pt.x - target_world.x, end_pt.z - target_world.z).length()
				var end_vert: float = absf(end_pt.y - target_world.y)
				if end_horiz <= max_dist + 0.15 and end_vert <= max_vert:
					return opt

	return PackedVector3Array()

const MAX_SHORTCUT_LOOKAHEAD: int = 6
const MAX_SHORTCUT_HORIZ_DIST: float = 6.0

func optimize_path(raw_path: PackedVector3Array) -> PackedVector3Array:
	## Removes redundant waypoints using bounded-lookahead capsule sweep and ground support checks.
	if raw_path.size() <= 2:
		return raw_path

	var viewport := get_viewport()
	if viewport == null:
		return raw_path
	var world_3d: World3D = viewport.find_world_3d()
	if world_3d == null or not world_3d.space.is_valid():
		return raw_path
	var direct_state: PhysicsDirectSpaceState3D = world_3d.direct_space_state
	if direct_state == null:
		return raw_path

	var optimized: PackedVector3Array = PackedVector3Array()
	optimized.append(raw_path[0])

	var current_idx: int = 0
	var n: int = raw_path.size()

	while current_idx < n - 1:
		var best_idx: int = current_idx + 1
		var max_lookahead_idx: int = mini(n - 1, current_idx + MAX_SHORTCUT_LOOKAHEAD)
		for test_idx in range(max_lookahead_idx, current_idx + 1, -1):
			if _is_shortcut_safe(direct_state, raw_path, current_idx, test_idx):
				best_idx = test_idx
				break
		optimized.append(raw_path[best_idx])
		current_idx = best_idx

	return optimized

func _is_shortcut_safe(space: PhysicsDirectSpaceState3D, path: PackedVector3Array, from_idx: int, to_idx: int) -> bool:
	var start: Vector3 = path[from_idx]
	var end: Vector3 = path[to_idx]

	# 1. Preserve height transitions: no shortcuts across steps, stairs, or ledges
	var base_y: float = start.y
	for i in range(from_idx + 1, to_idx + 1):
		if absf(path[i].y - base_y) > 0.25:
			return false

	var delta := end - start
	var horiz_dist := Vector2(delta.x, delta.z).length()
	if horiz_dist < 0.1:
		return true
	if horiz_dist > MAX_SHORTCUT_HORIZ_DIST:
		return false

	# 2. Capsule sweep clearance check from start to end using reusable query
	var sweep_query := _get_sweep_query()
	sweep_query.transform = Transform3D(Basis.IDENTITY, start + Vector3(0.0, 0.75, 0.0))
	sweep_query.motion = delta

	var cast_res := space.cast_motion(sweep_query)
	if cast_res.is_empty() or cast_res[0] < 0.99:
		return false

	# 3. Ground support check: verify floor exists along shortcut to prevent walking off ledges
	var steps: int = maxi(1, int(ceil(horiz_dist / 0.7)))
	for s in range(1, steps):
		var frac: float = float(s) / float(steps)
		var sample_pt: Vector3 = start.lerp(end, frac)
		var ray_from := sample_pt + Vector3(0.0, 0.5, 0.0)
		var ray_to := sample_pt - Vector3(0.0, 1.2, 0.0)
		var ray_q := _get_ray_query(ray_from, ray_to)
		var ground_hit := space.intersect_ray(ray_q)
		if ground_hit.is_empty():
			return false
		var hit_y: float = ground_hit.position.y
		if absf(hit_y - base_y) > 0.5:
			return false

	return true

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
