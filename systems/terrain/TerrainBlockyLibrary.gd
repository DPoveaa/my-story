class_name TerrainBlockyLibrary
extends RefCounted

## Builds a VoxelBlockyLibrary for VoxelMesherBlocky.
## Full cubes keep rocky sides/undersides angular. Walkable tops use stair-style
## ramp / corner models (horizontal treads + risers) so VoxelMesherBlocky mesh
## collision matches visuals. Orientations are separate TYPE ids chosen at generation.

const BLOCK_AIR: int = 0
const BLOCK_GRASS: int = 1
const BLOCK_DIRT: int = 2
const BLOCK_STONE: int = 3
const BLOCK_COAL: int = 4
const BLOCK_IRON: int = 5
const BLOCK_GOLD: int = 6

## Grass 1-step ramps: low edge faces the given axis.
const BLOCK_GRASS_RAMP_PX: int = 10
const BLOCK_GRASS_RAMP_NX: int = 11
const BLOCK_GRASS_RAMP_PZ: int = 12
const BLOCK_GRASS_RAMP_NZ: int = 13
## Outer corners: low toward the named axes (high L opposite).
const BLOCK_GRASS_CORNER_PX_PZ: int = 14
const BLOCK_GRASS_CORNER_PX_NZ: int = 15
const BLOCK_GRASS_CORNER_NX_PZ: int = 16
const BLOCK_GRASS_CORNER_NX_NZ: int = 17

const MODEL_COUNT: int = 18
const _STEP_Y: float = 0.5

const _HYBRID_SHADER = preload("res://systems/terrain/terrain_hybrid.gdshader")

static func material_id_of(type_id: int) -> int:
	match type_id:
		BLOCK_GRASS, BLOCK_GRASS_RAMP_PX, BLOCK_GRASS_RAMP_NX, BLOCK_GRASS_RAMP_PZ, BLOCK_GRASS_RAMP_NZ, \
		BLOCK_GRASS_CORNER_PX_PZ, BLOCK_GRASS_CORNER_PX_NZ, BLOCK_GRASS_CORNER_NX_PZ, BLOCK_GRASS_CORNER_NX_NZ:
			return BLOCK_GRASS
		BLOCK_DIRT:
			return BLOCK_DIRT
		BLOCK_STONE:
			return BLOCK_STONE
		BLOCK_COAL:
			return BLOCK_COAL
		BLOCK_IRON:
			return BLOCK_IRON
		BLOCK_GOLD:
			return BLOCK_GOLD
		_:
			return BLOCK_AIR


static func type_to_name(type_id: int) -> StringName:
	match material_id_of(type_id):
		BLOCK_GRASS:
			return &"grass"
		BLOCK_DIRT:
			return &"dirt"
		BLOCK_STONE:
			return &"stone"
		BLOCK_COAL:
			return &"coal"
		BLOCK_IRON:
			return &"iron"
		BLOCK_GOLD:
			return &"gold"
		_:
			return &""


static func make_materials() -> Dictionary:
	var mats: Dictionary = {}
	mats[&"grass"] = _mat(Color(0.33, 0.56, 0.27), 0.92, 0.0, 0.08, 0.35)
	mats[&"dirt"] = _mat(Color(0.62, 0.40, 0.23), 0.94, 0.0, 0.10, 0.95)
	mats[&"stone"] = _mat(Color(0.50, 0.46, 0.41), 0.90, 0.0, 0.14, 1.0)
	mats[&"coal"] = _mat(Color(0.20, 0.20, 0.22), 0.92, 0.0, 0.12, 1.0)
	mats[&"iron"] = _mat(Color(0.68, 0.66, 0.62), 0.55, 0.45, 0.35, 1.0)
	mats[&"gold"] = _mat(Color(0.86, 0.70, 0.16), 0.40, 0.70, 0.45, 1.0)
	return mats


static func _mat(
	albedo: Color, roughness: float, metallic: float, specular: float, facet: float
) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = _HYBRID_SHADER
	m.set_shader_parameter("u_albedo", albedo)
	m.set_shader_parameter("u_roughness", roughness)
	m.set_shader_parameter("u_metallic", metallic)
	m.set_shader_parameter("u_specular", specular)
	m.set_shader_parameter("u_facet_strength", facet)
	return m


static func build_library() -> VoxelBlockyLibrary:
	var mats: Dictionary = make_materials()
	var models: Array = []
	models.resize(MODEL_COUNT)
	for i in range(MODEL_COUNT):
		models[i] = VoxelBlockyModelEmpty.new()

	models[BLOCK_AIR] = VoxelBlockyModelEmpty.new()
	models[BLOCK_GRASS] = _make_cube(mats[&"grass"])
	models[BLOCK_DIRT] = _make_cube(mats[&"dirt"])
	models[BLOCK_STONE] = _make_cube(mats[&"stone"])
	models[BLOCK_COAL] = _make_cube(mats[&"coal"])
	models[BLOCK_IRON] = _make_cube(mats[&"iron"])
	models[BLOCK_GOLD] = _make_cube(mats[&"gold"])

	var grass_mat: Material = mats[&"grass"]
	models[BLOCK_GRASS_RAMP_PX] = _make_mesh_model(_build_ramp_mesh(+1, 0), grass_mat)
	models[BLOCK_GRASS_RAMP_NX] = _make_mesh_model(_build_ramp_mesh(-1, 0), grass_mat)
	models[BLOCK_GRASS_RAMP_PZ] = _make_mesh_model(_build_ramp_mesh(0, +1), grass_mat)
	models[BLOCK_GRASS_RAMP_NZ] = _make_mesh_model(_build_ramp_mesh(0, -1), grass_mat)
	models[BLOCK_GRASS_CORNER_PX_PZ] = _make_mesh_model(_build_corner_mesh(+1, +1), grass_mat)
	models[BLOCK_GRASS_CORNER_PX_NZ] = _make_mesh_model(_build_corner_mesh(+1, -1), grass_mat)
	models[BLOCK_GRASS_CORNER_NX_PZ] = _make_mesh_model(_build_corner_mesh(-1, +1), grass_mat)
	models[BLOCK_GRASS_CORNER_NX_NZ] = _make_mesh_model(_build_corner_mesh(-1, -1), grass_mat)

	var lib := VoxelBlockyLibrary.new()
	# Untextured hybrid shader does not need tangents; keeps bake reliable.
	if "bake_tangents" in lib:
		lib.bake_tangents = false
	if "models" in lib:
		lib.models = models
	elif lib.has_method("set_models"):
		lib.set_models(models)
	else:
		for i in range(MODEL_COUNT):
			if lib.has_method("add_model"):
				lib.add_model(models[i])
			elif lib.has_method("set_model"):
				lib.set_model(i, models[i])

	if lib.has_method("bake"):
		lib.bake()
	return lib


## Pick a surface model from cardinal height drops of exactly 1.
## Drops > 1 (solid cliff neighbors) stay cubes. Air neighbors (encoded as >= 90)
## do not block ramps toward other solid 1-step neighbors.
## Ambiguous multi-axis cases use corners only for exactly two adjacent 1-steps.
static func surface_model_for_drops(base_id: int, drop_px: int, drop_nx: int, drop_pz: int, drop_nz: int) -> int:
	if base_id != BLOCK_GRASS:
		return base_id

	if _is_solid_cliff(drop_px) or _is_solid_cliff(drop_nx) or _is_solid_cliff(drop_pz) or _is_solid_cliff(drop_nz):
		return BLOCK_GRASS

	var dpx: bool = drop_px == 1
	var dnx: bool = drop_nx == 1
	var dpz: bool = drop_pz == 1
	var dnz: bool = drop_nz == 1
	var count: int = int(dpx) + int(dnx) + int(dpz) + int(dnz)
	if count == 0:
		return BLOCK_GRASS
	if count == 1:
		if dpx:
			return BLOCK_GRASS_RAMP_PX
		if dnx:
			return BLOCK_GRASS_RAMP_NX
		if dpz:
			return BLOCK_GRASS_RAMP_PZ
		return BLOCK_GRASS_RAMP_NZ
	if count == 2:
		if dpx and dpz and not dnx and not dnz:
			return BLOCK_GRASS_CORNER_PX_PZ
		if dpx and dnz and not dnx and not dpz:
			return BLOCK_GRASS_CORNER_PX_NZ
		if dnx and dpz and not dpx and not dnz:
			return BLOCK_GRASS_CORNER_NX_PZ
		if dnx and dnz and not dpx and not dpz:
			return BLOCK_GRASS_CORNER_NX_NZ
		return BLOCK_GRASS
	return BLOCK_GRASS


static func _is_solid_cliff(drop: int) -> bool:
	return drop > 1 and drop < 90


static func _make_cube(mat: Material) -> VoxelBlockyModelCube:
	var model := VoxelBlockyModelCube.new()
	model.set_material_override(0, mat)
	if model.has_method("set_mesh_collision_enabled"):
		model.set_mesh_collision_enabled(0, true)
	model.collision_aabbs = [AABB(Vector3.ZERO, Vector3.ONE)]
	model.culls_neighbors = true
	model.transparency_index = 0
	return model


static func _make_mesh_model(mesh: ArrayMesh, mat: Material) -> VoxelBlockyModelMesh:
	var model := VoxelBlockyModelMesh.new()
	# Mesh first so surface_count is valid before collision / material overrides.
	if model.has_method("set_mesh"):
		model.set_mesh(mesh)
	else:
		model.mesh = mesh
	model.set_material_override(0, mat)
	# Mesh-based physics for CharacterBody3D (collision_aabbs are VoxelBoxMover only).
	if model.has_method("set_mesh_collision_enabled"):
		model.set_mesh_collision_enabled(0, true)
	model.collision_aabbs = [AABB(Vector3.ZERO, Vector3.ONE)]
	# Full unit sides still cull; partial stair sides won't match cube patterns.
	model.culls_neighbors = true
	model.transparency_index = 0
	model.side_vertex_tolerance = 0.001
	return model


static func _build_ramp_mesh(dir_x: int, dir_z: int) -> ArrayMesh:
	## Two-step stair: high tread opposite the drop, low tread toward it.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	# Unit underside (side-cullable against the dirt below).
	_quad(st,
		Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 0, 1), Vector3(0, 0, 1),
		Vector3.DOWN)

	if dir_x > 0:
		_emit_straight_stair(st, true, true)
	elif dir_x < 0:
		_emit_straight_stair(st, true, false)
	elif dir_z > 0:
		_emit_straight_stair(st, false, true)
	else:
		_emit_straight_stair(st, false, false)

	st.index()
	return st.commit()


static func _emit_straight_stair(st: SurfaceTool, along_x: bool, low_positive: bool) -> void:
	## along_x: step across X; else across Z. low_positive: low tread on + axis side.
	var mid: float = 0.5
	# Outer shell of lower slab (y=0..0.5), skipping top under the upper tread.
	_quad(st,
		Vector3(0, 0, 0), Vector3(0, 0, 1), Vector3(0, _STEP_Y, 1), Vector3(0, _STEP_Y, 0),
		Vector3.LEFT)
	_quad(st,
		Vector3(1, 0, 0), Vector3(1, _STEP_Y, 0), Vector3(1, _STEP_Y, 1), Vector3(1, 0, 1),
		Vector3.RIGHT)
	_quad(st,
		Vector3(0, 0, 0), Vector3(0, _STEP_Y, 0), Vector3(1, _STEP_Y, 0), Vector3(1, 0, 0),
		Vector3.FORWARD)
	_quad(st,
		Vector3(0, 0, 1), Vector3(1, 0, 1), Vector3(1, _STEP_Y, 1), Vector3(0, _STEP_Y, 1),
		Vector3.BACK)

	if along_x:
		var high_x0: float = 0.0 if low_positive else mid
		var high_x1: float = mid if low_positive else 1.0
		var low_x0: float = mid if low_positive else 0.0
		var low_x1: float = 1.0 if low_positive else mid
		# Low tread top.
		_quad(st,
			Vector3(low_x0, _STEP_Y, 0), Vector3(low_x1, _STEP_Y, 0),
			Vector3(low_x1, _STEP_Y, 1), Vector3(low_x0, _STEP_Y, 1),
			Vector3.UP)
		# Upper tread volume (exposed faces only).
		_quad(st,
			Vector3(high_x0, 1.0, 0), Vector3(high_x0, 1.0, 1),
			Vector3(high_x1, 1.0, 1), Vector3(high_x1, 1.0, 0),
			Vector3.UP)
		# Riser between treads.
		if low_positive:
			_quad(st,
				Vector3(mid, _STEP_Y, 0), Vector3(mid, _STEP_Y, 1),
				Vector3(mid, 1.0, 1), Vector3(mid, 1.0, 0),
				Vector3.RIGHT)
			_quad(st,
				Vector3(high_x0, _STEP_Y, 0), Vector3(high_x0, 1.0, 0),
				Vector3(high_x0, 1.0, 1), Vector3(high_x0, _STEP_Y, 1),
				Vector3.LEFT)
		else:
			_quad(st,
				Vector3(mid, _STEP_Y, 1), Vector3(mid, _STEP_Y, 0),
				Vector3(mid, 1.0, 0), Vector3(mid, 1.0, 1),
				Vector3.LEFT)
			_quad(st,
				Vector3(high_x1, _STEP_Y, 0), Vector3(high_x1, _STEP_Y, 1),
				Vector3(high_x1, 1.0, 1), Vector3(high_x1, 1.0, 0),
				Vector3.RIGHT)
		# Upper ±Z sides.
		_quad(st,
			Vector3(high_x0, _STEP_Y, 0), Vector3(high_x1, _STEP_Y, 0),
			Vector3(high_x1, 1.0, 0), Vector3(high_x0, 1.0, 0),
			Vector3.FORWARD)
		_quad(st,
			Vector3(high_x0, _STEP_Y, 1), Vector3(high_x0, 1.0, 1),
			Vector3(high_x1, 1.0, 1), Vector3(high_x1, _STEP_Y, 1),
			Vector3.BACK)
	else:
		var high_z0: float = 0.0 if low_positive else mid
		var high_z1: float = mid if low_positive else 1.0
		var low_z0: float = mid if low_positive else 0.0
		var low_z1: float = 1.0 if low_positive else mid
		_quad(st,
			Vector3(0, _STEP_Y, low_z0), Vector3(1, _STEP_Y, low_z0),
			Vector3(1, _STEP_Y, low_z1), Vector3(0, _STEP_Y, low_z1),
			Vector3.UP)
		_quad(st,
			Vector3(0, 1.0, high_z0), Vector3(0, 1.0, high_z1),
			Vector3(1, 1.0, high_z1), Vector3(1, 1.0, high_z0),
			Vector3.UP)
		if low_positive:
			_quad(st,
				Vector3(0, _STEP_Y, mid), Vector3(1, _STEP_Y, mid),
				Vector3(1, 1.0, mid), Vector3(0, 1.0, mid),
				Vector3.BACK)
			_quad(st,
				Vector3(0, _STEP_Y, high_z0), Vector3(0, 1.0, high_z0),
				Vector3(1, 1.0, high_z0), Vector3(1, _STEP_Y, high_z0),
				Vector3.FORWARD)
		else:
			_quad(st,
				Vector3(1, _STEP_Y, mid), Vector3(0, _STEP_Y, mid),
				Vector3(0, 1.0, mid), Vector3(1, 1.0, mid),
				Vector3.FORWARD)
			_quad(st,
				Vector3(0, _STEP_Y, high_z1), Vector3(1, _STEP_Y, high_z1),
				Vector3(1, 1.0, high_z1), Vector3(0, 1.0, high_z1),
				Vector3.BACK)
		_quad(st,
			Vector3(0, _STEP_Y, high_z0), Vector3(0, _STEP_Y, high_z1),
			Vector3(0, 1.0, high_z1), Vector3(0, 1.0, high_z0),
			Vector3.LEFT)
		_quad(st,
			Vector3(1, _STEP_Y, high_z0), Vector3(1, 1.0, high_z0),
			Vector3(1, 1.0, high_z1), Vector3(1, _STEP_Y, high_z1),
			Vector3.RIGHT)


static func _build_corner_mesh(dir_x: int, dir_z: int) -> ArrayMesh:
	## Outer-corner stair: high L opposite (dir_x, dir_z), low quadrant toward drops.
	## Compatible with adjacent straight ramps (shared half-edges at mid-height / full).
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	_quad(st,
		Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 0, 1), Vector3(0, 0, 1),
		Vector3.DOWN)

	# Lower slab outer sides.
	_quad(st,
		Vector3(0, 0, 0), Vector3(0, 0, 1), Vector3(0, _STEP_Y, 1), Vector3(0, _STEP_Y, 0),
		Vector3.LEFT)
	_quad(st,
		Vector3(1, 0, 0), Vector3(1, _STEP_Y, 0), Vector3(1, _STEP_Y, 1), Vector3(1, 0, 1),
		Vector3.RIGHT)
	_quad(st,
		Vector3(0, 0, 0), Vector3(0, _STEP_Y, 0), Vector3(1, _STEP_Y, 0), Vector3(1, 0, 0),
		Vector3.FORWARD)
	_quad(st,
		Vector3(0, 0, 1), Vector3(1, 0, 1), Vector3(1, _STEP_Y, 1), Vector3(0, _STEP_Y, 1),
		Vector3.BACK)

	# Low tread = outer quadrant toward drops.
	var lx0: float = 0.5 if dir_x > 0 else 0.0
	var lx1: float = 1.0 if dir_x > 0 else 0.5
	var lz0: float = 0.5 if dir_z > 0 else 0.0
	var lz1: float = 1.0 if dir_z > 0 else 0.5
	_quad(st,
		Vector3(lx0, _STEP_Y, lz0), Vector3(lx1, _STEP_Y, lz0),
		Vector3(lx1, _STEP_Y, lz1), Vector3(lx0, _STEP_Y, lz1),
		Vector3.UP)

	# High L = two rectangles that share the inner corner (no overlap).
	# 1) Full strip opposite dir_x.
	var hx0: float = 0.0 if dir_x > 0 else 0.5
	var hx1: float = 0.5 if dir_x > 0 else 1.0
	_quad(st,
		Vector3(hx0, 1.0, 0.0), Vector3(hx0, 1.0, 1.0),
		Vector3(hx1, 1.0, 1.0), Vector3(hx1, 1.0, 0.0),
		Vector3.UP)
	# 2) Remaining stub opposite dir_z on the low-x half only.
	var sx0: float = lx0
	var sx1: float = lx1
	var sz0: float = 0.0 if dir_z > 0 else 0.5
	var sz1: float = 0.5 if dir_z > 0 else 1.0
	_quad(st,
		Vector3(sx0, 1.0, sz0), Vector3(sx0, 1.0, sz1),
		Vector3(sx1, 1.0, sz1), Vector3(sx1, 1.0, sz0),
		Vector3.UP)

	# Risers into the low quadrant.
	# Facing dir_x at x=mid, only over low-z span.
	var mx: float = 0.5
	var mz: float = 0.5
	if dir_x > 0:
		_quad(st,
			Vector3(mx, _STEP_Y, lz0), Vector3(mx, _STEP_Y, lz1),
			Vector3(mx, 1.0, lz1), Vector3(mx, 1.0, lz0),
			Vector3.RIGHT)
	else:
		_quad(st,
			Vector3(mx, _STEP_Y, lz1), Vector3(mx, _STEP_Y, lz0),
			Vector3(mx, 1.0, lz0), Vector3(mx, 1.0, lz1),
			Vector3.LEFT)
	if dir_z > 0:
		_quad(st,
			Vector3(lx0, _STEP_Y, mz), Vector3(lx1, _STEP_Y, mz),
			Vector3(lx1, 1.0, mz), Vector3(lx0, 1.0, mz),
			Vector3.BACK)
	else:
		_quad(st,
			Vector3(lx1, _STEP_Y, mz), Vector3(lx0, _STEP_Y, mz),
			Vector3(lx0, 1.0, mz), Vector3(lx1, 1.0, mz),
			Vector3.FORWARD)

	# Outer high sides (unit-cell faces for neighbor matching).
	if dir_x > 0:
		_quad(st,
			Vector3(0.0, _STEP_Y, 0.0), Vector3(0.0, 1.0, 0.0),
			Vector3(0.0, 1.0, 1.0), Vector3(0.0, _STEP_Y, 1.0),
			Vector3.LEFT)
	else:
		_quad(st,
			Vector3(1.0, _STEP_Y, 0.0), Vector3(1.0, _STEP_Y, 1.0),
			Vector3(1.0, 1.0, 1.0), Vector3(1.0, 1.0, 0.0),
			Vector3.RIGHT)
	if dir_z > 0:
		_quad(st,
			Vector3(0.0, _STEP_Y, 0.0), Vector3(1.0, _STEP_Y, 0.0),
			Vector3(1.0, 1.0, 0.0), Vector3(0.0, 1.0, 0.0),
			Vector3.FORWARD)
	else:
		_quad(st,
			Vector3(0.0, _STEP_Y, 1.0), Vector3(0.0, 1.0, 1.0),
			Vector3(1.0, 1.0, 1.0), Vector3(1.0, _STEP_Y, 1.0),
			Vector3.BACK)

	# High strip end-cap on the drop Z side (only over hx span).
	var strip_z_cap: float = 1.0 if dir_z > 0 else 0.0
	var strip_z_n: Vector3 = Vector3.BACK if dir_z > 0 else Vector3.FORWARD
	_quad(st,
		Vector3(hx0, _STEP_Y, strip_z_cap), Vector3(hx1, _STEP_Y, strip_z_cap),
		Vector3(hx1, 1.0, strip_z_cap), Vector3(hx0, 1.0, strip_z_cap),
		strip_z_n)

	# High stub outer wall on the drop-X side (half Z span).
	if dir_x > 0:
		_quad(st,
			Vector3(1.0, _STEP_Y, sz0), Vector3(1.0, _STEP_Y, sz1),
			Vector3(1.0, 1.0, sz1), Vector3(1.0, 1.0, sz0),
			Vector3.RIGHT)
	else:
		_quad(st,
			Vector3(0.0, _STEP_Y, sz1), Vector3(0.0, _STEP_Y, sz0),
			Vector3(0.0, 1.0, sz0), Vector3(0.0, 1.0, sz1),
			Vector3.LEFT)

	st.index()
	return st.commit()


static func _quad(
	st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3
) -> void:
	_tri(st, a, b, c, n)
	_tri(st, a, c, d, n)


static func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, n: Vector3) -> void:
	var area: Vector3 = (b - a).cross(c - a)
	if area.length_squared() < 1e-12:
		return
	var pb := b
	var pc := c
	if area.dot(n) < 0.0:
		pb = c
		pc = b
		area = -area
	var geo_n: Vector3 = area.normalized()
	st.set_normal(geo_n)
	st.set_uv(Vector2(a.x, a.z))
	st.add_vertex(a)
	st.set_normal(geo_n)
	st.set_uv(Vector2(pb.x, pb.z))
	st.add_vertex(pb)
	st.set_normal(geo_n)
	st.set_uv(Vector2(pc.x, pc.z))
	st.add_vertex(pc)
