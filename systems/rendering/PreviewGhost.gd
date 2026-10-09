class_name PreviewGhost
extends Node3D

## Visual preview indicator showing potential block placement.
## Changes color to provide clear feedback on placement validity.

@export var valid_color: Color = Color(0.2, 0.9, 0.4, 0.45)
@export var invalid_color: Color = Color(0.9, 0.2, 0.2, 0.45)

var _mesh_instance: MeshInstance3D
var _material: StandardMaterial3D

func _ready() -> void:
	_mesh_instance = MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	box_mesh.size = Vector3.ONE * 1.02 # Slightly larger than 1.0 to frame targeted cell clearly
	_material = StandardMaterial3D.new()
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_material.albedo_color = valid_color
	box_mesh.material = _material
	_mesh_instance.mesh = box_mesh
	add_child(_mesh_instance)
	visible = false

## Updates the position and visual state of the single-block preview ghost.
func update_preview(cell: Vector3i, is_valid: bool, cell_size: float = 1.0) -> void:
	if _mesh_instance != null and _mesh_instance.mesh is BoxMesh:
		(_mesh_instance.mesh as BoxMesh).size = Vector3.ONE * (cell_size * 1.02)
	var world_center := Vector3(
		(float(cell.x) + 0.5) * cell_size,
		(float(cell.y) + 0.5) * cell_size,
		(float(cell.z) + 0.5) * cell_size
	)
	global_position = world_center
	_material.albedo_color = valid_color if is_valid else invalid_color
	visible = true

## Updates the position and visual bounding box preview for area selection.
func update_area_preview(min_cell: Vector3i, max_cell: Vector3i, cell_size: float = 1.0) -> void:
	var bounds_size := Vector3(
		float(max_cell.x - min_cell.x + 1) * cell_size,
		float(max_cell.y - min_cell.y + 1) * cell_size,
		float(max_cell.z - min_cell.z + 1) * cell_size
	)
	var bounds_center := Vector3(
		(float(min_cell.x + max_cell.x) + 1.0) * 0.5 * cell_size,
		(float(min_cell.y + max_cell.y) + 1.0) * 0.5 * cell_size,
		(float(min_cell.z + max_cell.z) + 1.0) * 0.5 * cell_size
	)
	if _mesh_instance != null and _mesh_instance.mesh is BoxMesh:
		(_mesh_instance.mesh as BoxMesh).size = bounds_size
	global_position = bounds_center
	_material.albedo_color = Color(0.3, 0.7, 1.0, 0.45)
	visible = true

func hide_preview() -> void:
	visible = false
