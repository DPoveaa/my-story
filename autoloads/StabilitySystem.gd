class_name StabilitySystem
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
@export var grid_system: GridSystem

func _ready() -> void:
	if grid_system == null and has_node("/root/GridSystem"):
		grid_system = get_node("/root/GridSystem")

	if grid_system != null:
		_connect_grid_signals()

func _connect_grid_signals() -> void:
	if not grid_system.block_removed.is_connected(_on_block_removed):
		grid_system.block_removed.connect(_on_block_removed)
	if not grid_system.grid_cleared.is_connected(_on_grid_cleared):
		grid_system.grid_cleared.connect(_on_grid_cleared)

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
	return cell.y <= ground_anchor_y or _custom_anchors.has(cell)

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

## Evaluates the structural stability of all blocks in GridSystem.
## Returns an Array[Vector3i] of all occupied cells that have lost structural support.
func evaluate_stability() -> Array[Vector3i]:
	var grid := grid_system
	if grid == null and has_node("/root/GridSystem"):
		grid = get_node("/root/GridSystem")

	if grid == null:
		push_error("StabilitySystem: No GridSystem found")
		return []

	var all_cells := grid.get_all_cells()
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

	# 2. Propagate support via 6-connectivity graph search
	var head: int = 0
	while head < queue.size():
		var current: Vector3i = queue[head]
		head += 1

		for offset in NEIGHBORS_6:
			var neighbor: Vector3i = current + offset
			if not visited.has(neighbor) and grid.has_block(neighbor):
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
func recalculate_stability() -> Array[Vector3i]:
	if _is_evaluating:
		return []

	_is_evaluating = true
	var unsupported := evaluate_stability()
	_is_evaluating = false

	if not unsupported.is_empty():
		stability_evaluated.emit(unsupported)

	return unsupported
