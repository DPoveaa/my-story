extends Node

## GridSystem is the authoritative single source of truth for stable construction blocks.
## It maintains a sparse map of cell coordinates to BlockData.

signal block_placed(cell: Vector3i, data: BlockData)
signal block_removed(cell: Vector3i, data: BlockData)
signal blocks_removed_batch(cells: Array[Vector3i], data_map: Dictionary)
signal block_damaged(cell: Vector3i, new_durability: float)
signal grid_cleared()

## Cell size in meters (configurable, default 1.0m)
@export var cell_size: float = 1.0

## Minimum Y coordinate allowed for block placement (default: 0 = ground level)
@export var min_y: int = 0
## Maximum coordinate bounds for sanity limits (can be expanded)
@export var max_coord_bound: int = 256

## Sparse dictionary storing occupied cells: Dictionary[Vector3i, BlockData]
var _blocks: Dictionary = {}

func _ready() -> void:
	pass

# ==============================================================================
# COORDINATE CONVERSIONS
# ==============================================================================

## Converts world position to grid cell coordinate.
func world_to_cell(pos: Vector3) -> Vector3i:
	return Vector3i(
		floori(pos.x / cell_size),
		floori(pos.y / cell_size),
		floori(pos.z / cell_size)
	)

## Converts grid cell coordinate to the center point in world space.
func cell_to_world_center(cell: Vector3i) -> Vector3:
	return Vector3(
		(float(cell.x) + 0.5) * cell_size,
		(float(cell.y) + 0.5) * cell_size,
		(float(cell.z) + 0.5) * cell_size
	)

## Converts grid cell coordinate to the minimum corner in world space.
func cell_to_world_min(cell: Vector3i) -> Vector3:
	return Vector3(
		float(cell.x) * cell_size,
		float(cell.y) * cell_size,
		float(cell.z) * cell_size
	)

# ==============================================================================
# QUERIES
# ==============================================================================

## Checks if a cell is currently occupied by a block.
func has_block(cell: Vector3i) -> bool:
	return _blocks.has(cell)

## Retrieves the BlockData for a cell, or null if empty.
func get_block(cell: Vector3i) -> BlockData:
	return _blocks.get(cell, null)

## Returns all currently occupied cell coordinates.
func get_all_cells() -> Array[Vector3i]:
	var result: Array[Vector3i] = []
	for c in _blocks.keys():
		result.append(c)
	return result

## Returns the total number of blocks in the grid.
func get_block_count() -> int:
	return _blocks.size()

## Validates if placement at cell is permissible.
func can_place_block(cell: Vector3i) -> bool:
	if _blocks.has(cell):
		return false
	if cell.y < min_y:
		return false
	if absi(cell.x) > max_coord_bound or absi(cell.z) > max_coord_bound or cell.y > max_coord_bound:
		return false
	return true

# ==============================================================================
# MODIFICATIONS
# ==============================================================================

## Places a block at cell. Accepts BlockData or StringName type.
## Returns true on success, false if invalid or already occupied.
func place_block(cell: Vector3i, block_data_or_type: Variant = &"stone") -> bool:
	if not can_place_block(cell):
		return false

	var data: BlockData
	if block_data_or_type is BlockData:
		data = (block_data_or_type as BlockData).duplicate_data()
	elif block_data_or_type is StringName or block_data_or_type is String:
		data = BlockData.new(StringName(block_data_or_type), 1.0)
	else:
		data = BlockData.new(&"stone", 1.0)

	_blocks[cell] = data
	block_placed.emit(cell, data)
	return true

## Removes a block at cell. Returns the removed BlockData, or null if cell was empty.
func remove_block(cell: Vector3i) -> BlockData:
	if not _blocks.has(cell):
		return null
	var removed_data: BlockData = _blocks[cell]
	_blocks.erase(cell)
	block_removed.emit(cell, removed_data)
	return removed_data

## Atomically removes a batch of cells from the grid (used during collapse).
## Returns a Dictionary[Vector3i, BlockData] of the removed blocks.
func remove_cells_batch(cells: Array) -> Dictionary:
	var removed_map: Dictionary = {}
	var removed_keys: Array[Vector3i] = []
	for cell in cells:
		if _blocks.has(cell):
			removed_map[cell] = _blocks[cell]
			_blocks.erase(cell)
			removed_keys.append(cell)

	if not removed_keys.is_empty():
		blocks_removed_batch.emit(removed_keys, removed_map)
	return removed_map

## Applies damage to a block at cell. If durability drops to 0 or below, removes it.
## Returns true if block was destroyed, false otherwise.
func apply_damage(cell: Vector3i, damage_amount: float) -> bool:
	if not _blocks.has(cell):
		return false
	var data: BlockData = _blocks[cell]
	data.durability = maxf(0.0, data.durability - damage_amount)
	block_damaged.emit(cell, data.durability)
	if data.durability <= 0.0:
		remove_block(cell)
		return true
	return false

## Clears all blocks from the grid.
func clear() -> void:
	_blocks.clear()
	grid_cleared.emit()

# ==============================================================================
# PERSISTENCE (VERSIONED JSON)
# ==============================================================================

const SAVE_FORMAT_VERSION: int = 1

## Serializes the grid state into a versioned JSON string.
func serialize_json() -> String:
	var blocks_list: Array = []
	for cell: Vector3i in _blocks.keys():
		var data: BlockData = _blocks[cell]
		blocks_list.append({
			"pos": [cell.x, cell.y, cell.z],
			"data": data.to_dict()
		})
	var dict: Dictionary = {
		"format_version": SAVE_FORMAT_VERSION,
		"cell_size": cell_size,
		"blocks": blocks_list
	}
	return JSON.stringify(dict, "\t")

## Loads grid state from a versioned JSON string.
## Replaces current grid. Returns true on success, false on error without corrupting state.
func deserialize_json(json_text: String) -> bool:
	var json := JSON.new()
	var error := json.parse(json_text)
	if error != OK:
		push_error("GridSystem: JSON parse error at line %d: %s" % [json.get_error_line(), json.get_error_message()])
		return false

	var dict = json.data
	if not (dict is Dictionary):
		push_error("GridSystem: Invalid root JSON type, expected Dictionary")
		return false

	var version: int = dict.get("format_version", 0)
	if version != SAVE_FORMAT_VERSION:
		push_warning("GridSystem: Unrecognized save format version %d (expected %d)" % [version, SAVE_FORMAT_VERSION])

	var new_cell_size: float = float(dict.get("cell_size", 1.0))
	var blocks_data = dict.get("blocks", null)
	if not (blocks_data is Array):
		push_error("GridSystem: Missing or invalid 'blocks' array")
		return false

	# Parse blocks into temporary buffer first to guarantee atomic swap
	var parsed_blocks: Dictionary = {}
	for item in blocks_data:
		if not (item is Dictionary):
			continue
		var pos_arr = item.get("pos", null)
		var block_dict = item.get("data", null)
		if pos_arr is Array and pos_arr.size() == 3 and block_dict is Dictionary:
			var cell := Vector3i(int(pos_arr[0]), int(pos_arr[1]), int(pos_arr[2]))
			parsed_blocks[cell] = BlockData.from_dict(block_dict)

	# Swap state
	clear()
	cell_size = new_cell_size
	for cell: Vector3i in parsed_blocks.keys():
		_blocks[cell] = parsed_blocks[cell]
		block_placed.emit(cell, _blocks[cell])

	return true
