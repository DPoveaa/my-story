class_name DebrisGrabber
extends Node3D

## M2.2 — Modular debris grab/carry/release/recover/throw system.
## Attach as a child of the Player node.
## Grabbing is only supported in BODY_CONTROL mode for safety.
## In SOUL_PROJECTION mode grabbing is disabled.
##
## M2.2 additions: throw_debris (F) launches the held block forward with a
## configurable impulse relative to the active camera.

signal grabbed_block(island: DebrisIsland, cell: Vector3i, block_data: BlockData)
signal released_block()
signal thrown_block(island: DebrisIsland, impulse: Vector3)
signal recovered_block_to_grid(cell: Vector3i, block_type: StringName)
signal recovered_as_raw_material(block_type: StringName, amount: int)
signal recover_failed(reason: String)

@export_group("Carry Settings")
@export var carry_distance: float = 2.2
@export var carry_spring_stiffness: float = 40.0
@export var carry_max_force: float = 80.0
@export var max_grabbable_mass: float = 8.0
@export var recovery_max_distance: float = 12.0

@export_group("Throw Settings")
## Forward impulse magnitude when throwing (m/s)
@export var throw_speed: float = 16.0
## Maximum allowed throw speed (clamped)
@export var throw_speed_max: float = 28.0
## Upward component added to the throw vector (slight loft)
@export var throw_loft: float = 0.15
## Subtle angular spin applied on throw (rad/s, random axis)
@export var throw_spin: float = 4.0

@export_group("Recovery Settings")
@export var preview_ghost: PreviewGhost
@export var grid_system: Node
@export var orchestrator: CollapseOrchestrator
## Durability fraction threshold for recovery classification.
## Above this value: block is recovered as a reusable construction block.
## At or below this value: block is recovered as raw material.
@export_range(0.0, 1.0) var recovery_durability_threshold: float = 0.5

var _grabbed_island: DebrisIsland = null
var _grabbed_cell: Vector3i = Vector3i.ZERO
var _grabbed_data: BlockData = null
var is_grabbing: bool = false
var _recover_preview_cell: Vector3i = Vector3i.ZERO
var _recover_preview_valid: bool = false
var _player: Node = null

func _ready() -> void:
	_player = get_parent()
	if grid_system == null and has_node("/root/GridSystem"):
		grid_system = get_node("/root/GridSystem")
	if orchestrator == null and _player != null:
		var world := _player.get_parent()
		if world != null and world.has_node("CollapseOrchestrator"):
			orchestrator = world.get_node("CollapseOrchestrator") as CollapseOrchestrator
	if preview_ghost == null and _player != null:
		var world := _player.get_parent()
		if world != null and world.has_node("PreviewGhost"):
			preview_ghost = world.get_node("PreviewGhost") as PreviewGhost

func _physics_process(delta: float) -> void:
	if not is_grabbing or not is_instance_valid(_grabbed_island):
		if is_grabbing:
			on_island_freed()
		return

	var cam: Camera3D = _get_active_camera()
	if cam == null:
		return

	var carry_target: Vector3 = cam.global_position + (-cam.global_transform.basis.z) * carry_distance
	var current_pos: Vector3 = _grabbed_island.global_position
	var diff: Vector3 = carry_target - current_pos
	var impulse: Vector3 = diff * carry_spring_stiffness * delta
	if impulse.length() > carry_max_force * delta:
		impulse = impulse.normalized() * carry_max_force * delta

	_grabbed_island.linear_velocity = impulse / delta
	_grabbed_island.angular_velocity = Vector3.ZERO

	_update_recovery_preview(cam)

## Attempts to grab an individual block from a debris island.
## If the island has multiple blocks, detaches that individual block into its own single-block island.
func try_grab(island: DebrisIsland, cell: Vector3i, block_data: BlockData = null) -> bool:
	if _player != null and "current_state" in _player and _player.current_state != 0:
		return false
	if not is_instance_valid(island):
		return false
	if is_grabbing:
		release()

	var target_island := island
	var target_cell := cell
	var target_data := block_data

	if target_data == null and island.constituent_blocks.has(cell):
		target_data = island.constituent_blocks[cell]

	# If multi-block island, separate the targeted block into its own 1-block debris island
	if island.constituent_blocks.size() > 1:
		var local_pos: Vector3 = island.local_offsets.get(cell, Vector3.ZERO)
		var block_world_pos: Vector3 = island.to_global(local_pos) if (island.is_inside_tree() and island.local_offsets.has(cell)) else island.global_position
		var removed := island.remove_block(cell)
		if removed == null:
			return false
		target_data = removed

		var single_island: DebrisIsland = DebrisIsland.new()
		single_island.cell_size = island.cell_size
		single_island.orchestrator = orchestrator
		var block_map: Dictionary = {Vector3i.ZERO: target_data}
		single_island.setup_island([Vector3i.ZERO], block_map, island.cell_size)
		if island.get_parent() != null:
			island.get_parent().add_child(single_island)
		if single_island.is_inside_tree():
			single_island.global_position = block_world_pos
		else:
			single_island.position = block_world_pos
		if orchestrator != null and orchestrator.has_method("register_debris_island"):
			orchestrator.register_debris_island(single_island)

		target_island = single_island
		target_cell = Vector3i.ZERO

	if target_island.mass > max_grabbable_mass:
		return false

	_grabbed_island = target_island
	_grabbed_cell = target_cell
	_grabbed_data = target_data
	is_grabbing = true
	_grabbed_island.sleeping = false
	_grabbed_island.can_sleep = false
	grabbed_block.emit(target_island, target_cell, target_data)
	return true

## Drops or throws the carried block into physical simulation.
func release(throw_impulse: Vector3 = Vector3.ZERO) -> void:
	if not is_grabbing:
		return
	if is_instance_valid(_grabbed_island):
		_grabbed_island.can_sleep = true
		if throw_impulse.length_squared() > 0.01:
			_grabbed_island.linear_velocity = throw_impulse
		elif _grabbed_island.linear_velocity.length() < 0.5:
			_grabbed_island.linear_velocity = Vector3.DOWN * 1.0
	_grabbed_island = null
	_grabbed_cell = Vector3i.ZERO
	_grabbed_data = null
	is_grabbing = false
	if preview_ghost != null:
		preview_ghost.hide_preview()
	released_block.emit()

	## Attempts to place the held debris block onto the static grid.
	## Only eligible reusable blocks (durability > recovery_durability_threshold) can be placed.
	## If the target position is invalid, rejects placement without consuming, converting,
	## dropping, duplicating, or modifying the held debris in any way.
	## Under no circumstances does this placement path convert debris into raw materials.
func try_place_to_grid() -> bool:
	if not is_grabbing or not is_instance_valid(_grabbed_island):
		return false
	if _grabbed_data == null:
		return false
	var grid := _get_grid()
	if grid == null:
		return false

	# Must target a valid grid cell
	if not _recover_preview_valid:
		return false

	var target_cell := _recover_preview_cell
	if not grid.can_place_block(target_cell):
		return false
	if orchestrator != null and orchestrator.is_cell_blocked_by_debris(target_cell, grid.cell_size, _grabbed_island):
		return false
	if _player != null and _player.has_method("is_cell_overlapping_player"):
		if _player.is_cell_overlapping_player(target_cell, grid.cell_size):
			return false

	# Must be classified as a reusable block (durability > threshold)
	var max_dur: float = BlockTypeCatalog.get_max_durability(_grabbed_data.block_type)
	var dur_ratio: float = _grabbed_data.durability / max_dur if max_dur > 0.0 else 0.0
	if dur_ratio <= recovery_durability_threshold:
		# Damaged block cannot be placed directly as a block on the grid.
		# Rejects placement without modifying, converting, or consuming the held debris.
		return false

	# Atomically remove block from debris island (prevents duplicates)
	var removed_data: BlockData = _grabbed_island.remove_block(_grabbed_cell)
	if removed_data == null:
		is_grabbing = false
		_grabbed_island = null
		return false

	# Re-place on grid preserving full BlockData (durability, type, metadata)
	grid.place_block(target_cell, removed_data)
	var placed_type := removed_data.block_type
	_grabbed_island = null
	_grabbed_cell = Vector3i.ZERO
	_grabbed_data = null
	is_grabbing = false
	if preview_ghost != null:
		preview_ghost.hide_preview()
	recovered_block_to_grid.emit(target_cell, placed_type)
	return true

	## Snaps the carried block back onto the static grid if reusable, or converts it into
	## raw materials if damaged (<= recovery_durability_threshold).
	## Explicit recovery action (typically triggered by key R).
func try_recover() -> bool:
	if not is_grabbing or not is_instance_valid(_grabbed_island):
		recover_failed.emit("No block is held")
		return false
	if _grabbed_data == null:
		recover_failed.emit("Block data missing")
		return false
	var grid := _get_grid()
	if grid == null:
		recover_failed.emit("GridSystem unavailable")
		return false

	# ---- Classify by durability BEFORE removing the block from the island ----
	var max_dur: float = BlockTypeCatalog.get_max_durability(_grabbed_data.block_type)
	var dur_ratio: float = _grabbed_data.durability / max_dur if max_dur > 0.0 else 0.0
	var is_raw_material: bool = dur_ratio <= recovery_durability_threshold

	if not is_raw_material:
		# Validate grid placement before removing block from island
		if not _recover_preview_valid:
			recover_failed.emit("No valid grid cell targeted")
			return false
		var target_cell := _recover_preview_cell
		if not grid.can_place_block(target_cell):
			recover_failed.emit("Cell occupied")
			return false
		if orchestrator != null and orchestrator.is_cell_blocked_by_debris(target_cell, grid.cell_size, _grabbed_island):
			recover_failed.emit("Cell blocked by debris")
			return false
		if _player != null and _player.has_method("is_cell_overlapping_player"):
			if _player.is_cell_overlapping_player(target_cell, grid.cell_size):
				recover_failed.emit("Cell overlaps player")
				return false

		# Remove block from island (authoritative — prevents duplicates)
		var removed_data: BlockData = _grabbed_island.remove_block(_grabbed_cell)
		if removed_data == null:
			recover_failed.emit("Block no longer in debris island")
			is_grabbing = false
			_grabbed_island = null
			return false

		# Re-place on grid preserving full BlockData (keeps durability, type, metadata)
		grid.place_block(target_cell, removed_data)
		var recovered_type := removed_data.block_type
		_grabbed_island = null
		_grabbed_cell = Vector3i.ZERO
		_grabbed_data = null
		is_grabbing = false
		if preview_ghost != null:
			preview_ghost.hide_preview()
		recovered_block_to_grid.emit(target_cell, recovered_type)
		return true

	else:
		# At or below threshold — explicit recovery converts to raw material; do NOT place on grid.
		var removed_data: BlockData = _grabbed_island.remove_block(_grabbed_cell)
		if removed_data == null:
			recover_failed.emit("Block no longer in debris island")
			is_grabbing = false
			_grabbed_island = null
			return false

		var raw_type := removed_data.block_type
		_grabbed_island = null
		_grabbed_cell = Vector3i.ZERO
		_grabbed_data = null
		is_grabbing = false
		if preview_ghost != null:
			preview_ghost.hide_preview()
		recovered_as_raw_material.emit(raw_type, 1)
		return true

## Throws the carried block forward from the active camera direction.
## Applies a clamped forward impulse + subtle loft + randomised spin.
## Returns false if nothing is held or the camera cannot be determined.
func try_throw() -> bool:
	if not is_grabbing or not is_instance_valid(_grabbed_island):
		return false

	var cam: Camera3D = _get_active_camera()
	if cam == null:
		return false

	# Build throw direction: camera forward + slight loft
	var throw_dir: Vector3 = (-cam.global_transform.basis.z).normalized()
	throw_dir.y += throw_loft
	throw_dir = throw_dir.normalized()

	# Clamp speed to configured max
	var speed: float = clampf(throw_speed, 0.0, throw_speed_max)
	var throw_impulse: Vector3 = throw_dir * speed * _grabbed_island.mass

	# Release hold first so the spring force stops competing
	var island: RigidBody3D = _grabbed_island
	_grabbed_island = null
	_grabbed_cell = Vector3i.ZERO
	_grabbed_data = null
	is_grabbing = false
	if preview_ghost != null:
		preview_ghost.hide_preview()

	# Apply throw impulse and subtle random spin
	island.can_sleep = false
	island.apply_central_impulse(throw_impulse)
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var spin_axis: Vector3 = Vector3(
		rng.randf_range(-1.0, 1.0),
		rng.randf_range(-0.3, 0.3),
		rng.randf_range(-1.0, 1.0)
	).normalized()
	island.apply_torque_impulse(spin_axis * throw_spin * island.mass)

	thrown_block.emit(island, throw_impulse)
	released_block.emit()
	return true

func _update_recovery_preview(cam: Camera3D) -> void:
	var grid := _get_grid()
	if grid == null or preview_ghost == null:
		return

	var ray_origin := cam.global_position
	var ray_dir := -cam.global_transform.basis.z
	var ray_end := ray_origin + ray_dir * recovery_max_distance

	if not is_inside_tree() or get_world_3d() == null or not get_world_3d().space.is_valid():
		preview_ghost.hide_preview()
		return

	var space := get_world_3d().direct_space_state
	if space == null:
		preview_ghost.hide_preview()
		return

	var exclude_rids: Array[RID] = []
	if is_instance_valid(_grabbed_island):
		exclude_rids.append(_grabbed_island.get_rid())
	if _player != null and _player.has_method("get_rid"):
		exclude_rids.append(_player.get_rid())

	var query := PhysicsRayQueryParameters3D.create(ray_origin, ray_end)
	query.exclude = exclude_rids
	var result := space.intersect_ray(query)
	if result.is_empty():
		_recover_preview_valid = false
		preview_ghost.hide_preview()
		return

	var hit_pos: Vector3 = result.position
	var hit_normal: Vector3 = result.normal
	var target: Vector3i = grid.world_to_cell(hit_pos + hit_normal * (grid.cell_size * 0.5))
	var is_valid: bool = grid.can_place_block(target)
	if is_valid and orchestrator != null:
		is_valid = not orchestrator.is_cell_blocked_by_debris(target, grid.cell_size, _grabbed_island)
	if is_valid and _player != null and _player.has_method("is_cell_overlapping_player"):
		is_valid = not _player.is_cell_overlapping_player(target, grid.cell_size)

	var is_reusable: bool = true
	if _grabbed_data != null:
		var max_dur: float = BlockTypeCatalog.get_max_durability(_grabbed_data.block_type)
		var dur_ratio: float = _grabbed_data.durability / max_dur if max_dur > 0.0 else 0.0
		is_reusable = dur_ratio > recovery_durability_threshold

	_recover_preview_cell = target
	_recover_preview_valid = is_valid and is_reusable
	preview_ghost.update_preview(target, _recover_preview_valid, grid.cell_size)

func _get_active_camera() -> Camera3D:
	if _player != null and _player.has_method("get_active_camera"):
		return _player.get_active_camera()
	return null

func _get_grid() -> Node:
	if grid_system != null:
		return grid_system
	if has_node("/root/GridSystem"):
		return get_node("/root/GridSystem")
	return null

func on_island_freed() -> void:
	if is_grabbing:
		is_grabbing = false
		_grabbed_island = null
		_grabbed_cell = Vector3i.ZERO
		_grabbed_data = null
		released_block.emit()

func get_grabbed_island() -> DebrisIsland:
	return _grabbed_island

func get_grabbed_block_data() -> BlockData:
	return _grabbed_data

func get_grabbed_cell() -> Vector3i:
	return _grabbed_cell

func is_grabbed_block_reusable() -> bool:
	if not is_grabbing or _grabbed_data == null:
		return false
	var max_dur: float = BlockTypeCatalog.get_max_durability(_grabbed_data.block_type)
	var ratio: float = _grabbed_data.durability / max_dur if max_dur > 0.0 else 0.0
	return ratio > recovery_durability_threshold

func get_grabbed_durability_ratio() -> float:
	if not is_grabbing or _grabbed_data == null:
		return 0.0
	var max_dur: float = BlockTypeCatalog.get_max_durability(_grabbed_data.block_type)
	return _grabbed_data.durability / max_dur if max_dur > 0.0 else 0.0
