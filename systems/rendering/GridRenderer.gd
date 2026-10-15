class_name GridRenderer
extends Node3D

## Visual renderer and static collider manager for stable grid blocks.
## Provides static physics colliders so raycasts can detect block faces
## and dynamic debris can collide against remaining stable buildings.

@export var grid_system: Node

## The static body hosting collision shapes for all stable blocks
var static_body: StaticBody3D

## Dictionaries holding visual meshes and collision shapes per occupied cell
var _mesh_nodes: Dictionary = {} # Vector3i -> MeshInstance3D
var _col_nodes: Dictionary = {}  # Vector3i -> CollisionShape3D

func _ready() -> void:
	if grid_system == null and has_node("/root/GridSystem"):
		grid_system = get_node("/root/GridSystem")

	_setup_static_body()

	if grid_system != null:
		_connect_grid_signals()
		# Initial populate if blocks already exist
		for cell in grid_system.get_all_cells():
			_create_block_node(cell, grid_system.get_block(cell))

func _setup_static_body() -> void:
	static_body = StaticBody3D.new()
	static_body.name = "GridStaticBody"
	add_child(static_body)

func _connect_grid_signals() -> void:
	if not grid_system.block_placed.is_connected(_on_block_placed):
		grid_system.block_placed.connect(_on_block_placed)
	if not grid_system.block_removed.is_connected(_on_block_removed):
		grid_system.block_removed.connect(_on_block_removed)
	if not grid_system.blocks_removed_batch.is_connected(_on_blocks_removed_batch):
		grid_system.blocks_removed_batch.connect(_on_blocks_removed_batch)
	if not grid_system.grid_cleared.is_connected(_on_grid_cleared):
		grid_system.grid_cleared.connect(_on_grid_cleared)

func _create_block_node(cell: Vector3i, data: BlockData) -> void:
	if not BlockTypeCatalog.is_structural(data.block_type):
		return
	if static_body == null:
		_setup_static_body()
	if _mesh_nodes.has(cell):
		_remove_block_node(cell)

	var cell_size: float = grid_system.cell_size if grid_system != null else 1.0
	var world_center: Vector3 = Vector3(
		(float(cell.x) + 0.5) * cell_size,
		(float(cell.y) + 0.5) * cell_size,
		(float(cell.z) + 0.5) * cell_size
	)

	# 1. Visual Box Mesh
	var mesh_inst := MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	box_mesh.size = Vector3.ONE * (cell_size * 0.99)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = BlockTypeCatalog.get_color(data.block_type)
	mat.roughness = 0.8
	box_mesh.material = mat
	mesh_inst.mesh = box_mesh
	mesh_inst.position = world_center
	add_child(mesh_inst)
	_mesh_nodes[cell] = mesh_inst

	# 2. Static Collision Shape
	var col_shape := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3.ONE * cell_size
	col_shape.shape = shape
	col_shape.position = world_center
	# Store cell coord in metadata for fast raycast lookup
	col_shape.set_meta("grid_cell", cell)
	static_body.add_child(col_shape)
	_col_nodes[cell] = col_shape

func _remove_block_node(cell: Vector3i) -> void:
	if _mesh_nodes.has(cell):
		var mesh_inst: MeshInstance3D = _mesh_nodes[cell]
		if is_instance_valid(mesh_inst):
			if mesh_inst.get_parent() != null:
				mesh_inst.get_parent().remove_child(mesh_inst)
			mesh_inst.queue_free()
		_mesh_nodes.erase(cell)

	if _col_nodes.has(cell):
		var col_shape: CollisionShape3D = _col_nodes[cell]
		if is_instance_valid(col_shape):
			if col_shape.get_parent() != null:
				col_shape.get_parent().remove_child(col_shape)
			col_shape.queue_free()
		_col_nodes.erase(cell)

func _on_block_placed(cell: Vector3i, data: BlockData) -> void:
	_create_block_node(cell, data)

func _on_block_removed(cell: Vector3i, _data: BlockData) -> void:
	_remove_block_node(cell)

func _on_blocks_removed_batch(cells: Array, _data_map: Dictionary) -> void:
	for c_var in cells:
		_remove_block_node(c_var)

func _on_grid_cleared() -> void:
	for cell in _mesh_nodes.keys():
		_remove_block_node(cell)
	_mesh_nodes.clear()
	_col_nodes.clear()
