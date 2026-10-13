class_name TerrainBlockyLibrary
extends RefCounted

## Builds a VoxelBlockyLibrary for VoxelMesherBlocky.
## Full cubes keep rocky sides/undersides angular. Only walkable tops use ramp /
## corner models for 1-voxel height steps. Voxel Tools does not auto-pick
## neighbor-dependent shapes — orientations are separate TYPE ids chosen at generation.

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
## Outer corners: high at the opposite corner, low toward +X/+Z variants.
const BLOCK_GRASS_CORNER_PX_PZ: int = 14
const BLOCK_GRASS_CORNER_PX_NZ: int = 15
const BLOCK_GRASS_CORNER_NX_PZ: int = 16
const BLOCK_GRASS_CORNER_NX_NZ: int = 17

const MODEL_COUNT: int = 18

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
	# Fill unused slots with empty so bake never sees null entries.
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

	# Solid cliff neighbor (steeper than 1) → angular cube. Air (>=90) ignored here.
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
		# Adjacent pair → outer corner; opposite pair → flat cube (ridge).
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
	model.mesh = mesh
	model.set_material_override(0, mat)
	if model.has_method("set_mesh_collision_enabled"):
		model.set_mesh_collision_enabled(0, true)
	# Conservative AABB so VoxelBoxMover / tool raycasts treat slopes as solid.
	model.collision_aabbs = [AABB(Vector3.ZERO, Vector3.ONE)]
	model.culls_neighbors = true
	model.transparency_index = 0
	model.side_vertex_tolerance = 0.001
	return model


static func _build_ramp_mesh(dir_x: int, dir_z: int) -> ArrayMesh:
	## Wedge: high on the face opposite the drop; low edge flush with neighbor top.
	var h00: float = 1.0
	var h10: float = 1.0
	var h01: float = 1.0
	var h11: float = 1.0
	if dir_x > 0:
		h00 = 1.0
		h01 = 1.0
		h10 = 0.0
		h11 = 0.0
	elif dir_x < 0:
		h00 = 0.0
		h01 = 0.0
		h10 = 1.0
		h11 = 1.0
	elif dir_z > 0:
		h00 = 1.0
		h10 = 1.0
		h01 = 0.0
		h11 = 0.0
	else:
		h00 = 0.0
		h10 = 0.0
		h01 = 1.0
		h11 = 1.0
	return _mesh_from_heights(h00, h10, h01, h11)


static func _build_corner_mesh(dir_x: int, dir_z: int) -> ArrayMesh:
	## Outer corner: only the far corner stays high; drops toward (dir_x, dir_z).
	var h00: float = 1.0
	var h10: float = 1.0
	var h01: float = 1.0
	var h11: float = 1.0
	# Low three corners toward the drop; high at the opposite corner.
	if dir_x > 0 and dir_z > 0:
		h00 = 1.0
		h10 = 0.0
		h01 = 0.0
		h11 = 0.0
	elif dir_x > 0 and dir_z < 0:
		h01 = 1.0
		h00 = 0.0
		h10 = 0.0
		h11 = 0.0
	elif dir_x < 0 and dir_z > 0:
		h10 = 1.0
		h00 = 0.0
		h01 = 0.0
		h11 = 0.0
	else:
		h11 = 1.0
		h00 = 0.0
		h10 = 0.0
		h01 = 0.0
	return _mesh_from_heights(h00, h10, h01, h11)


static func _mesh_from_heights(h00: float, h10: float, h01: float, h11: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	# Bottom face (underside) — unit-cube side; winding yields geometric -Y.
	_quad(st,
		Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 0, 1), Vector3(0, 0, 1),
		Vector3.DOWN)

	# Top slope (CCW from above so normals point outward / +Y).
	var v00 := Vector3(0, h00, 0)
	var v10 := Vector3(1, h10, 0)
	var v01 := Vector3(0, h01, 1)
	var v11 := Vector3(1, h11, 1)
	var n0 := _tri_n(v00, v01, v11)
	var n1 := _tri_n(v00, v11, v10)
	_tri(st, v00, v01, v11, n0)
	_tri(st, v00, v11, v10, n1)

	# ±X sides — only emit geometry that sits on the unit face for culling.
	_side_x(st, 0.0, h00, h01, Vector3.LEFT)
	_side_x(st, 1.0, h10, h11, Vector3.RIGHT)
	# ±Z sides
	_side_z(st, 0.0, h00, h10, Vector3.FORWARD)
	_side_z(st, 1.0, h01, h11, Vector3.BACK)

	st.index()
	return st.commit()


static func _side_x(st: SurfaceTool, x: float, hy0: float, hy1: float, outward: Vector3) -> void:
	## Vertical face at x from y=0 up to the slope edge (hy0 at z=0, hy1 at z=1).
	## Winding matches unit-cube neighbors so Blocky side culling stays reliable.
	if hy0 <= 1e-4 and hy1 <= 1e-4:
		return
	if outward.x > 0.0:
		_quad(st,
			Vector3(x, 0.0, 0.0), Vector3(x, 0.0, 1.0),
			Vector3(x, hy1, 1.0), Vector3(x, hy0, 0.0),
			outward)
	else:
		_quad(st,
			Vector3(x, 0.0, 1.0), Vector3(x, 0.0, 0.0),
			Vector3(x, hy0, 0.0), Vector3(x, hy1, 1.0),
			outward)


static func _side_z(st: SurfaceTool, z: float, hx0: float, hx1: float, outward: Vector3) -> void:
	if hx0 <= 1e-4 and hx1 <= 1e-4:
		return
	if outward.z > 0.0:
		_quad(st,
			Vector3(0.0, 0.0, z), Vector3(1.0, 0.0, z),
			Vector3(1.0, hx1, z), Vector3(0.0, hx0, z),
			outward)
	else:
		_quad(st,
			Vector3(1.0, 0.0, z), Vector3(0.0, 0.0, z),
			Vector3(0.0, hx0, z), Vector3(1.0, hx1, z),
			outward)


static func _quad(
	st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3
) -> void:
	_tri(st, a, b, c, n)
	_tri(st, a, c, d, n)


static func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, n: Vector3) -> void:
	var area: Vector3 = (b - a).cross(c - a)
	if area.length_squared() < 1e-12:
		return
	st.set_normal(n)
	st.set_uv(Vector2(a.x, a.z))
	st.add_vertex(a)
	st.set_normal(n)
	st.set_uv(Vector2(b.x, b.z))
	st.add_vertex(b)
	st.set_normal(n)
	st.set_uv(Vector2(c.x, c.z))
	st.add_vertex(c)


static func _tri_n(a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	var n: Vector3 = (b - a).cross(c - a)
	if n.length_squared() < 1e-12:
		return Vector3.UP
	return n.normalized()
