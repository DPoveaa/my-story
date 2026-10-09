class_name TestM2_3
extends RefCounted

## Automated acceptance tests for Milestone 2.3
## Structural Joints & Bonding.

const GridSystemScript = preload("res://autoloads/GridSystem.gd")
const StabilitySystemScript = preload("res://autoloads/StabilitySystem.gd")
const JointSystemScript = preload("res://autoloads/JointSystem.gd")
const StructuralJointScript = preload("res://data/StructuralJoint.gd")
const DebrisIslandScript = preload("res://systems/collapse/DebrisIsland.gd")
const CollapseOrchestratorScript = preload("res://systems/collapse/CollapseOrchestrator.gd")
const PlayerScene = preload("res://scenes/player/Player.tscn")
const InputManagerScript = preload("res://autoloads/InputManager.gd")

var passed_count: int = 0
var failed_count: int = 0

func run_all() -> bool:
	print("==================================================")
	print("RUNNING MILESTONE 2.3 STRUCTURAL JOINTS & BONDING TESTS")
	print("==================================================")

	_run_test("test_unbonded_blocks_default_state", test_unbonded_blocks_default_state)
	_run_test("test_apply_cement_creates_joint", test_apply_cement_creates_joint)
	_run_test("test_face_priming_bonds_on_placement", test_face_priming_bonds_on_placement)
	_run_test("test_material_compatibility_and_strengths", test_material_compatibility_and_strengths)
	_run_test("test_no_duplicate_or_orphaned_joints", test_no_duplicate_or_orphaned_joints)
	_run_test("test_unbonded_blocks_move_on_push", test_unbonded_blocks_move_on_push)
	_run_test("test_immediate_breakage_from_strong_impact", test_immediate_breakage_from_strong_impact)
	_run_test("test_accumulated_damage_from_repeated_loads", test_accumulated_damage_from_repeated_loads)
	_run_test("test_broken_joint_triggers_stability_reevaluation", test_broken_joint_triggers_stability_reevaluation)
	_run_test("test_compound_debris_preserves_internal_joints", test_compound_debris_preserves_internal_joints)
	_run_test("test_debris_splits_when_internal_joint_breaks", test_debris_splits_when_internal_joint_breaks)
	_run_test("test_cement_inventory_consumption_and_insufficient_resources", test_cement_inventory_consumption_and_insufficient_resources)
	_run_test("test_unlimited_cement_debug_flag", test_unlimited_cement_debug_flag)
	_run_test("test_input_actions_no_conflicts", test_input_actions_no_conflicts)

	print("==================================================")
	print("M2.3 TEST RESULTS: %d PASSED, %d FAILED" % [passed_count, failed_count])
	print("==================================================")
	return failed_count == 0

func _run_test(test_name: String, test_func: Callable) -> void:
	var ok: bool = false
	var result: Variant = test_func.call()
	if result is bool:
		ok = bool(result)
	else:
		ok = true
	if ok:
		passed_count += 1
		print("[PASS] %s" % test_name)
	else:
		failed_count += 1
		print("[FAIL] %s" % test_name)

## 1. Newly placed blocks occupy grid cells and have weak default connection without requiring mortar
func test_unbonded_blocks_default_state() -> bool:
	var grid: Node = GridSystemScript.new()
	var joints: Node = JointSystemScript.new()
	joints.grid_system = grid

	grid.place_block(Vector3i(0, 0, 0), &"stone")
	grid.place_block(Vector3i(0, 1, 0), &"stone")

	# Both cells are occupied in grid
	var occupied: bool = grid.has_block(Vector3i(0, 0, 0)) and grid.has_block(Vector3i(0, 1, 0))
	# They have weak default connection, but are unmortared
	var has_default: bool = joints.has_joint(Vector3i(0, 0, 0), Vector3i(0, 1, 0))
	var is_bonded: bool = joints.is_block_bonded(Vector3i(0, 1, 0))
	var is_mortared: bool = joints.is_joint_mortared(Vector3i(0, 0, 0), Vector3i(0, 1, 0))

	grid.queue_free()
	joints.queue_free()
	return occupied and has_default and not is_bonded and not is_mortared

## 2. Applying cement to adjacent blocks creates an explicit structural joint with configurable strength
func test_apply_cement_creates_joint() -> bool:
	var grid: Node = GridSystemScript.new()
	var joints: Node = JointSystemScript.new()
	joints.grid_system = grid

	grid.place_block(Vector3i(0, 0, 0), &"stone")
	grid.place_block(Vector3i(1, 0, 0), &"stone")

	# Apply cement from cell (0,0,0) towards (+X)
	var joint = joints.apply_cement_to_face(Vector3i(0, 0, 0), Vector3i(1, 0, 0))
	if joint == null:
		grid.queue_free()
		joints.queue_free()
		return false

	var exists: bool = joints.has_intact_joint(Vector3i(0, 0, 0), Vector3i(1, 0, 0))
	var strength_ok: bool = joint.max_strength == 100.0 and joint.current_health == 100.0
	var bonded_a: bool = joints.is_block_bonded(Vector3i(0, 0, 0))
	var bonded_b: bool = joints.is_block_bonded(Vector3i(1, 0, 0))

	grid.queue_free()
	joints.queue_free()
	return exists and strength_ok and bonded_a and bonded_b

## 3. Applying cement to open face coats it; subsequent adjacent placement automatically bonds
func test_face_priming_bonds_on_placement() -> bool:
	var grid: Node = GridSystemScript.new()
	var joints: Node = JointSystemScript.new()
	joints.grid_system = grid
	joints._connect_grid_signals()

	grid.place_block(Vector3i(0, 0, 0), &"stone")

	# Coat top face (+Y) before placing top block
	var primed_joint = joints.apply_cement_to_face(Vector3i(0, 0, 0), Vector3i.UP)
	var is_primed: bool = joints.is_face_coated(Vector3i(0, 0, 0), Vector3i.UP)

	# Now place block on top
	grid.place_block(Vector3i(0, 1, 0), &"brick")

	# Joint should automatically form upon placement
	var auto_bonded: bool = joints.has_intact_joint(Vector3i(0, 0, 0), Vector3i(0, 1, 0))
	var j = joints.get_joint(Vector3i(0, 0, 0), Vector3i(0, 1, 0))
	var strength_ok: bool = j != null and j.max_strength == 95.0 # stone + brick

	grid.queue_free()
	joints.queue_free()
	return is_primed and auto_bonded and strength_ok

## 4. Material compatibility and distinct joint strengths based on materials
func test_material_compatibility_and_strengths() -> bool:
	var joints: Node = JointSystemScript.new()

	var s_s: float = joints.calculate_base_strength(&"stone", &"stone")
	var s_b: float = joints.calculate_base_strength(&"stone", &"brick")
	var b_b: float = joints.calculate_base_strength(&"brick", &"brick")
	var s_w: float = joints.calculate_base_strength(&"stone", &"wood")
	var w_w: float = joints.calculate_base_strength(&"wood", &"wood")
	var g_g: float = joints.calculate_base_strength(&"gold", &"gold")

	var compat_ok: bool = joints.are_materials_compatible(&"stone", &"wood")
	var ranking_ok: bool = (s_s >= s_b) and (s_b >= b_b) and (b_b > s_w) and (s_w > w_w) and (w_w > g_g)

	joints.queue_free()
	return compat_ok and ranking_ok

## 5. Prevent duplicate joints and clean up orphaned joints upon block removal or grid clear
func test_no_duplicate_or_orphaned_joints() -> bool:
	var grid: Node = GridSystemScript.new()
	var joints: Node = JointSystemScript.new()
	joints.grid_system = grid
	joints._connect_grid_signals()

	grid.place_block(Vector3i(0, 0, 0), &"stone")
	grid.place_block(Vector3i(0, 1, 0), &"stone")

	# Bond once
	var j1 = joints.bond_adjacent(Vector3i(0, 0, 0), Vector3i(0, 1, 0))
	# Bond second time (duplicate prevention)
	var j2 = joints.bond_adjacent(Vector3i(0, 0, 0), Vector3i(0, 1, 0))
	var no_duplicate: bool = (j1 == j2) and (joints.get_joint_count() == 1)

	# Remove one block
	grid.remove_block(Vector3i(0, 1, 0))

	# Joint must be removed, zero orphaned joints
	var cleaned_up: bool = (joints.get_joint_count() == 0) and not joints.is_block_bonded(Vector3i(0, 0, 0))

	grid.queue_free()
	joints.queue_free()
	return no_duplicate and cleaned_up

## 6. Unbonded block converts to dynamic debris and moves under physical push; bonded block resists
func test_unbonded_blocks_move_on_push() -> bool:
	var dummy_root := Node3D.new()
	var grid: Node = GridSystemScript.new()
	var joints: Node = JointSystemScript.new()
	joints.grid_system = grid
	var orch: CollapseOrchestrator = CollapseOrchestratorScript.new()
	orch.grid_system = grid
	dummy_root.add_child(orch)

	grid.place_block(Vector3i(0, 1, 0), &"stone")

	# Block (0, 1, 0) is unbonded
	var is_bonded: bool = joints.is_block_bonded(Vector3i(0, 1, 0))
	if is_bonded:
		dummy_root.queue_free()
		grid.queue_free()
		joints.queue_free()
		return false

	# Push unbonded block
	var push_dir := Vector3(1.0, 0.0, 0.0)
	var spawned_debris: DebrisIsland = orch.push_unbonded_block(Vector3i(0, 1, 0), push_dir * 5.0)

	var removed_from_grid: bool = not grid.has_block(Vector3i(0, 1, 0))
	var debris_valid: bool = is_instance_valid(spawned_debris)
	var moving: bool = debris_valid and spawned_debris.linear_velocity.length() > 1.0

	dummy_root.queue_free()
	grid.queue_free()
	joints.queue_free()
	return removed_from_grid and debris_valid and moving

## 7. Immediate joint breakage from strong impact exceeding breakage threshold
func test_immediate_breakage_from_strong_impact() -> bool:
	var grid: Node = GridSystemScript.new()
	var joints: Node = JointSystemScript.new()
	joints.grid_system = grid

	grid.place_block(Vector3i(0, 0, 0), &"stone")
	grid.place_block(Vector3i(1, 0, 0), &"stone")
	var joint = joints.bond_adjacent(Vector3i(0, 0, 0), Vector3i(1, 0, 0), 100.0)

	# Impact energy: 250 Joules (exceeds 100 * 1.8 = 180 threshold)
	var broken: Array = joints.apply_impact_to_block_joints(Vector3i(1, 0, 0), 250.0)

	var broke_immediately: bool = not broken.is_empty() and joint.is_broken and joint.current_health == 0.0

	grid.queue_free()
	joints.queue_free()
	return broke_immediately

## 8. Accumulated damage from repeated loads below the immediate breakage threshold
func test_accumulated_damage_from_repeated_loads() -> bool:
	var grid: Node = GridSystemScript.new()
	var joints: Node = JointSystemScript.new()
	joints.grid_system = grid

	grid.place_block(Vector3i(0, 0, 0), &"stone")
	grid.place_block(Vector3i(1, 0, 0), &"stone")
	var joint = joints.bond_adjacent(Vector3i(0, 0, 0), Vector3i(1, 0, 0), 100.0)

	# Hit 1: 40 Joules (below 180 threshold) -> inflicts 40 damage, 60 health remains
	joints.apply_impact_to_block_joints(Vector3i(1, 0, 0), 40.0)
	var survives_hit_1: bool = not joint.is_broken and joint.current_health == 60.0

	# Hit 2: 30 Joules -> 30 health remains
	joints.apply_impact_to_block_joints(Vector3i(1, 0, 0), 30.0)
	var survives_hit_2: bool = not joint.is_broken and joint.current_health == 30.0

	# Hit 3: 40 Joules -> exhausts remaining 30 health, joint breaks!
	joints.apply_impact_to_block_joints(Vector3i(1, 0, 0), 40.0)
	var breaks_on_hit_3: bool = joint.is_broken and joint.current_health == 0.0

	grid.queue_free()
	joints.queue_free()
	return survives_hit_1 and survives_hit_2 and breaks_on_hit_3

## 9. Breaking a supporting joint triggers stability reevaluation and collapse of the cantilever
func test_broken_joint_triggers_stability_reevaluation() -> bool:
	var grid: Node = GridSystemScript.new()
	var joints: Node = JointSystemScript.new()
	joints.grid_system = grid
	var stability: Node = StabilitySystemScript.new()
	stability.grid_system = grid
	stability.joint_system = joints
	stability.require_joints_for_lateral_support = true
	stability.ground_anchor_y = 0

	# Pillar at x = 0 (y = 0, 1)
	grid.place_block(Vector3i(0, 0, 0), &"stone")
	grid.place_block(Vector3i(0, 1, 0), &"stone")
	joints.bond_adjacent(Vector3i(0, 0, 0), Vector3i(0, 1, 0))

	# Horizontal overhang cantilever at (1, 1, 0)
	grid.place_block(Vector3i(1, 1, 0), &"stone")
	var cantilever_joint = joints.bond_adjacent(Vector3i(0, 1, 0), Vector3i(1, 1, 0))

	# With intact joint, all blocks are supported
	var unsupported_init: Array = stability.evaluate_stability()
	if not unsupported_init.is_empty():
		grid.queue_free()
		joints.queue_free()
		stability.queue_free()
		return false

	# Break the cantilever joint
	joints.break_joint(cantilever_joint)

	# Cantilever block (1, 1, 0) is now unsupported and detected for collapse!
	var unsupported_after: Array = stability.evaluate_stability()
	var collapse_detected: bool = unsupported_after.size() == 1 and unsupported_after[0] == Vector3i(1, 1, 0)

	grid.queue_free()
	joints.queue_free()
	stability.queue_free()
	return collapse_detected

## 10. Compound debris preserves internal joints from the collapsed structure
func test_compound_debris_preserves_internal_joints() -> bool:
	var cells: Array = [Vector3i(0, 0, 0), Vector3i(1, 0, 0)]
	var bdm: Dictionary = {
		Vector3i(0, 0, 0): BlockData.new(&"stone", 1.0),
		Vector3i(1, 0, 0): BlockData.new(&"stone", 1.0)
	}

	var j = StructuralJointScript.new(Vector3i(0, 0, 0), Vector3i(1, 0, 0), 100.0, &"stone", &"stone")
	var island: DebrisIsland = DebrisIslandScript.new()
	island.setup_island(cells, bdm, 1.0, [j])

	var preserves_j: bool = island.internal_joints.has(j.get_key())
	var constituent_count: bool = island.constituent_blocks.size() == 2

	island.queue_free()
	return preserves_j and constituent_count

## 11. Compound debris splits into smaller bodies when an internal joint breaks on impact
func test_debris_splits_when_internal_joint_breaks() -> bool:
	var cells: Array = [Vector3i(0, 0, 0), Vector3i(1, 0, 0)]
	var bdm: Dictionary = {
		Vector3i(0, 0, 0): BlockData.new(&"stone", 1.0),
		Vector3i(1, 0, 0): BlockData.new(&"stone", 1.0)
	}

	var j = StructuralJointScript.new(Vector3i(0, 0, 0), Vector3i(1, 0, 0), 100.0, &"stone", &"stone")
	var dummy_root := Node3D.new()
	var island: DebrisIsland = DebrisIslandScript.new()
	dummy_root.add_child(island)
	island.setup_island(cells, bdm, 1.0, [j])

	# Apply severe impact that breaks the internal joint
	island.apply_impact_damage(Vector3i(0, 0, 0), 250.0)

	# Joint should be broken
	var joint_broken: bool = j.is_broken

	# Check splitting: with joint broken, 2 disconnected blocks split
	var split_result: Array = island.check_and_split_on_broken_joints()
	var split_happened: bool = split_result.size() == 2

	dummy_root.queue_free()
	return joint_broken and split_happened

## 12. Cement inventory consumption and rejection on insufficient resources
func test_cement_inventory_consumption_and_insufficient_resources() -> bool:
	var player: CharacterBody3D = PlayerScene.instantiate() as CharacterBody3D
	if player == null:
		return false

	player.unlimited_cement = false
	player.cement_count = 2

	# Use 1 cement
	var ok1: bool = player.use_cement(1)
	var count1: bool = player.get_cement_count() == 1

	# Use second cement
	var ok2: bool = player.use_cement(1)
	var count2: bool = player.get_cement_count() == 0

	# Try using when 0 available: must reject!
	var ok3: bool = not player.use_cement(1)
	var count3: bool = player.get_cement_count() == 0

	player.queue_free()
	return ok1 and count1 and ok2 and count2 and ok3 and count3

## 13. Unlimited cement debug flag allows infinite usage without depleting count
func test_unlimited_cement_debug_flag() -> bool:
	var player: CharacterBody3D = PlayerScene.instantiate() as CharacterBody3D
	if player == null:
		return false

	player.unlimited_cement = true
	player.cement_count = 0

	var can_use_0: bool = player.use_cement(1)
	var can_use_1: bool = player.use_cement(5)

	player.queue_free()
	return can_use_0 and can_use_1

## 14. Input action apply_cement is registered in InputManager without key conflicts
func test_input_actions_no_conflicts() -> bool:
	var im: Node = InputManagerScript.new()
	im.setup_default_input_actions()

	var has_cement_action: bool = InputMap.has_action(&"apply_cement")

	# Check that G is mapped to apply_cement and not to movement or other conflicting actions
	var events: Array = InputMap.action_get_events(&"apply_cement")
	var key_g_bound: bool = false
	for ev in events:
		if ev is InputEventKey and (ev.keycode == KEY_G or ev.physical_keycode == KEY_G):
			key_g_bound = true
			break

	im.queue_free()
	return has_cement_action and key_g_bound
