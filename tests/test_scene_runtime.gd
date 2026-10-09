extends SceneTree

func _init() -> void:
	print("==================================================")
	print("STARTING LIVE GAMEWORLD RUNTIME INTEGRATION TEST")
	print("==================================================")

	var grid_sys: Node = root.get_node_or_null("GridSystem")
	if grid_sys == null:
		grid_sys = preload("res://autoloads/GridSystem.gd").new()
		grid_sys.name = "GridSystem"
		root.add_child(grid_sys)

	var stab_sys: Node = root.get_node_or_null("StabilitySystem")
	if stab_sys == null:
		stab_sys = preload("res://autoloads/StabilitySystem.gd").new()
		stab_sys.name = "StabilitySystem"
		root.add_child(stab_sys)

	stab_sys.grid_system = grid_sys

	var world_scene: Node = load("res://scenes/world/GameWorld.tscn").instantiate()
	root.add_child(world_scene)

	var orchestrator: CollapseOrchestrator = world_scene.get_node("CollapseOrchestrator")
	orchestrator.grid_system = grid_sys
	orchestrator.stability_system = stab_sys

	world_scene.grid_system = grid_sys
	world_scene.stability_system = stab_sys
	var grid_renderer: Node = world_scene.get_node("GridRenderer")
	grid_renderer.grid_system = grid_sys
	grid_renderer._connect_grid_signals()

	world_scene.spawn_test_tower(Vector3i(0, 0, 0))
	var initial_block_count: int = grid_sys.get_block_count()
	print("GameWorld initialized. Blocks spawned in initial tower: %d" % initial_block_count)
	if initial_block_count <= 0:
		printerr("FAILED: Initial tower was not spawned")
		quit(1)
		return

	# Test cutting foundation of the tower
	print("Cutting base foundation blocks of the tower (y = 0)...")
	grid_sys.remove_block(Vector3i(0, 0, 0))
	grid_sys.remove_block(Vector3i(1, 0, 0))
	grid_sys.remove_block(Vector3i(0, 0, 1))
	grid_sys.remove_block(Vector3i(1, 0, 1))

	var unsupported: Array[Vector3i] = stab_sys.recalculate_stability()
	print("Unsupported blocks identified: %d" % unsupported.size())
	if unsupported.is_empty():
		printerr("FAILED: Upper tower blocks were not flagged unsupported")
		quit(1)
		return

	var islands: Array = orchestrator.trigger_collapse(unsupported)
	print("Debris physics islands spawned: %d" % islands.size())
	if islands.is_empty():
		printerr("FAILED: Debris islands were not spawned")
		quit(1)
		return

	var debris_island: DebrisIsland = islands[0]
	var initial_debris_block_count: int = debris_island.constituent_blocks.size()
	print("Testing targeted block removal on live DebrisIsland (initial blocks: %d)..." % initial_debris_block_count)
	var first_cell: Vector3i = debris_island.constituent_blocks.keys()[0]
	var removed_block: BlockData = debris_island.remove_block(first_cell)
	if removed_block == null:
		printerr("FAILED: Could not remove targeted block from DebrisIsland")
		quit(1)
		return
	print("Block removed successfully from DebrisIsland (type: %s, remaining blocks: %d)" % [removed_block.block_type, debris_island.constituent_blocks.size()])

	var remaining_in_grid: int = grid_sys.get_block_count()
	print("Remaining blocks in GridSystem: %d" % remaining_in_grid)
	if remaining_in_grid != 0:
		printerr("FAILED: Expected 0 blocks remaining in grid after tower base cut, got %d" % remaining_in_grid)
		quit(1)
		return

	# Test Bridge Preset
	print("Testing Bridge Preset...")
	world_scene.spawn_test_bridge()
	var bridge_blocks: int = grid_sys.get_block_count()
	print("Bridge spawned successfully. Blocks in grid: %d" % bridge_blocks)
	var bridge_unsupported: Array[Vector3i] = stab_sys.evaluate_stability()
	if not bridge_unsupported.is_empty():
		printerr("FAILED: Bridge walkway should be supported via lateral pillar connection")
		quit(1)
		return

	# Test Arch Preset
	print("Testing Arch Preset...")
	world_scene.spawn_test_arch()
	var total_blocks: int = grid_sys.get_block_count()
	print("Arch spawned successfully. Total blocks in grid: %d" % total_blocks)

	# Test Clear
	print("Testing Clear World...")
	world_scene.clear_world()
	if grid_sys.get_block_count() != 0:
		printerr("FAILED: Grid not empty after clear_world")
		quit(1)
		return

	print("==================================================")
	print("LIVE GAMEWORLD RUNTIME INTEGRATION TEST PASSED!")
	print("==================================================")
	quit(0)
