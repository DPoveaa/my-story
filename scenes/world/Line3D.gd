class_name Line3D
extends MeshInstance3D

## Visual 3D line node that renders a path from an array of Vector3 points
## using ImmediateMesh.

@export var line_color: Color = Color(0.18, 0.95, 1.0, 0.95)
@export var line_width: float = 4.0

var points: PackedVector3Array = PackedVector3Array():
	set(val):
		points = val
		_update_mesh()

var _imm_mesh: ImmediateMesh = null
var _material: StandardMaterial3D = null

func _ready() -> void:
	top_level = true
	global_transform = Transform3D.IDENTITY
	_init_resources()
	_update_mesh()

func _init_resources() -> void:
	if _imm_mesh == null:
		_imm_mesh = ImmediateMesh.new()
		mesh = _imm_mesh

	if _material == null:
		_material = StandardMaterial3D.new()
		_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_material.albedo_color = line_color
		_material.no_depth_test = true
		_material.use_point_size = true
		_material.point_size = line_width
		material_override = _material

func _update_mesh() -> void:
	_init_resources()
	if _imm_mesh == null:
		return

	global_transform = Transform3D.IDENTITY
	_imm_mesh.clear_surfaces()
	if points.size() < 2:
		return

	_imm_mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP, _material)
	for p in points:
		_imm_mesh.surface_add_vertex(p)
	_imm_mesh.surface_end()
