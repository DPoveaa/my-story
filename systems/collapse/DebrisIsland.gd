class_name DebrisIsland
extends RigidBody3D

## Dynamic rigid body representing a fallen structural island.
## Preserves constituent block data and generates exact compound collision shapes.

signal island_settled(island: DebrisIsland)
signal island_fell_out_of_world(island: DebrisIsland)

## Stored constituent blocks: Dictionary[Vector3i, BlockData]
var constituent_blocks: Dictionary = {}

## Local offsets of constituent blocks relative to the island's center: Dictionary[Vector3i, Vector3]
var local_offsets: Dictionary = {}

## Grid cell size
var cell_size: float = 1.0

## Settled state flag
var is_settled: bool = false

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
	global_position = pivot_world

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

		# Exact constituent collision shape (no single oversized box)
		var col_shape := CollisionShape3D.new()
		var box_shape := BoxShape3D.new()
		box_shape.size = Vector3.ONE * cell_size
		col_shape.shape = box_shape
		col_shape.position = local_pos
		add_child(col_shape)

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

		total_mass += BlockTypeCatalog.get_mass(block_data.block_type)

	# 3. Configure physics parameters for reliable settling
	mass = maxf(1.0, total_mass)
	linear_damp = 0.6
	angular_damp = 0.8
	can_sleep = true
	contact_monitor = true
	max_contacts_reported = 4

func _physics_process(_delta: float) -> void:
	# Out of world bounds check
	if global_position.y < -50.0:
		island_fell_out_of_world.emit(self)
		queue_free()

func _on_sleeping_state_changed() -> void:
	if sleeping and not is_settled:
		is_settled = true
		island_settled.emit(self)
	elif not sleeping:
		is_settled = false
