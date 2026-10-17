class_name Line3D
extends MeshInstance3D

## Visual 3D route ribbon node that renders a continuous, thick 3D path beam
## with genuine geometry using ImmediateMesh and unshaded material.

@export var line_color: Color = Color(0.18, 0.95, 1.0, 0.95)
@export var ribbon_width: float = 0.14
@export var ribbon_height: float = 0.08

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
		_material.cull_mode = BaseMaterial3D.CULL_DISABLED
		_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material_override = _material

func set_route_color(col: Color) -> void:
	line_color = col
	if _material != null:
		_material.albedo_color = col

func _update_mesh() -> void:
	_init_resources()
	if _imm_mesh == null:
		return

	global_transform = Transform3D.IDENTITY
	_imm_mesh.clear_surfaces()
	if points.size() < 2:
		return

	var half_w: float = ribbon_width * 0.5
	var half_h: float = ribbon_height * 0.5

	_imm_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES, _material)

	for i in range(points.size() - 1):
		var p0 := points[i]
		var p1 := points[i + 1]
		var delta := p1 - p0
		if delta.length_squared() < 0.0001:
			continue

		var fwd := delta.normalized()
		var right := fwd.cross(Vector3.UP)
		if right.length_squared() < 0.001:
			right = fwd.cross(Vector3.RIGHT)
		right = right.normalized() * half_w
		var up := fwd.cross(right).normalized() * half_h

		# Horizontal plane quad
		var h0_a := p0 - right
		var h0_b := p0 + right
		var h1_a := p1 - right
		var h1_b := p1 + right

		_imm_mesh.surface_add_vertex(h0_a)
		_imm_mesh.surface_add_vertex(h0_b)
		_imm_mesh.surface_add_vertex(h1_b)

		_imm_mesh.surface_add_vertex(h0_a)
		_imm_mesh.surface_add_vertex(h1_b)
		_imm_mesh.surface_add_vertex(h1_a)

		# Vertical plane quad
		var v0_a := p0 - up
		var v0_b := p0 + up
		var v1_a := p1 - up
		var v1_b := p1 + up

		_imm_mesh.surface_add_vertex(v0_a)
		_imm_mesh.surface_add_vertex(v0_b)
		_imm_mesh.surface_add_vertex(v1_b)

		_imm_mesh.surface_add_vertex(v0_a)
		_imm_mesh.surface_add_vertex(v1_b)
		_imm_mesh.surface_add_vertex(v1_a)

	_imm_mesh.surface_end()
