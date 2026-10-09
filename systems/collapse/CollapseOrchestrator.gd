class_name CollapseOrchestrator
extends Node3D

## Coordinates the conversion of unsupported grid blocks into dynamic physics DebrisIslands.
## Ensures atomic removal from GridSystem so no duplicate blocks exist simultaneously.
## Manages debris splitting and mutual exclusive occupancy validation.

signal collapse_occurred(islands: Array[DebrisIsland])
signal debris_settled(island: DebrisIsland)
signal debris_split(original: DebrisIsland, new_islands: Array)
signal debris_removed(island: DebrisIsland)

@export var grid_system: Node
@export var stability_system: Node
@export var debris_container: Node3D

## List of active debris islands
var _active_debris: Array[DebrisIsland] = []

func _ready() -> void:
	if grid_system == null and has_node("/root/GridSystem"):
		grid_system = get_node("/root/GridSystem")
	if stability_system == null and has_node("/root/StabilitySystem"):
		stability_system = get_node("/root/StabilitySystem")

	if stability_system != null:
		if not stability_system.stability_evaluated.is_connected(_on_stability_evaluated):
			stability_system.stability_evaluated.connect(_on_stability_evaluated)

	if debris_container == null:
		debris_container = self

func _on_stability_evaluated(unsupported_cells: Array[Vector3i]) -> void:
	trigger_collapse(unsupported_cells)

## Executes the collapse transition for the given unsupported cells.
## Validates cell presence and atomically transfers ownership from GridSystem to DebrisIslands.
func trigger_collapse(unsupported_cells: Array[Vector3i]) -> Array[DebrisIsland]:
	if unsupported_cells.is_empty():
		return []

	var grid := grid_system
	if grid == null and has_node("/root/GridSystem"):
		grid = get_node("/root/GridSystem")

	if grid == null:
		push_error("CollapseOrchestrator: GridSystem reference is null")
		return []

	# 1. Deduplicate and filter to ONLY cells currently present in GridSystem
	var valid_cells: Array[Vector3i] = []
	var seen: Dictionary = {}
	for c in unsupported_cells:
		if not seen.has(c) and grid.has_block(c):
			seen[c] = true
			valid_cells.append(c)

	if valid_cells.is_empty():
		return []

	# 2. Atomically remove valid cells from GridSystem to prevent duplicates
	var removed_block_data: Dictionary = grid.remove_cells_batch(valid_cells)
	if removed_block_data.is_empty():
		return []

	var actually_removed_cells: Array[Vector3i] = []
	for c in removed_block_data.keys():
		actually_removed_cells.append(c)

	# 3. Group actually removed cells into connected component islands
	var island_groups: Array = IslandBuilder.group_islands(actually_removed_cells)

	# 4. Instantiate one DebrisIsland per disconnected island group
	var spawned_islands: Array[DebrisIsland] = []

	for group_var in island_groups:
		var cell_group: Array = group_var
		if cell_group.is_empty():
			continue

		var island := DebrisIsland.new()
		island.orchestrator = self
		debris_container.add_child(island)
		island.setup_island(cell_group, removed_block_data, grid.cell_size)

		island.island_settled.connect(_on_island_settled)
		island.island_fell_out_of_world.connect(_on_island_destroyed)

		_active_debris.append(island)
		spawned_islands.append(island)

	if not spawned_islands.is_empty():
		collapse_occurred.emit(spawned_islands)

	return spawned_islands

## Splits an existing debris island into independent bodies after block removal disconnects it.
func split_debris_island(original: DebrisIsland, groups: Array) -> Array[DebrisIsland]:
	var spawned_islands: Array[DebrisIsland] = []
	var parent_node: Node = original.get_parent()
	if parent_node == null:
		parent_node = debris_container

	var orig_transform: Transform3D = original.global_transform if original.is_inside_tree() else original.transform
	var orig_lin_vel: Vector3 = original.linear_velocity
	var orig_ang_vel: Vector3 = original.angular_velocity
	var orig_cell_size: float = original.cell_size
	var orig_blocks: Dictionary = original.constituent_blocks
	var orig_local_offsets: Dictionary = original.local_offsets

	for group_var in groups:
		var group: Array = group_var
		if group.is_empty():
			continue

		var new_island := DebrisIsland.new()
		new_island.orchestrator = self
		parent_node.add_child(new_island)

		var group_data: Dictionary = {}
		for c_var in group:
			var c: Vector3i = c_var
			group_data[c] = orig_blocks[c]

		var local_centroid := Vector3.ZERO
		for c_var in group:
			var c: Vector3i = c_var
			local_centroid += orig_local_offsets[c]
		local_centroid /= float(group.size())

		var new_world_pos: Vector3 = original.to_global(local_centroid) if original.is_inside_tree() else (orig_transform * local_centroid)
		if new_island.is_inside_tree():
			new_island.global_transform = Transform3D(orig_transform.basis, new_world_pos)
		else:
			new_island.transform = Transform3D(orig_transform.basis, new_world_pos)

		var r_offset: Vector3 = orig_transform.basis * local_centroid
		new_island.linear_velocity = orig_lin_vel + orig_ang_vel.cross(r_offset)
		new_island.angular_velocity = orig_ang_vel

		new_island.setup_island_split(group, group_data, orig_local_offsets, local_centroid, orig_cell_size)

		new_island.island_settled.connect(_on_island_settled)
		new_island.island_fell_out_of_world.connect(_on_island_destroyed)

		_active_debris.append(new_island)
		spawned_islands.append(new_island)

	unregister_debris_island(original)
	original.queue_free()

	debris_split.emit(original, spawned_islands)
	return spawned_islands

## Checks if any active debris currently physically occupies the space of a grid cell.
func is_cell_blocked_by_debris(cell: Vector3i, p_cell_size: float = 1.0) -> bool:
	var cell_center := Vector3(
		(float(cell.x) + 0.5) * p_cell_size,
		(float(cell.y) + 0.5) * p_cell_size,
		(float(cell.z) + 0.5) * p_cell_size
	)
	var threshold_sq: float = (p_cell_size * 0.7) * (p_cell_size * 0.7)

	for island in _active_debris:
		if not is_instance_valid(island):
			continue
		var island_tf: Transform3D = island.global_transform if island.is_inside_tree() else island.transform
		for c in island.constituent_blocks.keys():
			var block_world_center: Vector3 = island_tf * island.local_offsets[c]
			if block_world_center.distance_squared_to(cell_center) < threshold_sq:
				return true
	return false

func register_debris_island(island: DebrisIsland) -> void:
	if not _active_debris.has(island):
		_active_debris.append(island)

func unregister_debris_island(island: DebrisIsland) -> void:
	_active_debris.erase(island)
	debris_removed.emit(island)

func _on_island_settled(island: DebrisIsland) -> void:
	debris_settled.emit(island)

func _on_island_destroyed(island: DebrisIsland) -> void:
	unregister_debris_island(island)

func get_active_debris_count() -> int:
	return _active_debris.size()

func get_all_active_debris() -> Array[DebrisIsland]:
	var result: Array[DebrisIsland] = []
	for island in _active_debris:
		if is_instance_valid(island):
			result.append(island)
	return result

func clear_all_debris() -> void:
	for island in _active_debris:
		if is_instance_valid(island):
			island.queue_free()
	_active_debris.clear()

