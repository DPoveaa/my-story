## IslandGenerator.gd
## Castle Story-style floating islands for Zylann VoxelTerrain + VoxelMesherTransvoxel.
## Writes CHANNEL_SDF (smooth geometry), CHANNEL_TYPE (mineable IDs), CHANNEL_INDICES (textures).
## No vegetation. Preserves island layout while producing rounded hills / walkable ramps
## and sharper cliffs where steepness is high. Fills tiny 1x1 / 1x2 surface void holes.
extends VoxelGeneratorScript

const BLOCK_AIR:   int = 0
const BLOCK_GRASS: int = 1
const BLOCK_DIRT:  int = 2
const BLOCK_STONE: int = 3
const BLOCK_COAL:  int = 4
const BLOCK_IRON:  int = 5
const BLOCK_GOLD:  int = 6

const ISLAND_Y_MIN: float = 32.0
const ISLAND_Y_MAX: float = 80.0
const MASK_CUTOFF: float = 0.30
const SPAWN_ISLAND_RADIUS: float = 42.0
const CAVE_THRESHOLD: float = 0.86
const DIRT_DEPTH: int = 3
const SDF_CLAMP: float = 3.5

var density_threshold: float = 0.30
var vertical_scale: float = 3.5

var noise_island: FastNoiseLite = null
var noise_island_2d: FastNoiseLite = null
var noise_ore: FastNoiseLite = null

func _get_used_channels_mask() -> int:
	return (
		(1 << VoxelBuffer.CHANNEL_TYPE)
		| (1 << VoxelBuffer.CHANNEL_SDF)
		| (1 << VoxelBuffer.CHANNEL_INDICES)
	)

func _generate_block(out_buffer: VoxelBuffer, origin_in_voxels: Vector3i, lod: int) -> void:
	if noise_island == null or noise_island_2d == null:
		_fill_air(out_buffer)
		return

	var size: Vector3i = out_buffer.get_size()
	var step: int = 1 << lod

	var y0: int = origin_in_voxels.y
	var y1: int = origin_in_voxels.y + (size.y - 1) * step
	if y1 < int(ISLAND_Y_MIN) - 48 or y0 > int(ISLAND_Y_MAX) + 28:
		_fill_air(out_buffer)
		return

	# Pass 1: sample every column profile once (avoids repeated noise in Y loop).
	var profiles: Array = []
	profiles.resize(size.x * size.z)
	for z in range(size.z):
		var gz: int = origin_in_voxels.z + z * step
		for x in range(size.x):
			var gx: int = origin_in_voxels.x + x * step
			profiles[z * size.x + x] = _sample_column(gx, gz)

	# Pass 2: close tiny accidental surface holes (1Ã—1 / 1Ã—2) without flattening terrain.
	_fill_tiny_surface_holes(profiles, size.x, size.z, origin_in_voxels, step)

	# Pass 3: write SDF + TYPE + INDICES.
	for z in range(size.z):
		var gz: int = origin_in_voxels.z + z * step
		for x in range(size.x):
			var gx: int = origin_in_voxels.x + x * step
			var profile: Vector4 = profiles[z * size.x + x]
			if profile.w < 0.5:
				for y in range(size.y):
					_write_air_voxel(out_buffer, x, y, z)
				continue
			var top_y: float = profile.x
			var bot_y: float = profile.y
			var center_y: float = profile.z
			var steep: float = profile.w - 1.0
			for y in range(size.y):
				var gy: int = origin_in_voxels.y + y * step
				var sdf: float = _eval_sdf(gx, gy, gz, top_y, bot_y, center_y, steep)
				var block_id: int = BLOCK_AIR
				if sdf < 0.0:
					block_id = _eval_in_column(gx, gy, gz, top_y, bot_y, center_y, steep)
					if block_id == BLOCK_AIR:
						# SDF solid but column classifier empty (soft shell) — stone core.
						block_id = BLOCK_STONE
				out_buffer.set_voxel_f(sdf, x, y, z, VoxelBuffer.CHANNEL_SDF)
				out_buffer.set_voxel(block_id, x, y, z, VoxelBuffer.CHANNEL_TYPE)
				# TEXTURES_SINGLE_S4: 8-bit texture index in INDICES (0 = air/unused).
				out_buffer.set_voxel(block_id, x, y, z, VoxelBuffer.CHANNEL_INDICES)

func eval_voxel(gx: int, gy: int, gz: int) -> int:
	if noise_island == null or noise_island_2d == null:
		return BLOCK_AIR
	var profile: Vector4 = _sample_column(gx, gz)
	if profile.w < 0.5:
		return BLOCK_AIR
	return _eval_in_column(gx, gy, gz, profile.x, profile.y, profile.z, profile.w - 1.0)

func eval_sdf(gx: int, gy: int, gz: int) -> float:
	if noise_island == null or noise_island_2d == null:
		return SDF_CLAMP
	var profile: Vector4 = _sample_column(gx, gz)
	if profile.w < 0.5:
		return SDF_CLAMP
	return _eval_sdf(gx, gy, gz, profile.x, profile.y, profile.z, profile.w - 1.0)

func eval_surface_y(gx: int, gz: int) -> int:
	if noise_island == null or noise_island_2d == null:
		return -1
	var profile: Vector4 = _sample_column(gx, gz)
	if profile.w < 0.5:
		return -1
	return int(floor(profile.x))

func _fill_air(out_buffer: VoxelBuffer) -> void:
	out_buffer.fill(BLOCK_AIR, VoxelBuffer.CHANNEL_TYPE)
	out_buffer.fill_f(SDF_CLAMP, VoxelBuffer.CHANNEL_SDF)
	out_buffer.fill(BLOCK_AIR, VoxelBuffer.CHANNEL_INDICES)

func _write_air_voxel(out_buffer: VoxelBuffer, x: int, y: int, z: int) -> void:
	out_buffer.set_voxel_f(SDF_CLAMP, x, y, z, VoxelBuffer.CHANNEL_SDF)
	out_buffer.set_voxel(BLOCK_AIR, x, y, z, VoxelBuffer.CHANNEL_TYPE)
	out_buffer.set_voxel(BLOCK_AIR, x, y, z, VoxelBuffer.CHANNEL_INDICES)

func _land_mask(fx: float, fz: float) -> float:
	var bias: float = density_threshold - MASK_CUTOFF
	var n_main: float = noise_island_2d.get_noise_2d(fx, fz)
	var n_med: float = noise_island_2d.get_noise_2d(fx * 2.4 + 410.0, fz * 2.4 - 155.0)
	var n_arch: float = noise_island_2d.get_noise_2d(fx * 3.6 + 77.0, fz * 3.6 - 211.0)
	var n_ridge: float = noise_island_2d.get_noise_2d(fx * 1.6 + 95.0, fz * 1.6 - 40.0)

	var cutoff: float = density_threshold if density_threshold > 0.0 else MASK_CUTOFF
	var mask: float = n_main
	if n_med > (0.18 + bias * 0.5):
		mask = maxf(mask, lerpf(cutoff, 0.85, (n_med - 0.18) / 0.82))
	if n_arch > (0.22 + bias * 0.4):
		mask = maxf(mask, lerpf(cutoff, 0.70, (n_arch - 0.22) / 0.78))

	var ridge: float = 1.0 - absf(n_ridge)
	if ridge > 0.80 and n_main > -0.15:
		mask = maxf(mask, cutoff + (ridge - 0.80) * 0.55)

	var origin_d: float = sqrt(fx * fx + fz * fz)
	if origin_d < SPAWN_ISLAND_RADIUS:
		var boost: float = (1.0 - origin_d / SPAWN_ISLAND_RADIUS) * 0.55
		mask = maxf(mask, cutoff + 0.12 + boost * 0.45)

	return mask

func _sample_column(gx: int, gz: int) -> Vector4:
	var fx := float(gx)
	var fz := float(gz)

	var mask_n: float = _land_mask(fx, fz)
	var cutoff: float = density_threshold if density_threshold > 0.0 else MASK_CUTOFF
	if mask_n < cutoff:
		return Vector4(0.0, 0.0, 0.0, 0.0)

	var footprint: float = clampf((mask_n - cutoff) / maxf(0.001, 1.0 - cutoff), 0.0, 1.0)

	var height_n: float = noise_island_2d.get_noise_2d(fx + 1703.0, fz - 911.0)
	var size_n: float = noise_island_2d.get_noise_2d(fx - 503.0, fz + 1201.0)
	var center_y: float = lerpf(ISLAND_Y_MIN + 6.0, ISLAND_Y_MAX - 6.0, (height_n + 1.0) * 0.5)
	var size_k: float = lerpf(0.70, 1.35, (size_n + 1.0) * 0.5)

	var style: float = noise_island_2d.get_noise_2d(fx * 0.35 + 19.0, fz * 0.35 - 7.0)
	var macro: float = noise_island_2d.get_noise_2d(fx * 0.55 + 12.0, fz * 0.55 - 33.0)
	var meso: float = noise_island_2d.get_noise_2d(fx * 1.35 - 70.0, fz * 1.35 + 55.0)
	var micro: float = noise_island.get_noise_3d(fx * 0.55, 0.0, fz * 0.55) * 0.35
	var ridge: float = 1.0 - absf(noise_island_2d.get_noise_2d(fx * 0.85 + 200.0, fz * 0.85))
	var valley: float = noise_island_2d.get_noise_2d(fx * 0.65 - 300.0, fz * 0.65 + 180.0)

	var relief: float
	var terraced: bool = false
	if style < -0.35:
		relief = macro * 1.6 + meso * 0.8 + micro
	elif style < 0.15:
		relief = macro * 4.5 + meso * 2.8 + micro
	elif style < 0.45:
		var terrace: float = floor((macro + 1.0) * 2.0) * 1.6
		relief = 3.5 + terrace + meso * 1.0 + micro * 0.4
		terraced = true
	else:
		relief = macro * 5.0 + pow(maxf(0.0, ridge), 1.6) * 12.0 + meso * 3.5 + micro
		if valley > 0.15:
			relief -= valley * 8.0

	var rim: float = smoothstep(0.0, 0.30, footprint)
	relief *= size_k * (0.55 + rim * 0.45)

	var roll: float = noise_island.get_noise_3d(fx * 0.45, center_y, fz * 0.45) * 1.6
	var plateau: float = (5.0 + footprint * 2.5) * size_k
	var top_y: float = center_y + plateau + relief + roll
	if terraced:
		# Keep terraces as stepped plateaus (sharp lips) while hills stay smooth.
		top_y = floor(top_y * 0.5) * 2.0 + 0.15

	var belly_noise: float = noise_island.get_noise_3d(fx * 1.25, center_y - 12.0, fz * 1.25) * 3.5
	var belly: float = (5.0 + footprint * footprint * 22.0) * size_k
	var bot_y: float = center_y - belly + belly_noise

	if top_y - bot_y < 2.5:
		return Vector4(0.0, 0.0, 0.0, 0.0)

	var dx: float = _land_mask(fx + 2.0, fz) - _land_mask(fx - 2.0, fz)
	var dz: float = _land_mask(fx, fz + 2.0) - _land_mask(fx, fz - 2.0)
	var steep: float = clampf((absf(dx) + absf(dz)) * 2.2, 0.0, 2.0)

	return Vector4(top_y, bot_y, center_y, 1.0 + steep)

func _fill_tiny_surface_holes(
	profiles: Array, width: int, depth: int,
	origin_in_voxels: Vector3i, step: int
) -> void:
	## Promote isolated air columns that sit inside an otherwise continuous island surface.
	## Only fills 1x1 or 1x2 gaps; leaves real craters, caves, cliffs and inter-island voids.
	var changed := true
	var passes := 0
	while changed and passes < 2:
		changed = false
		passes += 1
		for z in range(depth):
			for x in range(width):
				var idx: int = z * width + x
				var p: Vector4 = profiles[idx]
				if p.w >= 0.5:
					continue
				var solid_n := 0
				var avg_top := 0.0
				var avg_bot := 0.0
				var avg_cen := 0.0
				var avg_steep := 0.0
				for d in [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)]:
					var nx: int = x + d.x
					var nz: int = z + d.y
					var np: Vector4
					if nx < 0 or nz < 0 or nx >= width or nz >= depth:
						# Sample outside the block so edge holes still heal when surrounded in world.
						np = _sample_column(
							origin_in_voxels.x + nx * step,
							origin_in_voxels.z + nz * step
						)
					else:
						np = profiles[nz * width + nx]
					if np.w >= 0.5:
						solid_n += 1
						avg_top += np.x
						avg_bot += np.y
						avg_cen += np.z
						avg_steep += np.w - 1.0

				# 1x1 hole: all 4 neighbors solid. 1x2 hole: 3 neighbors solid.
				if solid_n < 3:
					continue

				avg_top /= float(solid_n)
				avg_bot /= float(solid_n)
				avg_cen /= float(solid_n)
				avg_steep /= float(solid_n)
				# Reject fills that would bridge distant islands / large height breaks.
				if avg_top - avg_bot < 2.5:
					continue
				var height_spread := 0.0
				for d2 in [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)]:
					var nx2: int = x + d2.x
					var nz2: int = z + d2.y
					var np2: Vector4
					if nx2 < 0 or nz2 < 0 or nx2 >= width or nz2 >= depth:
						np2 = _sample_column(
							origin_in_voxels.x + nx2 * step,
							origin_in_voxels.z + nz2 * step
						)
					else:
						np2 = profiles[nz2 * width + nx2]
					if np2.w >= 0.5:
						height_spread = maxf(height_spread, absf(np2.x - avg_top))
				if height_spread > 6.0:
					continue
				profiles[idx] = Vector4(avg_top, avg_bot, avg_cen, 1.0 + avg_steep)
				changed = true

func _eval_sdf(
	gx: int, gy: int, gz: int,
	top_y: float, bot_y: float, center_y: float, steep: float
) -> float:
	var fy: float = float(gy)
	# Vertical shell SDF (negative inside the island band).
	var sd: float = maxf(fy - top_y, bot_y - fy)

	# Horizontal edge falloff from land mask — soft ramps on gentle shores, cliffs when steep.
	var fx := float(gx)
	var fz := float(gz)
	var cutoff: float = density_threshold if density_threshold > 0.0 else MASK_CUTOFF
	var mask_n: float = _land_mask(fx, fz)
	var footprint: float = clampf((mask_n - cutoff) / maxf(0.001, 1.0 - cutoff), 0.0, 1.0)
	var edge_sd: float = (0.22 - footprint) * lerpf(2.4, 6.0, clampf(steep * 0.5, 0.0, 1.0))
	sd = maxf(sd, edge_sd)

	# Cave carving as union with air SDF (positive inside cave).
	var from_top: float = top_y - fy
	var from_bot: float = fy - bot_y
	if from_top > 4.0 and from_bot > 5.0:
		var cave_n: float = noise_island.get_noise_3d(fx * 0.85, fy * 0.85, fz * 0.85)
		# Air = positive SDF. When cave_n > CAVE_THRESHOLD, force positive SDF.
		if cave_n > CAVE_THRESHOLD:
			var cave_air: float = (cave_n - CAVE_THRESHOLD) * 8.0
			sd = maxf(sd, cave_air)

	# Steep faces: sharpen the gradient so cliffs stay terraced/craggy.
	# Gentle faces: keep soft gradients for walkable natural ramps.
	var sharpen: float = lerpf(1.0, 2.4, clampf((steep - 0.85) / 0.9, 0.0, 1.0))
	if (top_y - center_y) > 22.0:
		sharpen = maxf(sharpen, 2.0)
	sd *= sharpen

	return clampf(sd, -SDF_CLAMP, SDF_CLAMP)

func _eval_in_column(
	gx: int, gy: int, gz: int,
	top_y: float, bot_y: float, center_y: float, steep: float
) -> int:
	var fy: float = float(gy)
	if fy > top_y or fy < bot_y:
		return BLOCK_AIR
	if _is_cave(gx, gy, gz, fy, top_y, bot_y):
		return BLOCK_AIR

	var depth: float = top_y - fy

	if depth < 1.0:
		if steep > 1.15 or (top_y - center_y) > 22.0:
			return BLOCK_STONE
		return BLOCK_GRASS
	if depth < float(DIRT_DEPTH) + 0.5:
		if steep > 1.15:
			return BLOCK_STONE
		return BLOCK_DIRT

	if noise_ore != null and depth > 4.0:
		var wx: float = float(gx) * 0.55 + noise_ore.get_noise_3d(float(gx) * 0.07, fy * 0.04, float(gz) * 0.07) * 4.0
		var wz: float = float(gz) * 0.55 + noise_ore.get_noise_3d(float(gx) * 0.07 + 40.0, fy * 0.05, float(gz) * 0.07) * 4.0
		var vein: float = noise_ore.get_noise_3d(wx, fy * 1.8, wz)
		var core: float = noise_ore.get_noise_3d(wx * 2.1 + 90.0, fy * 0.6, wz * 2.1)
		if depth >= 5.0 and depth <= 16.0 and vein > 0.72 and core > 0.22:
			return BLOCK_COAL
		if depth >= 11.0 and depth <= 28.0 and vein > 0.82 and core > 0.38:
			return BLOCK_IRON
		if depth >= 20.0 and vein > 0.88 and core > 0.52:
			return BLOCK_GOLD

	return BLOCK_STONE

func _is_cave(gx: int, gy: int, gz: int, fy: float, top_y: float, bot_y: float) -> bool:
	var from_top: float = top_y - fy
	var from_bot: float = fy - bot_y
	if from_top <= 4.0 or from_bot <= 5.0:
		return false
	return noise_island.get_noise_3d(float(gx) * 0.85, fy * 0.85, float(gz) * 0.85) > CAVE_THRESHOLD
