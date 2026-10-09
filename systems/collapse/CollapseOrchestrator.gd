class_name CollapseOrchestrator
extends Node

## Coordinates the conversion of unsupported grid blocks into dynamic physics DebrisIslands.
## Ensures atomic removal from GridSystem so no duplicate blocks exist simultaneously.

signal collapse_occurred(islands: Array[DebrisIsland])
signal debris_settled(island: DebrisIsland)

@export var grid_system: GridSystem
@export var stability_system: StabilitySystem
@export var debris_container: Node3D

## List of active debris islands
var _active_debris: Array[DebrisIsland] = []

func _ready() -> void:
	if grid_system == null and has_node("/root/GridSystem"):
		grid_system = get_node("/root/GridSystem")
	if stability_system == null and has_node("/root/StabilitySystem"):
		stability_system = get_node("/root/StabilitySystem")

	if stability_system != null:
		if not stability_system.stability_evaluated.is_connected(_on_stability_evaluated):
			stability_system.stability_evaluated.connect(_on_stability_evaluated)

	if debris_container == null:
		debris_container = self

func _on_stability_evaluated(unsupported_cells: Array[Vector3i]) -> void:
	trigger_collapse(unsupported_cells)

## Executes the collapse transition for the given unsupported cells.
## Returns the newly spawned DebrisIsland instances.
func trigger_collapse(unsupported_cells: Array[Vector3i]) -> Array[DebrisIsland]:
	if unsupported_cells.is_empty():
		return []

	var grid := grid_system
	if grid == null and has_node("/root/GridSystem"):
		grid = get_node("/root/GridSystem")

	if grid == null:
		push_error("CollapseOrchestrator: GridSystem reference is null")
		return []

	# 1. Group unsupported cells into connected component islands
	var island_groups: Array = IslandBuilder.group_islands(unsupported_cells)

	# 2. Atomically remove all unsupported cells from GridSystem to prevent duplicates
	var removed_block_data: Dictionary = grid.remove_cells_batch(unsupported_cells)

	# 3. Instantiate one DebrisIsland per disconnected island group
	var spawned_islands: Array[DebrisIsland] = []

	for group_var in island_groups:
		var cell_group: Array = group_var
		if cell_group.is_empty():
			continue

		var island := DebrisIsland.new()
		debris_container.add_child(island)
		island.setup_island(cell_group, removed_block_data, grid.cell_size)

		island.island_settled.connect(_on_island_settled)
		island.island_fell_out_of_world.connect(_on_island_destroyed)

		_active_debris.append(island)
		spawned_islands.append(island)

	if not spawned_islands.is_empty():
		collapse_occurred.emit(spawned_islands)

	return spawned_islands

func _on_island_settled(island: DebrisIsland) -> void:
	debris_settled.emit(island)

func _on_island_destroyed(island: DebrisIsland) -> void:
	_active_debris.erase(island)

func get_active_debris_count() -> int:
	return _active_debris.size()

func clear_all_debris() -> void:
	for island in _active_debris:
		if is_instance_valid(island):
			island.queue_free()
	_active_debris.clear()
