extends Node

## Minimal, repeatable survival objective manager for the core gameplay loop.
## Tracks cyclic survival progression using existing systems:
## 1. Gather Resources (natural terrain mining via VoxelWorld)
## 2. Build Structure (grid block placement via GridSystem)
## 3. Fortify Surfaces (mortar coating via JointSystem)
##
## Completing a cycle awards material rewards and mortar supplies, then advances to the next cycle.

signal objective_updated(stage: int, current: int, target: int, description: String)
signal objective_stage_completed(stage: int, title: String)
signal cycle_completed(cycle_number: int, reward_description: String)

enum Stage {
	GATHER_RESOURCES = 0,
	BUILD_STRUCTURE = 1,
	FORTIFY_SURFACES = 2
}

var current_cycle: int = 1
var current_stage: Stage = Stage.GATHER_RESOURCES
var current_progress: int = 0
var is_active: bool = true

func _ready() -> void:
	_connect_system_signals()

func _connect_system_signals() -> void:
	if has_node("/root/GridSystem"):
		var gs = get_node("/root/GridSystem")
		if not gs.block_placed.is_connected(_on_grid_block_placed):
			gs.block_placed.connect(_on_grid_block_placed)

	if has_node("/root/JointSystem"):
		var js = get_node("/root/JointSystem")
		if not js.face_coated.is_connected(_on_face_coated):
			js.face_coated.connect(_on_face_coated)

func reset_progress() -> void:
	current_cycle = 1
	current_stage = Stage.GATHER_RESOURCES
	current_progress = 0
	_emit_update()

func get_target_for_stage(stage: Stage, cycle: int = current_cycle) -> int:
	match stage:
		Stage.GATHER_RESOURCES:
			return 3 + (cycle - 1) * 2
		Stage.BUILD_STRUCTURE:
			return 3 + (cycle - 1) * 2
		Stage.FORTIFY_SURFACES:
			return 2 + (cycle - 1)
	return 1

func get_stage_title(stage: Stage) -> String:
	match stage:
		Stage.GATHER_RESOURCES:
			return "Gather Resources"
		Stage.BUILD_STRUCTURE:
			return "Build Structure"
		Stage.FORTIFY_SURFACES:
			return "Fortify Surfaces"
	return "Survival Goal"

func get_stage_action_text(stage: Stage) -> String:
	match stage:
		Stage.GATHER_RESOURCES:
			return "Mine Natural Voxels [RMB]"
		Stage.BUILD_STRUCTURE:
			return "Place Grid Blocks [LMB]"
		Stage.FORTIFY_SURFACES:
			return "Apply Mortar to Faces [G]"
	return "Progress Objective"

func get_objective_display_text() -> String:
	var target := get_target_for_stage(current_stage, current_cycle)
	var stage_num: int = int(current_stage) + 1
	return "Cycle %d [%d/3 %s]: %s (%d/%d)" % [
		current_cycle,
		stage_num,
		get_stage_title(current_stage),
		get_stage_action_text(current_stage),
		current_progress,
		target
	]

func on_voxel_mined(_world_cell: Vector3i, _block_type: StringName) -> void:
	if not is_active:
		return
	if current_stage == Stage.GATHER_RESOURCES:
		_advance_progress(1)

func _on_grid_block_placed(_cell: Vector3i, _data: Variant) -> void:
	if not is_active:
		return
	if current_stage == Stage.BUILD_STRUCTURE:
		_advance_progress(1)

func _on_face_coated(_cell: Vector3i, _face_dir: Vector3i) -> void:
	if not is_active:
		return
	if current_stage == Stage.FORTIFY_SURFACES:
		_advance_progress(1)

func _advance_progress(amount: int = 1) -> void:
	current_progress += amount
	var target := get_target_for_stage(current_stage, current_cycle)

	if current_progress >= target:
		_complete_current_stage()
	else:
		_emit_update()

func _complete_current_stage() -> void:
	var completed_stage := current_stage
	var title := get_stage_title(completed_stage)
	objective_stage_completed.emit(int(completed_stage), title)

	if current_stage == Stage.FORTIFY_SURFACES:
		_complete_cycle()
	else:
		current_stage = (int(current_stage) + 1) as Stage
		current_progress = 0
		_emit_update()

func _complete_cycle() -> void:
	var completed_cycle := current_cycle
	var reward_stone := 5 * completed_cycle
	var reward_wood := 3 * completed_cycle

	if has_node("/root/InventoryManager"):
		var inv = get_node("/root/InventoryManager")
		inv.add_material(&"stone", reward_stone)
		inv.add_material(&"wood", reward_wood)

	var reward_desc := "+%d Stone, +%d Wood awarded!" % [reward_stone, reward_wood]
	cycle_completed.emit(completed_cycle, reward_desc)

	current_cycle += 1
	current_stage = Stage.GATHER_RESOURCES
	current_progress = 0
	_emit_update()

func _emit_update() -> void:
	var target := get_target_for_stage(current_stage, current_cycle)
	objective_updated.emit(int(current_stage), current_progress, target, get_objective_display_text())
