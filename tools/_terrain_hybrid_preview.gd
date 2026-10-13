extends SceneTree

## Builds one hybrid mesh from IslandGenerator around spawn and prints bounds/stats.
func _initialize() -> void:
	var Gen = load("res://systems/terrain/IslandGenerator.gd")
	var Mesher = load("res://systems/terrain/HybridSurfaceMesher.gd")
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

	var size := Vector3i(16, 48, 16)
	var origin := Vector3i(-8, 24, -8)
	var py: int = size.y + 2
	var pz: int = size.z + 2
	var types := PackedByteArray()
	types.resize((size.x + 2) * py * pz)
	types.fill(0)
	var solids := 0
	for lx in range(-1, size.x + 1):
		for ly in range(-1, size.y + 1):
			for lz in range(-1, size.z + 1):
				var id: int = int(gen.eval_voxel(origin.x + lx, origin.y + ly, origin.z + lz))
				if id != 0:
					solids += 1
				var idx: int = ((lx + 1) * py + (ly + 1)) * pz + (lz + 1)
				types[idx] = id

	var built: Dictionary = Mesher.build(types, size)
	var surfaces: Dictionary = built["surfaces"]
	var faces: PackedVector3Array = built["collision_faces"]
	var ymin := 1e9
	var ymax := -1e9
	var verts := 0
	for k in surfaces.keys():
		for v in surfaces[k]["verts"]:
			ymin = minf(ymin, v.y)
			ymax = maxf(ymax, v.y)
			verts += 1
	print("hybrid_preview solids=%d verts=%d tris=%d y=[%.2f,%.2f] mats=%s" % [
		solids, verts, faces.size() / 3, ymin, ymax, str(surfaces.keys())
	])
	quit(0 if verts > 0 and solids > 0 else 1)
