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

	# Ensure coated faces tracked by JointSystem are copied to block metadata prior to grid removal
	var joint_sys: Node = null
	if is_inside_tree() and has_node("/root/JointSystem"):
		joint_sys = get_node("/root/JointSystem")

	if joint_sys != null and joint_sys.has_method("get_coated_faces_for_cell"):
		for c in valid_cells:
			var bdata: BlockData = grid.get_block(c)
			if bdata != null:
				var c_faces: Array = joint_sys.get_coated_faces_for_cell(c)
				for f in c_faces:
					joint_sys._add_coated_face_to_metadata(bdata, f)

	# 2. Atomically remove valid cells from GridSystem to prevent duplicates
	var removed_block_data: Dictionary = grid.remove_cells_batch(valid_cells)
	if removed_block_data.is_empty():
		return []

	var actually_removed_cells: Array[Vector3i] = []
	for c in removed_block_data.keys():
		actually_removed_cells.append(c)

	# 3. Group actually removed cells into connected component islands
	var island_groups: Array = IslandBuilder.group_islands(actually_removed_cells)

	# Extract any structural joints among the collapsing cells to preserve compound debris
	if joint_sys == null and is_inside_tree() and has_node("/root/JointSystem"):
		joint_sys = get_node("/root/JointSystem")

	var extracted_joints: Array = []
	if joint_sys != null and joint_sys.has_method("extract_joints_for_cells"):
		extracted_joints = joint_sys.extract_joints_for_cells(actually_removed_cells)

	# 4. Instantiate one DebrisIsland per disconnected island group
	var spawned_islands: Array[DebrisIsland] = []

	for group_var in island_groups:
		var cell_group: Array = group_var
		if cell_group.is_empty():
			continue

		var group_set: Dictionary = {}
		for c_var in cell_group:
			group_set[c_var] = true

		var group_joints: Array = []
		for j in extracted_joints:
			if group_set.has(j.cell_a) and group_set.has(j.cell_b):
				group_joints.append(j)

		var island := DebrisIsland.new()
		island.orchestrator = self
		var container: Node = debris_container if debris_container != null else self
		container.add_child(island)
		island.setup_island(cell_group, removed_block_data, grid.cell_size, group_joints)

		island.island_settled.connect(_on_island_settled)
		island.island_fell_out_of_world.connect(_on_island_destroyed)

		_active_debris.append(island)
		spawned_islands.append(island)

	if not spawned_islands.is_empty():
		collapse_occurred.emit(spawned_islands)
		# Wake any existing settled debris so stacked islands resume falling
		_wake_all_active_debris_except(spawned_islands)

	return spawned_islands

## Spawns dynamic physics debris island(s) for a set of cell positions and BlockData map.
func spawn_debris_for_cells(cells: Array, block_data_map: Dictionary) -> Array[DebrisIsland]:
	var grid := grid_system
	if grid == null and has_node("/root/GridSystem"):
		grid = get_node("/root/GridSystem")
	var cs: float = grid.cell_size if grid != null else 1.0

	var typed_cells: Array[Vector3i] = []
	for c in cells:
		typed_cells.append(c as Vector3i)
	var island_groups: Array = IslandBuilder.group_islands(typed_cells)
	var spawned_islands: Array[DebrisIsland] = []

	for group_var in island_groups:
		var cell_group: Array = group_var
		if cell_group.is_empty():
			continue

		var island := DebrisIsland.new()
		island.orchestrator = self
		var container: Node = debris_container if debris_container != null else self
		container.add_child(island)
		island.setup_island(cell_group, block_data_map, cs, [])

		island.island_settled.connect(_on_island_settled)
		island.island_fell_out_of_world.connect(_on_island_destroyed)

		_active_debris.append(island)
		spawned_islands.append(island)

	if not spawned_islands.is_empty():
		_wake_all_active_debris_except(spawned_islands)

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

		var group_joints: Array = []
		if "internal_joints" in original and original.internal_joints is Dictionary:
			var g_set: Dictionary = {}
			for cv in group:
				g_set[cv] = true
			for j in original.internal_joints.values():
				if g_set.has(j.cell_a) and g_set.has(j.cell_b):
					group_joints.append(j)

		new_island.setup_island_split(group, group_data, orig_local_offsets, local_centroid, orig_cell_size, group_joints)

		new_island.island_settled.connect(_on_island_settled)
		new_island.island_fell_out_of_world.connect(_on_island_destroyed)

		_active_debris.append(new_island)
		spawned_islands.append(new_island)

	unregister_debris_island(original)
	original.queue_free()

	debris_split.emit(original, spawned_islands)
	return spawned_islands

## Converts an unbonded grid block into an active dynamic debris island moving under physics.
func push_unbonded_block(cell: Vector3i, impulse_velocity: Vector3 = Vector3.ZERO) -> DebrisIsland:
	var grid := grid_system
	if grid == null and has_node("/root/GridSystem"):
		grid = get_node("/root/GridSystem")
	if grid == null or not grid.has_block(cell):
		return null

	var block_data: BlockData = grid.remove_block(cell)
	if block_data == null:
		return null

	var data_map: Dictionary = {cell: block_data}
	var island := DebrisIsland.new()
	island.orchestrator = self
	var container: Node = debris_container if debris_container != null else self
	container.add_child(island)
	island.setup_island([cell], data_map, grid.cell_size, [])

	if impulse_velocity.length_squared() > 0.001:
		island.linear_velocity = impulse_velocity

	island.island_settled.connect(_on_island_settled)
	island.island_fell_out_of_world.connect(_on_island_destroyed)

	_active_debris.append(island)
	_wake_all_active_debris_except([island])
	return island

## Checks if any active debris currently physically occupies the space of a grid cell.
## Optional exclude_island parameter prevents held debris from blocking its own target placement cell.
func is_cell_blocked_by_debris(cell: Vector3i, p_cell_size: float = 1.0, exclude_island: DebrisIsland = null) -> bool:
	var cell_center := Vector3(
		(float(cell.x) + 0.5) * p_cell_size,
		(float(cell.y) + 0.5) * p_cell_size,
		(float(cell.z) + 0.5) * p_cell_size
	)
	var threshold_sq: float = (p_cell_size * 0.7) * (p_cell_size * 0.7)

	for island in _active_debris:
		if not is_instance_valid(island):
			continue
		if island == exclude_island:
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
	# Wake all remaining debris so islands stacked above the freed one resume falling
	_wake_all_active_debris_except([])

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

## Wakes all active debris islands that are not in the exclusion list.
## Prevents settled debris from staying asleep when a supporting island beneath it was removed.
func _wake_all_active_debris_except(exclude: Array) -> void:
	for island in _active_debris:
		if not is_instance_valid(island):
			continue
		if island in exclude:
			continue
		if island.is_settled or island.sleeping:
			island.wake_and_disable_sleep()
