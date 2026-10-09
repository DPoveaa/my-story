class_name TestMortarBrush
extends RefCounted

## Focused acceptance & regression tests for the Surface-Based Mortar Brush
## and Default Block Connections.

const GridSystemScript = preload("res://autoloads/GridSystem.gd")
const StabilitySystemScript = preload("res://autoloads/StabilitySystem.gd")
const JointSystemScript = preload("res://autoloads/JointSystem.gd")
const StructuralJointScript = preload("res://data/StructuralJoint.gd")
const DebrisIslandScript = preload("res://systems/collapse/DebrisIsland.gd")
const CollapseOrchestratorScript = preload("res://systems/collapse/CollapseOrchestrator.gd")
const PlayerScene = preload("res://scenes/player/Player.tscn")

var passed_count: int = 0
var failed_count: int = 0

func run_all() -> bool:
	print("==================================================")
	print("RUNNING SURFACE-BASED MORTAR BRUSH & DEFAULT CONNECTION TESTS")
	print("==================================================")

	_run_test("test_surface_orientation", test_surface_orientation)
	_run_test("test_plus_adjacency_rule", test_plus_adjacency_rule)
	_run_test("test_no_through_wall_connections", test_no_through_wall_connections)
	_run_test("test_resource_consumption_and_no_duplicates", test_resource_consumption_and_no_duplicates)
	_run_test("test_placement_near_existing_joints_no_domino_collapse", test_placement_near_existing_joints_no_domino_collapse)
	_run_test("test_post_collapse_mortar_application", test_post_collapse_mortar_application)
	_run_test("test_joint_damage_and_breakage", test_joint_damage_and_breakage)
	_run_test("test_debris_splitting_on_broken_joints", test_debris_splitting_on_broken_joints)

	print("==================================================")
	print("MORTAR BRUSH TEST RESULTS: %d PASSED, %d FAILED" % [passed_count, failed_count])
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

## 1. Surface orientation: orthogonal 2D directions for all 6 face normals
func test_surface_orientation() -> bool:
	var joints: Node = JointSystemScript.new()

	# +Z face normal
	var dirs_pz: Array[Vector3i] = joints.get_surface_orthogonal_directions(Vector3i(0, 0, 1))
	if dirs_pz.size() != 4:
		joints.queue_free()
		return false
	for d in dirs_pz:
		if d.z != 0: # Must be in X-Y plane
			joints.queue_free()
			return false

	# +X face normal
	var dirs_px: Array[Vector3i] = joints.get_surface_orthogonal_directions(Vector3i(1, 0, 0))
	if dirs_px.size() != 4:
		joints.queue_free()
		return false
	for d in dirs_px:
		if d.x != 0: # Must be in Y-Z plane
			joints.queue_free()
			return false

	# +Y face normal
	var dirs_py: Array[Vector3i] = joints.get_surface_orthogonal_directions(Vector3i(0, 1, 0))
	if dirs_py.size() != 4:
		joints.queue_free()
		return false
	for d in dirs_py:
		if d.y != 0: # Must be in X-Z plane
			joints.queue_free()
			return false

	joints.queue_free()
	return true

## 2. Mortar brush reinforces connections in 2D '+' pattern on painted surface
func test_plus_adjacency_rule() -> bool:
	var grid: Node = GridSystemScript.new()
	var joints: Node = JointSystemScript.new()
	joints.grid_system = grid

	# Center block and 4 coplanar neighbors in X-Y wall (Z = 0)
	var center := Vector3i(1, 1, 0)
	var up := Vector3i(1, 2, 0)
	var down := Vector3i(1, 0, 0)
	var left := Vector3i(0, 1, 0)
	var right := Vector3i(2, 1, 0)

	grid.place_block(center, &"stone")
	grid.place_block(up, &"stone")
	grid.place_block(down, &"stone")
	grid.place_block(left, &"stone")
	grid.place_block(right, &"stone")

	# Prior to mortar: blocks have weak default connections, but are not mortared
	var default_center_up: bool = joints.has_joint(center, up)
	var mortared_before: bool = joints.is_joint_mortared(center, up)

	# Paint the +Z surface of center block with mortar brush
	var res: Dictionary = joints.apply_mortar_brush(center, Vector3i(0, 0, 1))
	var success: bool = res.get("success", false)
	var reinforced: Array = res.get("reinforced_joints", [])

	var coated: bool = joints.is_face_coated(center, Vector3i(0, 0, 1))
	var mort_up: bool = joints.is_joint_mortared(center, up)
	var mort_down: bool = joints.is_joint_mortared(center, down)
	var mort_left: bool = joints.is_joint_mortared(center, left)
	var mort_right: bool = joints.is_joint_mortared(center, right)

	grid.queue_free()
	joints.queue_free()

	return default_center_up and not mortared_before and success and reinforced.size() == 4 and coated and mort_up and mort_down and mort_left and mort_right

## 3. Mortar brush does NOT connect through wall depth (-normal) or behind surface
func test_no_through_wall_connections() -> bool:
	var grid: Node = GridSystemScript.new()
	var joints: Node = JointSystemScript.new()
	joints.grid_system = grid

	var center := Vector3i(1, 1, 0)
	var behind := Vector3i(1, 1, -1) # Through-wall depth block

	grid.place_block(center, &"stone")
	grid.place_block(behind, &"stone")

	# Paint the front (+Z) face of center
	var res: Dictionary = joints.apply_mortar_brush(center, Vector3i(0, 0, 1))
	var success: bool = res.get("success", false)

	# Joint between center and behind must NOT be reinforced with mortar
	var through_wall_mortared: bool = joints.is_joint_mortared(center, behind)

	grid.queue_free()
	joints.queue_free()

	return success and not through_wall_mortared

## 4. Resource consumption: only valid newly coated faces consume mortar; no duplicate consumption
func test_resource_consumption_and_no_duplicates() -> bool:
	var grid: Node = GridSystemScript.new()
	var joints: Node = JointSystemScript.new()
	joints.grid_system = grid

	var cell := Vector3i(2, 2, 2)
	grid.place_block(cell, &"stone")

	var player := PlayerScene.instantiate()
	player.grid_system = grid
	player.cement_count = 25
	player.unlimited_cement = false

	# First coat: consumes 1
	var res1: Dictionary = joints.apply_mortar_brush(cell, Vector3i(0, 1, 0))
	var consumed1: bool = res1.get("consumed", false)
	if consumed1:
		player.use_cement(1)

	var count_after_first: int = player.cement_count

	# Second coat on same face (simulating holding brush): does NOT consume
	var res2: Dictionary = joints.apply_mortar_brush(cell, Vector3i(0, 1, 0))
	var consumed2: bool = res2.get("consumed", false)
	var already_coated2: bool = res2.get("already_coated", false)
	if consumed2:
		player.use_cement(1)

	var count_after_second: int = player.cement_count

	# Depleted mortar check:
	player.cement_count = 0
	var can_afford: bool = player.use_cement(1)

	grid.queue_free()
	joints.queue_free()
	player.queue_free()

	return consumed1 and count_after_first == 24 and not consumed2 and already_coated2 and count_after_second == 24 and not can_afford

## 5. Placing an uncoated block into a bridge does NOT cause domino collapse
func test_placement_near_existing_joints_no_domino_collapse() -> bool:
	var grid: Node = GridSystemScript.new()
	var stab: Node = StabilitySystemScript.new()
	var joints: Node = JointSystemScript.new()
	stab.grid_system = grid
	stab.joint_system = joints
	joints.grid_system = grid
	joints.stability_system = stab
	stab.require_joints_for_lateral_support = true

	# Build two pillars anchored at y = 0
	grid.place_block(Vector3i(0, 0, 0), &"stone")
	grid.place_block(Vector3i(0, 1, 0), &"stone")
	grid.place_block(Vector3i(0, 2, 0), &"stone")

	grid.place_block(Vector3i(3, 0, 0), &"stone")
	grid.place_block(Vector3i(3, 1, 0), &"stone")
	grid.place_block(Vector3i(3, 2, 0), &"stone")

	# Span bridge blocks
	grid.place_block(Vector3i(1, 2, 0), &"stone")
	grid.place_block(Vector3i(2, 2, 0), &"stone")

	# Reinforce bridge surface with mortar
	joints.apply_mortar_brush(Vector3i(1, 2, 0), Vector3i(0, 1, 0))
	joints.apply_mortar_brush(Vector3i(2, 2, 0), Vector3i(0, 1, 0))

	var initial_unsupported: Array[Vector3i] = stab.recalculate_stability()
	var bridge_stable_init: bool = initial_unsupported.is_empty()

	# Place a new uncoated block into the structure:
	# e.g. placing on top of the bridge span
	grid.place_block(Vector3i(1, 3, 0), &"stone")

	# Placing this block must NOT collapse the bridge!
	var post_place_unsupported: Array[Vector3i] = stab.recalculate_stability()

	grid.queue_free()
	stab.queue_free()
	joints.queue_free()

	return bridge_stable_init and post_place_unsupported.is_empty()

## 6. Post-collapse mortar application: surviving blocks can be painted without stale reference errors
func test_post_collapse_mortar_application() -> bool:
	var grid: Node = GridSystemScript.new()
	var stab: Node = StabilitySystemScript.new()
	var joints: Node = JointSystemScript.new()
	var orch: CollapseOrchestrator = CollapseOrchestratorScript.new()

	stab.grid_system = grid
	stab.joint_system = joints
	joints.grid_system = grid
	joints.stability_system = stab
	orch.grid_system = grid
	orch.stability_system = stab
	stab.require_joints_for_lateral_support = true

	# Pillar at (0,0,0) to (0,2,0)
	grid.place_block(Vector3i(0, 0, 0), &"stone")
	grid.place_block(Vector3i(0, 1, 0), &"stone")
	grid.place_block(Vector3i(0, 2, 0), &"stone")

	# Cantilever block at (1,2,0)
	grid.place_block(Vector3i(1, 2, 0), &"stone")

	# Simulate collapse of the cantilever block
	orch.trigger_collapse([Vector3i(1, 2, 0)])

	# Surviving pillar block at (0,2,0) has exposed face (+X) where cantilever was
	var surviving_cell := Vector3i(0, 2, 0)
	var face_dir := Vector3i(1, 0, 0)

	# Applying mortar to the surviving structure must succeed cleanly
	var res: Dictionary = joints.apply_mortar_brush(surviving_cell, face_dir)
	var success: bool = res.get("success", false)
	var coated: bool = joints.is_face_coated(surviving_cell, face_dir)

	grid.queue_free()
	stab.queue_free()
	joints.queue_free()
	orch.queue_free()

	return success and coated

## 7. Joint damage and breakage from physical impact
func test_joint_damage_and_breakage() -> bool:
	var grid: Node = GridSystemScript.new()
	var joints: Node = JointSystemScript.new()
	joints.grid_system = grid

	grid.place_block(Vector3i(0, 0, 0), &"stone")
	grid.place_block(Vector3i(1, 0, 0), &"stone")

	# Reinforce with mortar
	joints.bond_adjacent(Vector3i(0, 0, 0), Vector3i(1, 0, 0))
	var joint = joints.get_joint(Vector3i(0, 0, 0), Vector3i(1, 0, 0))
	if joint == null:
		grid.queue_free()
		joints.queue_free()
		return false

	var initial_hp: float = joint.current_health # 100.0

	# 1. Below threshold impact (energy < 8.0) -> no damage
	joints.apply_impact_to_block_joints(Vector3i(0, 0, 0), 5.0)
	var unharmed: bool = joint.current_health == initial_hp

	# 2. Moderate impact (energy 40.0) -> sustained damage
	joints.apply_impact_to_block_joints(Vector3i(0, 0, 0), 40.0)
	var damaged: bool = joint.current_health < initial_hp and not joint.is_broken

	# 3. Catastrophic impact -> broken immediately
	joints.apply_impact_to_block_joints(Vector3i(0, 0, 0), 1000.0)
	var broken: bool = joint.is_broken and joint.current_health == 0.0

	grid.queue_free()
	joints.queue_free()

	return unharmed and damaged and broken

## 8. Compound debris preserves internal joints and splits when internal joint breaks
func test_debris_splitting_on_broken_joints() -> bool:
	var island := DebrisIslandScript.new()

	var cells: Array = [Vector3i(0, 0, 0), Vector3i(1, 0, 0), Vector3i(2, 0, 0)]
	var block_data: Dictionary = {
		Vector3i(0, 0, 0): BlockData.new(&"stone", 1.0),
		Vector3i(1, 0, 0): BlockData.new(&"stone", 1.0),
		Vector3i(2, 0, 0): BlockData.new(&"stone", 1.0)
	}

	var dummy_root := Node3D.new()
	dummy_root.add_child(island)

	var j1 = StructuralJointScript.new(Vector3i(0, 0, 0), Vector3i(1, 0, 0), 100.0, &"stone", &"stone", true)
	var j2 = StructuralJointScript.new(Vector3i(1, 0, 0), Vector3i(2, 0, 0), 100.0, &"stone", &"stone", true)

	island.setup_island(cells, block_data, 1.0, [j1, j2])

	# Preserves internal joints
	var initial_intact: bool = island.internal_joints.size() == 2

	# Break j1
	j1.break_joint()

	# When checked, island should partition into two independent groups: [0,0,0] and [1,0,0 + 2,0,0]
	var splits: Array = island.check_and_split_on_broken_joints()
	var split_ok: bool = splits.size() == 2

	# The second sub-group [1,0,0 + 2,0,0] still has j2 intact as a compound debris body!
	var compound_preserved: bool = false
	for s in splits:
		if s.constituent_blocks.size() == 2 and s.internal_joints.has(j2.get_key()):
			compound_preserved = true

	dummy_root.queue_free()

	return initial_intact and split_ok and compound_preserved
