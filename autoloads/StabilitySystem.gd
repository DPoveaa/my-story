extends Node

## Calculates structural stability and connectivity from foundation anchors.
## Emits stability_evaluated with any unsupported cells.

signal stability_evaluated(unsupported_cells: Array[Vector3i])

const NEIGHBORS_6: Array[Vector3i] = [
	Vector3i(0, 1, 0),  # Up
	Vector3i(0, -1, 0), # Down
	Vector3i(1, 0, 0),  # Right (+X)
	Vector3i(-1, 0, 0), # Left (-X)
	Vector3i(0, 0, 1),  # Forward (+Z)
	Vector3i(0, 0, -1)  # Backward (-Z)
]

## Ground foundation Y level (blocks at this Y level are direct anchors)
@export var ground_anchor_y: int = 0

## Optional custom anchor cells (e.g. bedrock, cliffs, immovable structures)
var _custom_anchors: Dictionary = {}

## Cached set of currently supported cells
var _supported_cells: Dictionary = {}

## Re-entrancy guard to prevent recursive collapse cascades
var _is_evaluating: bool = false

## Reference to GridSystem
@export var grid_system: Node
## Optional reference to TerrainGenerator for procedural ground support
var terrain_generator: Node = null

## Reference to JointSystem
@export var joint_system: Node
## Whether lateral / hanging support strictly requires cemented structural joints (M2.3)
@export var require_joints_for_lateral_support: bool = false

func _ready() -> void:
	if grid_system == null and has_node("/root/GridSystem"):
		grid_system = get_node("/root/GridSystem")
	if joint_system == null and has_node("/root/JointSystem"):
		joint_system = get_node("/root/JointSystem")

	if grid_system != null:
		_connect_grid_signals()
	if joint_system != null:
		_connect_joint_signals()

func _connect_grid_signals() -> void:
	if not grid_system.block_placed.is_connected(_on_block_placed):
		grid_system.block_placed.connect(_on_block_placed)
	if not grid_system.block_removed.is_connected(_on_block_removed):
		grid_system.block_removed.connect(_on_block_removed)
	if not grid_system.grid_cleared.is_connected(_on_grid_cleared):
		grid_system.grid_cleared.connect(_on_grid_cleared)

func _connect_joint_signals() -> void:
	if not joint_system.joint_broken.is_connected(_on_joint_broken):
		joint_system.joint_broken.connect(_on_joint_broken)
	if not joint_system.joint_created.is_connected(_on_joint_created):
		joint_system.joint_created.connect(_on_joint_created)
	if joint_system.has_signal("joint_reinforced") and not joint_system.joint_reinforced.is_connected(_on_joint_created):
		joint_system.joint_reinforced.connect(_on_joint_created)

func _on_joint_broken(_joint: Variant) -> void:
	if not _is_evaluating:
		call_deferred("recalculate_stability")

func _on_joint_created(_joint: Variant) -> void:
	if not _is_evaluating:
		call_deferred("recalculate_stability")

func _on_block_placed(cell: Vector3i, _data: BlockData) -> void:
	# If placed cell directly connects to an anchor or an already supported block, mark supported immediately
	if is_anchor_cell(cell):
		_supported_cells[cell] = true
	else:
		var has_support: bool = false
		var check_joints: bool = (joint_system != null and require_joints_for_lateral_support)
		if check_joints:
			# Directly on top of an already supported block (vertical resting)
			if _supported_cells.has(cell + Vector3i.DOWN):
				has_support = true
			else:
				# Or connected via intact joint to any supported neighbor
				for offset in NEIGHBORS_6:
					var neighbor: Vector3i = cell + offset
					if _supported_cells.has(neighbor):
						if joint_system.has_intact_joint(cell, neighbor):
							has_support = true
							break
						elif not joint_system.has_joint(cell, neighbor):
							joint_system._create_default_joint(cell, neighbor)
							has_support = true
							break
		else:
			for offset in NEIGHBORS_6:
				if _supported_cells.has(cell + offset):
					has_support = true
					break

		if has_support:
			_supported_cells[cell] = true
		else:
			# Placed in midair without immediate support - trigger evaluation
			if not _is_evaluating:
				call_deferred("recalculate_stability")

func _on_block_removed(_cell: Vector3i, _data: BlockData) -> void:
	if not _is_evaluating:
		call_deferred("recalculate_stability")

func _on_grid_cleared() -> void:
	_supported_cells.clear()

# ==============================================================================
# ANCHOR MANAGEMENT
# ==============================================================================

## Tests whether a cell is a valid ground/foundation anchor.
func is_anchor_cell(cell: Vector3i) -> bool:
	if cell.y <= ground_anchor_y or _custom_anchors.has(cell):
		return true
	if terrain_generator != null and terrain_generator.has_method("is_ground_cell"):
		return terrain_generator.is_ground_cell(cell)
	return false

func register_custom_anchor(cell: Vector3i) -> void:
	_custom_anchors[cell] = true

func unregister_custom_anchor(cell: Vector3i) -> void:
	_custom_anchors.erase(cell)

func clear_custom_anchors() -> void:
	_custom_anchors.clear()

# ==============================================================================
# STABILITY EVALUATION (BFS CONNECTIVITY)
# ==============================================================================

## Checks if a specific cell was marked as supported during the last evaluation.
func is_cell_supported(cell: Vector3i) -> bool:
	return _supported_cells.has(cell)

## Evaluates regional stability around a modified cell when safe,
## falling back to full evaluation if complex connectivity changes are detected.
func evaluate_affected_region(removed_cell: Vector3i) -> Array[Vector3i]:
	var grid := grid_system
	if grid == null and has_node("/root/GridSystem"):
		grid = get_node("/root/GridSystem")
	if grid == null:
		return []

	# Check occupied neighbors of the removed cell
	var occupied_neighbors: Array[Vector3i] = []
	for offset in NEIGHBORS_6:
		var n: Vector3i = removed_cell + offset
		if grid.has_block(n):
			occupied_neighbors.append(n)

	# If no neighbors, no other blocks could have relied on this removed cell
	if occupied_neighbors.is_empty():
		_supported_cells.erase(removed_cell)
		return []

	# Use full evaluation as comprehensive correctness fallback
	return evaluate_stability()

## Evaluates the structural stability of all blocks in GridSystem.
## Returns an Array[Vector3i] of all occupied cells that have lost structural support.
func evaluate_stability() -> Array[Vector3i]:
	var grid := grid_system
	if grid == null and has_node("/root/GridSystem"):
		grid = get_node("/root/GridSystem")

	if grid == null:
		push_error("StabilitySystem: No GridSystem found")
		return []

	var all_cells: Array[Vector3i] = grid.get_all_cells()
	if all_cells.is_empty():
		_supported_cells.clear()
		return []

	# BFS Queue and visited map
	var queue: Array[Vector3i] = []
	var visited: Dictionary = {}

	# 1. Seed BFS with all occupied cells that are valid anchors
	for cell in all_cells:
		if is_anchor_cell(cell):
			visited[cell] = true
			queue.append(cell)

	# 2. Propagate support via graph search
	var head: int = 0
	var check_joints: bool = (joint_system != null and require_joints_for_lateral_support)
	while head < queue.size():
		var current: Vector3i = queue[head]
		head += 1

		for offset in NEIGHBORS_6:
			var neighbor: Vector3i = current + offset
			if not visited.has(neighbor) and grid.has_block(neighbor):
				if check_joints:
					# Vertical resting support: current is directly below neighbor
					var is_resting_vertical: bool = (offset == Vector3i.UP)
					# Or structural joint connects current and neighbor
					var has_joint: bool = joint_system.has_intact_joint(current, neighbor)
					if not has_joint and not joint_system.has_joint(current, neighbor):
						joint_system._create_default_joint(current, neighbor)
						has_joint = true
					if is_resting_vertical or has_joint:
						visited[neighbor] = true
						queue.append(neighbor)
				else:
					visited[neighbor] = true
					queue.append(neighbor)

	# 3. Identify all occupied cells that were NOT reached
	var unsupported: Array[Vector3i] = []
	for cell in all_cells:
		if not visited.has(cell):
			unsupported.append(cell)

	_supported_cells = visited
	return unsupported

## Runs stability evaluation and emits signal if unsupported cells are detected.
## Strictly guards re-entrancy during collapse signal dispatch.
func recalculate_stability() -> Array[Vector3i]:
	if _is_evaluating:
		return []

	_is_evaluating = true
	var unsupported := evaluate_stability()
	if not unsupported.is_empty():
		stability_evaluated.emit(unsupported)
	_is_evaluating = false

	return unsupported

