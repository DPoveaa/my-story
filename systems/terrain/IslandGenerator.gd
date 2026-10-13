## IslandGenerator.gd
## Castle Story hybrid floating islands — discrete TYPE voxels are authoritative.
## Geometry smoothing happens at mesh time (HybridSurfaceMesher), not via full-volume SDF.
## CHANNEL_SDF is a simple solid/air field for VoxelTool raycasts only.
## Continuous style blend; local height-slope chooses ramps vs cliffs. No vegetation.
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
const DIRT_CLIFF_EXTRA: float = 5.0
const SDF_CLAMP: float = 3.5
const MIN_COLUMN_THICKNESS: float = 3.5
const SLOPE_SAMPLE_STEP: int = 2
## Local geometric slope above this → angular cliff materials / steeper silhouette.
const CLIFF_SLOPE: float = 1.05

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

	var profiles: Array = []
	profiles.resize(size.x * size.z)
	for z in range(size.z):
		var gz: int = origin_in_voxels.z + z * step
		for x in range(size.x):
			var gx: int = origin_in_voxels.x + x * step
			profiles[z * size.x + x] = _sample_column(gx, gz)

	_fill_tiny_surface_holes(profiles, size.x, size.z, origin_in_voxels, step)
	_refine_slope_from_neighbors(profiles, size.x, size.z, step)
	_cull_isolated_spikes(profiles, size.x, size.z)

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
				var block_id: int = _eval_in_column(gx, gy, gz, top_y, bot_y, center_y, steep)
				var sdf: float = _eval_sdf_discrete(gy, top_y, bot_y, block_id)
				out_buffer.set_voxel_f(sdf, x, y, z, VoxelBuffer.CHANNEL_SDF)
				out_buffer.set_voxel(block_id, x, y, z, VoxelBuffer.CHANNEL_TYPE)
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
	var block_id: int = _eval_in_column(gx, gy, gz, profile.x, profile.y, profile.z, profile.w - 1.0)
	return _eval_sdf_discrete(gy, profile.x, profile.y, block_id)

func eval_surface_y(gx: int, gz: int) -> int:
	if noise_island == null or noise_island_2d == null:
		return -1
	var profile: Vector4 = _sample_column(gx, gz)
	if profile.w < 0.5:
		return -1
	return int(floor(profile.x))

func eval_surface_height_f(gx: int, gz: int) -> float:
	if noise_island == null or noise_island_2d == null:
		return -1.0
	var profile: Vector4 = _sample_column(gx, gz)
	if profile.w < 0.5:
		return -1.0
	return profile.x

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
	if ridge > 0.88 and n_main > 0.02 and n_med > -0.05:
		mask = maxf(mask, cutoff + (ridge - 0.88) * 0.40)

	var origin_d: float = sqrt(fx * fx + fz * fz)
	if origin_d < SPAWN_ISLAND_RADIUS:
		var boost: float = (1.0 - origin_d / SPAWN_ISLAND_RADIUS) * 0.55
		mask = maxf(mask, cutoff + 0.12 + boost * 0.45)

	return mask

## Heights only (w=1 solid / 0 air). No steep — used for neighbor slope without recursion.
func _column_heights(gx: int, gz: int) -> Vector4:
	var fx := float(gx)
	var fz := float(gz)

	var mask_n: float = _land_mask(fx, fz)
	var cutoff: float = density_threshold if density_threshold > 0.0 else MASK_CUTOFF
	if mask_n < cutoff:
		return Vector4(0.0, 0.0, 0.0, 0.0)

	var footprint: float = clampf((mask_n - cutoff) / maxf(0.001, 1.0 - cutoff), 0.0, 1.0)
	if footprint < 0.06:
		return Vector4(0.0, 0.0, 0.0, 0.0)

	var height_n: float = noise_island_2d.get_noise_2d(fx + 1703.0, fz - 911.0)
	var size_n: float = noise_island_2d.get_noise_2d(fx - 503.0, fz + 1201.0)
	var center_y: float = lerpf(ISLAND_Y_MIN + 6.0, ISLAND_Y_MAX - 6.0, (height_n + 1.0) * 0.5)
	var size_k: float = lerpf(0.70, 1.35, (size_n + 1.0) * 0.5)

	# Continuous style blend (plateau ↔ hills ↔ ridges) — no hard if/elif switches.
	var style: float = noise_island_2d.get_noise_2d(fx * 0.35 + 19.0, fz * 0.35 - 7.0)
	var style_t: float = clampf((style + 1.0) * 0.5, 0.0, 1.0)
	var macro: float = noise_island_2d.get_noise_2d(fx * 0.55 + 12.0, fz * 0.55 - 33.0)
	var meso: float = noise_island_2d.get_noise_2d(fx * 0.95 - 70.0, fz * 0.95 + 55.0)
	var micro: float = 0.0
	if noise_island != null:
		micro = noise_island.get_noise_3d(fx * 0.22, 0.0, fz * 0.22) * 0.10
	var ridge: float = 1.0 - absf(noise_island_2d.get_noise_2d(fx * 0.55 + 200.0, fz * 0.55))
	var valley: float = noise_island_2d.get_noise_2d(fx * 0.45 - 300.0, fz * 0.45 + 180.0)

	# Plateau (low style_t): broad gentle tops.
	var plateau_relief: float = macro * 1.2 + meso * 0.30 + micro
	# Rolling hills (mid): walkable ramps.
	var hill_relief: float = macro * 3.0 + meso * 1.0 + micro
	# Ridged highlands (high): mountains with valleys — no terrace quantization.
	var ridge_relief: float = macro * 3.4 + pow(maxf(0.0, ridge), 2.0) * 5.5 + meso * 1.2 + micro
	if valley > 0.25:
		ridge_relief -= (valley - 0.25) * 3.0

	var w_plateau: float = 1.0 - smoothstep(0.20, 0.45, style_t)
	var w_ridge: float = smoothstep(0.55, 0.85, style_t)
	var w_hill: float = maxf(0.0, 1.0 - w_plateau - w_ridge)
	var w_sum: float = maxf(1e-4, w_plateau + w_hill + w_ridge)
	w_plateau /= w_sum
	w_hill /= w_sum
	w_ridge /= w_sum

	var relief: float = (
		plateau_relief * w_plateau
		+ hill_relief * w_hill
		+ ridge_relief * w_ridge
	)

	var rim: float = smoothstep(0.0, 0.30, footprint)
	relief *= size_k * (0.55 + rim * 0.45) * clampf(vertical_scale / 3.5, 0.75, 1.35)

	var roll: float = 0.0
	if noise_island != null:
		roll = noise_island.get_noise_3d(fx * 0.18, center_y * 0.04, fz * 0.18) * 0.70
	var plateau: float = (5.0 + footprint * 2.5) * size_k
	var top_y: float = center_y + plateau + relief + roll

	# Soft tapered belly — low-frequency only (no underside needle / tube noise).
	var belly_noise: float = 0.0
	if noise_island != null:
		belly_noise = noise_island.get_noise_3d(fx * 0.14, center_y - 12.0, fz * 0.14) * 0.40
	var belly: float = (6.0 + footprint * footprint * 18.0) * size_k
	var bot_y: float = center_y - belly + belly_noise

	# Edge taper: pull underside up near weak footprint so silhouettes read solid, not hollow.
	if footprint < 0.42:
		var edge_lift: float = (0.42 - footprint) / 0.42
		bot_y = lerpf(bot_y, top_y - MIN_COLUMN_THICKNESS - 1.0, edge_lift * 0.55)
		# Keep a coherent rocky mass — avoid thin shells at the rim.
		bot_y = minf(bot_y, top_y - MIN_COLUMN_THICKNESS)

	var thickness: float = top_y - bot_y
	if thickness < MIN_COLUMN_THICKNESS:
		return Vector4(0.0, 0.0, 0.0, 0.0)
	if thickness < 5.0 and footprint < 0.22:
		return Vector4(0.0, 0.0, 0.0, 0.0)

	return Vector4(top_y, bot_y, center_y, 1.0)

func _slope_from_heights(gx: int, gz: int, top_y: float, bot_y: float) -> float:
	## Local geometric slope from neighboring column tops — not only the footprint mask.
	var s: int = SLOPE_SAMPLE_STEP
	var n_e: Vector4 = _column_heights(gx + s, gz)
	var n_w: Vector4 = _column_heights(gx - s, gz)
	var n_n: Vector4 = _column_heights(gx, gz - s)
	var n_s: Vector4 = _column_heights(gx, gz + s)

	var top_dx := 0.0
	var top_dz := 0.0
	var samples := 0.0
	if n_e.w >= 0.5 and n_w.w >= 0.5:
		top_dx = (n_e.x - n_w.x) / float(s * 2)
		samples += 1.0
	elif n_e.w >= 0.5:
		top_dx = (n_e.x - top_y) / float(s)
		samples += 0.5
	elif n_w.w >= 0.5:
		top_dx = (top_y - n_w.x) / float(s)
		samples += 0.5
	if n_n.w >= 0.5 and n_s.w >= 0.5:
		top_dz = (n_s.x - n_n.x) / float(s * 2)
		samples += 1.0
	elif n_s.w >= 0.5:
		top_dz = (n_s.x - top_y) / float(s)
		samples += 0.5
	elif n_n.w >= 0.5:
		top_dz = (top_y - n_n.x) / float(s)
		samples += 0.5

	var geom: float = 0.0
	if samples > 0.0:
		geom = sqrt(top_dx * top_dx + top_dz * top_dz)
		var air_edges := 0
		for np in [n_e, n_w, n_n, n_s]:
			if np.w < 0.5:
				air_edges += 1
		if air_edges >= 1:
			geom = maxf(geom, 0.60 + float(air_edges) * 0.28)
		# Large neighbor height break → cliff even without air.
		for np2 in [n_e, n_w, n_n, n_s]:
			if np2.w >= 0.5 and absf(np2.x - top_y) > 1.0:
				geom = maxf(geom, absf(np2.x - top_y) * 0.55)

	var fx := float(gx)
	var fz := float(gz)
	var dx_m: float = _land_mask(fx + float(s), fz) - _land_mask(fx - float(s), fz)
	var dz_m: float = _land_mask(fx, fz + float(s)) - _land_mask(fx, fz - float(s))
	var mask_grad: float = (absf(dx_m) + absf(dz_m)) * 0.85

	return clampf(geom * 0.90 + mask_grad * 0.40, 0.0, 2.5)

func _sample_column(gx: int, gz: int) -> Vector4:
	var heights: Vector4 = _column_heights(gx, gz)
	if heights.w < 0.5:
		return Vector4(0.0, 0.0, 0.0, 0.0)
	var steep: float = _slope_from_heights(gx, gz, heights.x, heights.y)
	return Vector4(heights.x, heights.y, heights.z, 1.0 + steep)

func _refine_slope_from_neighbors(profiles: Array, width: int, depth: int, step: int) -> void:
	var refined: Array = profiles.duplicate()
	for z in range(depth):
		for x in range(width):
			var idx: int = z * width + x
			var p: Vector4 = profiles[idx]
			if p.w < 0.5:
				continue
			var top_dx := 0.0
			var top_dz := 0.0
			var have_x := false
			var have_z := false
			var air_edges := 0
			var max_break := 0.0
			if x > 0 and x < width - 1:
				var pe: Vector4 = profiles[z * width + (x + 1)]
				var pw: Vector4 = profiles[z * width + (x - 1)]
				if pe.w < 0.5:
					air_edges += 1
				else:
					max_break = maxf(max_break, absf(pe.x - p.x))
				if pw.w < 0.5:
					air_edges += 1
				else:
					max_break = maxf(max_break, absf(pw.x - p.x))
				if pe.w >= 0.5 and pw.w >= 0.5:
					top_dx = (pe.x - pw.x) / float(step * 2)
					have_x = true
			if z > 0 and z < depth - 1:
				var ps: Vector4 = profiles[(z + 1) * width + x]
				var pn: Vector4 = profiles[(z - 1) * width + x]
				if ps.w < 0.5:
					air_edges += 1
				else:
					max_break = maxf(max_break, absf(ps.x - p.x))
				if pn.w < 0.5:
					air_edges += 1
				else:
					max_break = maxf(max_break, absf(pn.x - p.x))
				if ps.w >= 0.5 and pn.w >= 0.5:
					top_dz = (ps.x - pn.x) / float(step * 2)
					have_z = true
			if not have_x and not have_z and air_edges == 0 and max_break <= 1.0:
				continue
			var geom: float = sqrt(top_dx * top_dx + top_dz * top_dz)
			if air_edges >= 1:
				geom = maxf(geom, 0.60 + float(air_edges) * 0.25)
			if max_break > 1.0:
				geom = maxf(geom, max_break * 0.55)
			var steep: float = clampf(lerpf(p.w - 1.0, geom * 0.95, 0.70), 0.0, 2.5)
			refined[idx] = Vector4(p.x, p.y, p.z, 1.0 + steep)
	for i in range(profiles.size()):
		profiles[i] = refined[i]

func _cull_isolated_spikes(profiles: Array, width: int, depth: int) -> void:
	## Drop 1-voxel twin-towers / single-column needles that read as spikes under hybrid meshing.
	for z in range(depth):
		for x in range(width):
			var idx: int = z * width + x
			var p: Vector4 = profiles[idx]
			if p.w < 0.5:
				continue
			var solid_n := 0
			var max_n_top := -1.0e9
			for d in [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)]:
				var nx: int = x + d.x
				var nz: int = z + d.y
				if nx < 0 or nz < 0 or nx >= width or nz >= depth:
					continue
				var np: Vector4 = profiles[nz * width + nx]
				if np.w >= 0.5:
					solid_n += 1
					max_n_top = maxf(max_n_top, np.x)
			if solid_n == 0:
				profiles[idx] = Vector4(0.0, 0.0, 0.0, 0.0)
			elif solid_n <= 1 and p.x > max_n_top + 1.6:
				# Lone column jutting above its only neighbor — flatten/cull spike.
				profiles[idx] = Vector4(0.0, 0.0, 0.0, 0.0)

func _fill_tiny_surface_holes(
	profiles: Array, width: int, depth: int,
	origin_in_voxels: Vector3i, step: int
) -> void:
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
				if solid_n < 3:
					continue
				avg_top /= float(solid_n)
				avg_bot /= float(solid_n)
				avg_cen /= float(solid_n)
				avg_steep /= float(solid_n)
				if avg_top - avg_bot < MIN_COLUMN_THICKNESS:
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

func _eval_sdf_discrete(gy: int, top_y: float, bot_y: float, block_id: int) -> float:
	## Simple solid/air SDF for VoxelTool raycasts — not used for Transvoxel meshing.
	if block_id == BLOCK_AIR:
		var fy: float = float(gy) + 0.5
		var outside: float = maxf(fy - top_y, bot_y - fy)
		return clampf(maxf(outside, 0.5), 0.5, SDF_CLAMP)
	var fy2: float = float(gy) + 0.5
	var from_top: float = top_y - fy2
	var from_bot: float = fy2 - bot_y
	var inside: float = -minf(from_top, from_bot)
	return clampf(minf(inside, -0.5), -SDF_CLAMP, -0.5)

func _eval_in_column(
	gx: int, gy: int, gz: int,
	top_y: float, bot_y: float, center_y: float, steep: float
) -> int:
	var fy: float = float(gy)
	# Discrete occupancy: solid for gy in [floor(bot), floor(top)].
	if fy > floor(top_y) or fy < floor(bot_y):
		return BLOCK_AIR
	if _is_cave(gx, gy, gz, fy, top_y, bot_y):
		return BLOCK_AIR

	var depth: float = top_y - fy
	var from_bot: float = fy - bot_y
	var thickness: float = maxf(1.0, top_y - bot_y)
	var fx := float(gx)
	var fz := float(gz)
	var cutoff: float = density_threshold if density_threshold > 0.0 else MASK_CUTOFF
	var mask_n: float = _land_mask(fx, fz)
	var footprint: float = clampf((mask_n - cutoff) / maxf(0.001, 1.0 - cutoff), 0.0, 1.0)
	var near_edge: bool = footprint < 0.40
	var cliffish: bool = steep >= CLIFF_SLOPE or (steep > 0.70 and near_edge)

	# Grass on gentle walkable tops only.
	if depth < 1.0 and steep < CLIFF_SLOPE and not cliffish:
		return BLOCK_GRASS

	# Dirt mantle under grass and across cliff faces.
	var dirt_band: float = float(DIRT_DEPTH) + 1.0
	if cliffish or near_edge:
		dirt_band += DIRT_CLIFF_EXTRA
	if depth < dirt_band and from_bot > 1.5:
		return BLOCK_DIRT
	if near_edge and depth < minf(thickness * 0.65, dirt_band + 4.0) and from_bot > 2.0:
		return BLOCK_DIRT

	# Stone on deep undersides and the steepest rocky faces past the dirt shell.
	var underside: bool = from_bot < 3.0 or depth > thickness * 0.75
	if cliffish and steep > 1.35 and depth > dirt_band + 0.5:
		return BLOCK_STONE
	if underside and depth > dirt_band:
		return BLOCK_STONE

	if noise_ore != null and depth > 4.0:
		var ore_id: int = _eval_ore(gx, gy, gz, depth)
		if ore_id != BLOCK_AIR:
			return ore_id

	return BLOCK_STONE

func _eval_ore(gx: int, gy: int, gz: int, depth: float) -> int:
	if noise_ore == null:
		return BLOCK_AIR
	var fy: float = float(gy)
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
	return BLOCK_AIR

func _is_cave(gx: int, gy: int, gz: int, fy: float, top_y: float, bot_y: float) -> bool:
	var from_top: float = top_y - fy
	var from_bot: float = fy - bot_y
	if from_top <= 4.0 or from_bot <= 5.0:
		return false
	return noise_island.get_noise_3d(float(gx) * 0.85, fy * 0.85, float(gz) * 0.85) > CAVE_THRESHOLD
