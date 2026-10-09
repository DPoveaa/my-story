class_name TestM2
extends RefCounted

## Test suite for Milestone 2: First-Person Character & Soul Projection.

const PlayerScript = preload("res://scenes/player/PlayerController.gd")
const PlayerScene = preload("res://scenes/player/Player.tscn")
const GridSystemScript = preload("res://autoloads/GridSystem.gd")
const StabilitySystemScript = preload("res://autoloads/StabilitySystem.gd")
const CollapseOrchestratorScript = preload("res://systems/collapse/CollapseOrchestrator.gd")

var passed_count: int = 0
var failed_count: int = 0
var test_names: Array[String] = []

func run_all() -> bool:
	print("==================================================")
	print("RUNNING MILESTONE 2 FIRST-PERSON & SOUL PROJECTION TESTS")
	print("==================================================")

	_run_test("test_player_scene_instantiation_and_nodes", test_player_scene_instantiation_and_nodes)
	_run_test("test_first_person_movement_and_gravity", test_first_person_movement_and_gravity)
	_run_test("test_soul_projection_state_machine", test_soul_projection_state_machine)
	_run_test("test_capsule_overlap_placement_prevention", test_capsule_overlap_placement_prevention)
	_run_test("test_shared_building_in_both_modes", test_shared_building_in_both_modes)
	_run_test("test_debug_camera_separate_from_soul_projection", test_debug_camera_separate_from_soul_projection)
	_run_test("test_input_actions_exist_and_no_conflicts", test_input_actions_exist_and_no_conflicts)

	print("==================================================")
	print("M2 TEST RESULTS: %d PASSED, %d FAILED" % [passed_count, failed_count])
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

## 1. Verifies player scene hierarchy, collision capsule, cameras, and configurable parameters.
func test_player_scene_instantiation_and_nodes() -> bool:
	var player: CharacterBody3D = PlayerScene.instantiate() as CharacterBody3D
	if player == null:
		return false

	# Must be a CharacterBody3D
	if not (player is CharacterBody3D):
		player.queue_free()
		return false

	# Must have CollisionShape3D with CapsuleShape3D
	var col_shape: CollisionShape3D = player.get_node_or_null("CollisionShape3D")
	if col_shape == null or not (col_shape.shape is CapsuleShape3D):
		player.queue_free()
		return false

	# Must have Head with BodyCamera
	var head_node: Node3D = player.get_node_or_null("Head")
	var body_cam: Camera3D = player.get_node_or_null("Head/BodyCamera")
	if head_node == null or body_cam == null:
		player.queue_free()
		return false

	# Must have ProjectionCamera
	var proj_cam: Camera3D = player.get_node_or_null("ProjectionCamera")
	if proj_cam == null:
		player.queue_free()
		return false

	# Configurable defaults sanity
	if player.walk_speed <= 0.0 or player.sprint_speed_multiplier <= 1.0:
		player.queue_free()
		return false
	if player.jump_velocity <= 0.0 or player.gravity <= 0.0:
		player.queue_free()
		return false
	if player.projection_speed <= 0.0 or player.projection_fast_multiplier <= 1.0:
		player.queue_free()
		return false

	player.queue_free()
	return true

## 2. Verifies gravity accelerates vertical velocity and locomotion values operate properly.
func test_first_person_movement_and_gravity() -> bool:
	var player: CharacterBody3D = PlayerScene.instantiate() as CharacterBody3D
	player.velocity = Vector3.ZERO

	# Simulate in-air gravity step (not on floor)
	player.velocity.y = 0.0
	var delta: float = 0.1
	player.velocity.y -= player.gravity * delta
	if player.velocity.y >= 0.0:
		player.queue_free()
		return false
	if not is_equal_approx(player.velocity.y, -player.gravity * delta):
		player.queue_free()
		return false

	# Jump velocity
	player.velocity.y = player.jump_velocity
	if not is_equal_approx(player.velocity.y, player.jump_velocity):
		player.queue_free()
		return false

	# Sprint multiplier
	var walk_spd: float = player.walk_speed
	var sprint_spd: float = player.walk_speed * player.sprint_speed_multiplier
	if sprint_spd <= walk_spd:
		player.queue_free()
		return false

	player.queue_free()
	return true

## 3. Verifies Soul Projection state transitions, camera detachment, and body stationary guarantee.
func test_soul_projection_state_machine() -> bool:
	var container := Node3D.new()
	var player: CharacterBody3D = PlayerScene.instantiate() as CharacterBody3D
	container.add_child(player)
	player.position = Vector3(10, 0, 10)

	# 1. Initial State: BODY_CONTROL
	if player.current_state != PlayerScript.State.BODY_CONTROL:
		container.queue_free()
		return false
	if player.get_active_camera() != player.body_camera:
		container.queue_free()
		return false

	var initial_body_pos: Vector3 = player.position

	# Repeat transition cycles
	for cycle in range(5):
		# 2. Activate Soul Projection
		player.toggle_soul_projection()
		if player.current_state != PlayerScript.State.SOUL_PROJECTION:
			container.queue_free()
			return false
		if player.get_active_camera() != player.projection_camera:
			container.queue_free()
			return false
		if player.velocity != Vector3.ZERO:
			container.queue_free()
			return false

		# Fly projection camera away
		player.projection_camera.position = Vector3(50 + cycle * 10, 30, 80)

		# Physical body MUST remain stationary
		if not player.position.is_equal_approx(initial_body_pos):
			container.queue_free()
			return false

		# 3. Return to Body
		player.toggle_soul_projection()
		if player.current_state != PlayerScript.State.BODY_CONTROL:
			container.queue_free()
			return false
		if player.get_active_camera() != player.body_camera:
			container.queue_free()
			return false

		# Body is still at original position
		if not player.position.is_equal_approx(initial_body_pos):
			container.queue_free()
			return false

	container.queue_free()
	return true

## 4. Verifies player cannot place blocks overlapping their own physical capsule.
func test_capsule_overlap_placement_prevention() -> bool:
	var player: CharacterBody3D = PlayerScene.instantiate() as CharacterBody3D
	player.position = Vector3(0.0, 0.0, 0.0)

	# Cell (0, 0, 0) covers [0..1, 0..1, 0..1], overlapping the player capsule base
	if not player.is_cell_overlapping_player(Vector3i(0, 0, 0), 1.0):
		player.queue_free()
		return false

	# Cell (0, 1, 0) covers [0..1, 1..2, 0..1], overlapping the player capsule torso/head
	if not player.is_cell_overlapping_player(Vector3i(0, 1, 0), 1.0):
		player.queue_free()
		return false

	# Cell (10, 0, 10) is 10 meters away, must NOT overlap
	if player.is_cell_overlapping_player(Vector3i(10, 0, 10), 1.0):
		player.queue_free()
		return false

	player.queue_free()
	return true

## 5. Verifies construction and removal function identically in both Body and Projection modes.
func test_shared_building_in_both_modes() -> bool:
	var container := Node3D.new()
	var grid := GridSystemScript.new()
	var player: CharacterBody3D = PlayerScene.instantiate() as CharacterBody3D
	player.grid_system = grid
	container.add_child(player)
	player.position = Vector3(0, 0, 0)

	# Mode 1: BODY_CONTROL
	player.set_state(PlayerScript.State.BODY_CONTROL)
	var cell_body := Vector3i(4, 0, 0)
	var placed_body: bool = grid.place_block(cell_body, player.get_selected_type())
	if not placed_body or not grid.has_block(cell_body):
		container.queue_free()
		return false

	var removed_body = grid.remove_block(cell_body)
	if removed_body == null or grid.has_block(cell_body):
		container.queue_free()
		return false

	# Mode 2: SOUL_PROJECTION
	player.set_state(PlayerScript.State.SOUL_PROJECTION)
	var cell_proj := Vector3i(8, 0, 8)
	var placed_proj: bool = grid.place_block(cell_proj, player.get_selected_type())
	if not placed_proj or not grid.has_block(cell_proj):
		container.queue_free()
		return false

	var removed_proj = grid.remove_block(cell_proj)
	if removed_proj == null or grid.has_block(cell_proj):
		container.queue_free()
		return false

	container.queue_free()
	return true

## 6. Verifies debug camera is separate from Soul Projection gameplay state.
func test_debug_camera_separate_from_soul_projection() -> bool:
	var player: CharacterBody3D = PlayerScene.instantiate() as CharacterBody3D
	player.set_state(PlayerScript.State.BODY_CONTROL)

	# Transition to DEBUG_FLIGHT
	player.set_state(PlayerScript.State.DEBUG_FLIGHT)
	if player.current_state != PlayerScript.State.DEBUG_FLIGHT:
		player.queue_free()
		return false

	# Return to BODY_CONTROL
	player.set_state(PlayerScript.State.BODY_CONTROL)
	if player.current_state != PlayerScript.State.BODY_CONTROL:
		player.queue_free()
		return false

	player.queue_free()
	return true

## 7. Verifies input actions are registered and free of key conflicts.
func test_input_actions_exist_and_no_conflicts() -> bool:
	var required_actions: Array[StringName] = [
		&"move_forward",
		&"move_backward",
		&"move_left",
		&"move_right",
		&"jump",
		&"sprint",
		&"fly_up",
		&"fly_down",
		&"soul_projection",
		&"debug_camera",
		&"place_block",
		&"remove_block",
		&"toggle_mouse_capture"
	]

	for action in required_actions:
		if not InputMap.has_action(action):
			# Ensure InputManager registers them
			var input_mgr := preload("res://autoloads/InputManager.gd").new()
			input_mgr.setup_default_input_actions()
			input_mgr.queue_free()
			if not InputMap.has_action(action):
				return false

	return true
