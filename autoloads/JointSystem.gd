extends Node

## Central authoritative manager for structural joints, default block connections, and surface-based mortar brush.
## Maintains active joints between grid blocks, manages surface mortar painting,
## calculates impact damage and force distribution, and emits signals on joint changes.

signal joint_created(joint: RefCounted)
signal joint_reinforced(joint: RefCounted)
signal joint_damaged(joint: RefCounted, damage: float, remaining_health: float)
signal joint_broken(joint: RefCounted)
signal joint_removed(joint: RefCounted)
signal face_coated(cell: Vector3i, face_dir: Vector3i)
signal joints_cleared()

const StructuralJointScript = preload("res://data/StructuralJoint.gd")

## Base strength for weak default connections between adjacent unmortared blocks
@export var default_joint_strength: float = 25.0

## Minimum impact energy (Joules) required before a joint sustains damage (filters out minor noise/brushing)
@export var impact_energy_min_threshold: float = 8.0

## Multiplier of joint max_strength above which a single impact causes immediate catastrophic breakage
@export var immediate_break_multiplier: float = 1.8

## Active structural joints: Dictionary[String, RefCounted]
var _joints: Dictionary = {}

## Fast lookup index: Dictionary[Vector3i, Array]
var _cell_to_joints: Dictionary = {}

## Faces coated with mortar: Dictionary[String, bool]
## Key format: "%d,%d,%d:%d,%d,%d" (cell:face_dir)
var _coated_faces: Dictionary = {}

## Optional reference to GridSystem
@export var grid_system: Node:
	set(val):
		grid_system = val
		if grid_system != null:
			_connect_grid_signals()

## Optional reference to StabilitySystem
@export var stability_system: Node

const NEIGHBORS_6: Array[Vector3i] = [
	Vector3i(0, 1, 0), Vector3i(0, -1, 0),
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1)
]

func _ready() -> void:
	if grid_system == null and has_node("/root/GridSystem"):
		grid_system = get_node("/root/GridSystem")
	if stability_system == null and has_node("/root/StabilitySystem"):
		stability_system = get_node("/root/StabilitySystem")

	if grid_system != null:
		_connect_grid_signals()

func _connect_grid_signals() -> void:
	if not grid_system.block_placed.is_connected(_on_grid_block_placed):
		grid_system.block_placed.connect(_on_grid_block_placed)
	if not grid_system.block_removed.is_connected(_on_grid_block_removed):
		grid_system.block_removed.connect(_on_grid_block_removed)
	if not grid_system.grid_cleared.is_connected(_on_grid_cleared):
		grid_system.grid_cleared.connect(_on_grid_cleared)

func _face_key(cell: Vector3i, face_dir: Vector3i) -> String:
	return "%d,%d,%d:%d,%d,%d" % [cell.x, cell.y, cell.z, face_dir.x, face_dir.y, face_dir.z]

# ==============================================================================
# COMPATIBILITY & STRENGTH CONFIGURATION
# ==============================================================================

## Returns whether two block materials can form structural joints.
func are_materials_compatible(type_a: StringName, type_b: StringName) -> bool:
	var valid_types: Array[StringName] = [&"stone", &"wood", &"brick", &"gold"]
	return type_a in valid_types and type_b in valid_types

## Calculates base maximum joint strength when reinforced with mortar.
func calculate_base_strength(type_a: StringName, type_b: StringName) -> float:
	var pair: Array[StringName] = [type_a, type_b]
	pair.sort()

	# Masonry-to-masonry (high tensile/shear resistance)
	if pair[0] == &"stone" and pair[1] == &"stone":
		return 100.0
	elif pair[0] == &"brick" and pair[1] == &"stone":
		return 95.0
	elif pair[0] == &"brick" and pair[1] == &"brick":
		return 90.0

	# Masonry-to-wood or wood-to-wood
	elif pair[0] == &"stone" and pair[1] == &"wood":
		return 65.0
	elif pair[0] == &"brick" and pair[1] == &"wood":
		return 60.0
	elif pair[0] == &"wood" and pair[1] == &"wood":
		return 50.0

	# Dense metal (gold) combinations
	elif pair[0] == &"gold" and pair[1] == &"stone":
		return 55.0
	elif pair[0] == &"brick" and pair[1] == &"gold":
		return 50.0
	elif pair[0] == &"gold" and pair[1] == &"gold":
		return 40.0
	elif pair[0] == &"gold" and pair[1] == &"wood":
		return 35.0

	return 70.0

## Calculates weak default strength for unmortared connections.
func calculate_default_strength(type_a: StringName, type_b: StringName) -> float:
	var base := calculate_base_strength(type_a, type_b)
	return maxf(5.0, default_joint_strength * (base / 100.0))

# ==============================================================================
# SURFACE-BASED MORTAR BRUSH
# ==============================================================================

## Returns the 4 coplanar directions in a 2D '+' pattern orthogonal to the surface normal.
## Explicitly excludes the depth direction (-normal) and front (+normal).
func get_surface_orthogonal_directions(normal: Vector3i) -> Array[Vector3i]:
	if normal.x != 0:
		return [Vector3i(0, 1, 0), Vector3i(0, -1, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]
	elif normal.y != 0:
		return [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]
	elif normal.z != 0:
		return [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0), Vector3i(0, -1, 0)]
	return []

## Checks whether a specific face of a cell has already been coated with mortar.
func is_face_coated(cell: Vector3i, face_dir: Vector3i) -> bool:
	var fk := _face_key(cell, face_dir)
	return _coated_faces.get(fk, false)

## Legacy alias for is_face_coated.
func is_face_cemented(cell: Vector3i, face_dir: Vector3i) -> bool:
	return is_face_coated(cell, face_dir)

## Returns an Array of all face directions coated with mortar on this cell.
func get_coated_faces_for_cell(cell: Vector3i) -> Array[Vector3i]:
	var result: Array[Vector3i] = []
	for offset in NEIGHBORS_6:
		if is_face_coated(cell, offset):
			result.append(offset)
	return result

## Sets a face as coated with mortar, emits face_coated, and updates block metadata.
func set_face_coated(cell: Vector3i, face_dir: Vector3i) -> void:
	if face_dir == Vector3i.ZERO:
		return
	var fk := _face_key(cell, face_dir)
	_coated_faces[fk] = true
	var grid := _get_grid()
	if grid != null and grid.has_block(cell):
		var b: BlockData = grid.get_block(cell)
		if b != null:
			_add_coated_face_to_metadata(b, face_dir)
	face_coated.emit(cell, face_dir)

func _add_coated_face_to_metadata(block: BlockData, face_dir: Vector3i) -> void:
	if block == null or face_dir == Vector3i.ZERO:
		return
	var cf: Array = block.metadata.get("coated_faces", [])
	var dir_arr = [face_dir.x, face_dir.y, face_dir.z]
	if not cf.has(dir_arr):
		cf.append(dir_arr)
	block.metadata["coated_faces"] = cf

## Applies the mortar brush to an exposed face of a block.
## Reinforces connections with coplanar neighbors in a 2D '+' pattern on that surface.
## Does NOT connect blocks through the wall's depth or behind the surface.
## Only coats valid, newly targeted faces to prevent duplicate resource consumption.
## Returns a Dictionary with:
##   - success: bool
##   - already_coated: bool
##   - consumed: bool
##   - reinforced_joints: Array
func apply_mortar_brush(cell: Vector3i, face_dir: Vector3i) -> Dictionary:
	var grid := _get_grid()
	if grid == null or not grid.has_block(cell) or face_dir == Vector3i.ZERO:
		return {"success": false, "already_coated": false, "consumed": false, "reinforced_joints": []}

	var fk := _face_key(cell, face_dir)
	if _coated_faces.get(fk, false):
		return {"success": false, "already_coated": true, "consumed": false, "reinforced_joints": []}

	# Mark face as coated
	_coated_faces[fk] = true

	var block_a: BlockData = grid.get_block(cell)
	if block_a != null:
		_add_coated_face_to_metadata(block_a, face_dir)

	face_coated.emit(cell, face_dir)

	var mat_a: StringName = block_a.block_type if block_a != null else &"stone"

	var reinforced: Array = []
	var orth_dirs := get_surface_orthogonal_directions(face_dir)

	for dir in orth_dirs:
		var neighbor: Vector3i = cell + dir
		if grid.has_block(neighbor):
			var block_b: BlockData = grid.get_block(neighbor)
			var mat_b: StringName = block_b.block_type if block_b != null else &"stone"
			if are_materials_compatible(mat_a, mat_b):
				var strength := calculate_base_strength(mat_a, mat_b)
				var key := StructuralJointScript.make_key(cell, neighbor)
				var joint: RefCounted = null
				if _joints.has(key):
					joint = _joints[key]
					joint.reinforce_with_mortar(strength)
					joint_reinforced.emit(joint)
				else:
					joint = StructuralJointScript.new(cell, neighbor, strength, mat_a, mat_b, true)
					_register_joint(joint)
					joint_created.emit(joint)
				reinforced.append(joint)

	return {"success": true, "already_coated": false, "consumed": true, "reinforced_joints": reinforced}

## Backward-compatible wrapper for apply_cement_to_face.
## If an adjacent block exists across face_dir, reinforces that contact joint directly.
## Otherwise coats the face and reinforces the 2D '+' coplanar surface.
func apply_cement_to_face(cell: Vector3i, face_dir: Vector3i, custom_strength: float = -1.0) -> RefCounted:
	var grid := _get_grid()
	if grid == null or not grid.has_block(cell) or face_dir == Vector3i.ZERO:
		return null

	var adj_cell := cell + face_dir
	if grid.has_block(adj_cell):
		return bond_adjacent(cell, adj_cell, custom_strength)
	else:
		var res := apply_mortar_brush(cell, face_dir)
		var joints: Array = res.get("reinforced_joints", [])
		if not joints.is_empty():
			return joints[0]
		return null

## Bonds two already adjacent blocks with a reinforced structural joint.
func bond_adjacent(cell_a: Vector3i, cell_b: Vector3i, custom_strength: float = -1.0) -> RefCounted:
	var grid := _get_grid()
	if grid == null:
		return null
	if not grid.has_block(cell_a) or not grid.has_block(cell_b):
		return null

	var block_a: BlockData = grid.get_block(cell_a)
	var block_b: BlockData = grid.get_block(cell_b)
	var mat_a: StringName = block_a.block_type if block_a != null else &"stone"
	var mat_b: StringName = block_b.block_type if block_b != null else &"stone"

	if not are_materials_compatible(mat_a, mat_b):
		return null

	var strength: float = custom_strength if custom_strength > 0.0 else calculate_base_strength(mat_a, mat_b)
	var key: String = StructuralJointScript.make_key(cell_a, cell_b)
	if _joints.has(key):
		var existing: RefCounted = _joints[key]
		existing.reinforce_with_mortar(strength)
		joint_reinforced.emit(existing)
		return existing

	var joint: RefCounted = StructuralJointScript.new(cell_a, cell_b, strength, mat_a, mat_b, true)
	_register_joint(joint)
	joint_created.emit(joint)
	return joint

## Bonds all currently adjacent touching neighbors of a cell.
func bond_all_adjacent_neighbors(cell: Vector3i) -> Array:
	var bonded: Array = []
	var grid := _get_grid()
	if grid == null or not grid.has_block(cell):
		return bonded

	for offset in NEIGHBORS_6:
		var neighbor: Vector3i = cell + offset
		if grid.has_block(neighbor):
			var joint = bond_adjacent(cell, neighbor)
			if joint != null and not bonded.has(joint):
				bonded.append(joint)

	return bonded

## Creates a default (weak, unmortared) joint between two adjacent blocks.
func _create_default_joint(cell_a: Vector3i, cell_b: Vector3i) -> RefCounted:
	var grid := _get_grid()
	if grid == null or not grid.has_block(cell_a) or not grid.has_block(cell_b):
		return null

	var key: String = StructuralJointScript.make_key(cell_a, cell_b)
	if _joints.has(key):
		return _joints[key]

	var block_a: BlockData = grid.get_block(cell_a)
	var block_b: BlockData = grid.get_block(cell_b)
	var mat_a: StringName = block_a.block_type if block_a != null else &"stone"
	var mat_b: StringName = block_b.block_type if block_b != null else &"stone"

	var strength := calculate_default_strength(mat_a, mat_b)
	var joint: RefCounted = StructuralJointScript.new(cell_a, cell_b, strength, mat_a, mat_b, false)
	_register_joint(joint)
	joint_created.emit(joint)
	return joint

func _register_joint(joint: RefCounted) -> void:
	var key: String = joint.get_key()
	_joints[key] = joint

	if not _cell_to_joints.has(joint.cell_a):
		_cell_to_joints[joint.cell_a] = []
	_cell_to_joints[joint.cell_a].append(joint)

	if not _cell_to_joints.has(joint.cell_b):
		_cell_to_joints[joint.cell_b] = []
	_cell_to_joints[joint.cell_b].append(joint)

func _unregister_joint(joint: RefCounted) -> void:
	var key: String = joint.get_key()
	_joints.erase(key)

	if _cell_to_joints.has(joint.cell_a):
		_cell_to_joints[joint.cell_a].erase(joint)
		if _cell_to_joints[joint.cell_a].is_empty():
			_cell_to_joints.erase(joint.cell_a)

	if _cell_to_joints.has(joint.cell_b):
		_cell_to_joints[joint.cell_b].erase(joint)
		if _cell_to_joints[joint.cell_b].is_empty():
			_cell_to_joints.erase(joint.cell_b)

	joint_removed.emit(joint)

# ==============================================================================
# QUERIES
# ==============================================================================

func has_joint(cell_a: Vector3i, cell_b: Vector3i) -> bool:
	var key: String = StructuralJointScript.make_key(cell_a, cell_b)
	return _joints.has(key)

func has_intact_joint(cell_a: Vector3i, cell_b: Vector3i) -> bool:
	var key: String = StructuralJointScript.make_key(cell_a, cell_b)
	if _joints.has(key):
		var j: RefCounted = _joints[key]
		return not j.is_broken
	return false

func is_joint_mortared(cell_a: Vector3i, cell_b: Vector3i) -> bool:
	var key: String = StructuralJointScript.make_key(cell_a, cell_b)
	if _joints.has(key):
		var j: RefCounted = _joints[key]
		return not j.is_broken and j.is_mortared
	return false

func get_joint(cell_a: Vector3i, cell_b: Vector3i) -> RefCounted:
	var key: String = StructuralJointScript.make_key(cell_a, cell_b)
	return _joints.get(key, null)

## Returns true if the block has at least one intact mortared joint.
func is_block_bonded(cell: Vector3i) -> bool:
	if not _cell_to_joints.has(cell):
		return false
	for j in _cell_to_joints[cell]:
		if not j.is_broken and j.is_mortared:
			return true
	return false

## Returns true if the block has any intact joint (default or mortared).
func has_any_intact_joint(cell: Vector3i) -> bool:
	if not _cell_to_joints.has(cell):
		return false
	for j in _cell_to_joints[cell]:
		if not j.is_broken:
			return true
	return false

func get_joints_for_cell(cell: Vector3i) -> Array:
	var result: Array = []
	if _cell_to_joints.has(cell):
		for j in _cell_to_joints[cell]:
			result.append(j)
	return result

func get_all_joints() -> Array:
	var result: Array = []
	for j in _joints.values():
		result.append(j)
	return result

func get_joint_count() -> int:
	return _joints.size()

# ==============================================================================
# DAMAGE, BREAKAGE & FORCE DISTRIBUTION
# ==============================================================================

## Damages a specific joint directly.
func damage_joint(cell_a: Vector3i, cell_b: Vector3i, amount: float) -> bool:
	var joint = get_joint(cell_a, cell_b)
	if joint == null or joint.is_broken:
		return false

	var broke: bool = joint.apply_damage(amount)
	joint_damaged.emit(joint, amount, joint.current_health)

	if broke:
		joint_broken.emit(joint)
		_on_joint_broken_internal(joint)
	return broke

## Explicitly breaks a joint.
func break_joint(joint: RefCounted) -> void:
	if joint == null or joint.is_broken:
		return
	joint.break_joint()
	joint_broken.emit(joint)
	_on_joint_broken_internal(joint)

func _on_joint_broken_internal(_joint: RefCounted) -> void:
	var stab := _get_stability()
	if stab != null and stab.has_method("recalculate_stability"):
		stab.call_deferred("recalculate_stability")

## Applies an impact of energy (in Joules) to a block in the grid.
## Considers impact energy, force distribution among attached joints, material resistance, and joint strength.
## Returns any joints that were broken by the impact.
func apply_impact_to_block_joints(cell: Vector3i, impact_energy: float, _hit_normal: Vector3 = Vector3.ZERO) -> Array:
	var broken_joints: Array = []
	if impact_energy < impact_energy_min_threshold:
		return broken_joints

	var attached := get_joints_for_cell(cell)
	if attached.is_empty():
		return broken_joints

	# Distribute force/energy among active attached joints
	var active_joints: Array = []
	for j in attached:
		if not j.is_broken:
			active_joints.append(j)

	if active_joints.is_empty():
		return broken_joints

	var energy_per_joint: float = impact_energy / float(active_joints.size())

	for j in active_joints:
		# 1. Immediate breakage check: if energy exceeds strength threshold
		if energy_per_joint >= j.max_strength * immediate_break_multiplier:
			break_joint(j)
			broken_joints.append(j)
		else:
			# 2. Accumulated damage: scale damage by material durability resistance
			var dur_resistance: float = BlockTypeCatalog.get_max_durability(j.material_a) * BlockTypeCatalog.get_max_durability(j.material_b)
			dur_resistance = maxf(0.5, dur_resistance)
			var damage: float = energy_per_joint / dur_resistance
			if j.apply_damage(damage):
				broken_joints.append(j)
				joint_broken.emit(j)
				_on_joint_broken_internal(j)
			else:
				joint_damaged.emit(j, damage, j.current_health)

	# Apply durability damage to the grid block itself
	var grid := _get_grid()
	if grid != null and grid.has_block(cell):
		var b_data: BlockData = grid.get_block(cell)
		if b_data != null:
			var dur_res: float = maxf(0.1, BlockTypeCatalog.get_max_durability(b_data.block_type))
			var block_dmg: float = impact_energy / (dur_res * 10.0)
			grid.apply_damage(cell, block_dmg)

	return broken_joints

# ==============================================================================
# REMOVAL & CLEANUP (ZERO ORPHANED JOINTS)
# ==============================================================================

## Removes all joints connected to a cell. Returns removed joints.
func remove_joints_for_cell(cell: Vector3i) -> Array:
	var to_remove: Array = []
	if _cell_to_joints.has(cell):
		for j in _cell_to_joints[cell]:
			to_remove.append(j)

	for j in to_remove:
		_unregister_joint(j)

	# Clean up any coated faces on this cell
	for offset in NEIGHBORS_6:
		_coated_faces.erase(_face_key(cell, offset))

	return to_remove

## Extracts and unregisters joints strictly between the specified cells (used during collapse).
## Returns internal joints for the debris island, while severing joints to non-collapsing cells.
func extract_joints_for_cells(cells: Array[Vector3i]) -> Array:
	var cell_set: Dictionary = {}
	for c in cells:
		cell_set[c] = true

	var internal_joints: Array = []
	var boundary_joints: Array = []

	var processed_keys: Dictionary = {}
	for c in cells:
		if _cell_to_joints.has(c):
			for j in _cell_to_joints[c]:
				var k: String = j.get_key()
				if processed_keys.has(k):
					continue
				processed_keys[k] = true

				if cell_set.has(j.cell_a) and cell_set.has(j.cell_b):
					internal_joints.append(j)
				else:
					boundary_joints.append(j)

	# Unregister all boundary joints (severed by collapse)
	for bj in boundary_joints:
		_unregister_joint(bj)

	# Unregister all internal joints from grid system (they transition into debris island)
	for ij in internal_joints:
		_unregister_joint(ij)

	# Ensure coated faces are saved to block metadata before removal
	var grid = _get_grid()
	if grid != null:
		for c in cells:
			var b: BlockData = grid.get_block(c)
			if b != null:
				for offset in NEIGHBORS_6:
					if is_face_coated(c, offset):
						_add_coated_face_to_metadata(b, offset)

	# Clean up coated faces on collapsing cells
	for c in cells:
		remove_joints_for_cell(c)

	return internal_joints

func clear_all_joints() -> void:
	_joints.clear()
	_cell_to_joints.clear()
	_coated_faces.clear()
	joints_cleared.emit()

# ==============================================================================
# GRID SYSTEM CALLBACKS
# ==============================================================================

func _on_grid_block_placed(cell: Vector3i, _data: BlockData) -> void:
	var grid := _get_grid()
	if grid == null:
		return

	# Restore coated faces from BlockData metadata if present
	if _data != null and _data.metadata.has("coated_faces"):
		var c_faces = _data.metadata["coated_faces"]
		if c_faces is Array:
			for f in c_faces:
				var fdir := Vector3i.ZERO
				if f is Vector3i:
					fdir = f
				elif f is Array and f.size() == 3:
					fdir = Vector3i(int(f[0]), int(f[1]), int(f[2]))
				if fdir != Vector3i.ZERO:
					var fk := _face_key(cell, fdir)
					_coated_faces[fk] = true
					face_coated.emit(cell, fdir)

	# Automatically create default connections with adjacent existing blocks
	for offset in NEIGHBORS_6:
		var neighbor: Vector3i = cell + offset
		if grid.has_block(neighbor):
			var joint = _create_default_joint(cell, neighbor)
			var opp_offset := -offset
			# Check if neighbor had an exposed face pointing to this cell that was coated with mortar
			if is_face_coated(neighbor, opp_offset):
				var mat_a: StringName = _data.block_type if _data != null else &"stone"
				var block_b: BlockData = grid.get_block(neighbor)
				var mat_b: StringName = block_b.block_type if block_b != null else &"stone"
				if joint != null and are_materials_compatible(mat_a, mat_b):
					joint.reinforce_with_mortar(calculate_base_strength(mat_a, mat_b))
			else:
				# Or if neighbor had a surface orthogonal to offset that was coated
				var orth_dirs := get_surface_orthogonal_directions(offset)
				for surf_norm in orth_dirs:
					if is_face_coated(neighbor, surf_norm):
						var mat_a: StringName = _data.block_type if _data != null else &"stone"
						var block_b: BlockData = grid.get_block(neighbor)
						var mat_b: StringName = block_b.block_type if block_b != null else &"stone"
						if joint != null and are_materials_compatible(mat_a, mat_b):
							joint.reinforce_with_mortar(calculate_base_strength(mat_a, mat_b))

func _on_grid_block_removed(cell: Vector3i, _data: BlockData) -> void:
	remove_joints_for_cell(cell)

func _on_grid_cleared() -> void:
	clear_all_joints()

func _get_grid() -> Node:
	if grid_system != null:
		return grid_system
	if is_inside_tree() and has_node("/root/GridSystem"):
		return get_node("/root/GridSystem")
	return null

func _get_stability() -> Node:
	if stability_system != null:
		return stability_system
	if is_inside_tree() and has_node("/root/StabilitySystem"):
		return get_node("/root/StabilitySystem")
	return null
