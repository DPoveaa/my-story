## IslandGenerator.gd
## Castle Story-style floating island generator for Zylann's godot_voxel plugin.
##
## Extends VoxelGeneratorScript so Zylann's C++ engine calls generate_block()
## on a background thread for each new chunk that enters the VoxelViewer range.
##
## Island shape (Castle Story formula):
##   density = Island_2D_Mask  -  (Y_gradient * height_factor)  +  Detail_3D
##
##   • Island_2D_Mask   — low-frequency 2D noise drives wide cluster layout;
##                        high values define where island COLUMNS exist.
##   • Y_gradient       — asymmetric: gentle negative slope above the flat top
##                        (keeps a thick plateau), steep positive slope below
##                        (carves an inverted-mountain belly).
##   • Detail_3D        — mid-frequency 3D noise adds overhangs and caves.
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

## Y band where islands cluster.
const ISLAND_Y_MIN: float = 32.0
const ISLAND_Y_MAX: float = 80.0

## Solid if combined density > this value.  Range roughly [-1, 2].
## 0.0 produces large, deeply solid islands.  Raise toward 0.4 to thin them.
var density_threshold: float = 0.0

## Legacy field — kept so VoxelWorld injects it without errors, but the
## Castle Story formula no longer uses a raw Y-scale on the 3D sample.
var vertical_scale: float = 3.5

## Strength of the 2D cluster mask contribution.  Higher = wider, more
## plate-like islands; lower = rounder, mushroom-like columns.
const MASK_STRENGTH: float   = 1.20

## How fast density falls off ABOVE the flat top plateau (gentle → thick cap).
const TOP_FALLOFF: float     = 0.055

## How fast density falls off BELOW the island centre (steep → sharp belly).
const BELLY_FALLOFF: float   = 0.110

## Y above ISLAND_Y_MAX where the flat plateau ends and sky begins.
const FLAT_TOP_VOXELS: float = 6.0

## Contribution weight of the 3D detail noise on top of the base formula.
const DETAIL_WEIGHT: float   = 0.35

# ---------------------------------------------------------------------------
# Noise resources (injected by VoxelWorld after construction)
# ---------------------------------------------------------------------------
var noise_island:    FastNoiseLite = null   ## 3D detail noise
var noise_island_2d: FastNoiseLite = null   ## 2D cluster-mask noise
var noise_ore:       FastNoiseLite = null   ## ore vein noise

# ---------------------------------------------------------------------------
# generate_block — called by the voxel engine on worker threads
# ---------------------------------------------------------------------------
func _generate_block(out_buffer: VoxelBuffer, origin_in_voxels: Vector3i, lod: int) -> void:
	if noise_island == null:
		return

	var size: Vector3i = out_buffer.get_size()
	var step: int      = 1 << lod

	var plateau_top: float  = ISLAND_Y_MAX + FLAT_TOP_VOXELS
	var island_mid:  float  = (ISLAND_Y_MIN + ISLAND_Y_MAX) * 0.5

	for z in range(size.z):
		for x in range(size.x):
			for y in range(size.y):
				var gx: int = origin_in_voxels.x + x * step
				var gy: int = origin_in_voxels.y + y * step
				var gz: int = origin_in_voxels.z + z * step

				var block_id: int = _eval_voxel(gx, gy, gz, island_mid, plateau_top)
				out_buffer.set_voxel(block_id, x, y, z, VoxelBuffer.CHANNEL_TYPE)

# ---------------------------------------------------------------------------
# Density evaluation — Castle Story formula
# ---------------------------------------------------------------------------
func _eval_voxel(gx: int, gy: int, gz: int, island_mid: float, plateau_top: float) -> int:
	var fy: float = float(gy)

	# Fast reject — well outside any possible island volume.
	if fy > plateau_top + 4.0 or fy < ISLAND_Y_MIN - 24.0:
		return BLOCK_AIR

	# ── 1. 2-D island cluster mask (XZ only) ────────────────────────────────
	# Low-frequency noise decides WHERE islands exist horizontally.
	# Values are in [-1, 1]; we remap to [0, 1] for a clean mask.
	var mask2d: float = 0.0
	if noise_island_2d != null:
		mask2d = (noise_island_2d.get_noise_2d(float(gx), float(gz)) + 1.0) * 0.5
	else:
		# Fallback: treat the whole world as one big island cluster.
		mask2d = 0.75

	# ── 2. Asymmetric Y-gradient ────────────────────────────────────────────
	# Above plateau_top: steep sky cutoff.
	# Between island_mid and plateau_top: gentle slope → thick flat top.
	# Below island_mid: steeper falloff → inverted-mountain belly.
	var y_gradient: float
	if fy >= plateau_top:
		# Above the flat cap — hard sky.
		y_gradient = (fy - plateau_top) * TOP_FALLOFF * 8.0
	elif fy >= island_mid:
		# Flat-top zone: very slow density loss upward.
		y_gradient = (fy - island_mid) * TOP_FALLOFF
	else:
		# Belly: faster density loss downward (inverted mountain).
		y_gradient = (island_mid - fy) * BELLY_FALLOFF

	# ── 3. 3-D detail noise ─────────────────────────────────────────────────
	var detail3d: float = noise_island.get_noise_3d(float(gx), fy, float(gz)) * DETAIL_WEIGHT

	# ── 4. Combined Castle Story density ────────────────────────────────────
	#   density = Island_2D_Mask * MASK_STRENGTH  -  y_gradient  +  Detail_3D
	var density: float = mask2d * MASK_STRENGTH - y_gradient + detail3d

	if density < density_threshold:
		return BLOCK_AIR

	# ── Surface classification ───────────────────────────────────────────────
	# Grass cap: recompute density one voxel above and check if it becomes air.
	var fy_a: float  = fy + 1.0
	var d3d_a: float = noise_island.get_noise_3d(float(gx), fy_a, float(gz)) * DETAIL_WEIGHT
	var yg_a: float
	if fy_a >= plateau_top:
		yg_a = (fy_a - plateau_top) * TOP_FALLOFF * 8.0
	elif fy_a >= island_mid:
		yg_a = (fy_a - island_mid) * TOP_FALLOFF
	else:
		yg_a = (island_mid - fy_a) * BELLY_FALLOFF
	var den_a: float = mask2d * MASK_STRENGTH - yg_a + d3d_a
	if den_a < density_threshold:
		return BLOCK_GRASS

	# Dirt: check two voxels above.
	var fy_b: float  = fy + 2.0
	var d3d_b: float = noise_island.get_noise_3d(float(gx), fy_b, float(gz)) * DETAIL_WEIGHT
	var yg_b: float
	if fy_b >= plateau_top:
		yg_b = (fy_b - plateau_top) * TOP_FALLOFF * 8.0
	elif fy_b >= island_mid:
		yg_b = (fy_b - island_mid) * TOP_FALLOFF
	else:
		yg_b = (island_mid - fy_b) * BELLY_FALLOFF
	var den_b: float = mask2d * MASK_STRENGTH - yg_b + d3d_b
	if den_b < density_threshold:
		return BLOCK_DIRT

	# Ore veins in the core.
	if noise_ore != null:
		var ore_n: float  = noise_ore.get_noise_3d(float(gx), fy, float(gz))
		var core_y: float = island_mid
		if gy < int(core_y) - 8  and ore_n > 0.45: return BLOCK_GOLD
		if gy < int(core_y) - 4  and ore_n > 0.35: return BLOCK_IRON
		if gy < int(core_y)      and ore_n > 0.25: return BLOCK_COAL

	return BLOCK_STONE
