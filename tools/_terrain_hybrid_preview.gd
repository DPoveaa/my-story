extends SceneTree

## Samples IslandGenerator around spawn and reports cube vs ramp/corner TYPE counts.
func _initialize() -> void:
	var Gen = load("res://systems/terrain/IslandGenerator.gd")
	var Lib = load("res://systems/terrain/TerrainBlockyLibrary.gd")
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

	var cubes := 0
	var ramps := 0
	var corners := 0
	var other := 0
	for z in range(-16, 16):
		for x in range(-16, 16):
			var top: int = gen.eval_surface_y(x, z)
			if top < 0:
				continue
			var id: int = int(gen.eval_voxel(x, top, z))
			match id:
				Lib.BLOCK_GRASS, Lib.BLOCK_DIRT, Lib.BLOCK_STONE, Lib.BLOCK_COAL, Lib.BLOCK_IRON, Lib.BLOCK_GOLD:
					cubes += 1
				Lib.BLOCK_GRASS_RAMP_PX, Lib.BLOCK_GRASS_RAMP_NX, Lib.BLOCK_GRASS_RAMP_PZ, Lib.BLOCK_GRASS_RAMP_NZ:
					ramps += 1
				Lib.BLOCK_GRASS_CORNER_PX_PZ, Lib.BLOCK_GRASS_CORNER_PX_NZ, Lib.BLOCK_GRASS_CORNER_NX_PZ, Lib.BLOCK_GRASS_CORNER_NX_NZ:
					corners += 1
				_:
					other += 1

	print("terrain_preview surface cubes=%d ramps=%d corners=%d other=%d" % [cubes, ramps, corners, other])
	quit(0)
