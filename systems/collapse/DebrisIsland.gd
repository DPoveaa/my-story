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

## Internal structural joints within this island: Dictionary[String, StructuralJoint]
var internal_joints: Dictionary = {}

## Local offsets of constituent blocks relative to the island's center: Dictionary[Vector3i, Vector3]
var local_offsets: Dictionary = {}

## Node references per constituent block cell
var _block_col_shapes: Dictionary = {} # Vector3i -> CollisionShape3D
var _block_meshes: Dictionary = {}     # Vector3i -> MeshInstance3D

## Grid cell size
var cell_size: float = 1.0

## Settled state flag
var is_settled: bool = false

## Frames the body has been awake since spawn — used to defer sleep re-enabling
var _awake_frames: int = 0
## Minimum awake frames before the body is allowed to sleep (prevents premature sleep)
const _MIN_AWAKE_FRAMES: int = 12

## Optional back-reference to CollapseOrchestrator for managing active debris registrations
var orchestrator: Node = null

func _ready() -> void:
	sleeping_state_changed.connect(_on_sleeping_state_changed)

func setup_island(cells: Array, block_data_map: Dictionary, p_cell_size: float, p_joints: Array = []) -> void:
	cell_size = p_cell_size
	internal_joints.clear()
	for j in p_joints:
		if j != null:
			internal_joints[j.get_key()] = j

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

	# 3. Configure physics parameters for reliable falling and natural tumbling.
	# linear_damp=0.0: no artificial drag so blocks continue falling even when stacked.
	# angular_damp=0.3: allows tumbling and rolling without permanent spinning.
	# can_sleep=false on spawn: prevents premature sleep from stale contact cache when
	#   a lower island is removed (the Jolt engine may not reactivate sleeping bodies
	#   that were resting on the freed body within the same frame).
	#   Sleep is re-enabled in _physics_process once the body has been awake for a few
	#   frames and has low velocity, allowing the engine to settle it correctly.
	mass = maxf(1.0, total_mass)
	linear_damp = 0.0
	angular_damp = 0.3
	can_sleep = false
	_awake_frames = 0
	contact_monitor = true
	max_contacts_reported = 6
	# Layer 4 = debris (bit 3); mask 7 = layers 1(ground)+2(player)+4(debris)
	collision_layer = 4
	collision_mask = 7

## Sets up an island resulting from a split of an existing debris island.
func setup_island_split(cells: Array, block_data_map: Dictionary, orig_offsets: Dictionary, centroid_offset: Vector3, p_cell_size: float, p_joints: Array = []) -> void:
	cell_size = p_cell_size
	internal_joints.clear()
	for j in p_joints:
		if j != null:
			internal_joints[j.get_key()] = j
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
	linear_damp = 0.0
	angular_damp = 0.3
	can_sleep = false
	_awake_frames = 0
	contact_monitor = true
	max_contacts_reported = 6
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

		var group_joints: Array = []
		var g_set: Dictionary = {}
		for cv in group:
			g_set[cv] = true
		for j in internal_joints.values():
			if g_set.has(j.cell_a) and g_set.has(j.cell_b):
				group_joints.append(j)

		new_island.setup_island_split(group, group_data, orig_offsets, local_centroid, orig_cell_size, group_joints)
		spawned.append(new_island)

	island_split.emit(self, spawned)
	queue_free()
	return spawned

## Applies impact energy to the internal structural joints connected to a constituent cell.
## Breaks joints if impact energy or accumulated damage exceeds strength limits.
## Splits the island if broken joints disconnect constituent blocks.
func apply_impact_damage(hit_cell: Vector3i, impact_energy: float) -> Array:
	var broken: Array = []
	if impact_energy < 8.0:
		return broken

	var relevant_joints: Array = []
	for j in internal_joints.values():
		if not j.is_broken and j.connects_cell(hit_cell):
			relevant_joints.append(j)

	if relevant_joints.is_empty():
		return broken

	var energy_per_joint: float = impact_energy / float(relevant_joints.size())

	for j in relevant_joints:
		if energy_per_joint >= j.max_strength * 1.8:
			j.break_joint()
			broken.append(j)
		else:
			var dur_res: float = maxf(0.5, BlockTypeCatalog.get_max_durability(j.material_a) * BlockTypeCatalog.get_max_durability(j.material_b))
			var dmg: float = energy_per_joint / dur_res
			if j.apply_damage(dmg):
				broken.append(j)

	if not broken.is_empty():
		call_deferred("check_and_split_on_broken_joints")

	return broken

## Evaluates connectivity among remaining blocks based strictly on intact internal joints.
## If broken joints disconnect the blocks, splits into independent compound bodies.
## Preserves compound debris groups where internal joints remain intact.
func check_and_split_on_broken_joints() -> Array:
	if constituent_blocks.size() <= 1:
		return []

	# Check connectivity based on intact internal joints
	var cells: Array = constituent_blocks.keys()
	var unvisited: Dictionary = {}
	for c in cells:
		unvisited[c] = true

	var groups: Array = []

	for c in cells:
		if not unvisited.has(c):
			continue

		var group: Array = []
		var queue: Array = [c]
		unvisited.erase(c)

		var head: int = 0
		while head < queue.size():
			var curr: Vector3i = queue[head]
			head += 1
			group.append(curr)

			for j in internal_joints.values():
				if not j.is_broken and j.connects_cell(curr):
					var other: Vector3i = j.get_other_cell(curr)
					if unvisited.has(other):
						unvisited.erase(other)
						queue.append(other)

		groups.append(group)

	if groups.size() > 1:
		if orchestrator != null and orchestrator.has_method("split_debris_island"):
			return orchestrator.split_debris_island(self, groups)
		else:
			return _split_without_orchestrator(groups)

	return []

func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if is_settled or sleeping:
		return
	var speed_sq: float = state.linear_velocity.length_squared()
	if speed_sq < 9.0: # speed < 3.0 m/s
		return

	var contact_count: int = state.get_contact_count()
	if contact_count == 0:
		return

	var impact_energy: float = 0.5 * mass * speed_sq

	for i in range(mini(contact_count, 2)):
		var collider_obj: Object = state.get_contact_collider_object(i)
		var contact_pos: Vector3 = state.get_contact_collider_position(i)

		# Resolve local cell hit
		var hit_cell = get_cell_from_shape_hit(0, contact_pos)
		if hit_cell != null and hit_cell is Vector3i:
			apply_impact_damage(hit_cell, impact_energy)

		# If collider is static grid body, transfer impact to grid joints
		if collider_obj is StaticBody3D:
			var joint_sys: Node = null
			if has_node("/root/JointSystem"):
				joint_sys = get_node("/root/JointSystem")
			var grid_sys: Node = null
			if has_node("/root/GridSystem"):
				grid_sys = get_node("/root/GridSystem")

			var shape_idx: int = state.get_contact_collider_shape(i)
			var owner_id: int = collider_obj.shape_find_owner(shape_idx)
			if owner_id >= 0:
				var owner_shape = collider_obj.shape_owner_get_owner(owner_id)
				if owner_shape != null and owner_shape.has_meta("grid_cell"):
					var grid_cell: Vector3i = owner_shape.get_meta("grid_cell")
					if joint_sys != null and grid_sys != null and grid_sys.has_block(grid_cell):
						if joint_sys.is_block_bonded(grid_cell):
							joint_sys.apply_impact_to_block_joints(grid_cell, impact_energy)
						else:
							# Unbonded block hit by high-speed debris: knock free!
							if orchestrator != null and orchestrator.has_method("push_unbonded_block"):
								var push_vel: Vector3 = state.linear_velocity * 0.5
								orchestrator.call_deferred("push_unbonded_block", grid_cell, push_vel)


func _physics_process(_delta: float) -> void:
	# Out of world bounds check
	if global_position.y < -50.0:
		if orchestrator != null and orchestrator.has_method("unregister_debris_island"):
			orchestrator.unregister_debris_island(self)
		island_fell_out_of_world.emit(self)
		queue_free()
		return

	# Gradually re-enable sleeping after the body has been active for enough frames.
	# This prevents stale contact-cache sleep from freezing debris mid-air after a
	# supporting body beneath it was removed.
	if not can_sleep:
		_awake_frames += 1
		if _awake_frames >= _MIN_AWAKE_FRAMES:
			can_sleep = true

## Wake this island and all debris islands resting on top of it.
## Called by CollapseOrchestrator when an island is removed/freed,
## so stacked bodies above it resume falling.
func wake_and_disable_sleep() -> void:
	can_sleep = false
	_awake_frames = 0
	is_settled = false
	if sleeping:
		sleeping = false

func _on_sleeping_state_changed() -> void:
	if sleeping and not is_settled:
		is_settled = true
		island_settled.emit(self)
	elif not sleeping:
		is_settled = false

