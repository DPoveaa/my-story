extends SceneTree

## Minimal smoke check: island sampling + blocky library + VoxelWorld API.
func _initialize() -> void:
	var ok := true
	var Gen = load("res://systems/terrain/IslandGenerator.gd")
	if Gen == null:
		push_error("IslandGenerator failed to load")
		quit(1)
		return
	var gen = Gen.new()
	var n2 := FastNoiseLite.new()
	n2.seed = 1337
	n2.noise_type = FastNoiseLite.TYPE_PERLIN
	n2.frequency = 0.0075
	n2.fractal_type = FastNoiseLite.FRACTAL_FBM
	n2.fractal_octaves = 3
	var n3 := FastNoiseLite.new()
	n3.seed = 1437
	n3.noise_type = FastNoiseLite.TYPE_PERLIN
	n3.frequency = 0.040
	gen.noise_island_2d = n2
	gen.noise_island = n3
	gen.noise_ore = n3
	gen.density_threshold = 0.30

	var solid := 0
	var thin := 0
	var steep_cliff := 0
	var smooth_top := 0
	var terrace_suspect := 0
	var prev_top := {}
	for z in range(-48, 49, 2):
		for x in range(-48, 49, 2):
			var p: Vector4 = gen._sample_column(x, z)
			if p.w < 0.5:
				continue
			solid += 1
			var thick: float = p.x - p.y
			if thick < 3.5:
				thin += 1
			var steep: float = p.w - 1.0
			if steep > 0.9:
				steep_cliff += 1
			elif steep < 0.45:
				smooth_top += 1
			# Detect repetitive two-unit terraces along a row.
			var key := z
			if prev_top.has(key):
				var d: float = absf(p.x - float(prev_top[key]))
				if d > 1.85 and d < 2.15:
					terrace_suspect += 1
			prev_top[key] = p.x

	print("terrain_smoke solid_cols=%d thin=%d cliffs=%d smooth=%d terrace_suspect=%d" % [
		solid, thin, steep_cliff, smooth_top, terrace_suspect
	])
	if solid < 80:
		push_error("Too few solid columns near origin — island layout likely broken")
		ok = false
	if thin > 0:
		push_error("Thin columns survived min-thickness cull")
		ok = false

	var spawn_y: int = gen.eval_surface_y(0, 0)
	print("terrain_smoke spawn_surface_y=%d" % spawn_y)
	if spawn_y < 0:
		push_error("Spawn column has no surface")
		ok = false

	var Lib = load("res://systems/terrain/TerrainBlockyLibrary.gd")
	if Lib == null:
		push_error("TerrainBlockyLibrary failed to load")
		ok = false
	else:
		var ramp_id: int = Lib.surface_model_for_drops(1, 1, 0, 0, 0)
		var cliff_id: int = Lib.surface_model_for_drops(1, 3, 0, 0, 0)
		var corner_id: int = Lib.surface_model_for_drops(1, 1, 0, 1, 0)
		print("terrain_smoke slope_ids ramp=%d cliff=%d corner=%d" % [ramp_id, cliff_id, corner_id])
		if ramp_id != Lib.BLOCK_GRASS_RAMP_PX:
			push_error("Expected +X grass ramp model")
			ok = false
		if cliff_id != Lib.BLOCK_GRASS:
			push_error("Expected cliff to stay full grass cube")
			ok = false
		if corner_id != Lib.BLOCK_GRASS_CORNER_PX_PZ:
			push_error("Expected +X+Z outer corner model")
			ok = false
		if Lib.type_to_name(Lib.BLOCK_GRASS_RAMP_PX) != &"grass":
			push_error("Ramp models must mine as grass")
			ok = false

	var shader_res = load("res://systems/terrain/terrain_hybrid.gdshader")
	if shader_res == null:
		push_error("terrain_hybrid.gdshader failed to load")
		ok = false
	else:
		print("terrain_smoke blocky_shader_ok")

	var VW = load("res://systems/terrain/VoxelWorld.gd")
	if VW == null:
		push_error("VoxelWorld failed to load")
		ok = false
	else:
		var vw = VW.new()
		if not vw.has_method("wait_for_terrain_at"):
			push_error("wait_for_terrain_at missing")
			ok = false
		if not vw.has_signal("terrain_loading_status"):
			push_error("terrain_loading_status signal missing")
			ok = false
		print("terrain_smoke voxelworld_api_ok")
		vw.free()

	quit(0 if ok else 1)
