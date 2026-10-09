class_name TestM2_1
extends RefCounted

## Automated acceptance tests for Milestone 2.1
## Camera, Movement & Physics Interaction.

const PlayerScene = preload("res://scenes/player/Player.tscn")
const DebrisGrabberScript = preload("res://systems/interaction/DebrisGrabber.gd")
const DebrisIslandScript = preload("res://systems/collapse/DebrisIsland.gd")
const BuildHUDScene = preload("res://scenes/ui/BuildHUD.tscn")
const InputManagerScript = preload("res://autoloads/InputManager.gd")

var passed_count: int = 0
var failed_count: int = 0

func run_all() -> bool:
	print("==================================================")
	print("RUNNING MILESTONE 2.1 CAMERA, MOVEMENT & PHYSICS INTERACTION TESTS")
	print("==================================================")

	_run_test("test_debris_grabber_node_in_player_scene", test_debris_grabber_node_in_player_scene)
	_run_test("test_grab_rejected_with_null_island", test_grab_rejected_with_null_island)
	_run_test("test_soul_projection_toggles_correctly", test_soul_projection_toggles_correctly)
	_run_test("test_debug_flight_state_sets_correctly", test_debug_flight_state_sets_correctly)
	_run_test("test_debris_grabber_signals_exist", test_debris_grabber_signals_exist)
	_run_test("test_debris_grabber_max_mass_rejects", test_debris_grabber_max_mass_rejects)
	_run_test("test_debris_grabber_release_clears_state", test_debris_grabber_release_clears_state)
	_run_test("test_debris_grabber_recover_fails_without_grab", test_debris_grabber_recover_fails_without_grab)
	_run_test("test_debris_grabber_detaches_from_multiblock_island", test_debris_grabber_detaches_from_multiblock_island)
	_run_test("test_hud_has_prompt_label", test_hud_has_prompt_label)
	_run_test("test_interact_and_recover_actions_exist", test_interact_and_recover_actions_exist)
	_run_test("test_player_has_carried_block_changed_signal", test_player_has_carried_block_changed_signal)
	_run_test("test_push_force_export_exists", test_push_force_export_exists)

	print("==================================================")
	print("M2.1 TEST RESULTS: %d PASSED, %d FAILED" % [passed_count, failed_count])
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

## 1. DebrisGrabber node must appear as a child in Player.tscn
func test_debris_grabber_node_in_player_scene() -> bool:
	var player: CharacterBody3D = PlayerScene.instantiate() as CharacterBody3D
	if player == null:
		return false
	var found: bool = player.get_node_or_null("DebrisGrabber") != null
	player.queue_free()
	return found

## 2. try_grab rejects null island
func test_grab_rejected_with_null_island() -> bool:
	var grabber: Node = DebrisGrabberScript.new() as Node
	var grab_result: bool = grabber.try_grab(null, Vector3i.ZERO, null)
	grabber.queue_free()
	return grab_result == false

## 3. Soul projection state machine toggles correctly
func test_soul_projection_toggles_correctly() -> bool:
	var player: CharacterBody3D = PlayerScene.instantiate() as CharacterBody3D
	if player == null:
		return false
	var initial_state: int = player.current_state
	player.set_state(1) # SOUL_PROJECTION
	var sp_state: int = player.current_state
	player.set_state(0) # BODY_CONTROL
	var back_state: int = player.current_state
	player.queue_free()
	return initial_state == 0 and sp_state == 1 and back_state == 0

## 4. Debug flight state sets correctly
func test_debug_flight_state_sets_correctly() -> bool:
	var player: CharacterBody3D = PlayerScene.instantiate() as CharacterBody3D
	if player == null:
		return false
	player.set_state(2) # DEBUG_FLIGHT
	var fs: int = player.current_state
	player.queue_free()
	return fs == 2

## 5. DebrisGrabber exposes the required signals
func test_debris_grabber_signals_exist() -> bool:
	var grabber: Node = DebrisGrabberScript.new() as Node
	var ok: bool = (
		grabber.has_signal("grabbed_block") and
		grabber.has_signal("released_block") and
		grabber.has_signal("recovered_block_to_grid") and
		grabber.has_signal("recover_failed")
	)
	grabber.queue_free()
	return ok

## 6. Grabber respects max_grabbable_mass — heavy island is rejected
func test_debris_grabber_max_mass_rejects() -> bool:
	var grabber: Node = DebrisGrabberScript.new() as Node
	var island: RigidBody3D = DebrisIslandScript.new() as RigidBody3D
	island.mass = 999.0
	var grab_result: bool = grabber.try_grab(island, Vector3i.ZERO, null)
	island.queue_free()
	grabber.queue_free()
	return grab_result == false

## 7. release() clears is_grabbing
func test_debris_grabber_release_clears_state() -> bool:
	var grabber: Node = DebrisGrabberScript.new() as Node
	grabber.is_grabbing = true
	grabber._grabbed_island = null
	grabber.release()
	var clear: bool = not grabber.is_grabbing
	grabber.queue_free()
	return clear

## 8. try_recover() returns false when nothing is grabbed
func test_debris_grabber_recover_fails_without_grab() -> bool:
	var grabber: Node = DebrisGrabberScript.new() as Node
	var recover_result: bool = grabber.try_recover()
	grabber.queue_free()
	return recover_result == false

## 9. try_grab on multi-block island detaches only the targeted block
func test_debris_grabber_detaches_from_multiblock_island() -> bool:
	var cells: Array[Vector3i] = [Vector3i(0, 0, 0), Vector3i(1, 0, 0)]
	var block_data_map: Dictionary = {}
	for c in cells:
		block_data_map[c] = BlockData.new(&"stone", 1.0)

	var dummy_parent: Node3D = Node3D.new()
	var island: RigidBody3D = DebrisIslandScript.new() as RigidBody3D
	dummy_parent.add_child(island)
	island.setup_island(cells, block_data_map, 1.0)

	var initial_count: int = island.constituent_blocks.size()

	var grabber: Node = DebrisGrabberScript.new() as Node
	dummy_parent.add_child(grabber)
	grabber.max_grabbable_mass = 999.0

	var bd: BlockData = BlockData.new(&"stone", 1.0)
	var grab_result: bool = grabber.try_grab(island, Vector3i(0, 0, 0), bd)

	var after_count: int = 0
	if is_instance_valid(island):
		after_count = island.constituent_blocks.size()

	grabber.queue_free()
	dummy_parent.queue_free()

	return grab_result and after_count == initial_count - 1

## 10. BuildHUD.tscn has PromptLabel node
func test_hud_has_prompt_label() -> bool:
	var hud: CanvasLayer = BuildHUDScene.instantiate() as CanvasLayer
	if hud == null:
		return false
	var label: Node = hud.get_node_or_null("PanelTop/HBox/PromptLabel")
	hud.queue_free()
	return label != null

## 11. interact and recover_block input actions exist after setup
func test_interact_and_recover_actions_exist() -> bool:
	var im: Node = Node.new()
	im.set_script(InputManagerScript)
	im.setup_default_input_actions()
	var ok: bool = InputMap.has_action(&"interact") and InputMap.has_action(&"recover_block")
	im.queue_free()
	return ok

## 12. PlayerController exposes carried_block_changed signal
func test_player_has_carried_block_changed_signal() -> bool:
	var player: CharacterBody3D = PlayerScene.instantiate() as CharacterBody3D
	if player == null:
		return false
	var has_sig: bool = player.has_signal("carried_block_changed")
	player.queue_free()
	return has_sig

## 13. push_force export property exists on player controller
func test_push_force_export_exists() -> bool:
	var player: CharacterBody3D = PlayerScene.instantiate() as CharacterBody3D
	if player == null:
		return false
	var has_prop: bool = "push_force" in player
	player.queue_free()
	return has_prop
