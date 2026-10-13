extends SceneTree

## Minimal smoke check: island sampling + hybrid mesher + VoxelWorld API.
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

	# Hybrid mesher: 1:1 ramp + cliff + underside on a tiny padded buffer.
	var Mesher = load("res://systems/terrain/HybridSurfaceMesher.gd")
	if Mesher == null:
		push_error("HybridSurfaceMesher failed to load")
		ok = false
	else:
		var size := Vector3i(4, 6, 4)
		var py: int = size.y + 2
		var pz: int = size.z + 2
		var types := PackedByteArray()
		types.resize((size.x + 2) * py * pz)
		types.fill(0)
		# Two columns: heights 4 and 3 (1:1 ramp) + one cliff drop to height 1.
		for lz in range(4):
			for ly in range(0, 4):
				_set_pad(types, 0, ly, lz, 1, py, pz) # grass/dirt id=1
			for ly2 in range(0, 3):
				_set_pad(types, 1, ly2, lz, 2, py, pz)
			for ly3 in range(0, 1):
				_set_pad(types, 2, ly3, lz, 3, py, pz)
		var built: Dictionary = Mesher.build(types, size)
		var surfaces: Dictionary = built.get("surfaces", {})
		var faces: PackedVector3Array = built.get("collision_faces", PackedVector3Array())
		var vert_count := 0
		for k in surfaces.keys():
			vert_count += surfaces[k]["verts"].size()
		print("terrain_smoke hybrid_verts=%d collision_tris=%d mats=%d" % [
			vert_count, faces.size() / 3, surfaces.size()
		])
		if vert_count < 36 or faces.size() < 36:
			push_error("Hybrid mesher produced too little geometry")
			ok = false
		# Smooth top heights should vary (not flat cubes) on the ramp column.
		var grass_buf = surfaces.get(&"grass", surfaces.get("grass", {}))
		if grass_buf is Dictionary and grass_buf.has("verts"):
			var ys: Dictionary = {}
			for v in grass_buf["verts"]:
				if absf(v.y - floor(v.y)) > 0.05:
					ys[snappedf(v.y, 0.01)] = true
			print("terrain_smoke hybrid_fractional_heights=%d" % ys.size())
			if ys.is_empty():
				push_error("Hybrid tops lack sub-voxel smoothing")
				ok = false

	var shader_res = load("res://systems/terrain/terrain_hybrid.gdshader")
	if shader_res == null:
		push_error("terrain_hybrid.gdshader failed to load")
		ok = false
	else:
		print("terrain_smoke hybrid_shader_ok")

	var VW = load("res://systems/terrain/VoxelWorld.gd")
	if VW == null:
		push_error("VoxelWorld failed to load")
		ok = false
	else:
		var vw = VW.new()
		if not vw.has_method("wait_for_terrain_at"):
			push_error("wait_for_terrain_at missing")
			ok = false
		if not vw.has_method("_rebuild_hybrid_block"):
			push_error("hybrid rebuild missing")
			ok = false
		if not vw.has_signal("terrain_loading_status"):
			push_error("terrain_loading_status signal missing")
			ok = false
		print("terrain_smoke voxelworld_api_ok")
		vw.free()

	quit(0 if ok else 1)


func _set_pad(types: PackedByteArray, x: int, y: int, z: int, id: int, py: int, pz: int) -> void:
	var idx: int = ((x + 1) * py + (y + 1)) * pz + (z + 1)
	types[idx] = id
