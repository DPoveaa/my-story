extends RefCounted

## Milestone 3 — Mortar Visuals + Block Durability + Recovery Classification
## Tests:
##   1.  Mortar overlay created for the coated face only.
##   2.  Overlay absent on uncoated faces of the same block.
##   3.  Overlay removed when the block is removed from the grid.
##   4.  Overlay removed via batch removal (collapse simulation).
##   5.  Overlay removed on grid_cleared.
##   6.  No duplicate overlays when coating the same face twice.
##   7.  Durability changes via existing GridSystem.apply_damage event.
##   8.  Recovery classification: above 50% -> block re-placed on grid.
##   9.  Recovery classification: exactly 50% -> raw material.
##   10. Recovery classification: below 50% -> raw material.
##   11. Durability preserved when block placed with BlockData object.
##   12. No duplicate blocks on grid recovery.
##   13. No duplicate raw-material rewards (second recover with nothing held).
##   14. Debris block durability reduced by apply_impact_damage.
##   15. Condition preserved: debris constituent_blocks carries original durability.
##   16. Brush consumption and joint-strength behaviour unchanged (regression).
##   17. Collapse behaviour unchanged (regression).
##   18. Grab / release signals still work (regression).
##   19. Soul Projection and raw_materials_changed signals still exist (regression).

var _passed: int = 0
var _failed: int = 0

const GridSystemScript = preload("res://autoloads/GridSystem.gd")
const JointSystemScript = preload("res://autoloads/JointSystem.gd")
const MortarOverlayScript = preload("res://systems/rendering/MortarOverlayRenderer.gd")
const DebrisIslandScript = preload("res://systems/collapse/DebrisIsland.gd")
const DebrisGrabberScript = preload("res://systems/interaction/DebrisGrabber.gd")
const PlayerControllerScript = preload("res://scenes/player/PlayerController.gd")

func run_all() -> bool:
	print("==================================================")
	print("RUNNING MILESTONE 3: MORTAR VISUALS + DURABILITY TESTS")
	print("==================================================")

	_run_test("test_overlay_created_on_coated_face",     Callable(self, "test_overlay_created_on_coated_face"))
	_run_test("test_overlay_absent_on_uncoated_faces",   Callable(self, "test_overlay_absent_on_uncoated_faces"))
	_run_test("test_overlay_removed_on_block_removal",   Callable(self, "test_overlay_removed_on_block_removal"))
	_run_test("test_overlay_removed_on_batch_removal",   Callable(self, "test_overlay_removed_on_batch_removal"))
	_run_test("test_overlay_removed_on_grid_cleared",    Callable(self, "test_overlay_removed_on_grid_cleared"))
	_run_test("test_no_duplicate_overlays",              Callable(self, "test_no_duplicate_overlays"))
	_run_test("test_durability_via_apply_damage",        Callable(self, "test_durability_via_apply_damage"))
	_run_test("test_recovery_above_threshold",           Callable(self, "test_recovery_above_threshold"))
	_run_test("test_recovery_at_threshold",              Callable(self, "test_recovery_at_threshold"))
	_run_test("test_recovery_below_threshold",           Callable(self, "test_recovery_below_threshold"))
	_run_test("test_durability_preserved_on_grid_place", Callable(self, "test_durability_preserved_on_grid_place"))
	_run_test("test_no_duplicate_blocks_on_recovery",    Callable(self, "test_no_duplicate_blocks_on_recovery"))
	_run_test("test_no_duplicate_raw_material_rewards",  Callable(self, "test_no_duplicate_raw_material_rewards"))
	_run_test("test_debris_durability_from_impact",      Callable(self, "test_debris_durability_from_impact"))
	_run_test("test_condition_preserved_in_debris",      Callable(self, "test_condition_preserved_in_debris"))
	_run_test("test_regression_brush_consumption",       Callable(self, "test_regression_brush_consumption"))
	_run_test("test_regression_collapse_no_duplicates",  Callable(self, "test_regression_collapse_no_duplicates"))
	_run_test("test_regression_grab_release_signals",    Callable(self, "test_regression_grab_release_signals"))
	_run_test("test_regression_soul_projection_signal",  Callable(self, "test_regression_soul_projection_signal"))
	_run_test("test_invalid_placement_rejects_and_preserves_held_debris_above_threshold", Callable(self, "test_invalid_placement_rejects_and_preserves_held_debris_above_threshold"))
	_run_test("test_invalid_placement_rejects_and_preserves_held_debris_below_threshold", Callable(self, "test_invalid_placement_rejects_and_preserves_held_debris_below_threshold"))
	_run_test("test_placement_never_converts_low_durability_debris_to_raw_material", Callable(self, "test_placement_never_converts_low_durability_debris_to_raw_material"))
	_run_test("test_valid_placement_places_reusable_debris_and_preserves_durability", Callable(self, "test_valid_placement_places_reusable_debris_and_preserves_durability"))
	_run_test("test_explicit_recovery_action_converts_low_durability_debris", Callable(self, "test_explicit_recovery_action_converts_low_durability_debris"))
	_run_test("test_explicit_recovery_action_fails_on_invalid_cell_for_reusable_debris", Callable(self, "test_explicit_recovery_action_fails_on_invalid_cell_for_reusable_debris"))
	_run_test("test_player_controller_place_action_with_held_debris_prevents_fallthrough", Callable(self, "test_player_controller_place_action_with_held_debris_prevents_fallthrough"))
	_run_test("test_configurable_recovery_durability_threshold", Callable(self, "test_configurable_recovery_durability_threshold"))
	_run_test("test_default_resolution_1920x1080_project_settings", Callable(self, "test_default_resolution_1920x1080_project_settings"))
	_run_test("test_hud_layout_anchors_and_centering", Callable(self, "test_hud_layout_anchors_and_centering"))

	print("==================================================")
	print("M3 TEST RESULTS: %d PASSED, %d FAILED" % [_passed, _failed])
	print("==================================================")
	return _failed == 0

func _run_test(name: String, callable: Callable) -> void:
	var result: bool = callable.call()
	if result:
		_passed += 1
		print("[PASS] " + name)
	else:
		_failed += 1
		printerr("[FAIL] " + name)

# ==============================================================================
# HELPERS
# ==============================================================================

func _make_grid() -> Node:
	return GridSystemScript.new()

func _make_joint_sys(gs: Node) -> Node:
	var js: Node = JointSystemScript.new()
	js.grid_system = gs
	return js

func _make_overlay(gs: Node, js: Node) -> Node:
	var ov: Node = MortarOverlayScript.new()
	ov.grid_system = gs
	ov.joint_system = js
	if not js.face_coated.is_connected(ov._on_face_coated):
		js.face_coated.connect(ov._on_face_coated)
	if not gs.block_removed.is_connected(ov._on_block_removed):
		gs.block_removed.connect(ov._on_block_removed)
	if not gs.blocks_removed_batch.is_connected(ov._on_blocks_removed_batch):
		gs.blocks_removed_batch.connect(ov._on_blocks_removed_batch)
	if not gs.grid_cleared.is_connected(ov._on_grid_cleared):
		gs.grid_cleared.connect(ov._on_grid_cleared)
	ov._build_mortar_material()
	return ov

func _make_island(cells: Array, block_data_map: Dictionary, cs: float = 1.0) -> Node:
	var island: Node = DebrisIslandScript.new()
	island.setup_island(cells, block_data_map, cs)
	return island

func _make_grabber(gs: Node) -> Node:
	var grabber: Node = DebrisGrabberScript.new()
	grabber.grid_system = gs
	return grabber

# ==============================================================================
# TEST 1 — Overlay created for the coated face only
# ==============================================================================
func test_overlay_created_on_coated_face() -> bool:
	var gs := _make_grid()
	var js := _make_joint_sys(gs)
	var ov := _make_overlay(gs, js)

	gs.place_block(Vector3i(0, 0, 0), &"stone")
	gs.place_block(Vector3i(1, 0, 0), &"stone")
	js.apply_mortar_brush(Vector3i(0, 0, 0), Vector3i(1, 0, 0))

	var ok: bool = ov.has_overlay(Vector3i(0, 0, 0), Vector3i(1, 0, 0))

	gs.free(); js.free(); ov.free()
	return ok

# ==============================================================================
# TEST 2 — Overlay absent on the other 5 faces of the same block
# ==============================================================================
func test_overlay_absent_on_uncoated_faces() -> bool:
	var gs := _make_grid()
	var js := _make_joint_sys(gs)
	var ov := _make_overlay(gs, js)

	gs.place_block(Vector3i(0, 0, 0), &"stone")
	gs.place_block(Vector3i(1, 0, 0), &"stone")
	js.apply_mortar_brush(Vector3i(0, 0, 0), Vector3i(1, 0, 0))

	var no_extra: bool = (
		not ov.has_overlay(Vector3i(0, 0, 0), Vector3i(-1, 0, 0)) and
		not ov.has_overlay(Vector3i(0, 0, 0), Vector3i(0, 1, 0)) and
		not ov.has_overlay(Vector3i(0, 0, 0), Vector3i(0, -1, 0)) and
		not ov.has_overlay(Vector3i(0, 0, 0), Vector3i(0, 0, 1)) and
		not ov.has_overlay(Vector3i(0, 0, 0), Vector3i(0, 0, -1))
	)

	gs.free(); js.free(); ov.free()
	return no_extra

# ==============================================================================
# TEST 3 — Overlay removed when block is removed from grid
# ==============================================================================
func test_overlay_removed_on_block_removal() -> bool:
	var gs := _make_grid()
	var js := _make_joint_sys(gs)
	var ov := _make_overlay(gs, js)

	gs.place_block(Vector3i(0, 0, 0), &"stone")
	gs.place_block(Vector3i(1, 0, 0), &"stone")
	js.apply_mortar_brush(Vector3i(0, 0, 0), Vector3i(1, 0, 0))
	var had_overlay: bool = ov.has_overlay(Vector3i(0, 0, 0), Vector3i(1, 0, 0))

	gs.remove_block(Vector3i(0, 0, 0))
	var overlay_gone: bool = not ov.has_overlay(Vector3i(0, 0, 0), Vector3i(1, 0, 0))

	gs.free(); js.free(); ov.free()
	return had_overlay and overlay_gone

# ==============================================================================
# TEST 4 — Overlay removed via batch removal (simulates collapse)
# ==============================================================================
func test_overlay_removed_on_batch_removal() -> bool:
	var gs := _make_grid()
	var js := _make_joint_sys(gs)
	var ov := _make_overlay(gs, js)

	gs.place_block(Vector3i(0, 0, 0), &"stone")
	gs.place_block(Vector3i(1, 0, 0), &"stone")
	js.apply_mortar_brush(Vector3i(0, 0, 0), Vector3i(1, 0, 0))
	var before: bool = ov.has_overlay(Vector3i(0, 0, 0), Vector3i(1, 0, 0))

	var cells: Array[Vector3i] = [Vector3i(0, 0, 0), Vector3i(1, 0, 0)]
	gs.remove_cells_batch(cells)
	var after: bool = ov.has_overlay(Vector3i(0, 0, 0), Vector3i(1, 0, 0))

	gs.free(); js.free(); ov.free()
	return before and not after

# ==============================================================================
# TEST 5 — Overlay removed on grid_cleared
# ==============================================================================
func test_overlay_removed_on_grid_cleared() -> bool:
	var gs := _make_grid()
	var js := _make_joint_sys(gs)
	var ov := _make_overlay(gs, js)

	gs.place_block(Vector3i(0, 0, 0), &"stone")
	gs.place_block(Vector3i(1, 0, 0), &"stone")
	js.apply_mortar_brush(Vector3i(0, 0, 0), Vector3i(1, 0, 0))
	var before_count: int = ov.get_overlay_count()

	gs.clear()
	var after_count: int = ov.get_overlay_count()

	gs.free(); js.free(); ov.free()
	return before_count > 0 and after_count == 0

# ==============================================================================
# TEST 6 — No duplicate overlays when coating the same face twice
# ==============================================================================
func test_no_duplicate_overlays() -> bool:
	var gs := _make_grid()
	var js := _make_joint_sys(gs)
	var ov := _make_overlay(gs, js)

	gs.place_block(Vector3i(0, 0, 0), &"stone")
	gs.place_block(Vector3i(1, 0, 0), &"stone")
	js.apply_mortar_brush(Vector3i(0, 0, 0), Vector3i(1, 0, 0))
	js.apply_mortar_brush(Vector3i(0, 0, 0), Vector3i(1, 0, 0))  # second call — duplicate guard

	var count: int = ov.get_overlay_count()

	gs.free(); js.free(); ov.free()
	return count == 1  # exactly one overlay for one face

# ==============================================================================
# TEST 7 — Durability changes via GridSystem.apply_damage
# ==============================================================================
func test_durability_via_apply_damage() -> bool:
	var gs := _make_grid()
	gs.place_block(Vector3i(0, 0, 0), &"stone")
	var data_before: BlockData = gs.get_block(Vector3i(0, 0, 0))
	var dur_before: float = data_before.durability  # 1.0

	gs.apply_damage(Vector3i(0, 0, 0), 0.3)
	var data_after: BlockData = gs.get_block(Vector3i(0, 0, 0))
	var dur_after: float = data_after.durability if data_after != null else 0.0

	gs.free()
	return dur_before > dur_after and absf(dur_after - 0.7) < 0.001

# ==============================================================================
# TEST 8 — Recovery above threshold: block re-placed on grid
# ==============================================================================
func test_recovery_above_threshold() -> bool:
	var gs := _make_grid()
	var grabber := _make_grabber(gs)

	# Durability 0.8 > 0.5 threshold
	var bd := BlockData.new(&"stone", 0.8)
	var island := _make_island([Vector3i.ZERO], {Vector3i.ZERO: bd})

	grabber._grabbed_island = island
	grabber._grabbed_cell = Vector3i.ZERO
	grabber._grabbed_data = bd
	grabber.is_grabbing = true
	grabber._recover_preview_cell = Vector3i(5, 0, 0)
	grabber._recover_preview_valid = true

	var result: bool = grabber.try_recover()
	var block_on_grid: bool = gs.has_block(Vector3i(5, 0, 0))

	gs.free(); grabber.free(); island.free()
	return result and block_on_grid

# ==============================================================================
# TEST 9 — Recovery exactly at threshold (0.5): raw material
# ==============================================================================
func test_recovery_at_threshold() -> bool:
	var gs := _make_grid()
	var grabber := _make_grabber(gs)

	var bd := BlockData.new(&"stone", 0.5)  # exactly at threshold
	var island := _make_island([Vector3i.ZERO], {Vector3i.ZERO: bd})

	grabber._grabbed_island = island
	grabber._grabbed_cell = Vector3i.ZERO
	grabber._grabbed_data = bd
	grabber.is_grabbing = true
	grabber._recover_preview_valid = false

	var raw_signal_fired := [false]
	grabber.recovered_as_raw_material.connect(func(_t, _a): raw_signal_fired[0] = true)

	var result: bool = grabber.try_recover()
	var nothing_on_grid: bool = gs.get_block_count() == 0

	gs.free(); grabber.free()
	if is_instance_valid(island):
		island.free()
	return result and raw_signal_fired[0] and nothing_on_grid

# ==============================================================================
# TEST 10 — Recovery below threshold (0.2): raw material
# ==============================================================================
func test_recovery_below_threshold() -> bool:
	var gs := _make_grid()
	var grabber := _make_grabber(gs)

	var bd := BlockData.new(&"stone", 0.2)
	var island := _make_island([Vector3i.ZERO], {Vector3i.ZERO: bd})

	grabber._grabbed_island = island
	grabber._grabbed_cell = Vector3i.ZERO
	grabber._grabbed_data = bd
	grabber.is_grabbing = true
	grabber._recover_preview_valid = false

	var raw_type_received := [&""]
	grabber.recovered_as_raw_material.connect(func(t, _a): raw_type_received[0] = t)

	var result: bool = grabber.try_recover()

	gs.free(); grabber.free()
	if is_instance_valid(island):
		island.free()
	return result and raw_type_received[0] == &"stone"

# ==============================================================================
# TEST 11 — Durability preserved when recovering block above threshold
# ==============================================================================
func test_durability_preserved_on_grid_place() -> bool:
	var gs := _make_grid()
	var grabber := _make_grabber(gs)

	var bd := BlockData.new(&"stone", 0.75)
	var island := _make_island([Vector3i.ZERO], {Vector3i.ZERO: bd})

	grabber._grabbed_island = island
	grabber._grabbed_cell = Vector3i.ZERO
	grabber._grabbed_data = bd
	grabber.is_grabbing = true
	grabber._recover_preview_cell = Vector3i(3, 0, 0)
	grabber._recover_preview_valid = true

	grabber.try_recover()
	var recovered_data: BlockData = gs.get_block(Vector3i(3, 0, 0))
	var ok: bool = recovered_data != null and absf(recovered_data.durability - 0.75) < 0.001

	gs.free(); grabber.free()
	if is_instance_valid(island):
		island.free()
	return ok

# ==============================================================================
# TEST 12 — No duplicate blocks on grid recovery
# ==============================================================================
func test_no_duplicate_blocks_on_recovery() -> bool:
	var gs := _make_grid()
	var grabber := _make_grabber(gs)

	var bd := BlockData.new(&"stone", 0.9)
	var island := _make_island([Vector3i.ZERO], {Vector3i.ZERO: bd})

	grabber._grabbed_island = island
	grabber._grabbed_cell = Vector3i.ZERO
	grabber._grabbed_data = bd
	grabber.is_grabbing = true
	grabber._recover_preview_cell = Vector3i(7, 0, 0)
	grabber._recover_preview_valid = true

	grabber.try_recover()
	var grid_count: int = gs.get_block_count()
	var debris_count: int = island.constituent_blocks.size() if is_instance_valid(island) else 0

	gs.free(); grabber.free()
	if is_instance_valid(island):
		island.free()
	return grid_count == 1 and debris_count == 0

# ==============================================================================
# TEST 13 — No duplicate raw-material rewards (second try_recover with nothing held)
# ==============================================================================
func test_no_duplicate_raw_material_rewards() -> bool:
	var gs := _make_grid()
	var grabber := _make_grabber(gs)

	var bd := BlockData.new(&"stone", 0.1)
	var island := _make_island([Vector3i.ZERO], {Vector3i.ZERO: bd})

	grabber._grabbed_island = island
	grabber._grabbed_cell = Vector3i.ZERO
	grabber._grabbed_data = bd
	grabber.is_grabbing = true
	grabber._recover_preview_valid = false

	var raw_count := [0]
	grabber.recovered_as_raw_material.connect(func(_t, _a): raw_count[0] += 1)

	grabber.try_recover()   # first - fires signal once
	grabber.try_recover()   # second - nothing held, should fail silently

	gs.free(); grabber.free()
	if is_instance_valid(island):
		island.free()
	return raw_count[0] == 1

# ==============================================================================
# TEST 14 — Debris block durability reduced by apply_impact_damage
# ==============================================================================
func test_debris_durability_from_impact() -> bool:
	var bd := BlockData.new(&"stone", 1.0)
	var island := _make_island([Vector3i.ZERO], {Vector3i.ZERO: bd})

	var dur_before: float = island.constituent_blocks[Vector3i.ZERO].durability
	island.apply_impact_damage(Vector3i.ZERO, 120.0)
	var dur_after: float = island.constituent_blocks[Vector3i.ZERO].durability

	island.free()
	return dur_after < dur_before

# ==============================================================================
# TEST 15 — Condition preserved: debris constituent_blocks carries original durability
# ==============================================================================
func test_condition_preserved_in_debris() -> bool:
	var bd := BlockData.new(&"wood", 0.7)
	var island := _make_island([Vector3i.ZERO], {Vector3i.ZERO: bd})
	var stored_dur: float = island.constituent_blocks[Vector3i.ZERO].durability

	island.free()
	return absf(stored_dur - 0.7) < 0.001

# ==============================================================================
# TEST 16 — Regression: brush consumption and joint-strength unchanged
# ==============================================================================
func test_regression_brush_consumption() -> bool:
	var gs := _make_grid()
	var js := _make_joint_sys(gs)

	gs.place_block(Vector3i(0, 0, 0), &"stone")
	gs.place_block(Vector3i(0, 1, 0), &"stone")

	# Painting +Z face reinforces orthogonal neighbors in the +Z surface, including (0, 1, 0)
	var res1: Dictionary = js.apply_mortar_brush(Vector3i(0, 0, 0), Vector3i(0, 0, 1))
	var consumed1: bool = res1.get("consumed", false)
	var res2: Dictionary = js.apply_mortar_brush(Vector3i(0, 0, 0), Vector3i(0, 0, 1))
	var already_coated: bool = res2.get("already_coated", false)

	var j = js.get_joint(Vector3i(0, 0, 0), Vector3i(0, 1, 0))
	var strength_ok: bool = j != null and j.max_strength > js.default_joint_strength

	gs.free(); js.free()
	return consumed1 and already_coated and strength_ok

# ==============================================================================
# TEST 17 — Regression: collapse removes cells from grid without duplicates
# ==============================================================================
func test_regression_collapse_no_duplicates() -> bool:
	var gs := _make_grid()
	gs.place_block(Vector3i(0, 3, 0), &"stone")
	gs.place_block(Vector3i(1, 3, 0), &"stone")

	var before: int = gs.get_block_count()
	var cells: Array[Vector3i] = [Vector3i(0, 3, 0), Vector3i(1, 3, 0)]
	var removed: Dictionary = gs.remove_cells_batch(cells)
	var after: int = gs.get_block_count()

	gs.free()
	return before == 2 and after == 0 and removed.size() == 2

# ==============================================================================
# TEST 18 — Regression: grab / release signals still work
# ==============================================================================
func test_regression_grab_release_signals() -> bool:
	var gs := _make_grid()
	var grabber := _make_grabber(gs)

	var grabbed_fired := [false]
	var released_fired := [false]
	grabber.grabbed_block.connect(func(_i, _c, _d): grabbed_fired[0] = true)
	grabber.released_block.connect(func(): released_fired[0] = true)

	var bd := BlockData.new(&"stone", 1.0)
	var island := _make_island([Vector3i.ZERO], {Vector3i.ZERO: bd})

	grabber._grabbed_island = island
	grabber._grabbed_cell = Vector3i.ZERO
	grabber._grabbed_data = bd
	grabber.is_grabbing = true
	grabber.grabbed_block.emit(island, Vector3i.ZERO, bd)

	grabber.release()

	if is_instance_valid(island):
		island.free()
	gs.free(); grabber.free()
	return grabbed_fired[0] and released_fired[0]

# ==============================================================================
# TEST 19 — Regression: Soul Projection and raw_materials_changed signals exist
# ==============================================================================
func test_regression_soul_projection_signal() -> bool:
	var pc: Node = PlayerControllerScript.new()
	var has_state_changed: bool = pc.has_signal("state_changed")
	var has_raw_mat: bool = pc.has_signal("raw_materials_changed")
	pc.free()
	return has_state_changed and has_raw_mat

# ==============================================================================
# TEST 20 — Invalid placement rejects and preserves held debris (> 50% durability)
# ==============================================================================
func test_invalid_placement_rejects_and_preserves_held_debris_above_threshold() -> bool:
	var gs := _make_grid()
	var grabber := _make_grabber(gs)

	var bd := BlockData.new(&"stone", 0.85)
	var island := _make_island([Vector3i.ZERO], {Vector3i.ZERO: bd})

	grabber._grabbed_island = island
	grabber._grabbed_cell = Vector3i.ZERO
	grabber._grabbed_data = bd
	grabber.is_grabbing = true
	grabber._recover_preview_cell = Vector3i(1, 0, 0)
	grabber._recover_preview_valid = false # Target position is INVALID

	var raw_fired := [false]
	grabber.recovered_as_raw_material.connect(func(_t, _a): raw_fired[0] = true)

	var result: bool = grabber.try_place_to_grid()

	var ok: bool = (
		result == false and
		grabber.is_grabbing == true and
		grabber._grabbed_island == island and
		grabber._grabbed_data == bd and
		absf(bd.durability - 0.85) < 0.001 and
		gs.get_block_count() == 0 and
		raw_fired[0] == false
	)

	gs.free(); grabber.free(); island.free()
	return ok

# ==============================================================================
# TEST 21 — Invalid placement rejects and preserves held debris (<= 50% durability)
# ==============================================================================
func test_invalid_placement_rejects_and_preserves_held_debris_below_threshold() -> bool:
	var gs := _make_grid()
	var grabber := _make_grabber(gs)

	# Low durability debris: <= 0.5 threshold
	var bd := BlockData.new(&"stone", 0.35)
	var island := _make_island([Vector3i.ZERO], {Vector3i.ZERO: bd})

	grabber._grabbed_island = island
	grabber._grabbed_cell = Vector3i.ZERO
	grabber._grabbed_data = bd
	grabber.is_grabbing = true
	grabber._recover_preview_cell = Vector3i(2, 0, 0)
	grabber._recover_preview_valid = false # INVALID region

	var raw_fired := [false]
	grabber.recovered_as_raw_material.connect(func(_t, _a): raw_fired[0] = true)

	var result: bool = grabber.try_place_to_grid()

	# Must reject WITHOUT converting into raw:stone or modifying held debris
	var ok: bool = (
		result == false and
		grabber.is_grabbing == true and
		grabber._grabbed_island == island and
		grabber._grabbed_data == bd and
		absf(bd.durability - 0.35) < 0.001 and
		gs.get_block_count() == 0 and
		raw_fired[0] == false # NOT converted to raw materials!
	)

	gs.free(); grabber.free(); island.free()
	return ok

# ==============================================================================
# TEST 22 — Placement path NEVER converts low durability debris to raw material
# ==============================================================================
func test_placement_never_converts_low_durability_debris_to_raw_material() -> bool:
	var gs := _make_grid()
	var grabber := _make_grabber(gs)

	var bd := BlockData.new(&"stone", 0.40)
	var island := _make_island([Vector3i.ZERO], {Vector3i.ZERO: bd})

	grabber._grabbed_island = island
	grabber._grabbed_cell = Vector3i.ZERO
	grabber._grabbed_data = bd
	grabber.is_grabbing = true
	grabber._recover_preview_cell = Vector3i(3, 0, 0)
	grabber._recover_preview_valid = true # Cell technically open, but block is damaged

	var raw_fired := [false]
	grabber.recovered_as_raw_material.connect(func(_t, _a): raw_fired[0] = true)

	var result: bool = grabber.try_place_to_grid()

	# try_place_to_grid must reject placement and MUST NOT trigger raw material conversion
	var ok: bool = (
		result == false and
		grabber.is_grabbing == true and
		grabber._grabbed_data == bd and
		absf(bd.durability - 0.40) < 0.001 and
		raw_fired[0] == false and
		gs.get_block_count() == 0
	)

	gs.free(); grabber.free(); island.free()
	return ok

# ==============================================================================
# TEST 23 — Valid placement places reusable debris and preserves durability
# ==============================================================================
func test_valid_placement_places_reusable_debris_and_preserves_durability() -> bool:
	var gs := _make_grid()
	var grabber := _make_grabber(gs)

	var bd := BlockData.new(&"stone", 0.72)
	var island := _make_island([Vector3i.ZERO], {Vector3i.ZERO: bd})

	grabber._grabbed_island = island
	grabber._grabbed_cell = Vector3i.ZERO
	grabber._grabbed_data = bd
	grabber.is_grabbing = true
	grabber._recover_preview_cell = Vector3i(4, 0, 0)
	grabber._recover_preview_valid = true

	var raw_fired := [false]
	grabber.recovered_as_raw_material.connect(func(_t, _a): raw_fired[0] = true)

	var result: bool = grabber.try_place_to_grid()
	var grid_data: BlockData = gs.get_block(Vector3i(4, 0, 0))

	var ok: bool = (
		result == true and
		grid_data != null and
		absf(grid_data.durability - 0.72) < 0.001 and
		grid_data.block_type == &"stone" and
		grabber.is_grabbing == false and
		raw_fired[0] == false
	)

	gs.free(); grabber.free(); island.free()
	return ok

# ==============================================================================
# TEST 24 — Explicit recovery action converts low durability debris to raw material
# ==============================================================================
func test_explicit_recovery_action_converts_low_durability_debris() -> bool:
	var gs := _make_grid()
	var grabber := _make_grabber(gs)

	var bd := BlockData.new(&"brick", 0.30)
	var island := _make_island([Vector3i.ZERO], {Vector3i.ZERO: bd})

	grabber._grabbed_island = island
	grabber._grabbed_cell = Vector3i.ZERO
	grabber._grabbed_data = bd
	grabber.is_grabbing = true
	grabber._recover_preview_valid = false

	var raw_type := [&""]
	var raw_amount := [0]
	grabber.recovered_as_raw_material.connect(func(t, a): raw_type[0] = t; raw_amount[0] = a)

	# Explicit recovery (R key)
	var result: bool = grabber.try_recover()

	var ok: bool = (
		result == true and
		raw_type[0] == &"brick" and
		raw_amount[0] == 1 and
		grabber.is_grabbing == false and
		gs.get_block_count() == 0
	)

	gs.free(); grabber.free()
	if is_instance_valid(island):
		island.free()
	return ok

# ==============================================================================
# TEST 25 — Explicit recovery action fails on invalid cell for reusable debris
# ==============================================================================
func test_explicit_recovery_action_fails_on_invalid_cell_for_reusable_debris() -> bool:
	var gs := _make_grid()
	var grabber := _make_grabber(gs)

	var bd := BlockData.new(&"wood", 0.80)
	var island := _make_island([Vector3i.ZERO], {Vector3i.ZERO: bd})

	grabber._grabbed_island = island
	grabber._grabbed_cell = Vector3i.ZERO
	grabber._grabbed_data = bd
	grabber.is_grabbing = true
	grabber._recover_preview_valid = false # Invalid cell

	var fail_fired := [false]
	grabber.recover_failed.connect(func(_r): fail_fired[0] = true)

	var result: bool = grabber.try_recover()

	var ok: bool = (
		result == false and
		fail_fired[0] == true and
		grabber.is_grabbing == true and
		absf(bd.durability - 0.80) < 0.001 and
		gs.get_block_count() == 0
	)

	gs.free(); grabber.free(); island.free()
	return ok

# ==============================================================================
# TEST 26 — PlayerController place action with held debris prevents fallthrough
# ==============================================================================
func test_player_controller_place_action_with_held_debris_prevents_fallthrough() -> bool:
	var gs := _make_grid()
	var player: PlayerController = PlayerControllerScript.new()
	player.grid_system = gs
	var grabber: DebrisGrabber = player.get_node_or_null("DebrisGrabber")
	if grabber == null:
		grabber = DebrisGrabberScript.new()
		player.add_child(grabber)
		player.debris_grabber = grabber
		grabber.grid_system = gs

	var bd := BlockData.new(&"stone", 0.45)
	var island := _make_island([Vector3i.ZERO], {Vector3i.ZERO: bd})

	grabber._grabbed_island = island
	grabber._grabbed_cell = Vector3i.ZERO
	grabber._grabbed_data = bd
	grabber.is_grabbing = true
	grabber._recover_preview_valid = false

	# Setup player target state as if pointing at an empty cell
	player.has_target = true
	player.can_place_target = true
	player.target_place_cell = Vector3i(10, 0, 0)

	# Execute place action
	player._handle_place_action()

	# Grid must NOT receive a newly placed block from the player's toolbar
	var ok: bool = (
		gs.get_block_count() == 0 and
		grabber.is_grabbing == true and
		grabber._grabbed_data == bd and
		absf(bd.durability - 0.45) < 0.001
	)

	gs.free(); player.free(); island.free()
	return ok

# ==============================================================================
# TEST 27 — Configurable recovery durability threshold
# ==============================================================================
func test_configurable_recovery_durability_threshold() -> bool:
	var gs := _make_grid()
	var grabber := _make_grabber(gs)

	var bd := BlockData.new(&"stone", 0.60)
	var island := _make_island([Vector3i.ZERO], {Vector3i.ZERO: bd})

	grabber._grabbed_island = island
	grabber._grabbed_cell = Vector3i.ZERO
	grabber._grabbed_data = bd
	grabber.is_grabbing = true

	# Default threshold 0.5: 0.60 > 0.5 is reusable
	var check1: bool = grabber.is_grabbed_block_reusable() == true

	# Change threshold to 0.70: 0.60 <= 0.70 is now raw material
	grabber.recovery_durability_threshold = 0.70
	var check2: bool = grabber.is_grabbed_block_reusable() == false

	# Change threshold to 0.20: 0.60 > 0.20 is reusable
	grabber.recovery_durability_threshold = 0.20
	var check3: bool = grabber.is_grabbed_block_reusable() == true

	gs.free(); grabber.free(); island.free()
	return check1 and check2 and check3

# ==============================================================================
# TEST 28 — Default resolution is 1920x1080 and resizable in project settings
# ==============================================================================
func test_default_resolution_1920x1080_project_settings() -> bool:
	var w: int = int(ProjectSettings.get_setting("display/window/size/viewport_width", 0))
	var h: int = int(ProjectSettings.get_setting("display/window/size/viewport_height", 0))
	var resizable: bool = bool(ProjectSettings.get_setting("display/window/size/resizable", false))
	return w == 1920 and h == 1080 and resizable == true

# ==============================================================================
# TEST 29 — HUD layout anchors and centering for 1920x1080
# ==============================================================================
func test_hud_layout_anchors_and_centering() -> bool:
	var hud_scene = load("res://scenes/ui/BuildHUD.tscn")
	if hud_scene == null:
		return false
	var hud = hud_scene.instantiate()
	if hud == null:
		return false

	var crosshair: Control = hud.get_node_or_null("Crosshair")
	var panel_top: Control = hud.get_node_or_null("PanelTop")
	var panel_ctrl: Control = hud.get_node_or_null("PanelControls")

	var ok: bool = (
		crosshair != null and
		crosshair.anchor_left == 0.5 and
		crosshair.anchor_top == 0.5 and
		crosshair.anchor_right == 0.5 and
		crosshair.anchor_bottom == 0.5 and
		panel_top != null and
		panel_top.anchor_right == 1.0 and
		panel_ctrl != null and
		panel_ctrl.anchor_top == 1.0 and
		panel_ctrl.anchor_bottom == 1.0
	)

	hud.free()
	return ok

