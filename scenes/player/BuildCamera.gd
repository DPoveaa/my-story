class_name BuildCamera
extends Camera3D

## Free-look and orbit building camera with raycast block targeting and placement controls.

signal block_type_changed(type_id: StringName)

@export var move_speed: float = 12.0
@export var fast_speed_multiplier: float = 2.5
@export var mouse_sensitivity: float = 0.003
@export var max_ray_distance: float = 80.0

@export var grid_system: GridSystem
@export var stability_system: StabilitySystem
@export var preview_ghost: PreviewGhost

var _mouse_captured: bool = false
var _yaw: float = 0.0
var _pitch: float = -0.4

var selected_type_index: int = 0
var available_types: Array[StringName] = [&"stone", &"wood", &"brick", &"gold"]

# Raycast state
var has_target: bool = false
var target_place_cell: Vector3i = Vector3i.ZERO
var target_remove_cell: Vector3i = Vector3i.ZERO
var can_place_target: bool = false

func _ready() -> void:
	if grid_system == null and has_node("/root/GridSystem"):
		grid_system = get_node("/root/GridSystem")
	if stability_system == null and has_node("/root/StabilitySystem"):
		stability_system = get_node("/root/StabilitySystem")

	_update_rotation()
	block_type_changed.emit(get_selected_type())

func get_selected_type() -> StringName:
	return available_types[selected_type_index]

func set_mouse_capture(captured: bool) -> void:
	_mouse_captured = captured
	if captured:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	else:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func toggle_mouse_capture() -> void:
	set_mouse_capture(not _mouse_captured)

func _unhandled_input(event: InputEvent) -> void:
	# Mouse look
	if event is InputEventMouseMotion:
		if _mouse_captured or Input.is_mouse_button_pressed(MOUSE_BUTTON_MIDDLE):
			_yaw -= event.relative.x * mouse_sensitivity
			_pitch = clampf(_pitch - event.relative.y * mouse_sensitivity, -1.45, 1.45)
			_update_rotation()

	# Clicks
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			# If mouse was not captured and user clicked in window, capture or perform action
			_handle_place_action()
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			_handle_remove_action()
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_cycle_block_type(-1)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_cycle_block_type(1)

	# Keyboard hotkeys
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_TAB or event.keycode == KEY_ESCAPE:
			toggle_mouse_capture()
		elif event.keycode == KEY_1:
			_select_type_by_index(0)
		elif event.keycode == KEY_2:
			_select_type_by_index(1)
		elif event.keycode == KEY_3:
			_select_type_by_index(2)
		elif event.keycode == KEY_4:
			_select_type_by_index(3)

func _update_rotation() -> void:
	transform.basis = Basis(Vector3.UP, _yaw) * Basis(Vector3.RIGHT, _pitch)

func _cycle_block_type(delta: int) -> void:
	selected_type_index = (selected_type_index + delta + available_types.size()) % available_types.size()
	block_type_changed.emit(get_selected_type())

func _select_type_by_index(idx: int) -> void:
	if idx >= 0 and idx < available_types.size():
		selected_type_index = idx
		block_type_changed.emit(get_selected_type())

func _process(delta: float) -> void:
	_handle_movement(delta)
	_update_raycast()

func _handle_movement(delta: float) -> void:
	var move_vec := Vector3.ZERO
	if Input.is_key_pressed(KEY_W):
		move_vec -= transform.basis.z
	if Input.is_key_pressed(KEY_S):
		move_vec += transform.basis.z
	if Input.is_key_pressed(KEY_A):
		move_vec -= transform.basis.x
	if Input.is_key_pressed(KEY_D):
		move_vec += transform.basis.x
	if Input.is_key_pressed(KEY_SPACE) or Input.is_key_pressed(KEY_E):
		move_vec += Vector3.UP
	if Input.is_key_pressed(KEY_Q) or Input.is_key_pressed(KEY_CTRL):
		move_vec -= Vector3.UP

	if move_vec.length_squared() > 0.001:
		var speed := move_speed
		if Input.is_key_pressed(KEY_SHIFT):
			speed *= fast_speed_multiplier
		global_position += move_vec.normalized() * speed * delta

func _update_raycast() -> void:
	var grid := grid_system
	if grid == null and has_node("/root/GridSystem"):
		grid = get_node("/root/GridSystem")

	if grid == null:
		return

	var space_state := get_world_3d().direct_space_state
	var ray_origin: Vector3
	var ray_dir: Vector3

	if _mouse_captured:
		# Raycast through center of screen
		ray_origin = global_position
		ray_dir = -transform.basis.z
	else:
		# Raycast through mouse cursor
		var mouse_pos := get_viewport().get_mouse_position()
		ray_origin = project_ray_origin(mouse_pos)
		ray_dir = project_ray_normal(mouse_pos)

	var ray_end := ray_origin + ray_dir * max_ray_distance
	var query := PhysicsRayQueryParameters3D.create(ray_origin, ray_end)
	var result := space_state.intersect_ray(query)

	if result.is_empty():
		has_target = false
		if preview_ghost != null:
			preview_ghost.hide_preview()
		return

	has_target = true
	var hit_pos: Vector3 = result.position
	var hit_normal: Vector3 = result.normal
	var hit_collider: Object = result.collider

	# Determine if we hit a static block or the ground
	if hit_collider is StaticBody3D:
		var hit_cell: Vector3i
		# Check if shape has metadata grid_cell
		var shape_idx: int = result.shape
		var col_shape: CollisionShape3D = null
		if hit_collider.get_child_count() > shape_idx:
			col_shape = hit_collider.get_child(shape_idx) as CollisionShape3D

		if col_shape != null and col_shape.has_meta("grid_cell"):
			hit_cell = col_shape.get_meta("grid_cell")
			target_remove_cell = hit_cell
			target_place_cell = hit_cell + _normal_to_cell_offset(hit_normal)
		else:
			# Hit ground plane
			target_place_cell = grid.world_to_cell(hit_pos + hit_normal * (grid.cell_size * 0.5))
			target_remove_cell = grid.world_to_cell(hit_pos - hit_normal * (grid.cell_size * 0.5))
	else:
		# Hit other collider / ground
		target_place_cell = grid.world_to_cell(hit_pos + hit_normal * (grid.cell_size * 0.5))
		target_remove_cell = grid.world_to_cell(hit_pos - hit_normal * (grid.cell_size * 0.5))

	can_place_target = grid.can_place_block(target_place_cell)

	if preview_ghost != null:
		preview_ghost.update_preview(target_place_cell, can_place_target, grid.cell_size)

func _normal_to_cell_offset(normal: Vector3) -> Vector3i:
	var abs_norm := normal.abs()
	if abs_norm.y >= abs_norm.x and abs_norm.y >= abs_norm.z:
		return Vector3i(0, 1 if normal.y > 0 else -1, 0)
	elif abs_norm.x >= abs_norm.y and abs_norm.x >= abs_norm.z:
		return Vector3i(1 if normal.x > 0 else -1, 0, 0)
	else:
		return Vector3i(0, 0, 1 if normal.z > 0 else -1)

func _handle_place_action() -> void:
	if not has_target:
		return
	var grid := grid_system
	if grid == null and has_node("/root/GridSystem"):
		grid = get_node("/root/GridSystem")
	if grid != null and can_place_target:
		grid.place_block(target_place_cell, get_selected_type())

func _handle_remove_action() -> void:
	if not has_target:
		return
	var grid := grid_system
	if grid == null and has_node("/root/GridSystem"):
		grid = get_node("/root/GridSystem")
	if grid != null and grid.has_block(target_remove_cell):
		grid.remove_block(target_remove_cell)
