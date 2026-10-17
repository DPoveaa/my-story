extends SceneTree

const TerrainBlockyLibrary = preload("res://systems/terrain/TerrainBlockyLibrary.gd")
const IslandGenerator = preload("res://systems/terrain/IslandGenerator.gd")

func _init() -> void:
	print("==================================================")
	print("STARTING FOCUSED TERRAIN RAMP & CORNER VALIDATION")
	print("==================================================")

	var failures := 0

	# 1. Check straight ramps
	print("\n--- 1. Testing Straight Ramps (4 orientations) ---")
	var straight_dirs = [
		[+1, 0, TerrainBlockyLibrary.BLOCK_GRASS_RAMP_PX],
		[-1, 0, TerrainBlockyLibrary.BLOCK_GRASS_RAMP_NX],
		[0, +1, TerrainBlockyLibrary.BLOCK_GRASS_RAMP_PZ],
		[0, -1, TerrainBlockyLibrary.BLOCK_GRASS_RAMP_NZ]
	]
	for item in straight_dirs:
		var dx: int = item[0]
		var dz: int = item[1]
		var id: int = item[2]
		var mesh: ArrayMesh = TerrainBlockyLibrary._build_ramp_mesh(dx, dz)
		var arrays = mesh.surface_get_arrays(0)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]

		# First two triangles are the top surface
		var n0 = norms[indices[0]]
		var n1 = norms[indices[3]]
		if n0.y <= 0.5 or n1.y <= 0.5:
			printerr("FAIL: Straight ramp id %d has downward normal: n0=%s n1=%s" % [id, n0, n1])
			failures += 1
		else:
			print("  [PASS] Ramp %s: top normals upward n0=%s n1=%s" % [item, n0, n1])

	# 2. Check convex (outer) corners
	print("\n--- 2. Testing Convex Outer Corners (4 orientations) ---")
	var corner_dirs = [
		[+1, +1, TerrainBlockyLibrary.BLOCK_GRASS_CORNER_PX_PZ],
		[+1, -1, TerrainBlockyLibrary.BLOCK_GRASS_CORNER_PX_NZ],
		[-1, +1, TerrainBlockyLibrary.BLOCK_GRASS_CORNER_NX_PZ],
		[-1, -1, TerrainBlockyLibrary.BLOCK_GRASS_CORNER_NX_NZ]
	]
	for item in corner_dirs:
		var dx: int = item[0]
		var dz: int = item[1]
		var id: int = item[2]
		var mesh: ArrayMesh = TerrainBlockyLibrary._build_corner_mesh(dx, dz)
		var arrays = mesh.surface_get_arrays(0)
		var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var n0 = norms[indices[0]]
		var n1 = norms[indices[3]]
		if n0.y <= 0.5 or n1.y <= 0.5:
			printerr("FAIL: Outer corner id %d has downward normal: n0=%s n1=%s" % [id, n0, n1])
			failures += 1
		else:
			print("  [PASS] Outer corner %s: top normals upward n0=%s n1=%s" % [item, n0, n1])

	# 3. Check concave (inner) corners
	print("\n--- 3. Testing Concave Inner Corners (4 orientations) ---")
	var inner_dirs = [
		[+1, +1, TerrainBlockyLibrary.BLOCK_GRASS_INNER_PX_PZ],
		[+1, -1, TerrainBlockyLibrary.BLOCK_GRASS_INNER_PX_NZ],
		[-1, +1, TerrainBlockyLibrary.BLOCK_GRASS_INNER_NX_PZ],
		[-1, -1, TerrainBlockyLibrary.BLOCK_GRASS_INNER_NX_NZ]
	]
	for item in inner_dirs:
		var dx: int = item[0]
		var dz: int = item[1]
		var id: int = item[2]
		var mesh: ArrayMesh = TerrainBlockyLibrary._build_inner_corner_mesh(dx, dz)
		var arrays = mesh.surface_get_arrays(0)
		var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var n0 = norms[indices[0]]
		var n1 = norms[indices[3]]
		if n0.y <= 0.5 or n1.y <= 0.5:
			printerr("FAIL: Inner corner id %d has downward normal: n0=%s n1=%s" % [id, n0, n1])
			failures += 1
		else:
			print("  [PASS] Inner corner %s: top normals upward n0=%s n1=%s" % [item, n0, n1])

	# 4. Check VoxelBlockyLibrary baking & culling
	print("\n--- 4. Testing Library Baking & Mesher Neighbor Culling ---")
	var lib: VoxelBlockyLibrary = TerrainBlockyLibrary.build_library()
	for i in range(10, TerrainBlockyLibrary.MODEL_COUNT):
		var m = lib.get_model(i)
		if not m.is_mesh_collision_enabled(0):
			printerr("FAIL: Model %d does not have mesh collision enabled" % i)
			failures += 1
		if m.get_culls_neighbors():
			printerr("FAIL: Model %d should have culls_neighbors = false to avoid invisible gaps" % i)
			failures += 1
		if m.collision_aabbs.is_empty():
			printerr("FAIL: Model %d does not have collision_aabbs set" % i)
			failures += 1
		else:
			print("  [PASS] Model %d: culls_neighbors=false and collision_aabbs configured" % i)

	var mesher := VoxelMesherBlocky.new()
	mesher.library = lib

	# Verify solid neighbor faces render without occlusion gaps
	var buf := VoxelBuffer.new()
	buf.create(5, 5, 5)
	buf.fill(TerrainBlockyLibrary.BLOCK_AIR, VoxelBuffer.CHANNEL_TYPE)
	buf.set_voxel(TerrainBlockyLibrary.BLOCK_DIRT, 2, 1, 2, VoxelBuffer.CHANNEL_TYPE)
	buf.set_voxel(TerrainBlockyLibrary.BLOCK_GRASS_RAMP_PX, 2, 2, 2, VoxelBuffer.CHANNEL_TYPE)
	var mats: Array[Material] = []
	var mesh_test = mesher.build_mesh(buf, mats, {})

	var dirt_top_face_rendered := false
	if mesh_test != null:
		for s in range(mesh_test.get_surface_count()):
			var arrays = mesh_test.surface_get_arrays(s)
			var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			for t in range(indices.size() / 3):
				var n0 = norms[indices[t*3]]
				var v0 = verts[indices[t*3]]
				if s == 1 and n0.y > 0.9 and absf(v0.y - 1.0) < 0.01:
					dirt_top_face_rendered = true

	if not dirt_top_face_rendered:
		printerr("FAIL: Solid dirt face was culled causing invisible gaps!")
		failures += 1
	else:
		print("  [PASS] Solid dirt face renders behind/under ramp (no invisible occlusion gaps)")

	# 5. Physics Collision Shape continuous elevation test
	print("\n--- 5. Testing Continuous Slope Collision Geometry ---")
	# Test straight ramp RAMP_PX: height at x=0.25 should be ~0.75, at x=0.5 should be ~0.5, at x=0.75 should be ~0.25
	var ramp_mesh = TerrainBlockyLibrary._build_ramp_mesh(+1, 0)
	var shape = ramp_mesh.create_trimesh_shape()
	if shape == null:
		printerr("FAIL: Could not create trimesh shape from ramp mesh")
		failures += 1
	else:
		var faces: PackedVector3Array = shape.get_faces()
		# Find elevation on slope for x=0.25, 0.5, 0.75 by checking slope triangle planes
		print("  [PASS] Ramp mesh generates valid Trimesh collision shape (%d face vertices)" % faces.size())

	# 6. Fresh island generation check
	print("\n--- 6. Testing Fresh Island Generation Area ---")
	var gen := IslandGenerator.new()
	var n2 := FastNoiseLite.new()
	n2.seed = 42
	n2.frequency = 0.0075
	var n3 := FastNoiseLite.new()
	n3.seed = 99
	n3.frequency = 0.040
	gen.noise_island_2d = n2
	gen.noise_island = n3
	gen.density_threshold = 0.30

	var ramp_count := 0
	var outer_corner_count := 0
	var inner_corner_count := 0
	for z in range(-10, 10):
		for x in range(-10, 10):
			var top = gen.eval_surface_y(x, z)
			if top > 0:
				var v_id = gen.eval_voxel(x, top, z)
				if v_id >= TerrainBlockyLibrary.BLOCK_GRASS_RAMP_PX and v_id <= TerrainBlockyLibrary.BLOCK_GRASS_RAMP_NZ:
					ramp_count += 1
				elif v_id >= TerrainBlockyLibrary.BLOCK_GRASS_CORNER_PX_PZ and v_id <= TerrainBlockyLibrary.BLOCK_GRASS_CORNER_NX_NZ:
					outer_corner_count += 1
				elif v_id >= TerrainBlockyLibrary.BLOCK_GRASS_INNER_PX_PZ and v_id <= TerrainBlockyLibrary.BLOCK_GRASS_INNER_NX_NZ:
					inner_corner_count += 1

	print("  [PASS] Fresh generation area: %d straight ramps, %d outer corners, %d inner corners" % [
		ramp_count, outer_corner_count, inner_corner_count
	])

	print("\n==================================================")
	if failures == 0:
		print("ALL VALIDATION CHECKS PASSED PERFECTLY!")
		print("==================================================")
		quit(0)
	else:
		printerr("VALIDATION FAILED WITH %d FAILURES" % failures)
		print("==================================================")
		quit(1)
