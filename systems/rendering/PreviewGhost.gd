class_name PreviewGhost
extends Node3D

## Visual preview indicator showing potential block placement.
## Changes color to provide clear feedback on placement validity.

@export var valid_color: Color = Color(0.2, 0.9, 0.4, 0.45)
@export var invalid_color: Color = Color(0.9, 0.2, 0.2, 0.45)

var _mesh_instance: MeshInstance3D
var _material: StandardMaterial3D

var _structure_ghost_root: Node3D = null
var _current_structure_scene: PackedScene = null

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
	_mesh_instance.visible = false
	add_child(_mesh_instance)
	# Hologram visual disabled — placement raycast/logic still driven by callers.
	visible = false
	hide()

## Updates the position and visual state of the single-block preview ghost.
## Shows translucent 1x1x1 grid snap preview hologram for valid placement targets.
func update_preview(cell: Vector3i, is_valid: bool, cell_size: float = 1.0) -> void:
	if not is_valid:
		hide_preview()
		return
	_clear_structure_ghost()
	if _mesh_instance != null and _mesh_instance.mesh is BoxMesh:
		(_mesh_instance.mesh as BoxMesh).size = Vector3.ONE * (cell_size * 1.02)
	var world_center := Vector3(
		(float(cell.x) + 0.5) * cell_size,
		(float(cell.y) + 0.5) * cell_size,
		(float(cell.z) + 0.5) * cell_size
	)
	global_position = world_center
	_material.albedo_color = valid_color
	visible = true
	if _mesh_instance != null:
		_mesh_instance.visible = true

## Updates the position and visual bounding box preview for area selection.
func update_area_preview(min_cell: Vector3i, max_cell: Vector3i, cell_size: float = 1.0) -> void:
	_clear_structure_ghost()
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
	if _mesh_instance != null:
		_mesh_instance.visible = true

## Updates the preview hologram to dynamically instantiate the exact visual mesh/scene
## of the selected structure (e.g. Pallet, ChoppingBlock) 1:1 in scale and geometry.
func update_structure_preview(structure_scene: PackedScene, xform: Transform3D, is_valid: bool) -> void:
	if not is_valid or structure_scene == null:
		hide_preview()
		return
	if _mesh_instance != null:
		_mesh_instance.visible = false
	if _structure_ghost_root == null or not is_instance_valid(_structure_ghost_root) or _current_structure_scene != structure_scene:
		_clear_structure_ghost()
		_current_structure_scene = structure_scene
		var inst: Node = structure_scene.instantiate()
		if inst is Node3D:
			_structure_ghost_root = inst as Node3D
			_strip_node_for_preview(_structure_ghost_root, _material)
			add_child(_structure_ghost_root)
	if _structure_ghost_root != null:
		_material.albedo_color = valid_color if is_valid else invalid_color
		global_transform = xform
		visible = true

func _strip_node_for_preview(node: Node, mat: StandardMaterial3D) -> void:
	node.set_script(null)
	node.set_process(false)
	node.set_physics_process(false)
	node.set_process_input(false)
	node.set_process_unhandled_input(false)
	if node is CollisionShape3D:
		(node as CollisionShape3D).disabled = true
	elif node is CollisionPolygon3D:
		(node as CollisionPolygon3D).disabled = true
	if node is CollisionObject3D:
		(node as CollisionObject3D).collision_layer = 0
		(node as CollisionObject3D).collision_mask = 0
	if node is Area3D:
		(node as Area3D).monitoring = false
		(node as Area3D).monitorable = false
	if node is NavigationObstacle3D:
		(node as NavigationObstacle3D).avoidance_enabled = false
	if node is Label3D:
		(node as Label3D).visible = false
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for child in node.get_children():
		_strip_node_for_preview(child, mat)

func _clear_structure_ghost() -> void:
	if _structure_ghost_root != null and is_instance_valid(_structure_ghost_root):
		_structure_ghost_root.queue_free()
	_structure_ghost_root = null
	_current_structure_scene = null

func hide_preview() -> void:
	visible = false
	if _mesh_instance != null:
		_mesh_instance.visible = false
	_clear_structure_ghost()
