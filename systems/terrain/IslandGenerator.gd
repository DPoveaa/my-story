## IslandGenerator.gd
## Castle Story-style floating island generator for Zylann's godot_voxel plugin.
##
## Extends VoxelGeneratorScript so Zylann's C++ engine calls generate_block()
## on a background thread for each new chunk that enters the VoxelViewer range.
##
## Island shape:
##   1. Signed 2D mask with a hard cutoff → true AIR outside island footprints
##      (never remap noise to [0,1] alone; that creates a world-wide layer).
##   2. Per-column altitude / size from decorrelated 2D samples → varied heights.
##   3. Broad grassy plateau with gentle roll; steep mask edges → blocky cliffs.
##   4. Footprint-scaled tapered belly; rare core caves only.
##
## Block layering (top → core):
##   Grass  →  Dirt (1-2 voxels)  →  Stone  →  Coal / Iron / Gold ore veins
extends VoxelGeneratorScript

# ---------------------------------------------------------------------------
# Block IDs
# ---------------------------------------------------------------------------
const BLOCK_AIR:   int = 0
const BLOCK_GRASS: int = 1
const BLOCK_DIRT:  int = 2
const BLOCK_STONE: int = 3
const BLOCK_COAL:  int = 4
const BLOCK_IRON:  int = 5
const BLOCK_GOLD:  int = 6

## Y band where island centres may sit.
const ISLAND_Y_MIN: float = 32.0
const ISLAND_Y_MAX: float = 80.0

## Signed 2D noise must exceed this to belong to an island.
## Higher = sparser, more separated landmasses.
const MASK_CUTOFF: float = 0.30

## Guaranteed soft starter island radius around world origin (spawn).
const SPAWN_ISLAND_RADIUS: float = 42.0

## Rare cave threshold on detail noise in the stone core (higher = fewer caves).
const CAVE_THRESHOLD: float = 0.78

## Legacy fields kept so VoxelWorld can inject without errors.
var density_threshold: float = 0.30
var vertical_scale: float = 3.5

# ---------------------------------------------------------------------------
# Noise resources (injected by VoxelWorld after construction)
# ---------------------------------------------------------------------------
var noise_island:    FastNoiseLite = null   ## 3D detail / caves / surface roll
var noise_island_2d: FastNoiseLite = null   ## 2D island footprint mask
var noise_ore:       FastNoiseLite = null   ## ore vein noise

# ---------------------------------------------------------------------------
func _get_used_channels_mask() -> int:
	return 1 << VoxelBuffer.CHANNEL_TYPE

# ---------------------------------------------------------------------------
# generate_block — called by the voxel engine on worker threads
# ---------------------------------------------------------------------------
func _generate_block(out_buffer: VoxelBuffer, origin_in_voxels: Vector3i, lod: int) -> void:
	if noise_island == null or noise_island_2d == null:
		return

	var size: Vector3i = out_buffer.get_size()
	var step: int = 1 << lod

	# Skip entire blocks well outside any possible island volume (no per-voxel work).
	var y0: int = origin_in_voxels.y
	var y1: int = origin_in_voxels.y + (size.y - 1) * step
	if y1 < int(ISLAND_Y_MIN) - 48 or y0 > int(ISLAND_Y_MAX) + 28:
		out_buffer.fill(BLOCK_AIR, VoxelBuffer.CHANNEL_TYPE)
		return

	for z in range(size.z):
		var gz: int = origin_in_voxels.z + z * step
		for x in range(size.x):
			var gx: int = origin_in_voxels.x + x * step
			# Column profile packed as Vector3(top, bot, center); w unused.
			# active flag returned via Vector4.w (1 = solid column).
			var profile: Vector4 = _sample_column(gx, gz)
			if profile.w < 0.5:
				for y in range(size.y):
					out_buffer.set_voxel(BLOCK_AIR, x, y, z, VoxelBuffer.CHANNEL_TYPE)
				continue

			var top_y: float = profile.x
			var bot_y: float = profile.y
			var center_y: float = profile.z
			for y in range(size.y):
				var gy: int = origin_in_voxels.y + y * step
				out_buffer.set_voxel(
					_eval_in_column(gx, gy, gz, top_y, bot_y, center_y),
					x, y, z, VoxelBuffer.CHANNEL_TYPE
				)

## Public entry used by VoxelWorld procedural fallback — must match runtime blocks.
func eval_voxel(gx: int, gy: int, gz: int) -> int:
	if noise_island == null or noise_island_2d == null:
		return BLOCK_AIR
	var profile: Vector4 = _sample_column(gx, gz)
	if profile.w < 0.5:
		return BLOCK_AIR
	return _eval_in_column(gx, gy, gz, profile.x, profile.y, profile.z)

# ---------------------------------------------------------------------------
# Per-column island profile (footprint, top, belly)
# Returns Vector4(top_y, bot_y, center_y, active_flag).
# All state is local — safe under VoxelGeneratorScript worker-thread parallelism.
# ---------------------------------------------------------------------------
func _sample_column(gx: int, gz: int) -> Vector4:
	var fx := float(gx)
	var fz := float(gz)

	var mask_n: float = noise_island_2d.get_noise_2d(fx, fz)

	# Soft starter island near origin so spawn always finds solid ground.
	var origin_d: float = sqrt(fx * fx + fz * fz)
	if origin_d < SPAWN_ISLAND_RADIUS:
		var boost: float = (1.0 - origin_d / SPAWN_ISLAND_RADIUS) * 0.55
		mask_n = maxf(mask_n, MASK_CUTOFF + 0.12 + boost * 0.45)

	var cutoff: float = density_threshold if density_threshold > 0.0 else MASK_CUTOFF
	if mask_n < cutoff:
		return Vector4(0.0, 0.0, 0.0, 0.0)

	# 0 at the cliff edge → 1 at the island core (never remapped across the whole world).
	var footprint: float = (mask_n - cutoff) / maxf(0.001, 1.0 - cutoff)
	footprint = clampf(footprint, 0.0, 1.0)

	# Decorrelated samples for altitude and size (same seed family, offset domain).
	var height_n: float = noise_island_2d.get_noise_2d(fx + 1703.0, fz - 911.0)
	var size_n: float = noise_island_2d.get_noise_2d(fx - 503.0, fz + 1201.0)
	var center_y: float = lerpf(ISLAND_Y_MIN + 6.0, ISLAND_Y_MAX - 6.0, (height_n + 1.0) * 0.5)
	var size_k: float = lerpf(0.70, 1.35, (size_n + 1.0) * 0.5)

	# Gentle rolling plateau (soft natural top — not a global smooth pass).
	var roll: float = noise_island.get_noise_3d(fx, center_y, fz) * 2.4

	# Broad walkable top: height stays high across most of the footprint so mask
	# contours read as steep stepped cliffs rather than gentle slopes.
	var plateau: float = (5.5 + footprint * 2.0) * size_k
	var top_y: float = center_y + plateau + roll

	# Tapered rugged underside — deep in the core, pinches shut at the rim.
	var belly_noise: float = noise_island.get_noise_3d(fx * 1.25, center_y - 12.0, fz * 1.25) * 3.5
	var belly: float = (5.0 + footprint * footprint * 22.0) * size_k
	var bot_y: float = center_y - belly + belly_noise

	# Degenerate edge slivers become air.
	if top_y - bot_y < 2.5:
		return Vector4(0.0, 0.0, 0.0, 0.0)

	return Vector4(top_y, bot_y, center_y, 1.0)

func _eval_in_column(gx: int, gy: int, gz: int, top_y: float, bot_y: float, center_y: float) -> int:
	var fy: float = float(gy)

	if fy > top_y or fy < bot_y:
		return BLOCK_AIR

	# Occasional limited caves in the stone core only — never the dominant shape.
	if _is_cave(gx, gy, gz, fy, top_y, bot_y):
		return BLOCK_AIR

	# Surface layers relative to column top (and caves above).
	if not _is_solid_at(gx, gy + 1, gz, fy + 1.0, top_y, bot_y):
		return BLOCK_GRASS
	if not _is_solid_at(gx, gy + 2, gz, fy + 2.0, top_y, bot_y):
		return BLOCK_DIRT

	# Deterministic ore deposits deeper in the core.
	if noise_ore != null:
		var ore_n: float = noise_ore.get_noise_3d(float(gx), fy, float(gz))
		var core_y: int = int(center_y)
		if gy < core_y - 8 and ore_n > 0.45:
			return BLOCK_GOLD
		if gy < core_y - 4 and ore_n > 0.35:
			return BLOCK_IRON
		if gy < core_y and ore_n > 0.25:
			return BLOCK_COAL

	return BLOCK_STONE

func _is_cave(gx: int, gy: int, gz: int, fy: float, top_y: float, bot_y: float) -> bool:
	var from_top: float = top_y - fy
	var from_bot: float = fy - bot_y
	if from_top <= 3.5 or from_bot <= 4.5:
		return false
	return noise_island.get_noise_3d(float(gx) * 0.85, fy * 0.85, float(gz) * 0.85) > CAVE_THRESHOLD

func _is_solid_at(gx: int, gy: int, gz: int, fy: float, top_y: float, bot_y: float) -> bool:
	if fy > top_y or fy < bot_y:
		return false
	return not _is_cave(gx, gy, gz, fy, top_y, bot_y)
