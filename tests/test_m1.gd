const BlockDataScript = preload("res://data/BlockData.gd")
const BlockTypeCatalogScript = preload("res://data/BlockTypeCatalog.gd")
const GridSystemScript = preload("res://autoloads/GridSystem.gd")
const StabilitySystemScript = preload("res://autoloads/StabilitySystem.gd")
const IslandBuilderScript = preload("res://systems/collapse/IslandBuilder.gd")
const DebrisIslandScript = preload("res://systems/collapse/DebrisIsland.gd")
const CollapseOrchestratorScript = preload("res://systems/collapse/CollapseOrchestrator.gd")

var passed_count: int = 0
var failed_count: int = 0
var test_names: Array[String] = []

func run_all() -> bool:
	print("==================================================")
	print("RUNNING MILESTONE 1 AUTOMATED ACCEPTANCE TESTS")
	print("==================================================")

	_run_test("test_grid_placement_and_bounds", test_grid_placement_and_bounds)
	_run_test("test_anchor_detection", test_anchor_detection)
	_run_test("test_vertical_stability_propagation", test_vertical_stability_propagation)
	_run_test("test_floating_block_unsupported", test_floating_block_unsupported)
	_run_test("test_bridge_and_overhang_lateral_support", test_bridge_and_overhang_lateral_support)
	_run_test("test_support_severing_collapse_detection", test_support_severing_collapse_detection)
	_run_test("test_island_grouping_connected_vs_disconnected", test_island_grouping_connected_vs_disconnected)
	_run_test("test_collapse_orchestrator_transition_and_no_duplicates", test_collapse_orchestrator_transition_and_no_duplicates)
	_run_test("test_compound_collision_geometry", test_compound_collision_geometry)
	_run_test("test_damage_entry_point", test_damage_entry_point)
	_run_test("test_json_serialization_and_validation", test_json_serialization_and_validation)

	print("==================================================")
	print("TEST RESULTS: %d PASSED, %d FAILED" % [passed_count, failed_count])
	print("==================================================")
	return failed_count == 0

func _run_test(test_name: String, test_func: Callable) -> void:
	test_names.append(test_name)
	var ok: bool = false
	var result = test_func.call()
	if result is bool:
		ok = result
	else:
		ok = true

	if ok:
		passed_count += 1
		print("[PASS] %s" % test_name)
	else:
		failed_count += 1
		print("[FAIL] %s" % test_name)

# ------------------------------------------------------------------------------
# TESTS
# ------------------------------------------------------------------------------

func test_grid_placement_and_bounds() -> bool:
	var grid = GridSystemScript.new()
	grid.clear()

	# 1. Valid placement at ground level
	var placed: bool = grid.place_block(Vector3i(0, 0, 0), &"stone")
	if not placed:
		return false
	if not grid.has_block(Vector3i(0, 0, 0)):
		return false
	if grid.get_block_count() != 1:
		return false

	# 2. Duplicate placement should be rejected
	var duplicate_placed: bool = grid.place_block(Vector3i(0, 0, 0), &"wood")
	if duplicate_placed:
		return false # Rejected!
	if grid.get_block(Vector3i(0, 0, 0)).block_type != &"stone":
		return false

	# 3. Placement below min_y (e.g. -1) should be rejected
	var below_ground: bool = grid.place_block(Vector3i(0, -1, 0), &"stone")
	if below_ground:
		return false

	# 4. Removal
	var removed = grid.remove_block(Vector3i(0, 0, 0))
	if removed == null or removed.block_type != &"stone":
		return false
	if grid.has_block(Vector3i(0, 0, 0)):
		return false
	if grid.get_block_count() != 0:
		return false

	return true

func test_anchor_detection() -> bool:
	var stability = StabilitySystemScript.new()
	stability.ground_anchor_y = 0

	# Ground y=0 is anchor
	if not stability.is_anchor_cell(Vector3i(5, 0, 10)):
		return false
	# Below ground is anchor
	if not stability.is_anchor_cell(Vector3i(2, -1, 3)):
		return false
	# Above ground is not anchor by default
	if stability.is_anchor_cell(Vector3i(0, 1, 0)):
		return false

	# Custom anchor registration
	var custom_pos := Vector3i(10, 5, 10)
	stability.register_custom_anchor(custom_pos)
	if not stability.is_anchor_cell(custom_pos):
		return false

	stability.unregister_custom_anchor(custom_pos)
	if stability.is_anchor_cell(custom_pos):
		return false

	return true

func test_vertical_stability_propagation() -> bool:
	var grid = GridSystemScript.new()
	var stability = StabilitySystemScript.new()
	stability.grid_system = grid
	stability.ground_anchor_y = 0

	# Build vertical column: y = 0, 1, 2, 3, 4
	for y in range(5):
		grid.place_block(Vector3i(0, y, 0), &"stone")

	var unsupported: Array[Vector3i] = stability.evaluate_stability()
	if not unsupported.is_empty():
		return false # All blocks connected to ground anchor, none should be unsupported

	return true

func test_floating_block_unsupported() -> bool:
	var grid = GridSystemScript.new()
	var stability = StabilitySystemScript.new()
	stability.grid_system = grid
	stability.ground_anchor_y = 0

	# Place floating block at y = 5 with nothing below
	grid.place_block(Vector3i(0, 5, 0), &"stone")

	var unsupported: Array[Vector3i] = stability.evaluate_stability()
	if unsupported.size() != 1:
		return false
	if unsupported[0] != Vector3i(0, 5, 0):
		return false

	return true

func test_bridge_and_overhang_lateral_support() -> bool:
	var grid = GridSystemScript.new()
	var stability = StabilitySystemScript.new()
	stability.grid_system = grid
	stability.ground_anchor_y = 0

	# Left pillar (y = 0..3)
	for y in range(4):
		grid.place_block(Vector3i(0, y, 0), &"stone")

	# Right pillar (y = 0..3) at x = 4
	for y in range(4):
		grid.place_block(Vector3i(4, y, 0), &"stone")

	# Bridge walkway spanning between pillars at y = 3 (x = 1, 2, 3)
	for x in range(1, 4):
		grid.place_block(Vector3i(x, 3, 0), &"wood")

	# Overhang cantilever extending from right pillar (x = 5, y = 3)
	grid.place_block(Vector3i(5, 3, 0), &"wood")

	# All blocks should be supported via lateral connectivity!
	var unsupported: Array[Vector3i] = stability.evaluate_stability()
	if not unsupported.is_empty():
		return false

	return true

func test_support_severing_collapse_detection() -> bool:
	var grid = GridSystemScript.new()
	var stability = StabilitySystemScript.new()
	stability.grid_system = grid
	stability.ground_anchor_y = 0

	# 4-block tower: y = 0, 1, 2, 3
	for y in range(4):
		grid.place_block(Vector3i(0, y, 0), &"stone")

	# Remove base block (y = 0)
	grid.remove_block(Vector3i(0, 0, 0))

	# Now y = 1, 2, 3 should be detected as unsupported!
	var unsupported: Array[Vector3i] = stability.evaluate_stability()
	if unsupported.size() != 3:
		return false

	for y in range(1, 4):
		if not unsupported.has(Vector3i(0, y, 0)):
			return false

	return true

func test_island_grouping_connected_vs_disconnected() -> bool:
	# Group contiguous cells
	var contiguous: Array[Vector3i] = [
		Vector3i(0, 2, 0),
		Vector3i(0, 3, 0),
		Vector3i(0, 4, 0)
	]
	var islands1: Array = IslandBuilderScript.group_islands(contiguous)
	if islands1.size() != 1:
		return false
	if (islands1[0] as Array).size() != 3:
		return false

	# Group two disconnected clusters
	var disconnected: Array[Vector3i] = [
		Vector3i(0, 2, 0),
		Vector3i(0, 3, 0),
		# Gap
		Vector3i(10, 2, 0),
		Vector3i(10, 3, 0)
	]
	var islands2: Array = IslandBuilderScript.group_islands(disconnected)
	if islands2.size() != 2:
		return false

	return true

func test_collapse_orchestrator_transition_and_no_duplicates() -> bool:
	var root_node := Node3D.new()
	var grid = GridSystemScript.new()
	var stability = StabilitySystemScript.new()
	stability.grid_system = grid
	stability.ground_anchor_y = 0

	var orchestrator = CollapseOrchestratorScript.new()
	orchestrator.grid_system = grid
	orchestrator.stability_system = stability
	orchestrator.debris_container = root_node

	# Place 3 blocks at y=1, 2, 3 (unsupported)
	grid.place_block(Vector3i(0, 1, 0), &"stone")
	grid.place_block(Vector3i(0, 2, 0), &"wood")
	grid.place_block(Vector3i(0, 3, 0), &"brick")

	if grid.get_block_count() != 3:
		return false

	var unsupported: Array[Vector3i] = stability.evaluate_stability()
	if unsupported.size() != 3:
		return false

	# Trigger collapse
	var spawned_islands: Array = orchestrator.trigger_collapse(unsupported)

	# 1. Grid must have 0 remaining blocks (atomic removal -> no duplicate blocks!)
	if grid.get_block_count() != 0:
		return false
	for cell in unsupported:
		if grid.has_block(cell):
			return false

	# 2. Exactly 1 island spawned (since 3 blocks were contiguous)
	if spawned_islands.size() != 1:
		return false

	var island = spawned_islands[0]
	if island.constituent_blocks.size() != 3:
		return false

	# 3. Block types and identity preserved
	if island.constituent_blocks[Vector3i(0, 1, 0)].block_type != &"stone":
		return false
	if island.constituent_blocks[Vector3i(0, 2, 0)].block_type != &"wood":
		return false
	if island.constituent_blocks[Vector3i(0, 3, 0)].block_type != &"brick":
		return false

	# Cleanup
	orchestrator.clear_all_debris()
	root_node.queue_free()
	return true

func test_compound_collision_geometry() -> bool:
	var island = DebrisIslandScript.new()
	var cells: Array = [
		Vector3i(0, 0, 0),
		Vector3i(1, 0, 0),
		Vector3i(0, 1, 0)
	] # L-shaped configuration
	var block_map: Dictionary = {
		Vector3i(0, 0, 0): BlockDataScript.new(&"stone"),
		Vector3i(1, 0, 0): BlockDataScript.new(&"wood"),
		Vector3i(0, 1, 0): BlockDataScript.new(&"brick")
	}

	island.setup_island(cells, block_map, 1.0)

	# Verify compound collision: should have 3 CollisionShape3D children with BoxShape3D
	var collision_shapes: Array[CollisionShape3D] = []
	for child in island.get_children():
		if child is CollisionShape3D:
			collision_shapes.append(child)

	if collision_shapes.size() != 3:
		island.queue_free()
		return false

	for col in collision_shapes:
		if not (col.shape is BoxShape3D):
			island.queue_free()
			return false
		var box: BoxShape3D = col.shape
		if not box.size.is_equal_approx(Vector3.ONE):
			island.queue_free()
			return false

	island.queue_free()
	return true

func test_damage_entry_point() -> bool:
	var grid = GridSystemScript.new()
	grid.place_block(Vector3i(0, 0, 0), &"stone")

	# Initial durability is 1.0
	if grid.get_block(Vector3i(0, 0, 0)).durability != 1.0:
		return false

	# Apply 0.4 damage -> durability should be 0.6, block still alive
	var destroyed: bool = grid.apply_damage(Vector3i(0, 0, 0), 0.4)
	if destroyed:
		return false
	if not is_equal_approx(grid.get_block(Vector3i(0, 0, 0)).durability, 0.6):
		return false
	if not grid.has_block(Vector3i(0, 0, 0)):
		return false

	# Apply 0.7 damage -> drops below 0 -> destroyed!
	destroyed = grid.apply_damage(Vector3i(0, 0, 0), 0.7)
	if not destroyed:
		return false
	if grid.has_block(Vector3i(0, 0, 0)):
		return false # Removed from grid!

	return true

func test_json_serialization_and_validation() -> bool:
	var grid = GridSystemScript.new()
	grid.place_block(Vector3i(1, 0, 2), &"stone")
	grid.place_block(Vector3i(1, 1, 2), &"wood")
	grid.get_block(Vector3i(1, 1, 2)).durability = 0.75

	var json_str: String = grid.serialize_json()
	if json_str.is_empty():
		return false

	var grid2 = GridSystemScript.new()
	var success: bool = grid2.deserialize_json(json_str)
	if not success:
		return false

	if grid2.get_block_count() != 2:
		return false
	if not grid2.has_block(Vector3i(1, 0, 2)) or grid2.get_block(Vector3i(1, 0, 2)).block_type != &"stone":
		return false
	if not grid2.has_block(Vector3i(1, 1, 2)) or not is_equal_approx(grid2.get_block(Vector3i(1, 1, 2)).durability, 0.75):
		return false

	# Invalid JSON safety check
	var invalid_success: bool = grid2.deserialize_json("INVALID { JSON")
	if invalid_success:
		return false # Must reject gracefully without crashing!

	return true
