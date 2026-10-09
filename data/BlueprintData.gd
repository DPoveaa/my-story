class_name BlueprintData
extends RefCounted

## Authoritative data representation for a registered construction blueprint.
## Independent of live scene/physics nodes to prevent corruption from collapses or debris.
## Serializes to and deserializes from versioned JSON format.

const FORMAT_VERSION: int = 1

var name: String = "unnamed"
var format_version: int = FORMAT_VERSION
var description: String = ""
var created_at: String = ""
var anchor_cell: Vector3i = Vector3i.ZERO
var bounds_min: Vector3i = Vector3i.ZERO
var bounds_max: Vector3i = Vector3i.ZERO

## Array of block entries:
## [ { "rel_pos": [x,y,z], "block_type": "stone", "durability": 1.0, "metadata": {} }, ... ]
var blocks: Array = []

## Array of structural joint entries between relative cell positions:
## [ { "rel_a": [x,y,z], "rel_b": [x,y,z], "strength": 90.0, "is_mortared": true, "material_a": "stone", "material_b": "stone" }, ... ]
var joints: Array = []

func _init(p_name: String = "unnamed") -> void:
	name = p_name
	created_at = Time.get_datetime_string_from_system(false, true)

func get_block_count() -> int:
	return blocks.size()

func get_dimensions() -> Vector3i:
	if blocks.is_empty():
		return Vector3i.ZERO
	return bounds_max - bounds_min + Vector3i.ONE

func get_block_at_rel_pos(rel_pos: Vector3i) -> Dictionary:
	var target_arr := [rel_pos.x, rel_pos.y, rel_pos.z]
	for b in blocks:
		if b is Dictionary and b.get("rel_pos", []) == target_arr:
			return b
	return {}

## Serializes this blueprint into a structured Dictionary.
func to_dict() -> Dictionary:
	return {
		"format_version": format_version,
		"name": name,
		"description": description,
		"created_at": created_at,
		"anchor_cell": [anchor_cell.x, anchor_cell.y, anchor_cell.z],
		"bounds_min": [bounds_min.x, bounds_min.y, bounds_min.z],
		"bounds_max": [bounds_max.x, bounds_max.y, bounds_max.z],
		"blocks": blocks.duplicate(true),
		"joints": joints.duplicate(true)
	}

## Deserializes a BlueprintData instance from a dictionary safely.
## Returns null if the dictionary format is invalid.
static func from_dict(dict: Dictionary) -> BlueprintData:
	if dict.is_empty():
		push_error("BlueprintData: Cannot load from empty dictionary")
		return null

	var ver: int = int(dict.get("format_version", 0))
	if ver != FORMAT_VERSION:
		push_warning("BlueprintData: Format version mismatch (got %d, expected %d)" % [ver, FORMAT_VERSION])

	var bp_name: String = String(dict.get("name", "unnamed"))
	var bp := BlueprintData.new(bp_name)
	bp.format_version = ver
	bp.description = String(dict.get("description", ""))
	bp.created_at = String(dict.get("created_at", ""))

	var anchor_arr = dict.get("anchor_cell", [0, 0, 0])
	if anchor_arr is Array and anchor_arr.size() == 3:
		bp.anchor_cell = Vector3i(int(anchor_arr[0]), int(anchor_arr[1]), int(anchor_arr[2]))

	var bmin_arr = dict.get("bounds_min", [0, 0, 0])
	if bmin_arr is Array and bmin_arr.size() == 3:
		bp.bounds_min = Vector3i(int(bmin_arr[0]), int(bmin_arr[1]), int(bmin_arr[2]))

	var bmax_arr = dict.get("bounds_max", [0, 0, 0])
	if bmax_arr is Array and bmax_arr.size() == 3:
		bp.bounds_max = Vector3i(int(bmax_arr[0]), int(bmax_arr[1]), int(bmax_arr[2]))

	var raw_blocks = dict.get("blocks", null)
	if not (raw_blocks is Array):
		push_error("BlueprintData: Missing or invalid 'blocks' array")
		return null

	bp.blocks = []
	for item in raw_blocks:
		if not (item is Dictionary):
			continue
		var pos_arr = item.get("rel_pos", null)
		if not (pos_arr is Array and pos_arr.size() == 3):
			continue
		var block_entry: Dictionary = {
			"rel_pos": [int(pos_arr[0]), int(pos_arr[1]), int(pos_arr[2])],
			"block_type": String(item.get("block_type", "stone")),
			"durability": float(item.get("durability", 1.0)),
			"metadata": item.get("metadata", {}).duplicate(true)
		}
		bp.blocks.append(block_entry)

	var raw_joints = dict.get("joints", [])
	bp.joints = []
	if raw_joints is Array:
		for j_item in raw_joints:
			if not (j_item is Dictionary):
				continue
			var a_arr = j_item.get("rel_a", null)
			var b_arr = j_item.get("rel_b", null)
			if not (a_arr is Array and a_arr.size() == 3 and b_arr is Array and b_arr.size() == 3):
				continue
			var joint_entry: Dictionary = {
				"rel_a": [int(a_arr[0]), int(a_arr[1]), int(a_arr[2])],
				"rel_b": [int(b_arr[0]), int(b_arr[1]), int(b_arr[2])],
				"strength": float(j_item.get("strength", 50.0)),
				"is_mortared": bool(j_item.get("is_mortared", false)),
				"material_a": String(j_item.get("material_a", "stone")),
				"material_b": String(j_item.get("material_b", "stone"))
			}
			bp.joints.append(joint_entry)

	return bp

## Converts the blueprint to formatted JSON text.
func to_json_string() -> String:
	return JSON.stringify(to_dict(), "\t")

## Parses a BlueprintData instance from JSON text.
static func from_json_string(json_text: String) -> BlueprintData:
	var json := JSON.new()
	var err := json.parse(json_text)
	if err != OK:
		push_error("BlueprintData: JSON parse error at line %d: %s" % [json.get_error_line(), json.get_error_message()])
		return null
	if not (json.data is Dictionary):
		push_error("BlueprintData: Root JSON value is not a Dictionary")
		return null
	return from_dict(json.data)

## Saves the blueprint to a specified file path.
func save_to_file(path: String) -> Error:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		var err := FileAccess.get_open_error()
		push_error("BlueprintData: Failed to open file for writing '%s' (Error %d)" % [path, err])
		return err
	file.store_string(to_json_string())
	file.close()
	return OK

## Loads a blueprint from a specified file path safely.
static func load_from_file(path: String) -> BlueprintData:
	if not FileAccess.file_exists(path):
		push_warning("BlueprintData: File does not exist '%s'" % path)
		return null
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		var err := FileAccess.get_open_error()
		push_error("BlueprintData: Failed to open file for reading '%s' (Error %d)" % [path, err])
		return null
	var content: String = file.get_as_text()
	file.close()
	return from_json_string(content)
