extends Node

## Centralized inventory/resource manager for construction materials.
## Tracks available quantities of materials (stone, wood, brick, gold),
## handles persistence (user://inventory.json), validates placement costs,
## and emits signals when inventory changes.

signal inventory_changed(materials: Dictionary)
signal material_consumed(type_id: StringName, amount: int)
signal material_added(type_id: StringName, amount: int)

const SAVE_PATH: String = "user://inventory.json"
const SAVE_VERSION: int = 1

## Default starting inventory
@export var default_starting_materials: Dictionary = {
	"stone": 50,
	"wood": 30,
	"brick": 30,
	"gold": 10
}

var _materials: Dictionary = {}

func _ready() -> void:
	if not load_inventory():
		reset_to_default_materials()

func reset_to_default_materials() -> void:
	_materials.clear()
	for k in default_starting_materials.keys():
		_materials[StringName(k)] = int(default_starting_materials[k])
	inventory_changed.emit(_materials.duplicate(true))

func get_materials() -> Dictionary:
	return _materials.duplicate(true)

func get_material_count(type_id: StringName) -> int:
	return int(_materials.get(type_id, 0))

func set_material_count(type_id: StringName, amount: int) -> void:
	_materials[type_id] = maxi(0, amount)
	inventory_changed.emit(_materials.duplicate(true))
	save_inventory()

func add_material(type_id: StringName, amount: int = 1) -> void:
	if amount <= 0:
		return
	var current: int = get_material_count(type_id)
	_materials[type_id] = current + amount
	material_added.emit(type_id, amount)
	inventory_changed.emit(_materials.duplicate(true))
	save_inventory()

func has_materials(costs: Dictionary) -> bool:
	for mat in costs.keys():
		var mat_type := StringName(mat)
		var required: int = int(costs[mat])
		if get_material_count(mat_type) < required:
			return false
	return true

func consume_materials(costs: Dictionary) -> bool:
	if not has_materials(costs):
		return false

	for mat in costs.keys():
		var mat_type := StringName(mat)
		var required: int = int(costs[mat])
		_materials[mat_type] = get_material_count(mat_type) - required
		material_consumed.emit(mat_type, required)

	inventory_changed.emit(_materials.duplicate(true))
	save_inventory()
	return true

# ==============================================================================
# PERSISTENCE (user://inventory.json)
# ==============================================================================

func save_inventory() -> bool:
	var dict: Dictionary = {
		"version": SAVE_VERSION,
		"materials": {}
	}
	for k in _materials.keys():
		dict["materials"][String(k)] = int(_materials[k])

	var file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(dict, "\t"))
	file.close()
	return true

func load_inventory() -> bool:
	if not FileAccess.file_exists(SAVE_PATH):
		return false

	var file := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if file == null:
		return false

	var content: String = file.get_as_text()
	file.close()

	var json := JSON.new()
	var err := json.parse(content)
	if err != OK or not (json.data is Dictionary):
		push_warning("InventoryManager: Failed to parse inventory save file, using default materials")
		return false

	var dict: Dictionary = json.data
	var mats = dict.get("materials", null)
	if not (mats is Dictionary):
		return false

	_materials.clear()
	for k in mats.keys():
		_materials[StringName(k)] = maxi(0, int(mats[k]))

	inventory_changed.emit(_materials.duplicate(true))
	return true
