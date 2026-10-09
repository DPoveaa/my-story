## Blueprint system automated tests (Milestone 4).
## Tests: BlueprintData serialization, BlueprintManager capture/save/load/list/delete/validate/apply,
##        invalid placement rejection, joint/mortar restoration, and mortar persistence on debris.
extends RefCounted

const BlueprintDataScript = preload("res://data/BlueprintData.gd")
const DebrisIslandScript = preload("res://systems/collapse/DebrisIsland.gd")
const BuildHUDScript = preload("res://scenes/ui/BuildHUD.gd")
const PlayerControllerScript = preload("res://scenes/player/PlayerController.gd")

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
	_run_test("test_durability_damage_updates_block_and_destroys_at_zero")
	_run_test("test_blueprint_save_requires_overwrite_confirmation")
	_run_test("test_mortar_coated_debris_ground_placement")
	_run_test("test_hud_modal_created_in_scene_tree")

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

func test_durability_damage_updates_block_and_destroys_at_zero() -> bool:
	var grid := _make_grid()
	var joint_sys = JointSystemScript.new()
	joint_sys.grid_system = grid

	grid.place_block(Vector3i(0, 0, 0), &"stone")
	var b: BlockData = grid.get_block(Vector3i(0, 0, 0))
	if b == null or absf(b.durability - 1.0) > 0.001:
		joint_sys.queue_free()
		return false

	# Light impact (< 8.0 J) causes 0 damage (bump immunity)
	joint_sys.apply_impact_to_block_joints(Vector3i(0, 0, 0), 5.0)
	if absf(b.durability - 1.0) > 0.001:
		joint_sys.queue_free()
		return false

	# Moderate impact (20 J) causes small durability reduction
	joint_sys.apply_impact_to_block_joints(Vector3i(0, 0, 0), 20.0)
	var expected_dur: float = 1.0 - (20.0 / 200.0) # 0.90
	if absf(b.durability - expected_dur) > 0.01:
		joint_sys.queue_free()
		return false

	# Heavy repeated damage eventually destroys block
	grid.apply_damage(Vector3i(0, 0, 0), 0.95)
	if grid.has_block(Vector3i(0, 0, 0)):
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
	var bp_mgr = _make_mgr(grid)
	hud.blueprint_manager = bp_mgr

	hud.open_save_blueprint_dialog()
	hud._save_name_input.text = "overwrite_test"

	# First save creates the blueprint
	hud._on_save_confirm_pressed()
	if not bp_mgr.has_blueprint("overwrite_test"):
		hud.queue_free()
		return false

	# Re-open save dialog and try to save again with same name
	hud.open_save_blueprint_dialog()
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
