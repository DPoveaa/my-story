class_name ReconstructionPlanner
extends RefCounted

## Deterministic system that compares a registered construction blueprint against the live world.
## Identifies what blocks exist (PRESENT), are missing (MISSING), conflict with wrong blocks/debris/player (CONFLICT),
## or are out of bounds (INVALID).
## Read-only and non-destructive: does NOT modify the world or live blueprint state during comparison.

class PlanResult extends RefCounted:
	var blueprint_name: String = ""
	var anchor_cell: Vector3i = Vector3i.ZERO
	var total_desired: int = 0
	var present_count: int = 0
	var missing_count: int = 0
	var conflict_count: int = 0
	var invalid_count: int = 0

	## Array of Dictionary entries:
	## [
	##   {
	##     "rel_pos": Vector3i,
	##     "world_cell": Vector3i,
	##     "expected_type": StringName,
	##     "expected_durability": float,
	##     "expected_metadata": Dictionary,
	##     "status": StringName, # &"PRESENT", &"MISSING", &"CONFLICT", &"INVALID"
	##     "actual_type": StringName,
	##     "reason": String
	##   }, ...
	## ]
	var entries: Array[Dictionary] = []

	func is_fully_intact() -> bool:
		return present_count == total_desired and total_desired > 0

	func is_ready_for_reconstruction() -> bool:
		return conflict_count == 0 and invalid_count == 0 and missing_count > 0

	func get_missing_entries() -> Array[Dictionary]:
		var res: Array[Dictionary] = []
		for e in entries:
			if e.get("status", &"") == &"MISSING":
				res.append(e)
		return res

	func get_conflict_entries() -> Array[Dictionary]:
		var res: Array[Dictionary] = []
		for e in entries:
			if e.get("status", &"") == &"CONFLICT":
				res.append(e)
		return res

	func get_invalid_entries() -> Array[Dictionary]:
		var res: Array[Dictionary] = []
		for e in entries:
			if e.get("status", &"") == &"INVALID":
				res.append(e)
		return res

## Generates a deterministic ReconstructionPlan for the given blueprint and world anchor.
static func generate_plan(blueprint: BlueprintData, anchor_cell: Vector3i, grid_system: Node, orchestrator: Node = null, player: Node = null) -> PlanResult:
	var result := PlanResult.new()
	if blueprint == null:
		return result

	result.blueprint_name = blueprint.name
	result.anchor_cell = anchor_cell

	if grid_system == null or blueprint.blocks.is_empty():
		return result

	result.total_desired = blueprint.blocks.size()

	for item in blueprint.blocks:
		if not (item is Dictionary):
			continue

		var pos_arr = item.get("rel_pos", null)
		if not (pos_arr is Array and pos_arr.size() == 3):
			continue

		var rel := Vector3i(int(pos_arr[0]), int(pos_arr[1]), int(pos_arr[2]))
		var world_cell := anchor_cell + rel
		var exp_type := StringName(item.get("block_type", "stone"))
		var exp_dur := float(item.get("durability", 1.0))
		var raw_meta = item.get("metadata", {})
		var exp_meta: Dictionary = raw_meta.duplicate(true) if raw_meta is Dictionary else {}

		var entry: Dictionary = {
			"rel_pos": rel,
			"world_cell": world_cell,
			"expected_type": exp_type,
			"expected_durability": exp_dur,
			"expected_metadata": exp_meta,
			"status": &"MISSING",
			"actual_type": &"",
			"reason": ""
		}

		# 1. Bounds Check
		if world_cell.y < grid_system.min_y or absi(world_cell.x) > grid_system.max_coord_bound or absi(world_cell.z) > grid_system.max_coord_bound or world_cell.y > grid_system.max_coord_bound:
			entry["status"] = &"INVALID"
			entry["reason"] = "OUT_OF_BOUNDS"
			result.invalid_count += 1
			result.entries.append(entry)
			continue

		# 2. Grid Occupancy Check
		if grid_system.has_block(world_cell):
			var actual_block: BlockData = grid_system.get_block(world_cell)
			var act_type: StringName = actual_block.block_type if actual_block != null else &""
			entry["actual_type"] = act_type

			if act_type == exp_type:
				entry["status"] = &"PRESENT"
				entry["reason"] = ""
				result.present_count += 1
			else:
				entry["status"] = &"CONFLICT"
				entry["reason"] = "WRONG_BLOCK_TYPE"
				result.conflict_count += 1

			result.entries.append(entry)
			continue

		# 3. Empty Grid Cell Check — Check Debris / Player Obstructions
		var is_blocked_by_debris: bool = false
		if orchestrator != null and orchestrator.has_method("is_cell_blocked_by_debris"):
			is_blocked_by_debris = orchestrator.is_cell_blocked_by_debris(world_cell, grid_system.cell_size)

		var overlaps_player: bool = false
		if player != null and player.has_method("is_cell_overlapping_player"):
			overlaps_player = player.is_cell_overlapping_player(world_cell, grid_system.cell_size)

		if is_blocked_by_debris:
			entry["status"] = &"CONFLICT"
			entry["reason"] = "DEBRIS_COLLISION"
			result.conflict_count += 1
		elif overlaps_player:
			entry["status"] = &"CONFLICT"
			entry["reason"] = "PLAYER_OVERLAP"
			result.conflict_count += 1
		else:
			entry["status"] = &"MISSING"
			entry["reason"] = "EMPTY_CELL"
			result.missing_count += 1

		result.entries.append(entry)

	return result
