class_name DebrisIsland
extends RigidBody3D

## Dynamic rigid body representing a fallen structural island.
## Preserves constituent block data and generates exact compound collision shapes.
## Supports targeted block removal and dynamic splitting when disconnected.

signal island_settled(island: DebrisIsland)
signal island_fell_out_of_world(island: DebrisIsland)
signal block_removed_from_island(island: DebrisIsland, cell: Vector3i, data: BlockData)
signal island_split(original_island: DebrisIsland, new_islands: Array)

## Stored constituent blocks: Dictionary[Vector3i, BlockData]
var constituent_blocks: Dictionary = {}

## Local offsets of constituent blocks relative to the island's center: Dictionary[Vector3i, Vector3]
var local_offsets: Dictionary = {}

## Node references per constituent block cell
var _block_col_shapes: Dictionary = {} # Vector3i -> CollisionShape3D
var _block_meshes: Dictionary = {}     # Vector3i -> MeshInstance3D

## Grid cell size
var cell_size: float = 1.0

## Settled state flag
var is_settled: bool = false

## Optional back-reference to CollapseOrchestrator for managing active debris registrations
var orchestrator: Node = null

func _ready() -> void:
	sleeping_state_changed.connect(_on_sleeping_state_changed)

func setup_island(cells: Array, block_data_map: Dictionary, p_cell_size: float) -> void:
	cell_size = p_cell_size
	if cells.is_empty():
		return

	# 1. Compute centroid of constituent cells in world space
	var sum_world_pos := Vector3.ZERO
	for cell_var in cells:
		var c: Vector3i = cell_var
		var cell_world_center := Vector3(
			(float(c.x) + 0.5) * cell_size,
			(float(c.y) + 0.5) * cell_size,
			(float(c.z) + 0.5) * cell_size
		)
		sum_world_pos += cell_world_center

	var pivot_world := sum_world_pos / float(cells.size())
	if is_inside_tree():
		global_position = pivot_world
	else:
		position = pivot_world

	# 2. Build compound collision shapes and meshes for each block
	var total_mass: float = 0.0

	for cell_var in cells:
		var c: Vector3i = cell_var
		var block_data: BlockData = block_data_map.get(c, null)
		if block_data == null:
			block_data = BlockData.new(&"stone", 1.0)

		# Preserve block identity and metadata
		constituent_blocks[c] = block_data.duplicate_data()

		var cell_world_center := Vector3(
			(float(c.x) + 0.5) * cell_size,
			(float(c.y) + 0.5) * cell_size,
			(float(c.z) + 0.5) * cell_size
		)
		var local_pos := cell_world_center - pivot_world
		local_offsets[c] = local_pos

		# Exact constituent collision shape tagged with cell metadata
		var col_shape := CollisionShape3D.new()
		var box_shape := BoxShape3D.new()
		box_shape.size = Vector3.ONE * cell_size
		col_shape.shape = box_shape
		col_shape.position = local_pos
		col_shape.set_meta("cell_coord", c)
		add_child(col_shape)
		_block_col_shapes[c] = col_shape

		# Visual representation with block-type color
		var mesh_instance := MeshInstance3D.new()
		var box_mesh := BoxMesh.new()
		box_mesh.size = Vector3.ONE * (cell_size * 0.98) # Slight edge inset for visual readability
		var mat := StandardMaterial3D.new()
		mat.albedo_color = BlockTypeCatalog.get_color(block_data.block_type)
		mat.roughness = 0.85
		box_mesh.material = mat
		mesh_instance.mesh = box_mesh
		mesh_instance.position = local_pos
		add_child(mesh_instance)
		_block_meshes[c] = mesh_instance

		total_mass += BlockTypeCatalog.get_mass(block_data.block_type)

	# 3. Configure physics parameters for reliable settling
	mass = maxf(1.0, total_mass)
	linear_damp = 0.6
	angular_damp = 0.8
	can_sleep = true
	contact_monitor = true
	max_contacts_reported = 4
	# Layer 3 = debris; mask 7 = collides with ground(1), player(2), other debris(4 is bit3)
	collision_layer = 4   # bit 3 = layer 3 in Godot (1-indexed)
	collision_mask = 7    # bits 1+2+3 = layers 1(ground)+2(player)+3(debris)

## Sets up an island resulting from a split of an existing debris island.
func setup_island_split(cells: Array, block_data_map: Dictionary, orig_offsets: Dictionary, centroid_offset: Vector3, p_cell_size: float) -> void:
	cell_size = p_cell_size
	var total_mass: float = 0.0

	for cell_var in cells:
		var c: Vector3i = cell_var
		var block_data: BlockData = block_data_map.get(c, null)
		if block_data == null:
			block_data = BlockData.new(&"stone", 1.0)

		constituent_blocks[c] = block_data.duplicate_data()
		var new_local_pos: Vector3 = orig_offsets[c] - centroid_offset
		local_offsets[c] = new_local_pos

		var col_shape := CollisionShape3D.new()
		var box_shape := BoxShape3D.new()
		box_shape.size = Vector3.ONE * cell_size
		col_shape.shape = box_shape
		col_shape.position = new_local_pos
		col_shape.set_meta("cell_coord", c)
		add_child(col_shape)
		_block_col_shapes[c] = col_shape

		var mesh_instance := MeshInstance3D.new()
		var box_mesh := BoxMesh.new()
		box_mesh.size = Vector3.ONE * (cell_size * 0.98)
		var mat := StandardMaterial3D.new()
		mat.albedo_color = BlockTypeCatalog.get_color(block_data.block_type)
		mat.roughness = 0.85
		box_mesh.material = mat
		mesh_instance.mesh = box_mesh
		mesh_instance.position = new_local_pos
		add_child(mesh_instance)
		_block_meshes[c] = mesh_instance

		total_mass += BlockTypeCatalog.get_mass(block_data.block_type)

	mass = maxf(1.0, total_mass)
	linear_damp = 0.6
	angular_damp = 0.8
	can_sleep = true
	contact_monitor = true
	max_contacts_reported = 4
	collision_layer = 4
	collision_mask = 7

## Resolves the constituent cell coordinate hit by a physics raycast.
func get_cell_from_shape_hit(shape_idx: int, hit_world_pos: Vector3) -> Variant:
	var owner_id: int = shape_find_owner(shape_idx)
	if owner_id >= 0:
		var owner_obj = shape_owner_get_owner(owner_id)
		if owner_obj != null and owner_obj.has_meta("cell_coord"):
			return owner_obj.get_meta("cell_coord")

	# Fallback: check closest constituent block to hit_world_pos in local space
	var local_hit: Vector3 = to_local(hit_world_pos) if is_inside_tree() else (transform.affine_inverse() * hit_world_pos)
	var best_cell = null
	var min_dist_sq: float = INF
	for c in constituent_blocks.keys():
		var offset: Vector3 = local_offsets.get(c, Vector3.ZERO)
		var dist_sq: float = local_hit.distance_squared_to(offset)
		if dist_sq < min_dist_sq:
			min_dist_sq = dist_sq
			best_cell = c
	return best_cell

## Returns true if the island is currently moving/tumbling.
func is_moving() -> bool:
	if not is_settled:
		return true
	if linear_velocity.length_squared() > 0.05 or angular_velocity.length_squared() > 0.05:
		return true
	return false

## Removes an individual block from this debris island.
## Updates visual mesh, collision shape, mass, and metadata.
## If removal disconnects remaining blocks, splits into independent islands.
func remove_block(cell: Vector3i) -> BlockData:
	if not constituent_blocks.has(cell):
		return null

	var removed_data: BlockData = constituent_blocks[cell]

	# 1. Clean up node representations for this block immediately
	if _block_col_shapes.has(cell):
		var col: CollisionShape3D = _block_col_shapes[cell]
		if is_instance_valid(col):
			if col.get_parent() != null:
				col.get_parent().remove_child(col)
			col.queue_free()
		_block_col_shapes.erase(cell)

	if _block_meshes.has(cell):
		var mesh_inst: MeshInstance3D = _block_meshes[cell]
		if is_instance_valid(mesh_inst):
			if mesh_inst.get_parent() != null:
				mesh_inst.get_parent().remove_child(mesh_inst)
			mesh_inst.queue_free()
		_block_meshes.erase(cell)

	local_offsets.erase(cell)
	constituent_blocks.erase(cell)

	block_removed_from_island.emit(self, cell, removed_data)

	# 2. Island fully emptied
	if constituent_blocks.is_empty():
		if orchestrator != null and orchestrator.has_method("unregister_debris_island"):
			orchestrator.unregister_debris_island(self)
		island_fell_out_of_world.emit(self)
		queue_free()
		return removed_data

	# 3. Partition remaining blocks to check connectivity
	var remaining_cells: Array[Vector3i] = []
	for k in constituent_blocks.keys():
		remaining_cells.append(k)

	var groups: Array = IslandBuilder.group_islands(remaining_cells)

	if groups.size() == 1:
		# Remains a single connected body: update mass and wake physics
		_recalculate_mass()
		sleeping = false
		is_settled = false
	elif groups.size() > 1:
		# Island disconnected: split into independent rigid bodies
		if orchestrator != null and orchestrator.has_method("split_debris_island"):
			orchestrator.split_debris_island(self, groups)
		else:
			_split_without_orchestrator(groups)

	return removed_data

func _recalculate_mass() -> void:
	var total_mass: float = 0.0
	for c in constituent_blocks.keys():
		var data: BlockData = constituent_blocks[c]
		total_mass += BlockTypeCatalog.get_mass(data.block_type)
	mass = maxf(1.0, total_mass)

func _split_without_orchestrator(groups: Array) -> Array:
	var spawned: Array = []
	var parent_node := get_parent()
	if parent_node == null:
		return []

	var orig_transform: Transform3D = global_transform if is_inside_tree() else transform
	var orig_lin_vel := linear_velocity
	var orig_ang_vel := angular_velocity
	var orig_cell_size := cell_size
	var orig_blocks := constituent_blocks
	var orig_offsets := local_offsets

	for group_var in groups:
		var group: Array = group_var
		if group.is_empty():
			continue

		var script_res: GDScript = get_script() as GDScript
		var new_island: DebrisIsland = script_res.new() as DebrisIsland
		new_island.orchestrator = orchestrator
		parent_node.add_child(new_island)

		var group_data: Dictionary = {}
		for c_var in group:
			var c: Vector3i = c_var
			group_data[c] = orig_blocks[c]

		var local_centroid := Vector3.ZERO
		for c_var in group:
			var c: Vector3i = c_var
			local_centroid += orig_offsets[c]
		local_centroid /= float(group.size())

		var new_world_pos: Vector3 = to_global(local_centroid) if is_inside_tree() else (orig_transform * local_centroid)
		if new_island.is_inside_tree():
			new_island.global_transform = Transform3D(orig_transform.basis, new_world_pos)
		else:
			new_island.transform = Transform3D(orig_transform.basis, new_world_pos)

		var r_offset: Vector3 = orig_transform.basis * local_centroid
		new_island.linear_velocity = orig_lin_vel + orig_ang_vel.cross(r_offset)
		new_island.angular_velocity = orig_ang_vel

		new_island.setup_island_split(group, group_data, orig_offsets, local_centroid, orig_cell_size)
		spawned.append(new_island)

	island_split.emit(self, spawned)
	queue_free()
	return spawned

func _physics_process(_delta: float) -> void:
	# Out of world bounds check
	if global_position.y < -50.0:
		if orchestrator != null and orchestrator.has_method("unregister_debris_island"):
			orchestrator.unregister_debris_island(self)
		island_fell_out_of_world.emit(self)
		queue_free()

func _on_sleeping_state_changed() -> void:
	if sleeping and not is_settled:
		is_settled = true
		island_settled.emit(self)
	elif not sleeping:
		is_settled = false

