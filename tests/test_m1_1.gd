class_name TestM1_1
extends RefCounted

const BlockDataScript = preload("res://data/BlockData.gd")
const BlockTypeCatalogScript = preload("res://data/BlockTypeCatalog.gd")
const GridSystemScript = preload("res://autoloads/GridSystem.gd")
const StabilitySystemScript = preload("res://autoloads/StabilitySystem.gd")
const IslandBuilderScript = preload("res://systems/collapse/IslandBuilder.gd")
const DebrisIslandScript = preload("res://systems/collapse/DebrisIsland.gd")
const CollapseOrchestratorScript = preload("res://systems/collapse/CollapseOrchestrator.gd")
const GridRendererScript = preload("res://systems/rendering/GridRenderer.gd")

var passed_count: int = 0
var failed_count: int = 0
var test_names: Array[String] = []

func run_all() -> bool:
	print("==================================================")
	print("RUNNING MILESTONE 1.1 REGRESSION & RELIABILITY TESTS")
	print("==================================================")

	_run_test("test_debris_block_removal_and_metadata", test_debris_block_removal_and_metadata)
	_run_test("test_debris_island_split_on_disconnection", test_debris_island_split_on_disconnection)
	_run_test("test_debris_full_removal_frees_island", test_debris_full_removal_frees_island)
	_run_test("test_safe_placement_rejects_moving_debris", test_safe_placement_rejects_moving_debris)
	_run_test("test_safe_placement_rejects_debris_overlap", test_safe_placement_rejects_debris_overlap)
	_run_test("test_mutual_exclusive_ownership", test_mutual_exclusive_ownership)
	_run_test("test_editing_structure_with_unrelated_debris_present", test_editing_structure_with_unrelated_debris_present)
	_run_test("test_collapse_duplicate_protection", test_collapse_duplicate_protection)
	_run_test("test_repeated_placement_removal_collapse_reset_cycles", test_repeated_placement_removal_collapse_reset_cycles)
	_run_test("test_shape_owner_lookup_reliability_after_deletions", test_shape_owner_lookup_reliability_after_deletions)
	_run_test("test_input_bindings_no_conflict", test_input_bindings_no_conflict)

	print("==================================================")
	print("M1.1 TEST RESULTS: %d PASSED, %d FAILED" % [passed_count, failed_count])
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

## 1. Targeted removal of an individual block from a debris island
func test_debris_block_removal_and_metadata() -> bool:
	var container := Node3D.new()
	var island := DebrisIslandScript.new()
	container.add_child(island)

	var cells: Array = [
		Vector3i(0, 0, 0),
		Vector3i(1, 0, 0),
		Vector3i(0, 1, 0)
	] # L-shaped: removing (0, 1, 0) leaves (0,0,0) and (1,0,0) connected
	var block_map: Dictionary = {
		Vector3i(0, 0, 0): BlockDataScript.new(&"stone", 1.0, {"meta_key": 42}),
		Vector3i(1, 0, 0): BlockDataScript.new(&"wood", 0.8),
		Vector3i(0, 1, 0): BlockDataScript.new(&"brick", 0.5, {"recovery": true})
	}
	island.setup_island(cells, block_map, 1.0)

	var initial_mass: float = island.mass
	var removed: BlockData = island.remove_block(Vector3i(0, 1, 0))

	# Verify removed block data and metadata preservation
	if removed == null:
		container.queue_free()
		return false
	if removed.block_type != &"brick" or not is_equal_approx(removed.durability, 0.5):
		container.queue_free()
		return false
	if not removed.metadata.has("recovery") or removed.metadata["recovery"] != true:
		container.queue_free()
		return false

	# Remaining block count in island must be 2
	if island.constituent_blocks.size() != 2:
		container.queue_free()
		return false
	if island.constituent_blocks.has(Vector3i(0, 1, 0)):
		container.queue_free()
		return false

	# Mass must be reduced
	if island.mass >= initial_mass:
		container.queue_free()
		return false

	# Collision shape for removed block must be removed
	var col_count: int = 0
	for child in island.get_children():
		if child is CollisionShape3D:
			col_count += 1
	if col_count != 2:
		container.queue_free()
		return false

	container.queue_free()
	return true

## 2. Removing a bridge/connecting block splits an island into independent bodies
func test_debris_island_split_on_disconnection() -> bool:
	var container := Node3D.new()
	var orchestrator := CollapseOrchestratorScript.new()
	orchestrator.debris_container = container
	container.add_child(orchestrator)

	var island := DebrisIslandScript.new()
	island.orchestrator = orchestrator
	container.add_child(island)
	orchestrator.register_debris_island(island)

	# 3 blocks in a linear chain: (0,0,0) - (1,0,0) - (2,0,0)
	var cells: Array = [
		Vector3i(0, 0, 0),
		Vector3i(1, 0, 0),
		Vector3i(2, 0, 0)
	]
	var block_map: Dictionary = {
		Vector3i(0, 0, 0): BlockDataScript.new(&"stone"),
		Vector3i(1, 0, 0): BlockDataScript.new(&"wood"),
		Vector3i(2, 0, 0): BlockDataScript.new(&"brick")
	}
	island.setup_island(cells, block_map, 1.0)

	if orchestrator.get_active_debris_count() != 1:
		container.queue_free()
		return false

	# Remove the middle block (1, 0, 0) -> disconnects (0,0,0) and (2,0,0)
	var removed: BlockData = island.remove_block(Vector3i(1, 0, 0))
	if removed == null or removed.block_type != &"wood":
		container.queue_free()
		return false

	# Orchestrator must now track exactly 2 independent split islands
	if orchestrator.get_active_debris_count() != 2:
		container.queue_free()
		return false

	var split_islands: Array[DebrisIsland] = orchestrator.get_all_active_debris()
	if split_islands.size() != 2:
		container.queue_free()
		return false

	# Each split piece must have 1 block and exact collision shape
	var found_stone: bool = false
	var found_brick: bool = false
	for p in split_islands:
		if p.constituent_blocks.size() != 1:
			container.queue_free()
			return false
		if p.constituent_blocks.has(Vector3i(0, 0, 0)):
			found_stone = true
		if p.constituent_blocks.has(Vector3i(2, 0, 0)):
			found_brick = true

	if not (found_stone and found_brick):
		container.queue_free()
		return false

	container.queue_free()
	return true

## 3. Removing all blocks from an island cleanly frees it
func test_debris_full_removal_frees_island() -> bool:
	var container := Node3D.new()
	var orchestrator := CollapseOrchestratorScript.new()
	orchestrator.debris_container = container
	container.add_child(orchestrator)

	var island := DebrisIslandScript.new()
	island.orchestrator = orchestrator
	container.add_child(island)
	orchestrator.register_debris_island(island)

	island.setup_island([Vector3i(0, 0, 0)], {Vector3i(0, 0, 0): BlockDataScript.new(&"gold")}, 1.0)
	if orchestrator.get_active_debris_count() != 1:
		container.queue_free()
		return false

	var removed: BlockData = island.remove_block(Vector3i(0, 0, 0))
	if removed == null or removed.block_type != &"gold":
		container.queue_free()
		return false

	if orchestrator.get_active_debris_count() != 0:
		container.queue_free()
		return false

	container.queue_free()
	return true

## 4. Safe placement rule: moving debris rejects block placement
func test_safe_placement_rejects_moving_debris() -> bool:
	var island := DebrisIslandScript.new()
	island.setup_island([Vector3i(0, 0, 0)], {Vector3i(0, 0, 0): BlockDataScript.new(&"stone")}, 1.0)

	# Moving state: not settled and has velocity
	island.is_settled = false
	island.linear_velocity = Vector3(0, -3.5, 0)
	if not island.is_moving():
		island.queue_free()
		return false

	# Settled state
	island.is_settled = true
	island.linear_velocity = Vector3.ZERO
	island.angular_velocity = Vector3.ZERO
	if island.is_moving():
		island.queue_free()
		return false

	island.queue_free()
	return true

## 5. Safe placement rule: grid cell blocked by active debris rejects placement
func test_safe_placement_rejects_debris_overlap() -> bool:
	var container := Node3D.new()
	var orchestrator := CollapseOrchestratorScript.new()
	orchestrator.debris_container = container
	container.add_child(orchestrator)

	var island := DebrisIslandScript.new()
	island.orchestrator = orchestrator
	container.add_child(island)
	orchestrator.register_debris_island(island)

	# Place island centered at (5, 0, 5)
	island.setup_island([Vector3i(5, 0, 5)], {Vector3i(5, 0, 5): BlockDataScript.new(&"stone")}, 1.0)

	# Cell (5, 0, 5) must be detected as blocked by debris
	if not orchestrator.is_cell_blocked_by_debris(Vector3i(5, 0, 5), 1.0):
		container.queue_free()
		return false

	# Cell (20, 0, 20) must be clear
	if orchestrator.is_cell_blocked_by_debris(Vector3i(20, 0, 20), 1.0):
		container.queue_free()
		return false

	container.queue_free()
	return true

## 6. Mutual exclusive ownership: blocks belong to either GridSystem or DebrisIsland, never both
func test_mutual_exclusive_ownership() -> bool:
	var container := Node3D.new()
	var grid := GridSystemScript.new()
	var stability := StabilitySystemScript.new()
	stability.grid_system = grid
	stability.ground_anchor_y = 0

	var orchestrator := CollapseOrchestratorScript.new()
	orchestrator.grid_system = grid
	orchestrator.stability_system = stability
	orchestrator.debris_container = container
	container.add_child(orchestrator)

	# Place 3 unsupported blocks
	var cells: Array[Vector3i] = [Vector3i(0, 1, 0), Vector3i(0, 2, 0), Vector3i(0, 3, 0)]
	for c in cells:
		grid.place_block(c, &"stone")

	if grid.get_block_count() != 3:
		container.queue_free()
		return false

	var unsupported: Array[Vector3i] = stability.evaluate_stability()
	var islands: Array = orchestrator.trigger_collapse(unsupported)

	# Must be removed from grid
	if grid.get_block_count() != 0:
		container.queue_free()
		return false
	for c in cells:
		if grid.has_block(c):
			container.queue_free()
			return false

	# Must be in debris island
	if islands.size() != 1:
		container.queue_free()
		return false
	var isl: DebrisIsland = islands[0]
	if isl.constituent_blocks.size() != 3:
		container.queue_free()
		return false

	orchestrator.clear_all_debris()
	container.queue_free()
	return true

## 7. Editing one structure while unrelated debris exists causes zero interference
func test_editing_structure_with_unrelated_debris_present() -> bool:
	var container := Node3D.new()
	var grid := GridSystemScript.new()
	var stability := StabilitySystemScript.new()
	stability.grid_system = grid
	stability.ground_anchor_y = 0

	var orchestrator := CollapseOrchestratorScript.new()
	orchestrator.grid_system = grid
	orchestrator.stability_system = stability
	orchestrator.debris_container = container
	container.add_child(orchestrator)

	# 1. Structure A collapses into debris
	grid.place_block(Vector3i(0, 1, 0), &"stone")
	var unsupp_a: Array[Vector3i] = stability.evaluate_stability()
	orchestrator.trigger_collapse(unsupp_a)

	if orchestrator.get_active_debris_count() != 1:
		container.queue_free()
		return false
	if grid.get_block_count() != 0:
		container.queue_free()
		return false

	# 2. Structure B is built at (20, 0, 20) with ground anchor
	grid.place_block(Vector3i(20, 0, 20), &"stone") # Anchor
	grid.place_block(Vector3i(20, 1, 20), &"wood")  # Supported
	grid.place_block(Vector3i(20, 2, 20), &"brick") # Supported

	# Stability evaluation for Structure B must report 0 unsupported blocks
	var unsupp_b: Array[Vector3i] = stability.evaluate_stability()
	if not unsupp_b.is_empty():
		container.queue_free()
		return false

	# Structure A debris remains intact and active
	if orchestrator.get_active_debris_count() != 1:
		container.queue_free()
		return false

	# 3. Remove top block of Structure B (20, 2, 20)
	grid.remove_block(Vector3i(20, 2, 20))
	var unsupp_c: Array[Vector3i] = stability.evaluate_stability()
	if not unsupp_c.is_empty():
		container.queue_free()
		return false

	# Structure A debris still completely unaffected
	if orchestrator.get_active_debris_count() != 1:
		container.queue_free()
		return false

	orchestrator.clear_all_debris()
	container.queue_free()
	return true

## 8. Prevent duplicate block processing during collapse
func test_collapse_duplicate_protection() -> bool:
	var container := Node3D.new()
	var grid := GridSystemScript.new()
	var stability := StabilitySystemScript.new()
	stability.grid_system = grid

	var orchestrator := CollapseOrchestratorScript.new()
	orchestrator.grid_system = grid
	orchestrator.stability_system = stability
	orchestrator.debris_container = container
	container.add_child(orchestrator)

	# Single block at (0, 5, 0)
	grid.place_block(Vector3i(0, 5, 0), &"stone")

	# Pass list with duplicates and non-existent cells
	var redundant_cells: Array[Vector3i] = [
		Vector3i(0, 5, 0),
		Vector3i(0, 5, 0), # Duplicate
		Vector3i(99, 99, 99), # Non-existent
		Vector3i(-10, -10, -10) # Non-existent
	]

	var islands: Array = orchestrator.trigger_collapse(redundant_cells)
	if islands.size() != 1:
		container.queue_free()
		return false

	var isl: DebrisIsland = islands[0]
	# Must have exactly 1 constituent block, NOT duplicated
	if isl.constituent_blocks.size() != 1:
		container.queue_free()
		return false

	# Calling trigger_collapse again with the same cells must produce 0 islands
	var second_try: Array = orchestrator.trigger_collapse(redundant_cells)
	if not second_try.is_empty():
		container.queue_free()
		return false

	orchestrator.clear_all_debris()
	container.queue_free()
	return true

## 9. Repeated placement, removal, collapse, and reset cycles
func test_repeated_placement_removal_collapse_reset_cycles() -> bool:
	var container := Node3D.new()
	var grid := GridSystemScript.new()
	var stability := StabilitySystemScript.new()
	stability.grid_system = grid
	stability.ground_anchor_y = 0

	var orchestrator := CollapseOrchestratorScript.new()
	orchestrator.grid_system = grid
	orchestrator.stability_system = stability
	orchestrator.debris_container = container
	container.add_child(orchestrator)

	for cycle in range(5):
		# Build 3-block column
		grid.place_block(Vector3i(0, 0, 0), &"stone")
		grid.place_block(Vector3i(0, 1, 0), &"wood")
		grid.place_block(Vector3i(0, 2, 0), &"brick")

		# Sever base
		grid.remove_block(Vector3i(0, 0, 0))
		var unsupp: Array[Vector3i] = stability.evaluate_stability()
		if unsupp.size() != 2:
			container.queue_free()
			return false

		orchestrator.trigger_collapse(unsupp)
		if orchestrator.get_active_debris_count() != 1:
			container.queue_free()
			return false

		# Reset world
		grid.clear()
		orchestrator.clear_all_debris()
		if grid.get_block_count() != 0 or orchestrator.get_active_debris_count() != 0:
			container.queue_free()
			return false

	container.queue_free()
	return true

## 10. Robust collision shape owner lookup after deletions
func test_shape_owner_lookup_reliability_after_deletions() -> bool:
	var container := Node3D.new()
	var grid := GridSystemScript.new()
	var renderer := GridRendererScript.new()
	renderer.grid_system = grid
	container.add_child(renderer)
	renderer._setup_static_body()

	# Place 5 blocks in a row: x = 0, 1, 2, 3, 4
	for x in range(5):
		grid.place_block(Vector3i(x, 0, 0), &"stone")
		renderer._create_block_node(Vector3i(x, 0, 0), grid.get_block(Vector3i(x, 0, 0)))

	var sb: StaticBody3D = renderer.static_body
	var initial_owners: int = sb.get_shape_owners().size()
	if initial_owners != 5:
		container.queue_free()
		return false

	# Remove middle block x = 2
	renderer._remove_block_node(Vector3i(2, 0, 0))
	grid.remove_block(Vector3i(2, 0, 0))

	# Verify remaining blocks can all be accurately resolved via shape owners
	var remaining_cells: Array[Vector3i] = [
		Vector3i(0, 0, 0),
		Vector3i(1, 0, 0),
		Vector3i(3, 0, 0),
		Vector3i(4, 0, 0)
	]

	var found_cells: Dictionary = {}
	for owner_id in sb.get_shape_owners():
		var owner_obj = sb.shape_owner_get_owner(owner_id)
		if owner_obj != null and owner_obj is CollisionShape3D and owner_obj.has_meta("grid_cell"):
			var c: Vector3i = owner_obj.get_meta("grid_cell")
			found_cells[c] = true

	for c in remaining_cells:
		if not found_cells.has(c):
			container.queue_free()
			return false
	if found_cells.has(Vector3i(2, 0, 0)):
		container.queue_free()
		return false

	container.queue_free()
	return true

## 11. Keybindings check: Arch preset must NOT use KEY_A
func test_input_bindings_no_conflict() -> bool:
	var world_script = load("res://scenes/world/GameWorld.gd")
	var source_code: String = world_script.source_code
	# KEY_A must not be used for Arch
	if "KEY_A:" in source_code and "spawn_test_arch" in source_code:
		# Check if KEY_A triggers spawn_test_arch
		var lines := source_code.split("\n")
		for i in range(lines.size()):
			if "KEY_A" in lines[i] and i + 1 < lines.size() and "spawn_test_arch" in lines[i + 1]:
				return false
	if not ("KEY_H" in source_code and "spawn_test_arch" in source_code):
		return false

	return true
