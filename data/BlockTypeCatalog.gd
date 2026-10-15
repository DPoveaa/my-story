class_name BlockTypeCatalog
extends RefCounted

## Catalog of block types, visual colors, and physical attributes.

const TYPES: Dictionary = {
	&"grass": {
		"name": "Grass",
		"color": Color(0.30, 0.62, 0.18),
		"mass": 1.2,
		"max_durability": 0.6
	},
	&"dirt": {
		"name": "Dirt",
		"color": Color(0.52, 0.36, 0.18),
		"mass": 1.4,
		"max_durability": 0.6
	},
	&"stone": {
		"name": "Stone",
		"color": Color(0.62, 0.64, 0.68),
		"mass": 2.5,
		"max_durability": 1.0
	},
	&"coal": {
		"name": "Coal",
		"color": Color(0.14, 0.14, 0.16),
		"mass": 1.8,
		"max_durability": 0.9
	},
	&"iron": {
		"name": "Iron",
		"color": Color(0.70, 0.68, 0.62),
		"mass": 3.5,
		"max_durability": 1.2
	},
	&"wood": {
		"name": "Wood",
		"color": Color(0.58, 0.40, 0.24),
		"mass": 0.9,
		"max_durability": 0.8
	},
	&"brick": {
		"name": "Brick",
		"color": Color(0.78, 0.35, 0.28),
		"mass": 1.8,
		"max_durability": 1.0
	},
	&"gold": {
		"name": "Gold",
		"color": Color(0.95, 0.78, 0.22),
		"mass": 4.0,
		"max_durability": 1.5
	}
}

static func get_type_names() -> Array[StringName]:
	var result: Array[StringName] = []
	for key in TYPES.keys():
		result.append(key)
	return result

static func get_display_name(type_id: StringName) -> String:
	if TYPES.has(type_id):
		return TYPES[type_id].get("name", String(type_id).capitalize())
	return String(type_id).capitalize()

static func get_color(type_id: StringName) -> Color:
	if TYPES.has(type_id):
		return TYPES[type_id].get("color", Color.WHITE)
	return Color.WHITE

static func get_mass(type_id: StringName) -> float:
	if TYPES.has(type_id):
		return TYPES[type_id].get("mass", 1.0)
	return 1.0

static func get_max_durability(type_id: StringName) -> float:
	if TYPES.has(type_id):
		return TYPES[type_id].get("max_durability", 1.0)
	return 1.0

static func get_cost(type_id: StringName) -> Dictionary:
	return {type_id: 1}

static func is_natural(type_id: StringName) -> bool:
	match type_id:
		&"grass", &"dirt", &"stone", &"coal", &"iron":
			return true
		_:
			return false

static func is_structural(type_id: StringName) -> bool:
	return not is_natural(type_id)
