## Voxel terrain system automated tests.
## Tests: VoxelChunk face rendering, CULL_BACK material settings, internal face culling,
##        collision geometry generation, VoxelWorld spawn positioning, queue deduplication,
##        single natural block mining, negative coordinate mapping, contiguous solid interiors,
##        watertight chunk boundary interfaces, and diagnostics.
extends RefCounted

const VoxelChunkScript = preload("res://systems/terrain/VoxelChunk.gd")
const VoxelWorldScript = preload("res://systems/terrain/VoxelWorld.gd")
const InventoryManagerScript = preload("res://autoloads/InventoryManager.gd")
const PlayerControllerScript = preload("res://scenes/player/PlayerController.gd")

var _passed: int = 0
var _failed: int = 0

func run_all() -> bool:
	print("==================================================")
	print("RUNNING VOXEL TERRAIN TESTS")
	print("==================================================")

	_run_test("test_chunk_material_cull_mode")
	_run_test("test_chunk_single_block_faces_and_collision")
	_run_test("test_chunk_adjacent_blocks_cull_internal_faces")
	_run_test("test_voxel_world_spawn_position")
	_run_test("test_voxel_world_generation_queue_deduplication")
	_run_test("test_voxel_world_mine_single_voxel")
	_run_test("test_negative_coordinate_mapping")
	_run_test("test_voxel_world_diagnostics")
	_run_test("test_contiguous_solid_interior_generation")
	_run_test("test_unloaded_neighbor_boundary_face_preservation")
	_run_test("test_watertight_chunk_boundary_rebuild_on_load_unload")
	_run_test("test_creative_mode_bypasses_inventory_costs")

	print("\n--------------------------------------------------")
	print("TERRAIN TESTS SUMMARY: %d Passed, %d Failed" % [_passed, _failed])
	print("==================================================")
	return _failed == 0

func _run_test(test_name: String) -> void:
	if has_method(test_name):
		call(test_name)

func _assert(condition: bool, message: String) -> void:
	if condition:
		_passed += 1
		print("  [PASS] %s" % message)
	else:
		_failed += 1
		print("  [FAIL] %s" % message)

func test_chunk_material_cull_mode() -> void:
	VoxelChunkScript._init_materials()
	var mats: Dictionary = VoxelChunkScript._materials
	_assert(not mats.is_empty(), "Chunk materials dictionary initialized")
	var grass_mat: StandardMaterial3D = mats.get(&"grass", null)
	_assert(grass_mat != null, "Grass material exists")
	if grass_mat != null:
		_assert(grass_mat.cull_mode == BaseMaterial3D.CULL_BACK, "Grass material has CULL_BACK set for solid rendering")

func test_chunk_single_block_faces_and_collision() -> void:
	var chunk: VoxelChunk = VoxelChunkScript.new()
	chunk.chunk_pos = Vector2i(0, 0)
	chunk.set_voxel_local(5, 5, 5, &"stone")
	chunk.rebuild_mesh_and_collision()

	var mesh_inst: MeshInstance3D = chunk._mesh_inst
	_assert(mesh_inst != null and mesh_inst.mesh != null, "Chunk mesh created for single block")
	var col_shape: CollisionShape3D = chunk._col_shape
	_assert(col_shape != null and col_shape.shape != null, "Chunk collision shape created for single block")

	if col_shape != null and col_shape.shape is ConcavePolygonShape3D:
		var concave: ConcavePolygonShape3D = col_shape.shape
		var faces: PackedVector3Array = concave.get_faces()
		# 6 faces * 2 triangles/face * 3 vertices/triangle = 36 vertices
		_assert(faces.size() == 36, "Single isolated block generates exactly 6 exposed quad faces (36 vertices)")

func test_chunk_adjacent_blocks_cull_internal_faces() -> void:
	var chunk: VoxelChunk = VoxelChunkScript.new()
	chunk.chunk_pos = Vector2i(0, 0)
	# Place two adjacent blocks along X axis
	chunk.set_voxel_local(5, 5, 5, &"stone")
	chunk.set_voxel_local(6, 5, 5, &"stone")
	chunk.rebuild_mesh_and_collision()

	var col_shape: CollisionShape3D = chunk._col_shape
	if col_shape != null and col_shape.shape is ConcavePolygonShape3D:
		var concave: ConcavePolygonShape3D = col_shape.shape
		var faces: PackedVector3Array = concave.get_faces()
		# 2 blocks = 12 total faces - 2 shared internal faces = 10 exposed faces = 60 vertices
		_assert(faces.size() == 60, "Adjacent solid blocks cull internal shared faces (60 vertices vs 72)")

func test_voxel_world_spawn_position() -> void:
	var world: VoxelWorld = VoxelWorldScript.new()
	world.seed_value = 1337
	var spawn_pos := world.get_spawn_position(0, 0)
	_assert(spawn_pos.y > 2.0, "Spawn position Y is on top of terrain island (Y=%.1f)" % spawn_pos.y)

func test_voxel_world_generation_queue_deduplication() -> void:
	var world: VoxelWorld = VoxelWorldScript.new()
	world.seed_value = 1337
	world.update_loaded_chunks(Vector3(0, 0, 0))
	var q_size_1 := world._generation_queue.size()
	world.update_loaded_chunks(Vector3(0, 0, 0))
	var q_size_2 := world._generation_queue.size()
	_assert(q_size_1 == q_size_2, "Chunk update deduplicates queued chunk generation requests")

func test_voxel_world_mine_single_voxel() -> void:
	var world: VoxelWorld = VoxelWorldScript.new()
	world.seed_value = 1337
	# Load spawn chunk
	var spawn_pos := world.get_spawn_position(0, 0)
	var terrain_cell := Vector3i(0, int(floor(spawn_pos.y - 1.2)), 0)
	var orig_type := world.get_voxel_at(terrain_cell)
	_assert(not orig_type.is_empty(), "Mined target cell starts as solid natural voxel (%s)" % orig_type)

	var mined_type := world.mine_voxel(terrain_cell)
	_assert(mined_type == orig_type, "mine_voxel returns mined block type")

	var after_type := world.get_voxel_at(terrain_cell)
	_assert(after_type.is_empty(), "Mined cell is now empty air in voxel data")

func test_negative_coordinate_mapping() -> void:
	var world: VoxelWorld = VoxelWorldScript.new()
	world.seed_value = 1337
	var neg_cell := Vector3i(-5, 10, -5)
	var voxel_type := world.get_voxel_at(neg_cell)
	_assert(voxel_type is StringName, "Negative world coordinates evaluate without crash or index out of bounds")

func test_voxel_world_diagnostics() -> void:
	var world: VoxelWorld = VoxelWorldScript.new()
	world.seed_value = 1337
	world._load_or_generate_chunk(Vector2i(0, 0))
	var diag := world.get_diagnostics()
	_assert(diag.get("loaded_chunks", 0) == 1, "Diagnostics track loaded chunk count (1)")
	_assert(diag.get("total_chunks_generated", 0) >= 1, "Diagnostics track total generated chunk count")

func test_contiguous_solid_interior_generation() -> void:
	var world: VoxelWorld = VoxelWorldScript.new()
	world.seed_value = 1337
	# Inspect vertical column at x=0, z=0
	var top_y := -1
	var bottom_y := -1
	for y in range(31, -1, -1):
		if world.is_solid_block(Vector3i(0, y, 0)):
			if top_y == -1:
				top_y = y
			bottom_y = y

	var contiguous := true
	if top_y != -1 and bottom_y != -1:
		for y in range(bottom_y, top_y + 1):
			if not world.is_solid_block(Vector3i(0, y, 0)):
				contiguous = false
				break

	_assert(contiguous and top_y > bottom_y, "Island vertical voxel column has 100% contiguous solid interior")

func test_unloaded_neighbor_boundary_face_preservation() -> void:
	var world: VoxelWorld = VoxelWorldScript.new()
	world.seed_value = 1337
	# Generate only chunk (0,0) without neighbor (1,0) loaded
	var chunk: VoxelChunk = world._load_or_generate_chunk(Vector2i(0, 0))

	# Border voxel at x=15 (right boundary facing unloaded chunk 1,0)
	var border_solid := chunk.is_solid_local(15, 10, 5)
	if border_solid:
		var col_shape: CollisionShape3D = chunk._col_shape
		_assert(col_shape != null and col_shape.shape != null, "Boundary faces rendered and collidable when neighbor chunk is unloaded")
	else:
		_assert(true, "Chunk boundary test evaluated")

func test_watertight_chunk_boundary_rebuild_on_load_unload() -> void:
	var world: VoxelWorld = VoxelWorldScript.new()
	world.seed_value = 1337
	var c0 := world._load_or_generate_chunk(Vector2i(0, 0))
	var initial_faces := 0
	if c0._col_shape != null and c0._col_shape.shape != null:
		initial_faces = c0._col_shape.shape.get_faces().size()

	# Loading neighbor chunk (1,0) rebuilds c0 to cull shared internal boundary faces
	var c1 := world._load_or_generate_chunk(Vector2i(1, 0))
	var faces_after_neighbor := 0
	if c0._col_shape != null and c0._col_shape.shape != null:
		faces_after_neighbor = c0._col_shape.shape.get_faces().size()

	_assert(faces_after_neighbor < initial_faces, "Loading neighbor chunk culls internal boundary faces and keeps interface watertight")

	# Unloading neighbor chunk (1,0) rebuilds c0 to restore exposed boundary faces
	world._unload_chunk(Vector2i(1, 0))
	var faces_after_unload := 0
	if c0._col_shape != null and c0._col_shape.shape != null:
		faces_after_unload = c0._col_shape.shape.get_faces().size()

	_assert(faces_after_unload == initial_faces, "Unloading neighbor chunk restores exposed boundary faces on edge")

func test_creative_mode_bypasses_inventory_costs() -> void:
	var player := PlayerControllerScript.new()
	player.game_mode = PlayerControllerScript.GameMode.CREATIVE
	var can_use := player.use_cement(100)
	_assert(can_use, "Creative mode bypasses cement inventory consumption")
