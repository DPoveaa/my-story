class_name TerrainBlockyLibrary
extends RefCounted

## Builds a VoxelBlockyLibrary for VoxelMesherBlocky.
## Full cubes keep rocky sides/undersides angular.
## Walkable tops use genuine continuous inclined ramp/corner meshes.
## Orientations are separate TYPE ids chosen at generation.

const BLOCK_AIR: int = 0
const BLOCK_GRASS: int = 1
const BLOCK_DIRT: int = 2
const BLOCK_STONE: int = 3
const BLOCK_COAL: int = 4
const BLOCK_IRON: int = 5
const BLOCK_GOLD: int = 6

## Grass ramps: the LOW edge faces the named axis (the slope descends in that direction).
const BLOCK_GRASS_RAMP_PX: int = 10  # low toward +X, high toward -X
const BLOCK_GRASS_RAMP_NX: int = 11  # low toward -X, high toward +X
const BLOCK_GRASS_RAMP_PZ: int = 12  # low toward +Z, high toward -Z
const BLOCK_GRASS_RAMP_NZ: int = 13  # low toward -Z, high toward +Z
## Outer corners: low corner toward (dir_x, dir_z), high corner opposite.
const BLOCK_GRASS_CORNER_PX_PZ: int = 14
const BLOCK_GRASS_CORNER_PX_NZ: int = 15
const BLOCK_GRASS_CORNER_NX_PZ: int = 16
const BLOCK_GRASS_CORNER_NX_NZ: int = 17
## Inner corners: low corner toward (dir_x, dir_z), three high corners opposite/adjacent.
const BLOCK_GRASS_INNER_PX_PZ: int = 18
const BLOCK_GRASS_INNER_PX_NZ: int = 19
const BLOCK_GRASS_INNER_NX_PZ: int = 20
const BLOCK_GRASS_INNER_NX_NZ: int = 21

const MODEL_COUNT: int = 22

const _HYBRID_SHADER = preload("res://systems/terrain/terrain_hybrid.gdshader")

static func material_id_of(type_id: int) -> int:
	match type_id:
		BLOCK_GRASS, BLOCK_GRASS_RAMP_PX, BLOCK_GRASS_RAMP_NX, BLOCK_GRASS_RAMP_PZ, BLOCK_GRASS_RAMP_NZ, \
		BLOCK_GRASS_CORNER_PX_PZ, BLOCK_GRASS_CORNER_PX_NZ, BLOCK_GRASS_CORNER_NX_PZ, BLOCK_GRASS_CORNER_NX_NZ, \
		BLOCK_GRASS_INNER_PX_PZ, BLOCK_GRASS_INNER_PX_NZ, BLOCK_GRASS_INNER_NX_PZ, BLOCK_GRASS_INNER_NX_NZ:
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
	mats[&"dirt"]  = _mat(Color(0.62, 0.40, 0.23), 0.94, 0.0, 0.10, 0.95)
	mats[&"stone"] = _mat(Color(0.50, 0.46, 0.41), 0.90, 0.0, 0.14, 1.0)
	mats[&"coal"]  = _mat(Color(0.20, 0.20, 0.22), 0.92, 0.0, 0.12, 1.0)
	mats[&"iron"]  = _mat(Color(0.68, 0.66, 0.62), 0.55, 0.45, 0.35, 1.0)
	mats[&"gold"]  = _mat(Color(0.86, 0.70, 0.16), 0.40, 0.70, 0.45, 1.0)
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

	models[BLOCK_AIR]   = VoxelBlockyModelEmpty.new()
	models[BLOCK_GRASS] = _make_cube(mats[&"grass"])
	models[BLOCK_DIRT]  = _make_cube(mats[&"dirt"])
	models[BLOCK_STONE] = _make_cube(mats[&"stone"])
	models[BLOCK_COAL]  = _make_cube(mats[&"coal"])
	models[BLOCK_IRON]  = _make_cube(mats[&"iron"])
	models[BLOCK_GOLD]  = _make_cube(mats[&"gold"])

	var grass_mat: Material = mats[&"grass"]
	models[BLOCK_GRASS_RAMP_PX]      = _make_mesh_model(_build_ramp_mesh(+1,  0), grass_mat)
	models[BLOCK_GRASS_RAMP_NX]      = _make_mesh_model(_build_ramp_mesh(-1,  0), grass_mat)
	models[BLOCK_GRASS_RAMP_PZ]      = _make_mesh_model(_build_ramp_mesh( 0, +1), grass_mat)
	models[BLOCK_GRASS_RAMP_NZ]      = _make_mesh_model(_build_ramp_mesh( 0, -1), grass_mat)
	models[BLOCK_GRASS_CORNER_PX_PZ] = _make_mesh_model(_build_corner_mesh(+1, +1), grass_mat)
	models[BLOCK_GRASS_CORNER_PX_NZ] = _make_mesh_model(_build_corner_mesh(+1, -1), grass_mat)
	models[BLOCK_GRASS_CORNER_NX_PZ] = _make_mesh_model(_build_corner_mesh(-1, +1), grass_mat)
	models[BLOCK_GRASS_CORNER_NX_NZ] = _make_mesh_model(_build_corner_mesh(-1, -1), grass_mat)
	models[BLOCK_GRASS_INNER_PX_PZ]  = _make_mesh_model(_build_inner_corner_mesh(+1, +1), grass_mat)
	models[BLOCK_GRASS_INNER_PX_NZ]  = _make_mesh_model(_build_inner_corner_mesh(+1, -1), grass_mat)
	models[BLOCK_GRASS_INNER_NX_PZ]  = _make_mesh_model(_build_inner_corner_mesh(-1, +1), grass_mat)
	models[BLOCK_GRASS_INNER_NX_NZ]  = _make_mesh_model(_build_inner_corner_mesh(-1, -1), grass_mat)

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


## Pick a surface model from cardinal (and optional diagonal) height drops of exactly 1.
## Drops > 1 (solid cliff neighbors) stay cubes. Air neighbors (encoded as >= 90)
## do not block ramps toward other solid 1-step neighbors.
## Straight slopes: exactly one cardinal drop of 1.
## Convex corners: exactly two adjacent cardinal drops of 1.
## Concave corners: zero cardinal drops, exactly one diagonal drop of 1.
static func surface_model_for_drops(
	base_id: int,
	drop_px: int, drop_nx: int, drop_pz: int, drop_nz: int,
	drop_px_pz: int = 0, drop_px_nz: int = 0, drop_nx_pz: int = 0, drop_nx_nz: int = 0
) -> int:
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
		# Check for concave (inner) corners where cardinal terrain matches height
		# and a single diagonal corner drops by 1 to connect the slopes.
		var c_px_pz: bool = drop_px_pz == 1
		var c_px_nz: bool = drop_px_nz == 1
		var c_nx_pz: bool = drop_nx_pz == 1
		var c_nx_nz: bool = drop_nx_nz == 1
		var diag_count: int = int(c_px_pz) + int(c_px_nz) + int(c_nx_pz) + int(c_nx_nz)
		if diag_count == 1:
			if c_px_pz:
				return BLOCK_GRASS_INNER_PX_PZ
			if c_px_nz:
				return BLOCK_GRASS_INNER_PX_NZ
			if c_nx_pz:
				return BLOCK_GRASS_INNER_NX_PZ
			if c_nx_nz:
				return BLOCK_GRASS_INNER_NX_NZ
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
		# Convex (outer) corners: low corner towards the two dropping axes
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
	# Assign mesh first so surface_count is valid before other overrides.
	if model.has_method("set_mesh"):
		model.set_mesh(mesh)
	else:
		model.mesh = mesh
	model.set_material_override(0, mat)
	# Enable mesh-based physics collision (CharacterBody3D path through VoxelTerrain).
	if model.has_method("set_mesh_collision_enabled"):
		model.set_mesh_collision_enabled(0, true)
	# Do NOT set collision_aabbs: that is the VoxelBoxMover path and would give a
	# full-cube collider mismatching the inclined geometry.
	# culls_neighbors = true allows VoxelMesherBlocky to cull the top face of the dirt
	# cube directly beneath the ramp/corner's flat underside.
	model.culls_neighbors = true
	model.transparency_index = 0
	return model


## Build a continuous inclined ramp mesh.
## dir_x / dir_z: which axis carries the LOW edge (the drop direction).
## e.g. dir_x=+1 means the ramp block sits above a 1-step drop toward +X:
##   high edge at x=0 (y=1, touching the upper plateau),
##   low edge at x=1 (y=0, touching the lower terrace).
##
## The top is a single inclined quad; sides are right-triangle wedges;
## underside is a flat quad at y=0.
static func _build_ramp_mesh(dir_x: int, dir_z: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	# Four top-surface corner heights.  A=(0,0), B=(1,0), C=(1,1), D=(0,1) in XZ.
	var y_a: float  # corner (x=0, z=0)
	var y_b: float  # corner (x=1, z=0)
	var y_c: float  # corner (x=1, z=1)
	var y_d: float  # corner (x=0, z=1)

	if dir_x > 0:
		# Drop toward +X: high at x=0, low at x=1.
		y_a = 1.0; y_b = 0.0; y_c = 0.0; y_d = 1.0
	elif dir_x < 0:
		# Drop toward -X: high at x=1, low at x=0.
		y_a = 0.0; y_b = 1.0; y_c = 1.0; y_d = 0.0
	elif dir_z > 0:
		# Drop toward +Z: high at z=0, low at z=1.
		y_a = 1.0; y_b = 1.0; y_c = 0.0; y_d = 0.0
	else:
		# Drop toward -Z: high at z=1, low at z=0.
		y_a = 0.0; y_b = 0.0; y_c = 1.0; y_d = 1.0

	var va := Vector3(0.0, y_a, 0.0)
	var vb := Vector3(1.0, y_b, 0.0)
	var vc := Vector3(1.0, y_c, 1.0)
	var vd := Vector3(0.0, y_d, 1.0)

	# Slope normal pointing UP and away from the drop direction (winding hint for _tri).
	var slope_n: Vector3 = Vector3(float(dir_x), 1.0, float(dir_z)).normalized()


	# Inclined top surface.
	_tri(st, va, vb, vc, slope_n)
	_tri(st, va, vc, vd, slope_n)

	# Flat underside.
	_quad(st,
		Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 0, 1), Vector3(0, 0, 1),
		Vector3.DOWN)

	# Side wedges (triangulated walls connecting top corners to y=0 base).
	_side_wedge(st, va, vb, Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3.FORWARD) # z=0 side
	_side_wedge(st, vd, vc, Vector3(0, 0, 1), Vector3(1, 0, 1), Vector3.BACK)    # z=1 side
	_side_wedge(st, va, vd, Vector3(0, 0, 0), Vector3(0, 0, 1), Vector3.LEFT)    # x=0 side
	_side_wedge(st, vb, vc, Vector3(1, 0, 0), Vector3(1, 0, 1), Vector3.RIGHT)   # x=1 side

	st.index()
	return st.commit()


## Emit one triangulated side wall between two top corners and their base equivalents.
## top_a / top_b: upper-edge positions (may differ in Y).
## bot_a / bot_b: corresponding positions at y=0.
## n: outward normal hint for winding correction.
static func _side_wedge(
	st: SurfaceTool,
	top_a: Vector3, top_b: Vector3,
	bot_a: Vector3, bot_b: Vector3,
	n: Vector3
) -> void:
	# Both tops at y=0: zero-height face, skip.
	if top_a.y < 0.001 and top_b.y < 0.001:
		return
	# Both at full height: rectangular quad.
	if top_a.y > 0.999 and top_b.y > 0.999:
		_quad(st, top_a, top_b, bot_b, bot_a, n)
		return
	# One corner at y=0 (coincides with its base): single triangle.
	if top_a.y > 0.001 and top_b.y < 0.001:
		_tri(st, top_a, bot_b, bot_a, n)
	elif top_b.y > 0.001 and top_a.y < 0.001:
		_tri(st, top_b, bot_a, bot_b, n)
	else:
		# Trapezoid (both > 0, different heights).
		_tri(st, top_a, top_b, bot_b, n)
		_tri(st, top_a, bot_b, bot_a, n)


## Build a continuous inclined convex (outer) corner mesh.
## dir_x / dir_z: axes toward the LOW corner (both neighboring drops equal 1).
##
## The high corner is at y = 1.0. The other three corners are at y = 0.0,
## seamlessly continuing the adjoining straight ramps with zero height mismatch
## or exposed vertical walls.
static func _build_corner_mesh(dir_x: int, dir_z: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	# Integer XZ coordinates of low (lx,lz) and high (hx,hz) corners.
	var lx: int = 1 if dir_x > 0 else 0
	var lz: int = 1 if dir_z > 0 else 0
	var hx: int = 1 - lx
	var hz: int = 1 - lz

	# Heights array indexed [x + z*2]: covers (0,0)=0, (1,0)=1, (0,1)=2, (1,1)=3.
	var heights: Array[float] = [0.0, 0.0, 0.0, 0.0]
	heights[lx + lz * 2] = 0.0   # low corner
	heights[hx + hz * 2] = 1.0   # high corner
	heights[lx + hz * 2] = 0.0   # side corner 1 (matches adjacent ramp low edge)
	heights[hx + lz * 2] = 0.0   # side corner 2 (matches adjacent ramp low edge)

	# Corner vectors: A=(0,0), B=(1,0), C=(1,1), D=(0,1).
	var va := Vector3(0.0, heights[0], 0.0)
	var vb := Vector3(1.0, heights[1], 0.0)
	var vc := Vector3(1.0, heights[3], 1.0)
	var vd := Vector3(0.0, heights[2], 1.0)

	var high_pos  := Vector3(float(hx), 1.0, float(hz))
	var side1_pos := Vector3(float(lx), 0.0, float(hz))
	var side2_pos := Vector3(float(hx), 0.0, float(lz))
	var low_pos   := Vector3(float(lx), 0.0, float(lz))

	var slope_n := Vector3(float(dir_x), 1.0, float(dir_z)).normalized()
	_tri(st, high_pos, side1_pos, side2_pos, slope_n)
	_tri(st, side1_pos, low_pos, side2_pos, Vector3.UP)

	# Flat underside.
	_quad(st,
		Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 0, 1), Vector3(0, 0, 1),
		Vector3.DOWN)

	# Side wedges using the same corner heights as the top surface.
	_side_wedge(st, va, vb, Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3.FORWARD)
	_side_wedge(st, vd, vc, Vector3(0, 0, 1), Vector3(1, 0, 1), Vector3.BACK)
	_side_wedge(st, va, vd, Vector3(0, 0, 0), Vector3(0, 0, 1), Vector3.LEFT)
	_side_wedge(st, vb, vc, Vector3(1, 0, 0), Vector3(1, 0, 1), Vector3.RIGHT)

	st.index()
	return st.commit()


## Build a continuous inclined concave (inner) corner mesh.
## dir_x / dir_z: axes toward the single LOW corner.
##
## Three corners are high (y = 1.0) flush with the upper plateau/slopes,
## and one corner is low (y = 0.0) descending to match the valley drop.
static func _build_inner_corner_mesh(dir_x: int, dir_z: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var lx: int = 1 if dir_x > 0 else 0
	var lz: int = 1 if dir_z > 0 else 0
	var hx: int = 1 - lx
	var hz: int = 1 - lz

	var heights: Array[float] = [1.0, 1.0, 1.0, 1.0]
	heights[lx + lz * 2] = 0.0   # single low corner
	heights[hx + hz * 2] = 1.0   # high corner
	heights[lx + hz * 2] = 1.0   # side corner 1 is high
	heights[hx + lz * 2] = 1.0   # side corner 2 is high

	var va := Vector3(0.0, heights[0], 0.0)
	var vb := Vector3(1.0, heights[1], 0.0)
	var vc := Vector3(1.0, heights[3], 1.0)
	var vd := Vector3(0.0, heights[2], 1.0)

	var high_pos  := Vector3(float(hx), 1.0, float(hz))
	var low_pos   := Vector3(float(lx), 0.0, float(lz))
	var side1_pos := Vector3(float(lx), 1.0, float(hz))
	var side2_pos := Vector3(float(hx), 1.0, float(lz))

	# Split along high-to-low diagonal into two inclined triangles
	var up := Vector3.UP
	_tri(st, high_pos, side1_pos, low_pos, up)
	_tri(st, high_pos, low_pos, side2_pos, up)

	# Flat underside.
	_quad(st,
		Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 0, 1), Vector3(0, 0, 1),
		Vector3.DOWN)

	# Side wedges using the same corner heights as the top surface.
	_side_wedge(st, va, vb, Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3.FORWARD)
	_side_wedge(st, vd, vc, Vector3(0, 0, 1), Vector3(1, 0, 1), Vector3.BACK)
	_side_wedge(st, va, vd, Vector3(0, 0, 0), Vector3(0, 0, 1), Vector3.LEFT)
	_side_wedge(st, vb, vc, Vector3(1, 0, 0), Vector3(1, 0, 1), Vector3.RIGHT)

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
