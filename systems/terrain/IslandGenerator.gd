## IslandGenerator.gd
## Castle Story-style floating islands for Zylann's VoxelTerrain + VoxelMesherBlocky.
## Writes CHANNEL_TYPE only (mineable block IDs). No vegetation.
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

var density_threshold: float = 0.30
var vertical_scale: float = 3.5

var noise_island: FastNoiseLite = null
var noise_island_2d: FastNoiseLite = null
var noise_ore: FastNoiseLite = null

func _get_used_channels_mask() -> int:
	return 1 << VoxelBuffer.CHANNEL_TYPE

func _generate_block(out_buffer: VoxelBuffer, origin_in_voxels: Vector3i, lod: int) -> void:
	if noise_island == null or noise_island_2d == null:
		out_buffer.fill(BLOCK_AIR, VoxelBuffer.CHANNEL_TYPE)
		return

	var size: Vector3i = out_buffer.get_size()
	var step: int = 1 << lod

	var y0: int = origin_in_voxels.y
	var y1: int = origin_in_voxels.y + (size.y - 1) * step
	if y1 < int(ISLAND_Y_MIN) - 48 or y0 > int(ISLAND_Y_MAX) + 28:
		out_buffer.fill(BLOCK_AIR, VoxelBuffer.CHANNEL_TYPE)
		return

	for z in range(size.z):
		var gz: int = origin_in_voxels.z + z * step
		for x in range(size.x):
			var gx: int = origin_in_voxels.x + x * step
			var profile: Vector4 = _sample_column(gx, gz)
			if profile.w < 0.5:
				for y in range(size.y):
					out_buffer.set_voxel(BLOCK_AIR, x, y, z, VoxelBuffer.CHANNEL_TYPE)
				continue
			var top_y: float = profile.x
			var bot_y: float = profile.y
			var center_y: float = profile.z
			var steep: float = profile.w - 1.0
			for y in range(size.y):
				var gy: int = origin_in_voxels.y + y * step
				out_buffer.set_voxel(
					_eval_in_column(gx, gy, gz, top_y, bot_y, center_y, steep),
					x, y, z, VoxelBuffer.CHANNEL_TYPE
				)

func eval_voxel(gx: int, gy: int, gz: int) -> int:
	if noise_island == null or noise_island_2d == null:
		return BLOCK_AIR
	var profile: Vector4 = _sample_column(gx, gz)
	if profile.w < 0.5:
		return BLOCK_AIR
	return _eval_in_column(gx, gy, gz, profile.x, profile.y, profile.z, profile.w - 1.0)

func eval_surface_y(gx: int, gz: int) -> int:
	if noise_island == null or noise_island_2d == null:
		return -1
	var profile: Vector4 = _sample_column(gx, gz)
	if profile.w < 0.5:
		return -1
	return int(floor(profile.x))

func _land_mask(fx: float, fz: float) -> float:
	var bias: float = density_threshold - MASK_CUTOFF
	var n_main: float = noise_island_2d.get_noise_2d(fx, fz)
	var n_med: float = noise_island_2d.get_noise_2d(fx * 2.4 + 410.0, fz * 2.4 - 155.0)
	var n_arch: float = noise_island_2d.get_noise_2d(fx * 3.6 + 77.0, fz * 3.6 - 211.0)
	var n_ridge: float = noise_island_2d.get_noise_2d(fx * 1.6 + 95.0, fz * 1.6 - 40.0)

	var cutoff: float = density_threshold if density_threshold > 0.0 else MASK_CUTOFF
	var mask: float = n_main
	# Medium islands / archipelagos fill gaps without one giant continent.
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
	if style < -0.35:
		relief = macro * 1.6 + meso * 0.8 + micro
	elif style < 0.15:
		relief = macro * 4.5 + meso * 2.8 + micro
	elif style < 0.45:
		var terrace: float = floor((macro + 1.0) * 2.0) * 1.6
		relief = 3.5 + terrace + meso * 1.0 + micro * 0.4
	else:
		relief = macro * 5.0 + pow(maxf(0.0, ridge), 1.6) * 12.0 + meso * 3.5 + micro
		if valley > 0.15:
			relief -= valley * 8.0

	var rim: float = smoothstep(0.0, 0.30, footprint)
	relief *= size_k * (0.55 + rim * 0.45)

	var roll: float = noise_island.get_noise_3d(fx * 0.45, center_y, fz * 0.45) * 1.6
	var plateau: float = (5.0 + footprint * 2.5) * size_k
	var top_y: float = center_y + plateau + relief + roll

	var belly_noise: float = noise_island.get_noise_3d(fx * 1.25, center_y - 12.0, fz * 1.25) * 3.5
	var belly: float = (5.0 + footprint * footprint * 22.0) * size_k
	var bot_y: float = center_y - belly + belly_noise

	if top_y - bot_y < 2.5:
		return Vector4(0.0, 0.0, 0.0, 0.0)

	# Steepness from footprint gradient — cliffs expose stone; plains stay grassy.
	var dx: float = _land_mask(fx + 2.0, fz) - _land_mask(fx - 2.0, fz)
	var dz: float = _land_mask(fx, fz + 2.0) - _land_mask(fx, fz - 2.0)
	var steep: float = clampf((absf(dx) + absf(dz)) * 2.2, 0.0, 2.0)

	return Vector4(top_y, bot_y, center_y, 1.0 + steep)

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

	# Walkable tops: grass, with dirt underneath. Stone only on steep faces.
	if depth < 1.0:
		if steep > 1.15 or (top_y - center_y) > 22.0:
			return BLOCK_STONE
		return BLOCK_GRASS
	if depth < float(DIRT_DEPTH) + 0.5:
		if steep > 1.15:
			return BLOCK_STONE
		return BLOCK_DIRT

	# Small underground veins — coal most common, iron rarer, gold rarest.
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
