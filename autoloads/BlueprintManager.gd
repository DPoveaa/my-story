extends Node

## Central manager for Construction Blueprints.
## Provides saving, loading, listing, updating, and placement validation for building layouts.
## Guarantees blueprint data independence from live scene/physics objects,
## preventing corruption from debris collapses or world modifications.

signal blueprint_saved(name: String, blueprint: BlueprintData)
signal blueprint_loaded(name: String, blueprint: BlueprintData)
signal blueprint_applied(name: String, anchor: Vector3i)
signal blueprint_rejected(name: String, anchor: Vector3i, reason: String, conflicts: Array)
signal blueprint_deleted(name: String)

const BlueprintDataScript = preload("res://data/BlueprintData.gd")
const ReconstructionPlannerScript = preload("res://systems/blueprint/ReconstructionPlanner.gd")

@export var storage_dir: String = "user://blueprints"

@export var grid_system: Node
@export var joint_system: Node
@export var stability_system: Node
@export var orchestrator: CollapseOrchestrator

func _ready() -> void:
	if grid_system == null and has_node("/root/GridSystem"):
		grid_system = get_node("/root/GridSystem")
	if joint_system == null and has_node("/root/JointSystem"):
		joint_system = get_node("/root/JointSystem")
	if stability_system == null and has_node("/root/StabilitySystem"):
		stability_system = get_node("/root/StabilitySystem")
	_ensure_storage_dir()
	load_all_registered_blueprints()

## Restores all saved blueprint files from storage_dir into active_registered_blueprints.
func load_all_registered_blueprints() -> void:
	var names := list_blueprints()
	for n in names:
		var bp := load_blueprint(n)
		if bp != null:
			active_registered_blueprints[n] = bp

func _ensure_storage_dir() -> bool:
	if not DirAccess.dir_exists_absolute(storage_dir):
		var err := DirAccess.make_dir_recursive_absolute(storage_dir)
		if err != OK:
			push_error("BlueprintManager: Failed to create storage dir '%s' (Error %d)" % [storage_dir, err])
			return false
	return true

## Normalizes a name into a safe filesystem filename.
func sanitize_name(blueprint_name: String) -> String:
	var clean := blueprint_name.strip_edges().to_lower()
	var safe := ""
	for i in range(clean.length()):
		var c := clean[i]
		if (c >= "a" and c <= "z") or (c >= "0" and c <= "9") or c == "_" or c == "-":
			safe += c
		elif c == " ":
			safe += "_"
	return safe if not safe.is_empty() else "blueprint"

func get_blueprint_file_path(blueprint_name: String) -> String:
	return "%s/%s.json" % [storage_dir.trim_suffix("/"), sanitize_name(blueprint_name)]

## Lists all valid saved blueprints available in storage_dir.
func list_blueprints() -> Array[String]:
	var result: Array[String] = []
	if not _ensure_storage_dir():
		return result

	var dir := DirAccess.open(storage_dir)
	if dir == null:
		return result

	dir.list_dir_begin()
	var file_name := dir.get_next()
	while not file_name.is_empty():
		if not dir.current_is_dir() and file_name.ends_with(".json"):
			result.append(file_name.get_basename())
		file_name = dir.get_next()
	dir.list_dir_end()
	result.sort()
	return result

## Returns true if a blueprint file exists in storage_dir.
func has_blueprint(blueprint_name: String) -> bool:
	var path := get_blueprint_file_path(blueprint_name)
	return FileAccess.file_exists(path)

## Loads a blueprint from disk safely. Returns null if missing or invalid.
func load_blueprint(blueprint_name: String) -> BlueprintData:
	var path := get_blueprint_file_path(blueprint_name)
	if not FileAccess.file_exists(path):
		push_warning("BlueprintManager: Blueprint '%s' does not exist at '%s'" % [blueprint_name, path])
		return null

	var bp = BlueprintDataScript.load_from_file(path)
	if bp != null:
		blueprint_loaded.emit(bp.name, bp)
	return bp

## Saves a blueprint to disk. If overwrite is false and file exists, aborts and returns false.
func save_blueprint(blueprint: BlueprintData, overwrite: bool = true) -> bool:
	if blueprint == null:
		push_error("BlueprintManager: Cannot save null blueprint")
		return false

	if not _ensure_storage_dir():
		return false

	var path := get_blueprint_file_path(blueprint.name)
	if not overwrite and FileAccess.file_exists(path):
		push_warning("BlueprintManager: Blueprint '%s' already exists and overwrite is false" % blueprint.name)
		return false

	var err := blueprint.save_to_file(path)
	if err == OK:
		blueprint_saved.emit(blueprint.name, blueprint)
		return true
	return false

## Deletes a saved blueprint from disk.
func delete_blueprint(blueprint_name: String) -> bool:
	var path := get_blueprint_file_path(blueprint_name)
	if not FileAccess.file_exists(path):
		return false

	var dir := DirAccess.open(storage_dir)
	if dir != null:
		var err := dir.remove(path.get_file())
		if err == OK:
			blueprint_deleted.emit(blueprint_name)
			return true
	return false

# ==============================================================================
# CAPTURING FROM LIVE WORLD
# ==============================================================================

## Dictionary of active registered construction areas in current scene: Dictionary[String, BlueprintData]
var active_registered_blueprints: Dictionary = {}

## Captures a snapshot of strictly the blocks within the specified bounded area [min_cell, max_cell].
## Never falls back to capturing the whole grid.
func capture_blueprint_area(blueprint_name: String, min_cell: Vector3i, max_cell: Vector3i) -> BlueprintData:
	var grid := _get_grid()
	if grid == null:
		push_error("BlueprintManager: GridSystem reference is null")
		return null

	var bounds_min := Vector3i(mini(min_cell.x, max_cell.x), mini(min_cell.y, max_cell.y), mini(min_cell.z, max_cell.z))
	var bounds_max := Vector3i(maxi(min_cell.x, max_cell.x), maxi(min_cell.y, max_cell.y), maxi(min_cell.z, max_cell.z))

	var target_cells: Array[Vector3i] = []
	for x in range(bounds_min.x, bounds_max.x + 1):
		for y in range(bounds_min.y, bounds_max.y + 1):
			for z in range(bounds_min.z, bounds_max.z + 1):
				var c := Vector3i(x, y, z)
				if grid.has_block(c):
					target_cells.append(c)

	if target_cells.is_empty():
		push_warning("BlueprintManager: No blocks found in bounded area (%s to %s) for '%s'" % [str(bounds_min), str(bounds_max), blueprint_name])
		return null

	var bp := capture_blueprint(blueprint_name, target_cells, bounds_min)
	if bp != null:
		bp.bounds_min = Vector3i.ZERO
		bp.bounds_max = bounds_max - bounds_min
		active_registered_blueprints[blueprint_name] = bp
	return bp

## Captures a snapshot of the specified cells (or all occupied cells if empty).
## Preserves block type, durability, metadata (including coated faces), and structural joints.
## Completely detached from live scene objects so subsequent collapses do not affect it.
func capture_blueprint(blueprint_name: String, cells: Array[Vector3i] = [], custom_anchor: Variant = null) -> BlueprintData:
	var grid := _get_grid()
	if grid == null:
		push_error("BlueprintManager: GridSystem reference is null")
		return null

	var target_cells: Array[Vector3i] = []
	if cells.is_empty():
		target_cells = grid.get_all_cells()
	else:
		for c in cells:
			if grid.has_block(c):
				target_cells.append(c)

	if target_cells.is_empty():
		push_warning("BlueprintManager: No blocks found to capture for blueprint '%s'" % blueprint_name)
		return null

	# Calculate bounding box
	var b_min := target_cells[0]
	var b_max := target_cells[0]
	for c in target_cells:
		b_min.x = mini(b_min.x, c.x)
		b_min.y = mini(b_min.y, c.y)
		b_min.z = mini(b_min.z, c.z)
		b_max.x = maxi(b_max.x, c.x)
		b_max.y = maxi(b_max.y, c.y)
		b_max.z = maxi(b_max.z, c.z)

	var anchor: Vector3i = b_min
	if custom_anchor != null and custom_anchor is Vector3i:
		anchor = custom_anchor

	var bp := BlueprintDataScript.new(blueprint_name)
	bp.anchor_cell = anchor
	bp.bounds_min = b_min - anchor
	bp.bounds_max = b_max - anchor

	var joint_sys := _get_joint_sys()
	var cell_set: Dictionary = {}

	# 1. Capture block data
	for c in target_cells:
		cell_set[c] = true
		var live_block: BlockData = grid.get_block(c)
		var dup_block: BlockData = live_block.duplicate_data() if live_block != null else BlockData.new(&"stone", 1.0)

		# Ensure coated faces are recorded in metadata
		if joint_sys != null and joint_sys.has_method("get_coated_faces_for_cell"):
			var c_faces: Array = joint_sys.get_coated_faces_for_cell(c)
			for f in c_faces:
				var cf_meta: Array = dup_block.metadata.get("coated_faces", [])
				var dir_arr = [f.x, f.y, f.z]
				if not cf_meta.has(dir_arr):
					cf_meta.append(dir_arr)
				dup_block.metadata["coated_faces"] = cf_meta

		var rel := c - anchor
		bp.blocks.append({
			"rel_pos": [rel.x, rel.y, rel.z],
			"block_type": String(dup_block.block_type),
			"durability": dup_block.durability,
			"metadata": dup_block.metadata.duplicate(true)
		})

	# 2. Capture internal structural joints strictly between captured cells
	if joint_sys != null and joint_sys.has_method("get_all_joints"):
		var all_joints: Array = joint_sys.get_all_joints()
		var processed: Dictionary = {}
		for j in all_joints:
			if j == null or j.is_broken:
				continue
			if cell_set.has(j.cell_a) and cell_set.has(j.cell_b):
				var k: String = j.get_key()
				if processed.has(k):
					continue
				processed[k] = true
				var rel_a: Vector3i = j.cell_a - anchor
				var rel_b: Vector3i = j.cell_b - anchor
				bp.joints.append({
					"rel_a": [rel_a.x, rel_a.y, rel_a.z],
					"rel_b": [rel_b.x, rel_b.y, rel_b.z],
					"strength": j.current_health if j.current_health > 0.0 else j.max_strength,
					"is_mortared": j.is_mortared,
					"material_a": String(j.material_a),
					"material_b": String(j.material_b)
				})

	return bp

# ==============================================================================
# VALIDATION & APPLICATION
# ==============================================================================

## Validates whether a blueprint can be safely placed at anchor_cell.
## Returns a Dictionary:
## {
##   "valid": bool,
##   "reason": String,     # "", "EMPTY_BLUEPRINT", "OUT_OF_BOUNDS", "CELL_OCCUPIED", "DEBRIS_COLLISION", "PLAYER_OVERLAP"
##   "conflicts": Array[Vector3i]
## }
func validate_placement(blueprint: BlueprintData, anchor_cell: Vector3i, allow_replacement: bool = false, player: Node = null) -> Dictionary:
	if blueprint == null or blueprint.blocks.is_empty():
		return {"valid": false, "reason": "EMPTY_BLUEPRINT", "conflicts": []}

	var grid := _get_grid()
	if grid == null:
		return {"valid": false, "reason": "NO_GRID_SYSTEM", "conflicts": []}

	var orch := _get_orchestrator()
	var conflicts: Array[Vector3i] = []
	var primary_reason := ""

	for item in blueprint.blocks:
		if not (item is Dictionary):
			continue
		var pos_arr = item.get("rel_pos", null)
		if not (pos_arr is Array and pos_arr.size() == 3):
			continue
		var rel := Vector3i(int(pos_arr[0]), int(pos_arr[1]), int(pos_arr[2]))
		var world_cell := anchor_cell + rel

		# 1. Bounds check
		if world_cell.y < grid.min_y or absi(world_cell.x) > grid.max_coord_bound or absi(world_cell.z) > grid.max_coord_bound or world_cell.y > grid.max_coord_bound:
			conflicts.append(world_cell)
			if primary_reason.is_empty():
				primary_reason = "OUT_OF_BOUNDS"
			continue

		# 2. Debris collision check (debris currently occupying this space)
		if orch != null and orch.is_cell_blocked_by_debris(world_cell, grid.cell_size):
			conflicts.append(world_cell)
			if primary_reason.is_empty():
				primary_reason = "DEBRIS_COLLISION"
			continue

		# 3. Existing static structure occupancy
		if grid.has_block(world_cell) and not allow_replacement:
			conflicts.append(world_cell)
			if primary_reason.is_empty():
				primary_reason = "CELL_OCCUPIED"
			continue

		# 4. Player physical presence collision
		if player != null and player.has_method("is_cell_overlapping_player"):
			if player.is_cell_overlapping_player(world_cell, grid.cell_size):
				conflicts.append(world_cell)
				if primary_reason.is_empty():
					primary_reason = "PLAYER_OVERLAP"
				continue

	if not conflicts.is_empty():
		return {
			"valid": false,
			"reason": primary_reason if not primary_reason.is_empty() else "CELL_OCCUPIED",
			"conflicts": conflicts
		}

	return {"valid": true, "reason": "", "conflicts": []}

## Places the blueprint into the live grid at anchor_cell.
## Validates safety first and rejects without world modification if invalid.
## If allow_replacement is true, removes existing occupied blocks before placement to prevent duplicates.
func apply_blueprint(blueprint: BlueprintData, anchor_cell: Vector3i, allow_replacement: bool = false, player: Node = null) -> Dictionary:
	var val := validate_placement(blueprint, anchor_cell, allow_replacement, player)
	if not val["valid"]:
		blueprint_rejected.emit(blueprint.name if blueprint != null else "", anchor_cell, val["reason"], val["conflicts"])
		return {"success": false, "reason": val["reason"], "conflicts": val["conflicts"]}

	var grid := _get_grid()
	var joint_sys := _get_joint_sys()

	# If replacement allowed, cleanly remove existing blocks first
	if allow_replacement:
		for item in blueprint.blocks:
			var pos_arr = item.get("rel_pos", null)
			if pos_arr is Array and pos_arr.size() == 3:
				var rel := Vector3i(int(pos_arr[0]), int(pos_arr[1]), int(pos_arr[2]))
				var world_cell := anchor_cell + rel
				if grid.has_block(world_cell):
					grid.remove_block(world_cell)

	# 1. Place all blocks with their exact saved BlockData
	for item in blueprint.blocks:
		var pos_arr = item.get("rel_pos", null)
		if not (pos_arr is Array and pos_arr.size() == 3):
			continue
		var rel := Vector3i(int(pos_arr[0]), int(pos_arr[1]), int(pos_arr[2]))
		var world_cell := anchor_cell + rel

		var b_type := StringName(item.get("block_type", "stone"))
		var dur := float(item.get("durability", 1.0))
		var meta: Dictionary = item.get("metadata", {}).duplicate(true)
		var b_data := BlockData.new(b_type, dur, meta)

		grid.place_block(world_cell, b_data)

	# 2. Restore internal structural joints and mortar bonding
	if joint_sys != null:
		# Restore mortared joints
		for j_item in blueprint.joints:
			var a_arr = j_item.get("rel_a", null)
			var b_arr = j_item.get("rel_b", null)
			if a_arr is Array and b_arr is Array:
				var world_a := anchor_cell + Vector3i(int(a_arr[0]), int(a_arr[1]), int(a_arr[2]))
				var world_b := anchor_cell + Vector3i(int(b_arr[0]), int(b_arr[1]), int(b_arr[2]))
				var is_mortared: bool = bool(j_item.get("is_mortared", false))
				var strength: float = float(j_item.get("strength", 50.0))
				if is_mortared and grid.has_block(world_a) and grid.has_block(world_b):
					joint_sys.bond_adjacent(world_a, world_b, strength)

		# Restore coated mortar faces and trigger visual overlays
		for item in blueprint.blocks:
			var pos_arr = item.get("rel_pos", null)
			if pos_arr is Array and pos_arr.size() == 3:
				var rel := Vector3i(int(pos_arr[0]), int(pos_arr[1]), int(pos_arr[2]))
				var world_cell := anchor_cell + rel
				var meta: Dictionary = item.get("metadata", {})
				if meta.has("coated_faces"):
					var c_faces = meta["coated_faces"]
					if c_faces is Array:
						for f in c_faces:
							var fdir := Vector3i.ZERO
							if f is Vector3i:
								fdir = f
							elif f is Array and f.size() == 3:
								fdir = Vector3i(int(f[0]), int(f[1]), int(f[2]))
							if fdir != Vector3i.ZERO and joint_sys.has_method("set_face_coated"):
								joint_sys.set_face_coated(world_cell, fdir)

	# 3. Trigger stability recalculation
	var stab := _get_stability()
	if stab != null and stab.has_method("recalculate_stability"):
		stab.call_deferred("recalculate_stability")

	blueprint_applied.emit(blueprint.name, anchor_cell)
	return {"success": true, "reason": "", "conflicts": []}

## Updates or replaces an existing saved blueprint with newly captured world cells.
func update_or_replace_blueprint(blueprint_name: String, cells: Array[Vector3i] = [], custom_anchor: Variant = null) -> bool:
	var bp := capture_blueprint(blueprint_name, cells, custom_anchor)
	if bp == null:
		return false
	return save_blueprint(bp, true)

## Explicitly updates a registered blueprint from the current live world cells inside its bounded area.
func update_registered_blueprint_from_world(blueprint_name: String, custom_min: Variant = null, custom_max: Variant = null) -> bool:
	var min_c := Vector3i.ZERO
	var max_c := Vector3i.ZERO

	if custom_min is Vector3i and custom_max is Vector3i:
		min_c = custom_min
		max_c = custom_max
	elif active_registered_blueprints.has(blueprint_name):
		var existing: BlueprintData = active_registered_blueprints[blueprint_name]
		min_c = existing.anchor_cell + existing.bounds_min
		max_c = existing.anchor_cell + existing.bounds_max
	else:
		push_warning("BlueprintManager: Cannot update unregistered blueprint '%s' without explicit bounds" % blueprint_name)
		return false

	var updated_bp := capture_blueprint_area(blueprint_name, min_c, max_c)
	if updated_bp == null:
		push_warning("BlueprintManager: No blocks found in bounded area for '%s'" % blueprint_name)
		return false

	return save_blueprint(updated_bp, true)

## Generates a ReconstructionPlanner comparison between a blueprint and current world state.
func plan_reconstruction(blueprint: BlueprintData, anchor_cell: Vector3i, player: Node = null) -> RefCounted:
	var grid := _get_grid()
	var orch := _get_orchestrator()
	return ReconstructionPlannerScript.generate_plan(blueprint, anchor_cell, grid, orch, player)

# ==============================================================================
# INTENTIONAL PLAYER EDIT TRACKING (Vs. Collapses / Destruction)
# ==============================================================================

## Called when the player intentionally builds/places a block.
## Updates any active registered construction area that contains this world cell.
func notify_intentional_block_placed(cell: Vector3i, data: BlockData) -> void:
	for bp: BlueprintData in active_registered_blueprints.values():
		if bp == null:
			continue
		var abs_min := bp.anchor_cell + bp.bounds_min
		var abs_max := bp.anchor_cell + bp.bounds_max
		if cell.x >= abs_min.x and cell.x <= abs_max.x and cell.y >= abs_min.y and cell.y <= abs_max.y and cell.z >= abs_min.z and cell.z <= abs_max.z:
			var rel := cell - bp.anchor_cell
			var existing_idx := -1
			for i in range(bp.blocks.size()):
				var b = bp.blocks[i]
				if b is Dictionary and b.get("rel_pos", []) == [rel.x, rel.y, rel.z]:
					existing_idx = i
					break
			var entry := {
				"rel_pos": [rel.x, rel.y, rel.z],
				"block_type": String(data.block_type),
				"durability": data.durability,
				"metadata": data.metadata.duplicate(true)
			}
			if existing_idx >= 0:
				bp.blocks[existing_idx] = entry
			else:
				bp.blocks.append(entry)
			save_blueprint(bp, true)

## Called when the player intentionally removes a block.
## Updates any active registered construction area that contains this world cell.
func notify_intentional_block_removed(cell: Vector3i) -> void:
	for bp: BlueprintData in active_registered_blueprints.values():
		if bp == null:
			continue
		var abs_min := bp.anchor_cell + bp.bounds_min
		var abs_max := bp.anchor_cell + bp.bounds_max
		if cell.x >= abs_min.x and cell.x <= abs_max.x and cell.y >= abs_min.y and cell.y <= abs_max.y and cell.z >= abs_min.z and cell.z <= abs_max.z:
			var rel := cell - bp.anchor_cell
			for i in range(bp.blocks.size() - 1, -1, -1):
				var b = bp.blocks[i]
				if b is Dictionary and b.get("rel_pos", []) == [rel.x, rel.y, rel.z]:
					bp.blocks.remove_at(i)
			save_blueprint(bp, true)

# ==============================================================================
# SYSTEM RESOLVERS
# ==============================================================================

func _get_grid() -> Node:
	if grid_system != null:
		return grid_system
	if is_inside_tree() and has_node("/root/GridSystem"):
		return get_node("/root/GridSystem")
	return null

func _get_joint_sys() -> Node:
	if joint_system != null:
		return joint_system
	if is_inside_tree() and has_node("/root/JointSystem"):
		return get_node("/root/JointSystem")
	return null

func _get_stability() -> Node:
	if stability_system != null:
		return stability_system
	if is_inside_tree() and has_node("/root/StabilitySystem"):
		return get_node("/root/StabilitySystem")
	return null

func _get_orchestrator() -> CollapseOrchestrator:
	if orchestrator != null:
		return orchestrator
	if is_inside_tree():
		var tree := get_tree()
		if tree != null and tree.current_scene != null:
			var found = tree.current_scene.get_node_or_null("CollapseOrchestrator")
			if found is CollapseOrchestrator:
				return found
	return null
