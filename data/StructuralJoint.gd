class_name StructuralJoint
extends RefCounted

## Represents a structural joint between two adjacent blocks.
## Tracks joint health, maximum strength, material properties, and face normal.
## Supports immediate breakage from high impact and accumulated damage from repeated loads.

signal joint_damaged(joint: StructuralJoint, damage: float, remaining_health: float)
signal joint_broken(joint: StructuralJoint)

var cell_a: Vector3i
var cell_b: Vector3i
var face_normal: Vector3i # Direction from cell_a to cell_b
var max_strength: float = 100.0
var current_health: float = 100.0
var material_a: StringName = &"stone"
var material_b: StringName = &"stone"
var is_broken: bool = false

func _init(
	p_cell_a: Vector3i = Vector3i.ZERO,
	p_cell_b: Vector3i = Vector3i.ZERO,
	p_strength: float = 100.0,
	p_mat_a: StringName = &"stone",
	p_mat_b: StringName = &"stone"
) -> void:
	cell_a = p_cell_a
	cell_b = p_cell_b
	face_normal = p_cell_b - p_cell_a
	max_strength = maxf(1.0, p_strength)
	current_health = max_strength
	material_a = p_mat_a
	material_b = p_mat_b
	is_broken = false

## Canonical deterministic key for dictionary indexing, avoiding order ambiguity between (A, B) and (B, A).
static func make_key(a: Vector3i, b: Vector3i) -> String:
	if a.x < b.x or (a.x == b.x and (a.y < b.y or (a.y == b.y and a.z < b.z))):
		return "%d,%d,%d:%d,%d,%d" % [a.x, a.y, a.z, b.x, b.y, b.z]
	else:
		return "%d,%d,%d:%d,%d,%d" % [b.x, b.y, b.z, a.x, a.y, a.z]

func get_key() -> String:
	return make_key(cell_a, cell_b)

## Applies damage to this joint. Returns true if the joint broke as a result.
func apply_damage(amount: float) -> bool:
	if is_broken:
		return false
	if amount <= 0.0:
		return false

	current_health = maxf(0.0, current_health - amount)
	joint_damaged.emit(self, amount, current_health)

	if current_health <= 0.0:
		break_joint()
		return true
	return false

## Immediately breaks the joint regardless of current health.
func break_joint() -> void:
	if not is_broken:
		is_broken = true
		current_health = 0.0
		joint_broken.emit(self)

## Returns the health ratio between 0.0 and 1.0.
func get_health_ratio() -> float:
	if max_strength <= 0.0:
		return 0.0
	return clampf(current_health / max_strength, 0.0, 1.0)

## Tests whether a cell is one of the two endpoints of this joint.
func connects_cell(cell: Vector3i) -> bool:
	return cell == cell_a or cell == cell_b

## Returns the adjacent cell connected across this joint from the given cell.
func get_other_cell(cell: Vector3i) -> Vector3i:
	if cell == cell_a:
		return cell_b
	elif cell == cell_b:
		return cell_a
	return Vector3i.ZERO

## Serializes joint state for save/load or replication.
func to_dict() -> Dictionary:
	return {
		"cell_a": [cell_a.x, cell_a.y, cell_a.z],
		"cell_b": [cell_b.x, cell_b.y, cell_b.z],
		"max_strength": max_strength,
		"current_health": current_health,
		"material_a": String(material_a),
		"material_b": String(material_b),
		"is_broken": is_broken
	}

static func from_dict(dict: Dictionary) -> RefCounted:
	var a_arr: Array = dict.get("cell_a", [0, 0, 0])
	var b_arr: Array = dict.get("cell_b", [0, 0, 0])
	var ca := Vector3i(int(a_arr[0]), int(a_arr[1]), int(a_arr[2]))
	var cb := Vector3i(int(b_arr[0]), int(b_arr[1]), int(b_arr[2]))
	var max_s: float = float(dict.get("max_strength", 100.0))
	var cur_h: float = float(dict.get("current_health", max_s))
	var ma := StringName(dict.get("material_a", "stone"))
	var mb := StringName(dict.get("material_b", "stone"))

	var script_res: GDScript = load("res://data/StructuralJoint.gd") as GDScript
	var joint = script_res.new(ca, cb, max_s, ma, mb)
	joint.current_health = cur_h
	joint.is_broken = bool(dict.get("is_broken", false))
	return joint
