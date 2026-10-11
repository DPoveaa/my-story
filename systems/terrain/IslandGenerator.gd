## IslandGenerator.gd
## Castle Story-style floating island generator for Zylann's godot_voxel plugin.
##
## Extends VoxelGeneratorScript so Zylann's C++ engine calls generate_block()
## on a background thread for each new chunk that enters the VoxelViewer range.
##
## Island shape:
##   A 3D Perlin density field determines solidity.  A vertical bias smoothly
##   removes material above ISLAND_Y_MAX and below ISLAND_Y_MIN, producing
##   landmasses that float in open sky rather than sitting on a bedrock floor.
##
## Block layering (top → core):
##   Grass  →  Dirt (1-2 voxels)  →  Stone  →  Coal / Iron / Gold ore veins
extends VoxelGeneratorScript

# ---------------------------------------------------------------------------
# Tunable constants (mirror VoxelWorld exports so they stay in sync)
# ---------------------------------------------------------------------------
const BLOCK_AIR:   int = 0
const BLOCK_GRASS: int = 1
const BLOCK_DIRT:  int = 2
const BLOCK_STONE: int = 3
const BLOCK_COAL:  int = 4
const BLOCK_IRON:  int = 5
const BLOCK_GOLD:  int = 6

## Y range where islands cluster.
const ISLAND_Y_MIN: float = 32.0
const ISLAND_Y_MAX: float = 80.0

## Density threshold — voxels with evaluated density > this become solid.
## Smaller = more islands, larger = fewer / thinner islands.
var density_threshold: float = 0.18

## Vertical scale applied to Y before sampling 3D noise.
## Higher = flatter islands (noise varies more slowly in Y → thicker slabs).
var vertical_scale: float = 3.5

# ---------------------------------------------------------------------------
# Noise resources (injected by VoxelWorld after construction)
# ---------------------------------------------------------------------------
var noise_island: FastNoiseLite = null   ## primary 3D density
var noise_ore:    FastNoiseLite = null   ## secondary ore veins

# ---------------------------------------------------------------------------
# generate_block — called by the voxel engine on worker threads
# ---------------------------------------------------------------------------
func _generate_block(out_buffer: VoxelBuffer, origin_in_voxels: Vector3i, lod: int) -> void:
	if noise_island == null:
		return

	var size: Vector3i = out_buffer.get_size()
	var step: int      = 1 << lod          # voxel step per LOD level

	var band_center: float = (ISLAND_Y_MIN + ISLAND_Y_MAX) * 0.5
	var band_half:   float = (ISLAND_Y_MAX - ISLAND_Y_MIN) * 0.5

	for z in range(size.z):
		for x in range(size.x):
			for y in range(size.y):
				var gx: int = origin_in_voxels.x + x * step
				var gy: int = origin_in_voxels.y + y * step
				var gz: int = origin_in_voxels.z + z * step

				var block_id: int = _eval_voxel(gx, gy, gz, band_center, band_half)
				out_buffer.set_voxel(block_id, x, y, z, VoxelBuffer.CHANNEL_TYPE)

# ---------------------------------------------------------------------------
# Density evaluation — deterministic for any world coordinate
# ---------------------------------------------------------------------------
func _eval_voxel(gx: int, gy: int, gz: int, band_center: float, band_half: float) -> int:
	# Quick reject: entirely outside island band (with margin)
	var fy: float = float(gy)
	if fy < ISLAND_Y_MIN - 12.0 or fy > ISLAND_Y_MAX + 12.0:
		return BLOCK_AIR

	# Sample 3D density noise (Y scaled so islands look like flat-ish masses)
	var density: float = noise_island.get_noise_3d(float(gx), fy * vertical_scale, float(gz))

	# Vertical bias: subtract more density the further we are from the island band
	var dist: float = abs(fy - band_center)
	var bias: float = clampf((dist - band_half * 0.3) / (band_half * 0.7), 0.0, 1.0)
	density -= bias * 0.55

	if density < density_threshold:
		return BLOCK_AIR

	# ---- Surface classification ----
	# Grass cap: voxel above is air
	var fy_a: float   = float(gy + 1)
	var den_a: float  = noise_island.get_noise_3d(float(gx), fy_a * vertical_scale, float(gz))
	var dist_a: float = abs(fy_a - band_center)
	var bias_a: float = clampf((dist_a - band_half * 0.3) / (band_half * 0.7), 0.0, 1.0)
	den_a -= bias_a * 0.55
	if den_a < density_threshold:
		return BLOCK_GRASS

	# Dirt: second voxel above is air
	var fy_b: float   = float(gy + 2)
	var den_b: float  = noise_island.get_noise_3d(float(gx), fy_b * vertical_scale, float(gz))
	var dist_b: float = abs(fy_b - band_center)
	var bias_b: float = clampf((dist_b - band_half * 0.3) / (band_half * 0.7), 0.0, 1.0)
	den_b -= bias_b * 0.55
	if den_b < density_threshold:
		return BLOCK_DIRT

	# Ore veins in the core
	if noise_ore != null:
		var ore_n: float  = noise_ore.get_noise_3d(float(gx), float(gy), float(gz))
		var core_y: float = band_center
		if gy < int(core_y) - 8  and ore_n > 0.45: return BLOCK_GOLD
		if gy < int(core_y) - 4  and ore_n > 0.35: return BLOCK_IRON
		if gy < int(core_y)      and ore_n > 0.25: return BLOCK_COAL

	return BLOCK_STONE
