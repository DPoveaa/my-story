class_name BlueprintVisualizer
extends Node3D

## Lightweight 3D spatial inspection visualizer for Blueprint Reconstruction Plans.
## Renders non-destructive translucent ghost blocks and wireframe bounding boxes in world space.
## Uses distinct accessible colors for cell states:
##   - PRESENT: Translucent Green
##   - MISSING: Translucent Cyan (Blueprint Blue)
##   - CONFLICT: Translucent Bright Red
##   - INVALID: Translucent Dark Orange

const COLOR_PRESENT: Color = Color(0.2, 0.9, 0.4, 0.22)
const COLOR_MISSING: Color = Color(0.2, 0.8, 1.0, 0.45)
const COLOR_CONFLICT: Color = Color(0.9, 0.2, 0.2, 0.55)
const COLOR_INVALID: Color = Color(0.9, 0.5, 0.1, 0.55)

var _mat_present: StandardMaterial3D
var _mat_missing: StandardMaterial3D
var _mat_conflict: StandardMaterial3D
var _mat_invalid: StandardMaterial3D

var _ghost_nodes: Array[Node3D] = []

func _ready() -> void:
	_mat_present = _create_preview_material(COLOR_PRESENT)
	_mat_missing = _create_preview_material(COLOR_MISSING)
	_mat_conflict = _create_preview_material(COLOR_CONFLICT)
	_mat_invalid = _create_preview_material(COLOR_INVALID)

func _create_preview_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = color
	return mat

## Clears all active inspection preview ghost meshes.
func clear_visuals() -> void:
	for node in _ghost_nodes:
		if is_instance_valid(node):
			node.queue_free()
	_ghost_nodes.clear()

## Renders 3D ghost blocks and outer bounding box for a ReconstructionPlan.
func render_plan(plan: RefCounted, cell_size: float = 1.0) -> void:
	clear_visuals()
	if plan == null or not ("entries" in plan):
		return

	if _mat_present == null:
		_ready()

	var entries: Array = plan.entries
	if entries.is_empty():
		return

	# Calculate bounding box from entries
	var first_cell: Vector3i = entries[0].get("world_cell", Vector3i.ZERO)
	var min_c := first_cell
	var max_c := first_cell

	for e in entries:
		if not (e is Dictionary):
			continue
		var wc: Vector3i = e.get("world_cell", Vector3i.ZERO)
		min_c.x = mini(min_c.x, wc.x)
		min_c.y = mini(min_c.y, wc.y)
		min_c.z = mini(min_c.z, wc.z)
		max_c.x = maxi(max_c.x, wc.x)
		max_c.y = maxi(max_c.y, wc.y)
		max_c.z = maxi(max_c.z, wc.z)

	# 1. Outer Bounding Box Mesh
	var box_inst := MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	var bounds_size := Vector3(
		float(max_c.x - min_c.x + 1) * cell_size + 0.05,
		float(max_c.y - min_c.y + 1) * cell_size + 0.05,
		float(max_c.z - min_c.z + 1) * cell_size + 0.05
	)
	var bounds_center := Vector3(
		(float(min_c.x + max_c.x) + 1.0) * 0.5 * cell_size,
		(float(min_c.y + max_c.y) + 1.0) * 0.5 * cell_size,
		(float(min_c.z + max_c.z) + 1.0) * 0.5 * cell_size
	)
	box_mesh.size = bounds_size
	var bbox_mat := _create_preview_material(Color(0.3, 0.7, 1.0, 0.2))
	box_mesh.material = bbox_mat
	box_inst.mesh = box_mesh
	box_inst.position = bounds_center
	add_child(box_inst)
	_ghost_nodes.append(box_inst)

	# 2. Individual Cell Ghost Block Meshes
	for e in entries:
		if not (e is Dictionary):
			continue

		var wc: Vector3i = e.get("world_cell", Vector3i.ZERO)
		var status: StringName = e.get("status", &"MISSING")

		var mat: StandardMaterial3D = _mat_missing
		match status:
			&"PRESENT": mat = _mat_present
			&"MISSING": mat = _mat_missing
			&"CONFLICT": mat = _mat_conflict
			&"INVALID": mat = _mat_invalid

		var ghost_inst := MeshInstance3D.new()
		var block_mesh := BoxMesh.new()
		block_mesh.size = Vector3.ONE * (cell_size * 0.96)
		block_mesh.material = mat
		ghost_inst.mesh = block_mesh
		ghost_inst.position = Vector3(
			(float(wc.x) + 0.5) * cell_size,
			(float(wc.y) + 0.5) * cell_size,
			(float(wc.z) + 0.5) * cell_size
		)
		add_child(ghost_inst)
		_ghost_nodes.append(ghost_inst)
