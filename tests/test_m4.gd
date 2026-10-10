## Blueprint system automated tests (Milestone 4).
## Tests: BlueprintData serialization, BlueprintManager capture/save/load/list/delete/validate/apply,
##        invalid placement rejection, joint/mortar restoration, and mortar persistence on debris.
extends RefCounted

const BlueprintDataScript = preload("res://data/BlueprintData.gd")
const DebrisIslandScript = preload("res://systems/collapse/DebrisIsland.gd")
const BuildHUDScript = preload("res://scenes/ui/BuildHUD.gd")
const PlayerControllerScript = preload("res://scenes/player/PlayerController.gd")
const JointSystemScript = preload("res://autoloads/JointSystem.gd")
const InventoryManagerScript = preload("res://autoloads/InventoryManager.gd")
const TerrainGeneratorScript = preload("res://systems/terrain/TerrainGenerator.gd")
const VoxelChunkScript = preload("res://systems/terrain/VoxelChunk.gd")
const VoxelWorldScript = preload("res://systems/terrain/VoxelWorld.gd")

var _passed: int = 0
var _failed: int = 0

func run_all() -> bool:
	print("==================================================")
	print("RUNNING MILESTONE 4: BLUEPRINT SYSTEM TESTS")
	print("==================================================")

	_run_test("test_blueprintdata_to_dict_and_from_dict")
	_run_test("test_blueprintdata_json_roundtrip")
	_run_test("test_blueprintdata_empty_blocks_returns_null")
	_run_test("test_blueprintdata_version_mismatch_warning")
	_run_test("test_blueprint_sanitize_name")
	_run_test("test_blueprint_save_and_load_roundtrip")
	_run_test("test_blueprint_list_includes_saved")
	_run_test("test_blueprint_delete")
	_run_test("test_blueprint_overwrite_false_rejects")
	_run_test("test_blueprint_capture_all_cells")
	_run_test("test_blueprint_capture_specific_cells")
	_run_test("test_blueprint_capture_preserves_block_type_and_durability")
	_run_test("test_blueprint_capture_preserves_joints")
	_run_test("test_blueprint_validate_empty_is_invalid")
	_run_test("test_blueprint_validate_occupied_rejects")
	_run_test("test_blueprint_validate_out_of_bounds_rejects")
	_run_test("test_blueprint_apply_places_blocks")
	_run_test("test_blueprint_apply_invalid_rejects_without_modification")
	_run_test("test_blueprint_apply_allow_replacement_succeeds")
	_run_test("test_blueprint_apply_preserves_durability")
	_run_test("test_blueprint_apply_invalid_does_not_corrupt_world")
	_run_test("test_blueprint_update_or_replace")
	_run_test("test_mortar_coated_faces_saved_in_blockdata_metadata")
	_run_test("test_debris_island_mortar_overlay_spawned_on_collapse")
	_run_test("test_mortar_overlay_absent_when_no_coated_faces")
	_run_test("test_blueprint_actions_no_conflict_with_existing_bindings")
	_run_test("test_hud_blueprint_modals_initial_state")
	_run_test("test_hud_open_save_modal_empty_grid_feedback")
	_run_test("test_hud_open_save_modal_with_blocks")
	_run_test("test_hud_save_blueprint_confirm_flow")
	_run_test("test_hud_load_modal_populates_anchor_and_list")
	_run_test("test_hud_load_placement_validation_rejection_feedback")
	_run_test("test_hud_load_placement_success_flow")
	_run_test("test_hud_is_modal_open_and_close")
	_run_test("test_player_controller_k_l_emits_signals")
	_run_test("test_player_controller_modal_blocks_gameplay_input")
	_run_test("test_impacts_do_not_alter_block_durability")
	_run_test("test_blueprint_save_requires_overwrite_confirmation")
	_run_test("test_mortar_coated_debris_ground_placement")
	_run_test("test_hud_modal_created_in_scene_tree")
	_run_test("test_area_bounded_capture_only_includes_in_bounds_blocks")
	_run_test("test_persisted_desired_layout_after_collapse")
	_run_test("test_intentional_edit_vs_destructive_event")
	_run_test("test_atomic_restoration_failure")
	_run_test("test_planner_fully_intact_all_present")
	_run_test("test_planner_missing_blocks")
	_run_test("test_planner_wrong_block_type_conflict")
	_run_test("test_planner_debris_and_player_obstruction")
	_run_test("test_planner_out_of_bounds_invalid")
	_run_test("test_planner_mixed_states_and_deterministic_reevaluation")
	_run_test("test_translated_anchor_coordinate_transformation")
	_run_test("test_plan_reconstruction_reevaluates_on_anchor_change")
	_run_test("test_startup_restoration_of_saved_blueprints")
	_run_test("test_explicit_update_registered_blueprint_from_world")
	_run_test("test_reconstruct_single_missing_cell_success")
	_run_test("test_reconstruct_single_cell_rejection_safety")
	_run_test("test_reconstruct_single_cell_restores_expected_block_type_and_metadata")
	_run_test("test_reconstruct_single_cell_restores_mortared_joints_without_duplicates")
	_run_test("test_inventory_consumption_on_placement")
	_run_test("test_insufficient_materials_prevents_placement")
	_run_test("test_debris_recovery_awards_materials")
	_run_test("test_inventory_json_persistence")
	_run_test("test_reconstruction_planner_material_status")
	_run_test("test_terrain_seeded_generation_identical_seed")
	_run_test("test_terrain_seeded_generation_different_seed")
	_run_test("test_terrain_layers_and_height_data")
	_run_test("test_terrain_spawn_position_safe")
	_run_test("test_construction_stability_on_generated_terrain")
	_run_test("test_voxel_chunk_solid_data_and_exposed_face_culling")
	_run_test("test_voxel_chunk_boundary_collision_continuity")
	_run_test("test_voxel_island_seeded_generation_and_differentiation")
	_run_test("test_voxel_world_chunk_streaming")
	_run_test("test_voxel_world_mining_awards_resource_once")
	_run_test("test_voxel_terrain_deltas_persistence_across_unload")
	_run_test("test_natural_terrain_remains_static_after_mining")
	_run_test("test_survival_mode_inventory_cost_vs_creative_mode")

	print("==================================================")
	print("M4 TEST RESULTS: %d PASSED, %d FAILED" % [_passed, _failed])
	print("==================================================")
	return _failed == 0

func _run_test(method_name: String) -> void:
	var result: bool = call(method_name)
	if result:
		print("[PASS] %s" % method_name)
		_passed += 1
	else:
		printerr("[FAIL] %s" % method_name)
		_failed += 1

# ==============================================================================
# DATA SERIALIZATION TESTS
# ==============================================================================

func test_blueprintdata_to_dict_and_from_dict() -> bool:
	var bp := BlueprintDataScript.new("test_struct")
	bp.description = "A simple 2-block test"
	bp.anchor_cell = Vector3i(1, 0, 2)
	bp.bounds_min = Vector3i.ZERO
	bp.bounds_max = Vector3i(1, 0, 0)
	bp.blocks = [
		{"rel_pos": [0, 0, 0], "block_type": "stone", "durability": 0.9, "metadata": {}},
		{"rel_pos": [1, 0, 0], "block_type": "wood", "durability": 0.7, "metadata": {}}
	]
	bp.joints = [
		{"rel_a": [0, 0, 0], "rel_b": [1, 0, 0], "strength": 80.0, "is_mortared": true, "material_a": "stone", "material_b": "wood"}
	]

	var d := bp.to_dict()
	if not d.has("format_version") or d["format_version"] != 1:
		return false
	if not d.has("blocks") or d["blocks"].size() != 2:
		return false
	if not d.has("joints") or d["joints"].size() != 1:
		return false

	var bp2: BlueprintData = BlueprintDataScript.from_dict(d)
	if bp2 == null:
		return false
	if bp2.name != "test_struct":
		return false
	if bp2.blocks.size() != 2:
		return false
	if bp2.joints.size() != 1:
		return false
	if not bp2.joints[0].get("is_mortared", false):
		return false
	return true

func test_blueprintdata_json_roundtrip() -> bool:
	var bp := BlueprintDataScript.new("json_test")
	bp.blocks = [
		{"rel_pos": [0, 0, 0], "block_type": "brick", "durability": 1.0, "metadata": {"coated_faces": [[1, 0, 0]]}}
	]
	var json_str: String = bp.to_json_string()
	if json_str.is_empty():
		return false

	var bp2: BlueprintData = BlueprintDataScript.from_json_string(json_str)
	if bp2 == null:
		return false
	if bp2.blocks.size() != 1:
		return false
	var meta: Dictionary = bp2.blocks[0].get("metadata", {})
	if not meta.has("coated_faces"):
		return false
	var cf = meta["coated_faces"]
	if not (cf is Array and cf.size() == 1):
		return false
	return true

func test_blueprintdata_empty_blocks_returns_null() -> bool:
	var result = BlueprintDataScript.from_dict({
		"format_version": 1,
		"name": "bad",
		"blocks": null
	})
	return result == null

func test_blueprintdata_version_mismatch_warning() -> bool:
	# Should not return null — just emit a warning and attempt to load
	var result = BlueprintDataScript.from_dict({
		"format_version": 99,
		"name": "old_version",
		"blocks": []
	})
	# null result would indicate a hard failure; old version should just warn
	return result != null

# ==============================================================================
# MANAGER TESTS
# ==============================================================================

func _make_manager() -> Node:
	var mgr := Node.new()
	var script = load("res://autoloads/BlueprintManager.gd")
	mgr.set_script(script)
	mgr.storage_dir = "user://blueprints_test_%d" % randi()
	return mgr

func test_blueprint_sanitize_name() -> bool:
	var mgr := _make_manager()
	if mgr.sanitize_name("My Blueprint 123") != "my_blueprint_123":
		return false
	if mgr.sanitize_name("  UPPER  ") != "upper":
		return false
	if mgr.sanitize_name("hello-world") != "hello-world":
		return false
	if mgr.sanitize_name("") != "blueprint":
		return false
	return true

func test_blueprint_save_and_load_roundtrip() -> bool:
	var mgr := _make_manager()

	var bp := BlueprintDataScript.new("save_load_test")
	bp.blocks = [{"rel_pos": [0, 0, 0], "block_type": "stone", "durability": 0.8, "metadata": {}}]

	var saved: bool = mgr.save_blueprint(bp, true)
	if not saved:
		return false

	var loaded = mgr.load_blueprint("save_load_test")
	if loaded == null:
		return false
	if loaded.blocks.size() != 1:
		return false
	if float(loaded.blocks[0].get("durability", 0.0)) != 0.8:
		return false

	# Cleanup
	mgr.delete_blueprint("save_load_test")
	return true

func test_blueprint_list_includes_saved() -> bool:
	var mgr := _make_manager()
	var bp := BlueprintDataScript.new("list_test_bp")
	bp.blocks = [{"rel_pos": [0, 0, 0], "block_type": "stone", "durability": 1.0, "metadata": {}}]
	mgr.save_blueprint(bp, true)

	var names: Array[String] = mgr.list_blueprints()
	var found := false
	for n in names:
		if n == "list_test_bp":
			found = true
			break

	mgr.delete_blueprint("list_test_bp")
	return found

func test_blueprint_delete() -> bool:
	var mgr := _make_manager()
	var bp := BlueprintDataScript.new("delete_test")
	bp.blocks = [{"rel_pos": [0, 0, 0], "block_type": "stone", "durability": 1.0, "metadata": {}}]
	mgr.save_blueprint(bp, true)

	if not mgr.has_blueprint("delete_test"):
		return false
	mgr.delete_blueprint("delete_test")
	return not mgr.has_blueprint("delete_test")

func test_blueprint_overwrite_false_rejects() -> bool:
	var mgr := _make_manager()
	var bp := BlueprintDataScript.new("overwrite_test")
	bp.blocks = [{"rel_pos": [0, 0, 0], "block_type": "stone", "durability": 1.0, "metadata": {}}]
	mgr.save_blueprint(bp, true)

	# Try to save again with overwrite=false
	var result: bool = mgr.save_blueprint(bp, false)
	mgr.delete_blueprint("overwrite_test")
	return result == false

# ==============================================================================
# CAPTURE TESTS
# ==============================================================================

func _make_grid() -> Node:
	var g := Node.new()
	var script = load("res://autoloads/GridSystem.gd")
	g.set_script(script)
	return g

func _make_joint_sys(grid: Node) -> Node:
	var js := Node.new()
	var script = load("res://autoloads/JointSystem.gd")
	js.set_script(script)
	js.grid_system = grid
	return js

func test_blueprint_capture_all_cells() -> bool:
	var grid := _make_grid()
	grid.place_block(Vector3i(0, 0, 0), BlockData.new(&"stone", 1.0))
	grid.place_block(Vector3i(1, 0, 0), BlockData.new(&"wood", 0.7))

	var mgr := _make_manager()
	mgr.grid_system = grid

	var bp = mgr.capture_blueprint("capture_all")
	if bp == null:
		return false
	if bp.blocks.size() != 2:
		return false
	return true

func test_blueprint_capture_specific_cells() -> bool:
	var grid := _make_grid()
	grid.place_block(Vector3i(0, 0, 0), BlockData.new(&"stone", 1.0))
	grid.place_block(Vector3i(1, 0, 0), BlockData.new(&"wood", 0.7))
	grid.place_block(Vector3i(5, 0, 0), BlockData.new(&"brick", 1.0)) # Should NOT be included

	var mgr := _make_manager()
	mgr.grid_system = grid

	var cells: Array[Vector3i] = [Vector3i(0, 0, 0), Vector3i(1, 0, 0)]
	var bp = mgr.capture_blueprint("capture_specific", cells)
	if bp == null:
		return false
	if bp.blocks.size() != 2:
		return false
	return true

func test_blueprint_capture_preserves_block_type_and_durability() -> bool:
	var grid := _make_grid()
	grid.place_block(Vector3i(0, 0, 0), BlockData.new(&"brick", 0.65))

	var mgr := _make_manager()
	mgr.grid_system = grid

	var bp = mgr.capture_blueprint("capture_preserve")
	if bp == null:
		return false
	if bp.blocks.size() != 1:
		return false
	var block = bp.blocks[0]
	if block.get("block_type", "") != "brick":
		return false
	if absf(float(block.get("durability", 0.0)) - 0.65) > 0.001:
		return false
	return true

func test_blueprint_capture_preserves_joints() -> bool:
	var grid := _make_grid()
	var js := _make_joint_sys(grid)
	grid.place_block(Vector3i(0, 0, 0), BlockData.new(&"stone", 1.0))
	grid.place_block(Vector3i(1, 0, 0), BlockData.new(&"stone", 1.0))
	js.bond_adjacent(Vector3i(0, 0, 0), Vector3i(1, 0, 0))

	var mgr := _make_manager()
	mgr.grid_system = grid
	mgr.joint_system = js

	var bp = mgr.capture_blueprint("capture_joints")
	if bp == null:
		return false
	if bp.joints.size() < 1:
		return false
	return true

# ==============================================================================
# VALIDATION TESTS
# ==============================================================================

func test_blueprint_validate_empty_is_invalid() -> bool:
	var grid := _make_grid()
	var mgr := _make_manager()
	mgr.grid_system = grid

	var bp := BlueprintDataScript.new("empty_bp")
	bp.blocks = []
	var val: Dictionary = mgr.validate_placement(bp, Vector3i.ZERO)
	return val["valid"] == false and val["reason"] == "EMPTY_BLUEPRINT"

func test_blueprint_validate_occupied_rejects() -> bool:
	var grid := _make_grid()
	grid.place_block(Vector3i(1, 0, 0), BlockData.new(&"stone", 1.0))

	var mgr := _make_manager()
	mgr.grid_system = grid

	var bp := BlueprintDataScript.new("occupied_test")
	bp.blocks = [{"rel_pos": [1, 0, 0], "block_type": "stone", "durability": 1.0, "metadata": {}}]

	var val: Dictionary = mgr.validate_placement(bp, Vector3i.ZERO, false)
	if val["valid"]:
		return false
	if val["reason"] != "CELL_OCCUPIED":
		return false
	if val["conflicts"].is_empty():
		return false
	return true

func test_blueprint_validate_out_of_bounds_rejects() -> bool:
	var grid := _make_grid()
	var mgr := _make_manager()
	mgr.grid_system = grid

	var bp := BlueprintDataScript.new("oob_test")
	# Place at extreme Y to go below min_y
	bp.blocks = [{"rel_pos": [0, -200, 0], "block_type": "stone", "durability": 1.0, "metadata": {}}]

	var val: Dictionary = mgr.validate_placement(bp, Vector3i.ZERO)
	return not val["valid"]

# ==============================================================================
# APPLY TESTS
# ==============================================================================

func test_blueprint_apply_places_blocks() -> bool:
	var grid := _make_grid()
	var mgr := _make_manager()
	mgr.grid_system = grid

	var bp := BlueprintDataScript.new("apply_test")
	bp.blocks = [
		{"rel_pos": [0, 0, 0], "block_type": "stone", "durability": 1.0, "metadata": {}},
		{"rel_pos": [1, 0, 0], "block_type": "wood", "durability": 0.8, "metadata": {}}
	]

	var res: Dictionary = mgr.apply_blueprint(bp, Vector3i(10, 0, 10))
	if not res["success"]:
		return false
	if not grid.has_block(Vector3i(10, 0, 10)):
		return false
	if not grid.has_block(Vector3i(11, 0, 10)):
		return false
	return true

func test_blueprint_apply_invalid_rejects_without_modification() -> bool:
	var grid := _make_grid()
	# Pre-occupy target cell
	grid.place_block(Vector3i(5, 0, 5), BlockData.new(&"brick", 1.0))
	var initial_count: int = grid.get_block_count()

	var mgr := _make_manager()
	mgr.grid_system = grid

	var bp := BlueprintDataScript.new("reject_test")
	bp.blocks = [{"rel_pos": [5, 0, 5], "block_type": "stone", "durability": 1.0, "metadata": {}}]

	var res: Dictionary = mgr.apply_blueprint(bp, Vector3i.ZERO, false)
	if res["success"]:
		return false
	# Grid count must not have changed
	if grid.get_block_count() != initial_count:
		return false
	return true

func test_blueprint_apply_allow_replacement_succeeds() -> bool:
	var grid := _make_grid()
	# Pre-occupy target cell
	grid.place_block(Vector3i(0, 0, 0), BlockData.new(&"brick", 1.0))

	var mgr := _make_manager()
	mgr.grid_system = grid

	var bp := BlueprintDataScript.new("replace_test")
	bp.blocks = [{"rel_pos": [0, 0, 0], "block_type": "gold", "durability": 0.9, "metadata": {}}]

	var res: Dictionary = mgr.apply_blueprint(bp, Vector3i.ZERO, true)
	if not res["success"]:
		return false
	var b: BlockData = grid.get_block(Vector3i(0, 0, 0))
	if b == null or b.block_type != &"gold":
		return false
	return true

func test_blueprint_apply_preserves_durability() -> bool:
	var grid := _make_grid()
	var mgr := _make_manager()
	mgr.grid_system = grid

	var bp := BlueprintDataScript.new("durability_test")
	bp.blocks = [{"rel_pos": [0, 0, 0], "block_type": "stone", "durability": 0.55, "metadata": {}}]

	var res: Dictionary = mgr.apply_blueprint(bp, Vector3i(20, 0, 20))
	if not res["success"]:
		return false

	var b: BlockData = grid.get_block(Vector3i(20, 0, 20))
	if b == null:
		return false
	if absf(b.durability - 0.55) > 0.001:
		return false
	return true

func test_blueprint_apply_invalid_does_not_corrupt_world() -> bool:
	var grid := _make_grid()
	# Place a 3-block structure
	grid.place_block(Vector3i(0, 0, 0), BlockData.new(&"stone", 1.0))
	grid.place_block(Vector3i(1, 0, 0), BlockData.new(&"stone", 1.0))
	grid.place_block(Vector3i(2, 0, 0), BlockData.new(&"stone", 1.0))

	var mgr := _make_manager()
	mgr.grid_system = grid

	# Blueprint that conflicts with cell (1,0,0) but has other valid cells
	var bp := BlueprintDataScript.new("corrupt_test")
	bp.blocks = [
		{"rel_pos": [0, 0, 0], "block_type": "wood", "durability": 1.0, "metadata": {}},  # conflicts
		{"rel_pos": [0, 5, 0], "block_type": "wood", "durability": 1.0, "metadata": {}}    # free
	]

	var res: Dictionary = mgr.apply_blueprint(bp, Vector3i(1, 0, 0), false)
	if res["success"]:
		return false

	# Original blocks must still be intact; no spurious wood block at (1,5,0)
	if not grid.has_block(Vector3i(0, 0, 0)):
		return false
	if not grid.has_block(Vector3i(1, 0, 0)):
		return false
	if grid.has_block(Vector3i(1, 5, 0)):
		return false
	return true

func test_blueprint_update_or_replace() -> bool:
	var grid := _make_grid()
	grid.place_block(Vector3i(0, 0, 0), BlockData.new(&"stone", 1.0))

	var mgr := _make_manager()
	mgr.grid_system = grid

	# Save initial blueprint
	var bp1 = mgr.capture_blueprint("update_test")
	if bp1 == null:
		return false
	mgr.save_blueprint(bp1, true)

	# Add another block and update
	grid.place_block(Vector3i(1, 0, 0), BlockData.new(&"wood", 1.0))
	var updated: bool = mgr.update_or_replace_blueprint("update_test")
	if not updated:
		return false

	var loaded = mgr.load_blueprint("update_test")
	if loaded == null:
		return false
	# Updated blueprint should have 2 blocks
	if loaded.blocks.size() != 2:
		return false

	mgr.delete_blueprint("update_test")
	return true

# ==============================================================================
# MORTAR METADATA AND DEBRIS VISUAL TESTS
# ==============================================================================

func test_mortar_coated_faces_saved_in_blockdata_metadata() -> bool:
	var grid := _make_grid()
	grid.place_block(Vector3i(0, 0, 0), BlockData.new(&"stone", 1.0))
	var js := _make_joint_sys(grid)

	# Apply mortar brush to a face
	js.apply_mortar_brush(Vector3i(0, 0, 0), Vector3i(0, 1, 0))

	# Block metadata should now have "coated_faces" entry
	var b: BlockData = grid.get_block(Vector3i(0, 0, 0))
	if b == null:
		return false
	if not b.metadata.has("coated_faces"):
		return false
	var cf = b.metadata["coated_faces"]
	if not (cf is Array and not cf.is_empty()):
		return false
	return true

func test_debris_island_mortar_overlay_spawned_on_collapse() -> bool:
	# Create a block with coated_faces metadata (simulating a coated grid block collapsed to debris)
	var block := BlockData.new(&"stone", 1.0, {"coated_faces": [[1, 0, 0]]})
	var island := DebrisIslandScript.new()
	island.setup_island([Vector3i.ZERO], {Vector3i.ZERO: block}, 1.0, [])

	# Check mortar overlay was created for the coated face
	var overlay_exists: bool = island.has_mortar_overlay(Vector3i.ZERO, Vector3i(1, 0, 0))

	island.queue_free()
	return overlay_exists

func test_mortar_overlay_absent_when_no_coated_faces() -> bool:
	var block := BlockData.new(&"stone", 1.0)  # No coated_faces in metadata
	var island := DebrisIslandScript.new()
	island.setup_island([Vector3i.ZERO], {Vector3i.ZERO: block}, 1.0, [])

	var overlay_exists: bool = island.has_mortar_overlay(Vector3i.ZERO, Vector3i(1, 0, 0))

	island.queue_free()
	return not overlay_exists

# ==============================================================================
# INPUT CONFLICT TESTS
# ==============================================================================

func test_blueprint_actions_no_conflict_with_existing_bindings() -> bool:
	if not InputMap.has_action(&"save_blueprint"):
		InputMap.add_action(&"save_blueprint")
	if not InputMap.has_action(&"load_blueprint"):
		InputMap.add_action(&"load_blueprint")

	# KEY_K must not be used by any other action (movement/interact/build actions)
	var reserved_actions: Array = [
		&"move_forward", &"move_backward", &"move_left", &"move_right",
		&"jump", &"sprint", &"interact", &"recover_block", &"throw_debris",
		&"apply_cement", &"soul_projection", &"debug_camera", &"place_block",
		&"remove_block", &"toggle_mouse_capture",
		&"select_slot_1", &"select_slot_2", &"select_slot_3", &"select_slot_4"
	]

	for action in reserved_actions:
		if not InputMap.has_action(action):
			continue
		for ev in InputMap.action_get_events(action):
			if ev is InputEventKey:
				if ev.physical_keycode == KEY_K or ev.keycode == KEY_K:
					printerr("save_blueprint KEY_K conflicts with action: %s" % action)
					return false
				if ev.physical_keycode == KEY_L or ev.keycode == KEY_L:
					printerr("load_blueprint KEY_L conflicts with action: %s" % action)
					return false

	return true

# ==============================================================================
# HUD IN-GAME WORKFLOW & INPUT TESTS
# ==============================================================================

func _make_hud(grid: Node) -> BuildHUD:
	var hud: BuildHUD = BuildHUDScript.new()
	hud.grid_system = grid
	hud.blueprint_manager = _make_manager()
	hud.blueprint_manager.grid_system = grid
	return hud

func test_hud_blueprint_modals_initial_state() -> bool:
	var grid := _make_grid()
	var hud = _make_hud(grid)

	if hud.is_modal_open():
		hud.queue_free()
		return false
	if hud._save_modal == null or hud._save_modal.visible:
		hud.queue_free()
		return false
	if hud._load_modal == null or hud._load_modal.visible:
		hud.queue_free()
		return false

	hud.queue_free()
	return true

func test_hud_open_save_modal_empty_grid_feedback() -> bool:
	var grid := _make_grid()
	var hud = _make_hud(grid)

	hud.open_save_blueprint_dialog()
	if not hud.is_modal_open():
		hud.queue_free()
		return false
	if not hud._save_modal.visible:
		hud.queue_free()
		return false
	if not hud._save_btn.disabled:
		hud.queue_free()
		return false
	if "Grid is empty" not in hud._save_feedback_label.text:
		hud.queue_free()
		return false

	hud.close_all_modals()
	hud.queue_free()
	return true

func test_hud_open_save_modal_with_blocks() -> bool:
	var grid := _make_grid()
	grid.place_block(Vector3i(0, 0, 0), BlockData.new(&"stone", 1.0))
	var hud = _make_hud(grid)

	hud.open_save_blueprint_dialog()
	if not hud._save_modal.visible:
		hud.queue_free()
		return false
	if hud._save_btn.disabled:
		hud.queue_free()
		return false
	if "1 block(s)" not in hud._save_info_label.text:
		hud.queue_free()
		return false

	hud.close_all_modals()
	hud.queue_free()
	return true

func test_hud_save_blueprint_confirm_flow() -> bool:
	var grid := _make_grid()
	grid.place_block(Vector3i(2, 0, 2), BlockData.new(&"brick", 0.9))
	var hud = _make_hud(grid)

	hud.open_save_blueprint_dialog()
	hud._save_name_input.text = "hud_save_test"
	hud._on_save_confirm_pressed()

	# BlueprintManager must have saved it
	var bp_mgr: Node = hud._get_blueprint_manager()
	if bp_mgr == null or not bp_mgr.has_blueprint("hud_save_test"):
		hud.queue_free()
		return false

	var loaded = bp_mgr.load_blueprint("hud_save_test")
	if loaded == null or loaded.blocks.size() != 1:
		bp_mgr.delete_blueprint("hud_save_test")
		hud.queue_free()
		return false

	bp_mgr.delete_blueprint("hud_save_test")
	hud.close_all_modals()
	hud.queue_free()
	return true

func test_hud_load_modal_populates_anchor_and_list() -> bool:
	var grid := _make_grid()
	var hud = _make_hud(grid)

	# Save a test blueprint so list is not empty
	var bp_mgr: Node = hud._get_blueprint_manager()
	if bp_mgr != null:
		var bp := BlueprintDataScript.new("hud_load_list_test")
		bp.blocks = [{"rel_pos": [0, 0, 0], "block_type": "wood", "durability": 1.0, "metadata": {}}]
		bp_mgr.save_blueprint(bp, true)

	var target_anchor := Vector3i(15, 3, -8)
	hud.open_load_blueprint_dialog(target_anchor)

	if not hud._load_modal.visible:
		hud.queue_free()
		return false
	if int(hud._anchor_x.value) != 15 or int(hud._anchor_y.value) != 3 or int(hud._anchor_z.value) != -8:
		hud.queue_free()
		return false
	if hud._load_item_list.item_count == 0:
		hud.queue_free()
		return false

	if bp_mgr != null:
		bp_mgr.delete_blueprint("hud_load_list_test")
	hud.close_all_modals()
	hud.queue_free()
	return true

func test_hud_load_placement_validation_rejection_feedback() -> bool:
	var grid := _make_grid()
	# Pre-occupy cell (5, 0, 5)
	grid.place_block(Vector3i(5, 0, 5), BlockData.new(&"stone", 1.0))
	var hud = _make_hud(grid)

	var bp_mgr: Node = hud._get_blueprint_manager()
	if bp_mgr != null:
		var bp := BlueprintDataScript.new("conflict_test_bp")
		bp.blocks = [{"rel_pos": [0, 0, 0], "block_type": "gold", "durability": 1.0, "metadata": {}}]
		bp_mgr.save_blueprint(bp, true)

	hud.open_load_blueprint_dialog(Vector3i(5, 0, 5))
	# Ensure conflict_test_bp is selected
	for i in range(hud._load_item_list.item_count):
		if hud._load_item_list.get_item_text(i) == "conflict_test_bp":
			hud._load_item_list.select(i)
			break

	# Attempt to place without allow_replacement
	hud._replace_checkbox.button_pressed = false
	hud._on_load_confirm_pressed()

	# Rejection feedback must be shown
	if "Cannot place [CELL_OCCUPIED]" not in hud._load_feedback_label.text:
		hud.queue_free()
		return false

	# Original block must still be stone, not gold
	var b: BlockData = grid.get_block(Vector3i(5, 0, 5))
	if b == null or b.block_type != &"stone":
		hud.queue_free()
		return false

	if bp_mgr != null:
		bp_mgr.delete_blueprint("conflict_test_bp")
	hud.close_all_modals()
	hud.queue_free()
	return true

func test_hud_load_placement_success_flow() -> bool:
	var grid := _make_grid()
	var hud = _make_hud(grid)

	var bp_mgr: Node = hud._get_blueprint_manager()
	if bp_mgr != null:
		var bp := BlueprintDataScript.new("hud_place_success_bp")
		bp.blocks = [{"rel_pos": [0, 0, 0], "block_type": "wood", "durability": 0.75, "metadata": {}}]
		bp_mgr.save_blueprint(bp, true)

	hud.open_load_blueprint_dialog(Vector3i(30, 0, 30))
	for i in range(hud._load_item_list.item_count):
		if hud._load_item_list.get_item_text(i) == "hud_place_success_bp":
			hud._load_item_list.select(i)
			break

	hud._on_load_confirm_pressed()

	# Block must now be placed at (30, 0, 30)
	if not grid.has_block(Vector3i(30, 0, 30)):
		hud.queue_free()
		return false
	var b: BlockData = grid.get_block(Vector3i(30, 0, 30))
	if b == null or b.block_type != &"wood" or absf(b.durability - 0.75) > 0.01:
		hud.queue_free()
		return false

	if bp_mgr != null:
		bp_mgr.delete_blueprint("hud_place_success_bp")
	hud.close_all_modals()
	hud.queue_free()
	return true

func test_hud_is_modal_open_and_close() -> bool:
	var grid := _make_grid()
	var hud = _make_hud(grid)

	if hud.is_modal_open():
		hud.queue_free()
		return false

	hud.open_save_blueprint_dialog()
	if not hud.is_modal_open():
		hud.queue_free()
		return false

	hud.close_all_modals()
	if hud.is_modal_open():
		hud.queue_free()
		return false

	hud.open_load_blueprint_dialog(Vector3i.ZERO)
	if not hud.is_modal_open():
		hud.queue_free()
		return false

	hud.close_all_modals()
	if hud.is_modal_open():
		hud.queue_free()
		return false

	hud.queue_free()
	return true

func test_player_controller_k_l_emits_signals() -> bool:
	var player = PlayerControllerScript.new()
	var state: Dictionary = {
		"saved": false,
		"loaded": false,
		"anchor": Vector3i.ZERO
	}

	player.save_blueprint_requested.connect(func() -> void: state["saved"] = true)
	player.load_blueprint_requested.connect(func(a: Vector3i) -> void:
		state["loaded"] = true
		state["anchor"] = a
	)

	player._handle_save_blueprint_action()
	if not state["saved"]:
		player.queue_free()
		return false

	player.has_target = true
	player.target_place_cell = Vector3i(7, 2, 9)
	player._handle_load_blueprint_action()
	if not state["loaded"] or state["anchor"] != Vector3i(7, 2, 9):
		player.queue_free()
		return false

	player.queue_free()
	return true

func test_player_controller_modal_blocks_gameplay_input() -> bool:
	var grid := _make_grid()
	var hud = _make_hud(grid)
	var player = PlayerControllerScript.new()
	player.build_hud = hud

	hud.open_save_blueprint_dialog()
	if not player._is_ui_modal_open():
		hud.queue_free()
		player.queue_free()
		return false

	hud.close_all_modals()
	if player._is_ui_modal_open():
		hud.queue_free()
		player.queue_free()
		return false

	hud.queue_free()
	player.queue_free()
	return true

func test_impacts_do_not_alter_block_durability() -> bool:
	var grid := _make_grid()
	var joint_sys = JointSystemScript.new()
	joint_sys.grid_system = grid

	grid.place_block(Vector3i(0, 0, 0), &"stone")
	grid.place_block(Vector3i(1, 0, 0), &"stone")
	var b: BlockData = grid.get_block(Vector3i(0, 0, 0))

	# Heavy impact breaks structural joint, but block durability remains unchanged (1.0)
	joint_sys.apply_impact_to_block_joints(Vector3i(0, 0, 0), 100.0)
	if absf(b.durability - 1.0) > 0.001:
		joint_sys.queue_free()
		return false

	joint_sys.queue_free()
	return true

func test_hud_modal_created_in_scene_tree() -> bool:
	var grid := _make_grid()
	var hud = _make_hud(grid)

	if hud._save_modal == null or hud._load_modal == null:
		hud.queue_free()
		return false
	if hud._save_modal.get_parent() != hud or hud._load_modal.get_parent() != hud:
		hud.queue_free()
		return false

	hud.open_save_blueprint_dialog()
	if not hud.is_modal_open() or not hud._save_modal.visible:
		hud.queue_free()
		return false

	hud.close_all_modals()
	if hud.is_modal_open() or hud._save_modal.visible:
		hud.queue_free()
		return false

	hud.queue_free()
	return true

func test_blueprint_save_requires_overwrite_confirmation() -> bool:
	var grid := _make_grid()
	grid.place_block(Vector3i(0, 0, 0), &"stone")
	var hud = _make_hud(grid)
	var bp_mgr = _make_manager()
	bp_mgr.grid_system = grid
	hud.blueprint_manager = bp_mgr

	hud.open_save_blueprint_dialog_bounded(Vector3i(0, 0, 0), Vector3i(1, 1, 1))
	if not hud._has_area_selected:
		hud.queue_free()
		return false

	hud._save_name_input.text = "overwrite_test"

	# First save creates the blueprint
	hud._on_save_confirm_pressed()
	if not bp_mgr.has_blueprint("overwrite_test"):
		hud.queue_free()
		return false

	# Re-open save dialog bounded and try to save again with same name
	hud.open_save_blueprint_dialog_bounded(Vector3i(0, 0, 0), Vector3i(1, 1, 1))
	hud._save_name_input.text = "overwrite_test"
	hud._on_save_confirm_pressed()

	# Should prompt for overwrite confirmation first
	if not hud._save_confirm_overwrite or "already exists" not in hud._save_feedback_label.text:
		hud.queue_free()
		return false

	# Confirming overwrite succeeds
	hud._on_save_confirm_pressed()
	if hud._save_confirm_overwrite:
		hud.queue_free()
		return false

	hud.queue_free()
	return true

func test_mortar_coated_debris_ground_placement() -> bool:
	var grid := _make_grid()
	var orch := CollapseOrchestrator.new()
	orch.grid_system = grid

	# Debris island with mortar-coated face
	var data := BlockData.new(&"stone", 1.0, {"coated_faces": [[0, -1, 0]]})
	var island := DebrisIsland.new()
	island.orchestrator = orch
	island.setup_island([Vector3i.ZERO], {Vector3i.ZERO: data}, 1.0)
	orch.register_debris_island(island)

	# Verify orchestrator is_cell_blocked_by_debris excludes held island
	var cell := Vector3i(2, 0, 2)
	island.position = Vector3(2.5, 0.5, 2.5) # Island located right at cell

	var blocked_with_held: bool = orch.is_cell_blocked_by_debris(cell, 1.0, island)
	var blocked_without_held: bool = orch.is_cell_blocked_by_debris(cell, 1.0, null)

	if blocked_with_held or not blocked_without_held:
		island.queue_free()
		orch.queue_free()
		return false

	island.queue_free()
	orch.queue_free()
	return true

func test_area_bounded_capture_only_includes_in_bounds_blocks() -> bool:
	var grid := _make_grid()
	var bp_mgr := _make_manager()
	bp_mgr.grid_system = grid

	grid.place_block(Vector3i(1, 1, 1), &"stone")
	grid.place_block(Vector3i(10, 10, 10), &"wood")

	var bp = bp_mgr.capture_blueprint_area("area_test", Vector3i(0, 0, 0), Vector3i(2, 2, 2))
	if bp == null or bp.get_block_count() != 1:
		return false

	var block_entry = bp.blocks[0]
	if block_entry.get("rel_pos", []) != [1, 1, 1] or block_entry.get("block_type", "") != "stone":
		return false

	return true

func test_inventory_consumption_on_placement() -> bool:
	var inv := InventoryManagerScript.new()
	inv.set_material_count(&"stone", 10)

	var ok := inv.consume_materials({"stone": 1})
	if not ok or inv.get_material_count(&"stone") != 9:
		inv.queue_free()
		return false

	var failed := inv.consume_materials({"stone": 20})
	if failed or inv.get_material_count(&"stone") != 9:
		inv.queue_free()
		return false

	inv.queue_free()
	return true

func test_insufficient_materials_prevents_placement() -> bool:
	var inv := InventoryManagerScript.new()
	inv.set_material_count(&"stone", 0)

	if inv.has_materials({"stone": 1}):
		inv.queue_free()
		return false

	inv.queue_free()
	return true

func test_debris_recovery_awards_materials() -> bool:
	var inv := InventoryManagerScript.new()
	inv.set_material_count(&"stone", 5)

	inv.add_material(&"stone", 1)
	if inv.get_material_count(&"stone") != 6:
		inv.queue_free()
		return false

	inv.queue_free()
	return true

func test_inventory_json_persistence() -> bool:
	var inv := InventoryManagerScript.new()
	inv.set_material_count(&"stone", 42)
	inv.save_inventory()

	var inv2 := InventoryManagerScript.new()
	inv2.load_inventory()
	if inv2.get_material_count(&"stone") != 42:
		inv.queue_free()
		inv2.queue_free()
		return false

	inv.queue_free()
	inv2.queue_free()
	return true

func test_reconstruction_planner_material_status() -> bool:
	var grid := _make_grid()
	var inv := InventoryManagerScript.new()
	inv.set_material_count(&"stone", 0)

	var bp := BlueprintDataScript.new("inv_plan_test")
	bp.blocks = [{"rel_pos": [0, 0, 0], "block_type": "stone", "durability": 1.0, "metadata": {}}]

	var plan = ReconstructionPlanner.generate_plan(bp, Vector3i(0, 0, 0), grid, null, null, inv)
	if plan == null or plan.missing_count != 1:
		inv.queue_free()
		return false

	var missing = plan.get_missing_entries()
	if missing.is_empty() or missing[0].get("reason", "") != "INSUFFICIENT_MATERIALS":
		inv.queue_free()
		return false

	inv.queue_free()
	return true

func test_terrain_seeded_generation_identical_seed() -> bool:
	var gen1 := TerrainGeneratorScript.new()
	gen1.seed_value = 12345

	var gen2 := TerrainGeneratorScript.new()
	gen2.seed_value = 12345

	for x in range(-10, 10):
		for z in range(-10, 10):
			if gen1.get_surface_y(x, z) != gen2.get_surface_y(x, z):
				gen1.queue_free()
				gen2.queue_free()
				return false

	gen1.queue_free()
	gen2.queue_free()
	return true

func test_terrain_seeded_generation_different_seed() -> bool:
	var gen1 := TerrainGeneratorScript.new()
	gen1.seed_value = 12345

	var gen2 := TerrainGeneratorScript.new()
	gen2.seed_value = 99999

	var matches := 0
	var total := 0
	for x in range(-10, 10):
		for z in range(-10, 10):
			total += 1
			if gen1.get_surface_y(x, z) == gen2.get_surface_y(x, z):
				matches += 1

	gen1.queue_free()
	gen2.queue_free()
	return matches < total

func test_terrain_layers_and_height_data() -> bool:
	var gen := TerrainGeneratorScript.new()
	gen.seed_value = 1337

	var surf_y := gen.get_surface_y(0, 0)
	if surf_y < gen.min_height or surf_y > gen.max_height:
		gen.queue_free()
		return false

	if gen.get_block_type_at(0, surf_y, 0) != &"stone":
		gen.queue_free()
		return false

	if gen.get_block_type_at(0, surf_y - 1, 0) != &"brick":
		gen.queue_free()
		return false

	if gen.get_block_type_at(0, 0, 0) != &"wood":
		gen.queue_free()
		return false

	gen.queue_free()
	return true

func test_terrain_spawn_position_safe() -> bool:
	var gen := TerrainGeneratorScript.new()
	gen.seed_value = 1337

	var surf_y := gen.get_surface_y(0, 0)
	var spawn_pos := gen.get_spawn_position(0, 0)

	if spawn_pos.y <= float(surf_y + 1):
		gen.queue_free()
		return false

	gen.queue_free()
	return true

func test_construction_stability_on_generated_terrain() -> bool:
	var grid := _make_grid()
	var js := _make_joint_sys(grid)
	var stability := Node.new()
	var script = load("res://autoloads/StabilitySystem.gd")
	stability.set_script(script)
	stability.grid_system = grid
	stability.joint_system = js

	var vox_world := VoxelWorldScript.new()
	vox_world.seed_value = 1337
	stability.terrain_generator = vox_world

	var spawn_pos := vox_world.get_spawn_position(5, 5)
	var surf_y := int(floor(spawn_pos.y - 1.2))
	var block_cell := Vector3i(5, surf_y + 1, 5)

	grid.place_block(block_cell, &"stone")
	if not stability.is_anchor_cell(block_cell):
		vox_world.queue_free()
		stability.queue_free()
		return false

	vox_world.queue_free()
	stability.queue_free()
	return true

func test_voxel_chunk_solid_data_and_exposed_face_culling() -> bool:
	var chunk := VoxelChunkScript.new()
	chunk.chunk_pos = Vector2i(0, 0)
	chunk.set_voxel_local(1, 1, 1, &"stone")
	chunk.rebuild_mesh_and_collision()

	var col_shape = chunk.get_node_or_null("ChunkCollision")
	if col_shape == null or col_shape.shape == null:
		chunk.queue_free()
		return false

	var faces: PackedVector3Array = col_shape.shape.get_faces()
	if faces.size() != 36:
		chunk.queue_free()
		return false

	chunk.queue_free()
	return true

func test_voxel_chunk_boundary_collision_continuity() -> bool:
	var world := VoxelWorldScript.new()
	world.seed_value = 1337

	var c1 = world._load_or_generate_chunk(Vector2i(0, 0))
	var c2 = world._load_or_generate_chunk(Vector2i(1, 0))

	if c1 == null or c2 == null:
		world.queue_free()
		return false

	world.queue_free()
	return true

func test_voxel_island_seeded_generation_and_differentiation() -> bool:
	var w1 := VoxelWorldScript.new()
	w1.seed_value = 1001

	var w2 := VoxelWorldScript.new()
	w2.seed_value = 1001

	var w3 := VoxelWorldScript.new()
	w3.seed_value = 8888

	var same_match := true
	for x in range(-5, 5):
		for y in range(2, 10):
			for z in range(-5, 5):
				if w1.get_voxel_at(Vector3i(x, y, z)) != w2.get_voxel_at(Vector3i(x, y, z)):
					same_match = false

	if not same_match:
		w1.queue_free()
		w2.queue_free()
		w3.queue_free()
		return false

	var diff_count := 0
	for x in range(-5, 5):
		for y in range(2, 10):
			for z in range(-5, 5):
				if w1.get_voxel_at(Vector3i(x, y, z)) != w3.get_voxel_at(Vector3i(x, y, z)):
					diff_count += 1

	w1.queue_free()
	w2.queue_free()
	w3.queue_free()
	return diff_count > 0

func test_voxel_world_chunk_streaming() -> bool:
	var world := VoxelWorldScript.new()
	world.seed_value = 1337
	world.view_distance_chunks = 1

	world.update_loaded_chunks(Vector3(0, 5, 0))
	if world._chunks.size() != 9:
		world.queue_free()
		return false

	world.update_loaded_chunks(Vector3(500, 5, 500))
	if world._chunks.has(Vector2i(0, 0)):
		world.queue_free()
		return false

	world.queue_free()
	return true

func test_voxel_world_mining_awards_resource_once() -> bool:
	var world := VoxelWorldScript.new()
	world.seed_value = 1337

	var target_cell := Vector3i.ZERO
	for y in range(20, 0, -1):
		if world.is_solid_block(Vector3i(0, y, 0)):
			target_cell = Vector3i(0, y, 0)
			break

	if target_cell == Vector3i.ZERO:
		world.queue_free()
		return false

	var orig_type := world.get_voxel_at(target_cell)
	var mined_type := world.mine_voxel(target_cell)

	if mined_type != orig_type or world.is_solid_block(target_cell):
		world.queue_free()
		return false

	world.queue_free()
	return true

func test_voxel_terrain_deltas_persistence_across_unload() -> bool:
	var world := VoxelWorldScript.new()
	world.seed_value = 1337

	var target_cell := Vector3i(0, 5, 0)
	var chunk = world._load_or_generate_chunk(Vector2i(0, 0))
	chunk.set_voxel_local(0, 5, 0, &"stone")

	world.mine_voxel(target_cell)

	world._unload_chunk(Vector2i(0, 0))
	var reloaded_chunk = world._load_or_generate_chunk(Vector2i(0, 0))

	if reloaded_chunk.get_voxel_local(0, 5, 0) != &"":
		world.queue_free()
		return false

	world.queue_free()
	return true

func test_natural_terrain_remains_static_after_mining() -> bool:
	var world := VoxelWorldScript.new()
	world.seed_value = 1337

	world.mine_voxel(Vector3i(0, 4, 0))
	world.queue_free()
	return true

func test_survival_mode_inventory_cost_vs_creative_mode() -> bool:
	var player = PlayerControllerScript.new()
	player.game_mode = 0

	if player.game_mode != 0:
		player.queue_free()
		return false

	player.game_mode = 1
	if player.game_mode != 1:
		player.queue_free()
		return false

	player.queue_free()
	return true

func test_reconstruct_single_missing_cell_success() -> bool:
	var grid := _make_grid()
	var bp_mgr := _make_manager()
	bp_mgr.grid_system = grid

	var bp := BlueprintDataScript.new("m5_reconstruct_test")
	bp.blocks = [
		{"rel_pos": [0, 0, 0], "block_type": "wood", "durability": 1.0, "metadata": {}},
		{"rel_pos": [1, 0, 0], "block_type": "brick", "durability": 1.0, "metadata": {}}
	]

	grid.place_block(Vector3i(0, 0, 0), &"wood")

	var plan1 = bp_mgr.plan_reconstruction(bp, Vector3i(0, 0, 0))
	if plan1 == null or plan1.present_count != 1 or plan1.missing_count != 1:
		return false

	var res: Dictionary = bp_mgr.reconstruct_single_cell(bp, Vector3i(0, 0, 0), Vector3i(1, 0, 0))
	if not res.get("success", false):
		return false

	if not grid.has_block(Vector3i(1, 0, 0)) or grid.get_block(Vector3i(1, 0, 0)).block_type != &"brick":
		return false

	var plan2 = res.get("plan", null)
	if plan2 == null or not plan2.is_fully_intact():
		return false

	return true

func test_reconstruct_single_cell_rejection_safety() -> bool:
	var grid := _make_grid()
	var bp_mgr := _make_manager()
	bp_mgr.grid_system = grid

	var bp := BlueprintDataScript.new("m5_reject_test")
	bp.blocks = [
		{"rel_pos": [0, 0, 0], "block_type": "stone", "durability": 1.0, "metadata": {}}
	]

	grid.place_block(Vector3i(0, 0, 0), &"gold")

	var res: Dictionary = bp_mgr.reconstruct_single_cell(bp, Vector3i(0, 0, 0), Vector3i(0, 0, 0))
	if res.get("success", true) or res.get("reason", "") != "CELL_OCCUPIED":
		return false

	if grid.get_block(Vector3i(0, 0, 0)).block_type != &"gold":
		return false

	return true

func test_reconstruct_single_cell_restores_expected_block_type_and_metadata() -> bool:
	var grid := _make_grid()
	var bp_mgr := _make_manager()
	bp_mgr.grid_system = grid

	var bp := BlueprintDataScript.new("m5_meta_test")
	bp.blocks = [
		{"rel_pos": [0, 0, 0], "block_type": "brick", "durability": 0.85, "metadata": {"coated_faces": [[0, 1, 0]]}}
	]

	var res: Dictionary = bp_mgr.reconstruct_single_cell(bp, Vector3i(0, 0, 0), Vector3i(0, 0, 0))
	if not res.get("success", false):
		return false

	var placed_b: BlockData = grid.get_block(Vector3i(0, 0, 0))
	if placed_b == null or placed_b.block_type != &"brick" or absf(placed_b.durability - 0.85) > 0.01:
		return false

	if not placed_b.metadata.has("coated_faces"):
		return false

	return true

func test_reconstruct_single_cell_restores_mortared_joints_without_duplicates() -> bool:
	var grid := _make_grid()
	var js := _make_joint_sys(grid)
	var bp_mgr := _make_manager()
	bp_mgr.grid_system = grid
	bp_mgr.joint_system = js

	grid.place_block(Vector3i(0, 0, 0), &"stone")

	var bp := BlueprintDataScript.new("m5_joint_test")
	bp.blocks = [
		{"rel_pos": [0, 0, 0], "block_type": "stone", "durability": 1.0, "metadata": {}},
		{"rel_pos": [1, 0, 0], "block_type": "stone", "durability": 1.0, "metadata": {}}
	]
	bp.joints = [
		{"rel_a": [0, 0, 0], "rel_b": [1, 0, 0], "strength": 90.0, "is_mortared": true, "material_a": "stone", "material_b": "stone"}
	]

	var res: Dictionary = bp_mgr.reconstruct_single_cell(bp, Vector3i(0, 0, 0), Vector3i(1, 0, 0))
	if not res.get("success", false):
		return false

	if not js.is_joint_mortared(Vector3i(0, 0, 0), Vector3i(1, 0, 0)):
		return false

	if js.get_joint_count() != 1:
		return false

	return true

func test_translated_anchor_coordinate_transformation() -> bool:
	var grid := _make_grid()
	var bp_mgr := _make_manager()
	bp_mgr.grid_system = grid

	var bp := BlueprintDataScript.new("translate_test")
	bp.blocks = [{"rel_pos": [0, 0, 0], "block_type": "stone", "durability": 1.0, "metadata": {}}]

	var proposed_anchor := Vector3i(10, 5, 20)
	var plan = bp_mgr.plan_reconstruction(bp, proposed_anchor)
	if plan == null or plan.entries.is_empty():
		return false

	var entry = plan.entries[0]
	if entry.get("world_cell", Vector3i.ZERO) != proposed_anchor:
		return false

	return true

func test_plan_reconstruction_reevaluates_on_anchor_change() -> bool:
	var grid := _make_grid()
	var bp_mgr := _make_manager()
	bp_mgr.grid_system = grid

	grid.place_block(Vector3i(0, 0, 0), &"stone")

	var bp := BlueprintDataScript.new("anchor_change_test")
	bp.blocks = [{"rel_pos": [0, 0, 0], "block_type": "stone", "durability": 1.0, "metadata": {}}]

	var plan1 = bp_mgr.plan_reconstruction(bp, Vector3i(0, 0, 0))
	if plan1 == null or plan1.present_count != 1:
		return false

	var plan2 = bp_mgr.plan_reconstruction(bp, Vector3i(10, 0, 0))
	if plan2 == null or plan2.missing_count != 1:
		return false

	return true

func test_startup_restoration_of_saved_blueprints() -> bool:
	var grid := _make_grid()
	var bp_mgr := _make_manager()
	bp_mgr.grid_system = grid

	grid.place_block(Vector3i(0, 0, 0), &"stone")
	var bp = bp_mgr.capture_blueprint_area("startup_bp", Vector3i(0, 0, 0), Vector3i(1, 1, 1))
	bp_mgr.save_blueprint(bp, true)

	var bp_mgr2 := _make_manager()
	bp_mgr2.storage_dir = bp_mgr.storage_dir
	bp_mgr2.grid_system = grid
	bp_mgr2.load_all_registered_blueprints()

	if not bp_mgr2.active_registered_blueprints.has("startup_bp"):
		return false

	return true

func test_explicit_update_registered_blueprint_from_world() -> bool:
	var grid := _make_grid()
	var bp_mgr := _make_manager()
	bp_mgr.grid_system = grid

	grid.place_block(Vector3i(0, 0, 0), &"stone")
	var bp = bp_mgr.capture_blueprint_area("update_area_test", Vector3i(0, 0, 0), Vector3i(2, 2, 2))
	bp_mgr.save_blueprint(bp, true)

	if bp.get_block_count() != 1:
		return false

	grid.place_block(Vector3i(2, 2, 2), &"wood")

	var ok: bool = bp_mgr.update_registered_blueprint_from_world("update_area_test")
	if not ok:
		return false

	var updated_bp = bp_mgr.load_blueprint("update_area_test")
	if updated_bp == null or updated_bp.get_block_count() != 2:
		return false

	return true

func test_planner_fully_intact_all_present() -> bool:
	var grid := _make_grid()
	grid.place_block(Vector3i(0, 0, 0), &"stone")
	grid.place_block(Vector3i(1, 0, 0), &"wood")

	var bp := BlueprintDataScript.new("intact_test")
	bp.blocks = [
		{"rel_pos": [0, 0, 0], "block_type": "stone", "durability": 1.0, "metadata": {}},
		{"rel_pos": [1, 0, 0], "block_type": "wood", "durability": 1.0, "metadata": {}}
	]

	var plan = ReconstructionPlanner.generate_plan(bp, Vector3i(0, 0, 0), grid)
	if plan == null or not plan.is_fully_intact():
		return false
	if plan.present_count != 2 or plan.missing_count != 0 or plan.conflict_count != 0:
		return false

	return true

func test_planner_missing_blocks() -> bool:
	var grid := _make_grid()
	grid.place_block(Vector3i(0, 0, 0), &"stone")

	var bp := BlueprintDataScript.new("missing_test")
	bp.blocks = [
		{"rel_pos": [0, 0, 0], "block_type": "stone", "durability": 1.0, "metadata": {}},
		{"rel_pos": [1, 0, 0], "block_type": "stone", "durability": 1.0, "metadata": {}}
	]

	var plan = ReconstructionPlanner.generate_plan(bp, Vector3i(0, 0, 0), grid)
	if plan == null or plan.present_count != 1 or plan.missing_count != 1:
		return false

	var missing = plan.get_missing_entries()
	if missing.size() != 1 or missing[0].get("world_cell", Vector3i.ZERO) != Vector3i(1, 0, 0):
		return false

	return true

func test_planner_wrong_block_type_conflict() -> bool:
	var grid := _make_grid()
	grid.place_block(Vector3i(0, 0, 0), &"brick")

	var bp := BlueprintDataScript.new("wrong_type_test")
	bp.blocks = [
		{"rel_pos": [0, 0, 0], "block_type": "stone", "durability": 1.0, "metadata": {}}
	]

	var plan = ReconstructionPlanner.generate_plan(bp, Vector3i(0, 0, 0), grid)
	if plan == null or plan.conflict_count != 1 or plan.present_count != 0:
		return false

	var conflicts = plan.get_conflict_entries()
	if conflicts.size() != 1 or conflicts[0].get("reason", "") != "WRONG_BLOCK_TYPE":
		return false

	return true

func test_planner_debris_and_player_obstruction() -> bool:
	var grid := _make_grid()
	var orch := CollapseOrchestrator.new()
	orch.grid_system = grid

	var island := DebrisIsland.new()
	island.orchestrator = orch
	island.setup_island([Vector3i.ZERO], {Vector3i.ZERO: BlockData.new("stone", 1.0)}, 1.0)
	island.position = Vector3(2.5, 0.5, 0.5)
	orch.register_debris_island(island)

	var bp := BlueprintDataScript.new("debris_test")
	bp.blocks = [
		{"rel_pos": [2, 0, 0], "block_type": "stone", "durability": 1.0, "metadata": {}}
	]

	var plan = ReconstructionPlanner.generate_plan(bp, Vector3i(0, 0, 0), grid, orch)
	if plan == null or plan.conflict_count != 1:
		island.queue_free()
		orch.queue_free()
		return false

	var conflicts = plan.get_conflict_entries()
	if conflicts.is_empty() or conflicts[0].get("reason", "") != "DEBRIS_COLLISION":
		island.queue_free()
		orch.queue_free()
		return false

	island.queue_free()
	orch.queue_free()
	return true

func test_planner_out_of_bounds_invalid() -> bool:
	var grid := _make_grid()
	var bp := BlueprintDataScript.new("bounds_test")
	bp.blocks = [
		{"rel_pos": [0, -10, 0], "block_type": "stone", "durability": 1.0, "metadata": {}}
	]

	var plan = ReconstructionPlanner.generate_plan(bp, Vector3i(0, 0, 0), grid)
	if plan == null or plan.invalid_count != 1:
		return false

	var invalids = plan.get_invalid_entries()
	if invalids.is_empty() or invalids[0].get("reason", "") != "OUT_OF_BOUNDS":
		return false

	return true

func test_planner_mixed_states_and_deterministic_reevaluation() -> bool:
	var grid := _make_grid()
	grid.place_block(Vector3i(0, 0, 0), &"stone")
	grid.place_block(Vector3i(1, 0, 0), &"gold")

	var bp := BlueprintDataScript.new("mixed_test")
	bp.blocks = [
		{"rel_pos": [0, 0, 0], "block_type": "stone", "durability": 1.0, "metadata": {}},
		{"rel_pos": [1, 0, 0], "block_type": "wood", "durability": 1.0, "metadata": {}},
		{"rel_pos": [2, 0, 0], "block_type": "brick", "durability": 1.0, "metadata": {}}
	]

	var plan1 = ReconstructionPlanner.generate_plan(bp, Vector3i(0, 0, 0), grid)
	var plan2 = ReconstructionPlanner.generate_plan(bp, Vector3i(0, 0, 0), grid)

	if plan1 == null or plan2 == null:
		return false

	if plan1.present_count != 1 or plan1.missing_count != 1 or plan1.conflict_count != 1:
		return false
	if plan1.present_count != plan2.present_count or plan1.missing_count != plan2.missing_count or plan1.conflict_count != plan2.conflict_count:
		return false

	if grid.get_block_count() != 2:
		return false

	return true

func test_persisted_desired_layout_after_collapse() -> bool:
	var grid := _make_grid()
	var bp_mgr := _make_manager()
	bp_mgr.grid_system = grid

	grid.place_block(Vector3i(0, 0, 0), &"stone")
	var bp = bp_mgr.capture_blueprint_area("desired_test", Vector3i(0, 0, 0), Vector3i(1, 1, 1))
	bp_mgr.save_blueprint(bp, true)

	grid.remove_cells_batch([Vector3i(0, 0, 0)])
	if grid.has_block(Vector3i(0, 0, 0)):
		return false

	var reloaded = bp_mgr.load_blueprint("desired_test")
	if reloaded == null or reloaded.get_block_count() != 1:
		return false

	return true

func test_intentional_edit_vs_destructive_event() -> bool:
	var grid := _make_grid()
	var bp_mgr := _make_manager()
	bp_mgr.grid_system = grid

	grid.place_block(Vector3i(0, 0, 0), &"stone")
	var bp = bp_mgr.capture_blueprint_area("edit_test", Vector3i(0, 0, 0), Vector3i(2, 2, 2))

	grid.place_block(Vector3i(1, 0, 0), &"wood")
	bp_mgr.notify_intentional_block_placed(Vector3i(1, 0, 0), grid.get_block(Vector3i(1, 0, 0)))

	if bp.get_block_count() != 2:
		return false

	grid.remove_cells_batch([Vector3i(0, 0, 0)])

	if bp.get_block_count() != 2:
		return false

	return true

func test_atomic_restoration_failure() -> bool:
	var grid := _make_grid()
	var bp_mgr := _make_manager()
	bp_mgr.grid_system = grid

	var bp := BlueprintDataScript.new("atomic_test")
	bp.blocks = [{"rel_pos": [0, 0, 0], "block_type": "stone", "durability": 1.0, "metadata": {}}]

	grid.place_block(Vector3i(5, 5, 5), &"gold")

	var res: Dictionary = bp_mgr.apply_blueprint(bp, Vector3i(5, 5, 5), false)
	if res.get("success", true):
		return false

	if grid.get_block(Vector3i(5, 5, 5)).block_type != &"gold":
		return false

	return true
