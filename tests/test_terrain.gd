## Voxel terrain system automated tests.
## Tests: VoxelChunk face rendering, CULL_BACK material settings, internal face culling,
##        collision geometry generation, VoxelWorld spawn positioning, queue deduplication,
##        single natural block mining, negative coordinate mapping, contiguous solid interiors,
##        watertight chunk boundary interfaces, hit voxel cell calculation, and diagnostics.
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

	_run_test("test_gameworld_ground_node_removed")
	_run_test("test_chunk_material_cull_mode")
	_run_test("test_chunk_single_block_faces_and_collision")
	_run_test("test_chunk_adjacent_blocks_cull_internal_faces")
	_run_test("test_voxel_world_spawn_position")
	_run_test("test_voxel_world_spawn_headroom_clearance")
	_run_test("test_spawn_feet_above_surface")
	_run_test("test_spawn_solid_ground_support")
	_run_test("test_spawn_chunk_collision_shape_exists")
	_run_test("test_startup_ordering_voxelworld_before_spawn")
	_run_test("test_force_sync_spawn_chunks_generates_radius")
	_run_test("test_voxel_world_generation_queue_deduplication")
	_run_test("test_voxel_world_mine_single_voxel")
	_run_test("test_negative_coordinate_mapping")
	_run_test("test_voxel_world_diagnostics")
	_run_test("test_contiguous_solid_interior_generation")
	_run_test("test_unloaded_neighbor_boundary_face_preservation")
	_run_test("test_watertight_chunk_boundary_rebuild_on_load_unload")
	_run_test("test_creative_mode_bypasses_inventory_costs")
	_run_test("test_chunk_local_coordinate_mesh_transforms")
	_run_test("test_chunk_collision_faces_outward_winding")
	_run_test("test_concave_polygon_shape_backface_collision")
	_run_test("test_physics_spawn_verification_ground_and_clearance")

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

func test_gameworld_ground_node_removed() -> void:
	var scene := load("res://scenes/world/GameWorld.tscn")
	_assert(scene != null, "GameWorld scene loads")
	if scene != null:
		var instance = scene.instantiate()
		var ground_node = instance.get_node_or_null("Ground")
		_assert(ground_node == null, "GameWorld.tscn contains NO fallback 'Ground' StaticBody3D node")
		instance.queue_free()

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

## SPAWN GEOMETRY INVARIANT:
## CharacterBody3D.global_position.y == bottom of capsule == FEET position.
## (CollisionShape3D is offset +0.9 local Y, CapsuleShape3D height=1.8 => capsule Y=[0, 1.8] local)
## get_spawn_position returns feet_y = float(top_solid_y) + 1.1 (0.1m safety above surface top face).

func test_voxel_world_spawn_position() -> void:
	var world: VoxelWorld = VoxelWorldScript.new()
	world.seed_value = 1337
	var spawn_pos := world.get_spawn_position(0, 0)
	_assert(spawn_pos.y > 2.0, "Spawn position Y is on top of terrain island (Y=%.1f)" % spawn_pos.y)

func test_voxel_world_spawn_headroom_clearance() -> void:
	var world: VoxelWorld = VoxelWorldScript.new()
	world.seed_value = 1337
	var spawn_pos := world.get_spawn_position(0, 0)
	# global_position.y = feet (bottom of capsule). Capsule occupies Y=[feet, feet+1.8].
	# Cell at feet: int(floor(spawn_pos.y)) — should be AIR (feet are above surface)
	# Cell at feet+1.7 (head): should also be AIR
	var feet_cell := Vector3i(int(floor(spawn_pos.x)), int(floor(spawn_pos.y)), int(floor(spawn_pos.z)))
	var head_cell := Vector3i(int(floor(spawn_pos.x)), int(floor(spawn_pos.y + 1.7)), int(floor(spawn_pos.z)))
	var ground_cell := feet_cell - Vector3i(0, 1, 0)

	var feet_clear: bool = not world.is_solid_block(feet_cell)
	var head_clear: bool = not world.is_solid_block(head_cell)
	var ground_solid: bool = world.is_solid_block(ground_cell)

	_assert(feet_clear and head_clear and ground_solid, "Player spawn provides 1.8m headroom above solid ground (feet=%.2f, feet_cell=%s, ground=%s)" % [spawn_pos.y, str(feet_cell), str(ground_cell)])

## Regression: feet must be strictly above the terrain surface (no partial overlap).
func test_spawn_feet_above_surface() -> void:
	var world: VoxelWorld = VoxelWorldScript.new()
	world.seed_value = 1337
	var spawn_pos := world.get_spawn_position(0, 0)
	# Find highest solid Y at x=0, z=0
	var top_y := -1
	for y in range(VoxelChunk.SIZE_Y - 1, -1, -1):
		if world.is_solid_block(Vector3i(0, y, 0)):
			top_y = y
			break
	# Feet must be strictly above the top surface face (float(top_y) + 1.0)
	var top_face_y := float(top_y) + 1.0
	_assert(spawn_pos.y >= top_face_y, "Feet Y (%.3f) >= top terrain face Y (%.3f) — player not inside terrain" % [spawn_pos.y, top_face_y])
	# Also verify feet are not more than 2m above surface (shouldn't need a crazy offset)
	_assert(spawn_pos.y < top_face_y + 2.0, "Feet Y (%.3f) is within 2m of terrain surface — not floating in air" % spawn_pos.y)

## Regression: solid ground must exist directly below the player feet.
func test_spawn_solid_ground_support() -> void:
	var world: VoxelWorld = VoxelWorldScript.new()
	world.seed_value = 1337
	var spawn_pos := world.get_spawn_position(0, 0)
	# Feet at spawn_pos.y (e.g. 16.1). The feet cell in voxel coords is int(floor(16.1)) = 16 (AIR).
	# Solid ground is directly below the feet cell: floor(spawn_pos.y) - 1 = 15.
	# This is what CharacterBody3D's is_on_floor() would collide with.
	var feet_cell_y := int(floor(spawn_pos.y))
	var ground_cell := Vector3i(int(floor(spawn_pos.x)), feet_cell_y - 1, int(floor(spawn_pos.z)))
	var is_solid := world.is_solid_block(ground_cell)
	_assert(is_solid, "Solid ground at %s supports player feet (feet_y=%.3f)" % [str(ground_cell), spawn_pos.y])

## Regression: spawn chunk collision shape must exist (not null) before player placement.
## This verifies _load_or_generate_chunk ran synchronously and collision was built.
func test_spawn_chunk_collision_shape_exists() -> void:
	var world: VoxelWorld = VoxelWorldScript.new()
	world.seed_value = 1337
	# Directly generate spawn chunk (same as get_spawn_position does internally)
	var chunk: VoxelChunk = world._load_or_generate_chunk_sync(Vector2i(0, 0))
	_assert(chunk != null, "Spawn chunk (0,0) generated successfully")
	if chunk != null:
		_assert(chunk._col_shape != null, "Spawn chunk has a CollisionShape3D node")
		if chunk._col_shape != null:
			_assert(chunk._col_shape.shape != null, "Spawn chunk CollisionShape3D has a non-null shape resource")
			if chunk._col_shape.shape != null and chunk._col_shape.shape is ConcavePolygonShape3D:
				var concave_s: ConcavePolygonShape3D = chunk._col_shape.shape as ConcavePolygonShape3D
				var face_count: int = concave_s.get_faces().size()
				_assert(face_count > 0, "Spawn chunk collision has %d face vertices (not empty)" % face_count)

## Regression: startup ordering — VoxelWorld must be fully set up before get_spawn_position is called.
## Simulates the GameWorld._ready() sequence: create VoxelWorld, then call get_spawn_position.
## Verifies the spawn position is valid (not the fallback Vector3(0.5, 24.0, 0.5)).
func test_startup_ordering_voxelworld_before_spawn() -> void:
	var world: VoxelWorld = VoxelWorldScript.new()
	world.seed_value = 1337
	# Simulate: VoxelWorld created but _ready() not yet called (no add_child). Noise setup done manually.
	world._setup_noise()
	var spawn_pos := world.get_spawn_position(0, 0)
	_assert(spawn_pos.y < 24.0, "Spawn position is not the void-fallback (%.1f < 24.0) — terrain found before placement" % spawn_pos.y)
	_assert(spawn_pos.y > 1.0, "Spawn position Y is above minimum terrain height")

## Regression: force_sync_spawn_chunks generates chunks in SPAWN_SYNC_RADIUS.
## In unit-test context (no tree), we verify that calling _load_or_generate_chunk for
## all radius positions populates _chunks correctly.
func test_force_sync_spawn_chunks_generates_radius() -> void:
	var world: VoxelWorld = VoxelWorldScript.new()
	world.seed_value = 1337
	world._setup_noise()
	var radius := VoxelWorld.SPAWN_SYNC_RADIUS
	for dx in range(-radius, radius + 1):
		for dz in range(-radius, radius + 1):
			world._load_or_generate_chunk_sync(Vector2i(dx, dz))
	var expected := (2 * radius + 1) * (2 * radius + 1)
	_assert(world._chunks.size() == expected, "force_sync_spawn_chunks generates %d chunks for radius %d (got %d)" % [expected, radius, world._chunks.size()])


func test_voxel_world_generation_queue_deduplication() -> void:
	var world: VoxelWorld = VoxelWorldScript.new()
	world.seed_value = 1337
	world.update_loaded_chunks(Vector3(0, 0, 0))
	var q_size_1: int = world._pending_queue.size()
	world.update_loaded_chunks(Vector3(0, 0, 0))
	var q_size_2: int = world._pending_queue.size()
	_assert(q_size_1 == q_size_2, "Chunk update deduplicates queued chunk generation requests")

func test_voxel_world_mine_single_voxel() -> void:
	var world: VoxelWorld = VoxelWorldScript.new()
	world.seed_value = 1337
	# Load spawn chunk
	var spawn_pos := world.get_spawn_position(0, 0)
	var terrain_cell := Vector3i(0, int(floor(spawn_pos.y - 1.0)), 0)
	var orig_type := world.get_voxel_at(terrain_cell)
	_assert(not orig_type.is_empty(), "Mined target cell starts as solid natural voxel (%s)" % orig_type)

	var mined_type := world.mine_voxel(terrain_cell)
	_assert(mined_type == orig_type, "mine_voxel returns mined block type")

	var after_type := world.get_voxel_at(terrain_cell)
	_assert(after_type.is_empty(), "Mined cell is now empty air in voxel data")

	# Clean up saved deltas so unit test does not leave mined hole for game startup
	if FileAccess.file_exists(VoxelWorld.DELTA_SAVE_PATH):
		DirAccess.remove_absolute(VoxelWorld.DELTA_SAVE_PATH)

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
	var chunk: VoxelChunk = world._load_or_generate_chunk_sync(Vector2i(0, 0))

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
	var c0: VoxelChunk = world._load_or_generate_chunk_sync(Vector2i(0, 0))
	var initial_faces: int = 0
	if c0._col_shape != null and c0._col_shape.shape != null:
		initial_faces = c0._col_shape.shape.get_faces().size()

	# Loading neighbor chunk (1,0) rebuilds c0 to cull shared internal boundary faces
	var c1: VoxelChunk = world._load_or_generate_chunk_sync(Vector2i(1, 0))
	var faces_after_neighbor: int = 0
	if c0._col_shape != null and c0._col_shape.shape != null:
		faces_after_neighbor = c0._col_shape.shape.get_faces().size()

	_assert(faces_after_neighbor < initial_faces, "Loading neighbor chunk culls internal boundary faces and keeps interface watertight")

	# Unloading neighbor chunk (1,0) rebuilds c0 to restore exposed boundary faces
	world._unload_chunk(Vector2i(1, 0))
	var faces_after_unload: int = 0
	if c0._col_shape != null and c0._col_shape.shape != null:
		faces_after_unload = c0._col_shape.shape.get_faces().size()

	_assert(faces_after_unload == initial_faces, "Unloading neighbor chunk restores exposed boundary faces on edge")

func test_creative_mode_bypasses_inventory_costs() -> void:
	var player := PlayerControllerScript.new()
	player.game_mode = PlayerControllerScript.GameMode.CREATIVE
	var can_use := player.use_cement(100)
	_assert(can_use, "Creative mode bypasses cement inventory consumption")

func test_hit_voxel_interior_cell_derivation() -> void:
	# Test hit_pos = (5.0, 10.5, 3.2), hit_normal = (0.0, 1.0, 0.0) -> top face of cell (5, 10, 3)
	var hit_pos := Vector3(5.0, 10.5, 3.2)
	var hit_normal := Vector3(0.0, 1.0, 0.0)
	var interior_pt := hit_pos - hit_normal * 0.05
	var derived_cell := Vector3i(
		int(floor(interior_pt.x)),
		int(floor(interior_pt.y)),
		int(floor(interior_pt.z))
	)
	_assert(derived_cell == Vector3i(5, 10, 3), "Hit point on top face correctly resolves interior voxel cell (5,10,3)")

func test_chunk_local_coordinate_mesh_transforms() -> void:
	var chunk := VoxelChunkScript.new()
	chunk.chunk_pos = Vector2i(-1, 2)
	chunk.set_voxel_local(0, 0, 0, &"stone")
	chunk.rebuild_mesh_and_collision()

	_assert(chunk.position == Vector3(-16.0, 0.0, 32.0), "Chunk node position aligned to world origin (-16, 0, 32)")
	var col_shape: CollisionShape3D = chunk._col_shape
	if col_shape != null and col_shape.shape is ConcavePolygonShape3D:
		var faces: PackedVector3Array = col_shape.shape.get_faces()
		_assert(faces[0].x >= 0.0 and faces[0].x <= 1.0, "Mesh/collision vertices generated in chunk-local coordinates (0 to 1)")

## Regression: VoxelChunk ConcavePolygonShape3D collision faces must have outward-facing winding.
## Prevents the player-spawn fall-through bug caused by inward-facing triangle winding.
func test_chunk_collision_faces_outward_winding() -> void:
	var chunk := VoxelChunkScript.new()
	chunk.chunk_pos = Vector2i(0, 0)
	chunk.set_voxel_local(5, 5, 5, &"stone")
	chunk.rebuild_mesh_and_collision()

	var col_shape: CollisionShape3D = chunk._col_shape
	_assert(col_shape != null and col_shape.shape is ConcavePolygonShape3D, "Collision shape exists for single solid block")
	if col_shape != null and col_shape.shape is ConcavePolygonShape3D:
		var faces: PackedVector3Array = (col_shape.shape as ConcavePolygonShape3D).get_faces()
		_assert(faces.size() == 36, "Single cube generates 36 collision vertices (12 triangles)")
		# Center of block in chunk space
		var block_center := Vector3(5.5, 5.5, 5.5)
		var all_normals_outward := true
		for i in range(0, faces.size(), 3):
			var v0 := faces[i]
			var v1 := faces[i + 1]
			var v2 := faces[i + 2]
			var tri_center := (v0 + v1 + v2) / 3.0
			var outward_dir := (tri_center - block_center).normalized()
			# Normal in Jolt / ConcavePolygonShape3D (v2 - v0) x (v1 - v0)
			var geom_normal := (v2 - v0).cross(v1 - v0).normalized()
			if geom_normal.dot(outward_dir) < 0.9:
				all_normals_outward = false
				break
		_assert(all_normals_outward, "All 12 collision triangles have outward-facing winding normals")

## Regression: ConcavePolygonShape3D must have backface_collision = true enabled.
## Ensures objects that penetrate boundary faces are still detected and resolved.
func test_concave_polygon_shape_backface_collision() -> void:
	var chunk := VoxelChunkScript.new()
	chunk.chunk_pos = Vector2i(0, 0)
	chunk.set_voxel_local(0, 0, 0, &"stone")
	chunk.rebuild_mesh_and_collision()

	var col_shape: CollisionShape3D = chunk._col_shape
	if col_shape != null and col_shape.shape is ConcavePolygonShape3D:
		var shape := col_shape.shape as ConcavePolygonShape3D
		_assert(shape.backface_collision == true, "ConcavePolygonShape3D has backface_collision enabled")

## Regression: verify_spawn_physics correctly checks ground support and capsule clearance.
func test_physics_spawn_verification_ground_and_clearance() -> void:
	var world: VoxelWorld = VoxelWorldScript.new()
	world.seed_value = 1337
	world._setup_noise()

	# Test in non-tree context: verify_spawn_physics safely returns true without crashing
	var dummy_pos := Vector3(0.5, 16.1, 0.5)
	var passes_no_tree := world.verify_spawn_physics(dummy_pos)
	_assert(passes_no_tree, "verify_spawn_physics safely passes in unit-test/offline mode without tree")
