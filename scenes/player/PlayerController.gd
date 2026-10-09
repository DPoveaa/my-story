class_name PlayerController
extends CharacterBody3D

## Reusable first-person player controller and Soul Projection state machine.
## M2.1: Fixed mouse capture flow, jump/gravity for 1m block clearance, step-up mechanic,
## debris push via CharacterBody3D contact, and modular grab/carry/recover system.

enum State {
	BODY_CONTROL,
	SOUL_PROJECTION,
	DEBUG_FLIGHT
}

signal state_changed(new_state: State)
signal block_type_changed(type_id: StringName)
signal carried_block_changed(is_carrying: bool, block_type: StringName)
signal cement_changed(current_count: int, max_count: int)
signal target_face_changed(has_target: bool, cell: Vector3i, face_dir: Vector3i, status_text: String)
signal raw_materials_changed(materials: Dictionary)
signal save_blueprint_requested()
signal load_blueprint_requested(anchor: Vector3i)

@export_group("Cement & Bonding")
@export var cement_count: int = 25
@export var max_cement: int = 100
@export var unlimited_cement: bool = false # Explicit debug/test flag

@export_group("First-Person Locomotion")
@export var walk_speed: float = 6.0
@export var sprint_speed_multiplier: float = 1.75
## Peak jump height ≈ jump_velocity² / (2*gravity)
## At 6.5 / 20.0: height ≈ 1.056m — clears a 1m block reliably.
@export var jump_velocity: float = 6.5
@export var gravity: float = 20.0
@export var mouse_sensitivity: float = 0.003
@export var capsule_radius: float = 0.4
@export var capsule_height: float = 1.8
## Step-up: automatically steps over ledges up to this height (voxel stairs / 1-block curbs).
@export var step_up_height: float = 0.45
## Impulse force applied when colliding horizontally with dynamic debris rigid bodies
@export var push_force: float = 120.0

@export_group("Soul Projection")
@export var projection_speed: float = 12.0
@export var projection_fast_multiplier: float = 2.5
@export var projection_mouse_sensitivity: float = 0.003

@export_group("Building Interaction")
@export var max_ray_distance: float = 80.0
@export var available_types: Array[StringName] = [&"stone", &"wood", &"brick", &"gold"]

# System References
@export var grid_system: Node
@export var stability_system: Node
@export var orchestrator: CollapseOrchestrator
@export var preview_ghost: PreviewGhost
@export var build_hud: Node = null

const DebrisGrabberScript = preload("res://systems/interaction/DebrisGrabber.gd")

# Internal Nodes
@onready var collision_shape: CollisionShape3D = $CollisionShape3D
@onready var body_mesh: MeshInstance3D = $BodyMesh
@onready var head: Node3D = $Head
@onready var body_camera: Camera3D = $Head/BodyCamera
@onready var projection_camera: Camera3D = $ProjectionCamera
@onready var debris_grabber: Node = get_node_or_null("DebrisGrabber")

# State
var current_state: State = State.BODY_CONTROL
var _mouse_captured: bool = false

# First-person view angles
var _yaw: float = 0.0
var _pitch: float = 0.0

# Projection view angles
var _proj_yaw: float = 0.0
var _proj_pitch: float = 0.0

# Material inventory selection
var selected_type_index: int = 0

# Raycast targeting state
var has_target: bool = false
var target_place_cell: Vector3i = Vector3i.ZERO
var target_remove_cell: Vector3i = Vector3i.ZERO
var target_face_dir: Vector3i = Vector3i.ZERO
var target_face_status: String = ""
var can_place_target: bool = false

# Debris targeting state
var target_is_debris: bool = false
var target_debris_island: DebrisIsland = null
var target_debris_cell: Variant = null

## Accumulated raw materials recovered from low-durability debris.
## Dictionary[StringName, int] — block_type -> amount
var raw_materials: Dictionary = {}

func _ensure_nodes() -> void:
	if collision_shape == null:
		collision_shape = get_node_or_null("CollisionShape3D")
	if body_mesh == null:
		body_mesh = get_node_or_null("BodyMesh")
	if head == null:
		head = get_node_or_null("Head")
	if body_camera == null:
		body_camera = get_node_or_null("Head/BodyCamera")
	if projection_camera == null:
		projection_camera = get_node_or_null("ProjectionCamera")
	if debris_grabber == null:
		debris_grabber = get_node_or_null("DebrisGrabber")

func _ready() -> void:
	_ensure_nodes()
	if grid_system == null and has_node("/root/GridSystem"):
		grid_system = get_node("/root/GridSystem")
	if stability_system == null and has_node("/root/StabilitySystem"):
		stability_system = get_node("/root/StabilitySystem")
	if preview_ghost == null and get_parent() != null and get_parent().has_node("PreviewGhost"):
		preview_ghost = get_parent().get_node("PreviewGhost") as PreviewGhost
	if orchestrator == null and get_parent() != null and get_parent().has_node("CollapseOrchestrator"):
		orchestrator = get_parent().get_node("CollapseOrchestrator") as CollapseOrchestrator

	if debris_grabber == null:
		debris_grabber = get_node_or_null("DebrisGrabber")
		if debris_grabber == null:
			debris_grabber = DebrisGrabberScript.new()
			debris_grabber.name = "DebrisGrabber"
			add_child(debris_grabber)

	if debris_grabber != null:
		debris_grabber.preview_ghost = preview_ghost
		debris_grabber.grid_system = grid_system
		debris_grabber.orchestrator = orchestrator
		if not debris_grabber.grabbed_block.is_connected(_on_grabbed_block):
			debris_grabber.grabbed_block.connect(_on_grabbed_block)
		if not debris_grabber.released_block.is_connected(_on_released_block):
			debris_grabber.released_block.connect(_on_released_block)
		if not debris_grabber.recovered_block_to_grid.is_connected(_on_recovered_block):
			debris_grabber.recovered_block_to_grid.connect(_on_recovered_block)
		if not debris_grabber.recovered_as_raw_material.is_connected(_on_recovered_raw_material):
			debris_grabber.recovered_as_raw_material.connect(_on_recovered_raw_material)

	# Ensure projection camera is top_level so it flies independently of body transform
	if projection_camera != null:
		projection_camera.top_level = true

	# Auto-capture mouse when game starts so first-person look works immediately
	set_mouse_capture(true)

	set_state(State.BODY_CONTROL)
	block_type_changed.emit(get_selected_type())
	cement_changed.emit(cement_count, max_cement)

func get_cement_count() -> int:
	return cement_count

func add_cement(amount: int) -> void:
	cement_count = clampi(cement_count + amount, 0, max_cement)
	cement_changed.emit(cement_count, max_cement)

func use_cement(amount: int = 1) -> bool:
	if unlimited_cement:
		return true
	if cement_count >= amount:
		cement_count -= amount
		cement_changed.emit(cement_count, max_cement)
		return true
	return false

func _on_grabbed_block(_island: DebrisIsland, _cell: Vector3i, data: BlockData) -> void:
	var b_type: StringName = data.block_type if data != null else &""
	carried_block_changed.emit(true, b_type)

func _on_released_block() -> void:
	carried_block_changed.emit(false, &"")

func _on_recovered_block(_cell: Vector3i, _b_type: StringName) -> void:
	carried_block_changed.emit(false, &"")

func _on_recovered_raw_material(block_type: StringName, amount: int) -> void:
	var current: int = raw_materials.get(block_type, 0)
	raw_materials[block_type] = current + amount
	carried_block_changed.emit(false, &"")
	raw_materials_changed.emit(raw_materials)

func get_selected_type() -> StringName:
	return available_types[selected_type_index]

func set_state(new_state: State) -> void:
	_ensure_nodes()
	var old_state := current_state
	current_state = new_state

	match current_state:
		State.BODY_CONTROL:
			if body_camera != null and is_inside_tree():
				body_camera.make_current()
			# Restore body orientation and look
			_pitch = 0.0
			if head != null:
				head.rotation.x = _pitch

		State.SOUL_PROJECTION:
			velocity = Vector3.ZERO
			# Safety: automatically release any carried debris block when soul detaches
			if debris_grabber != null and debris_grabber.is_grabbing:
				debris_grabber.release()
			if projection_camera != null and body_camera != null:
				if is_inside_tree():
					projection_camera.global_transform = body_camera.global_transform
					projection_camera.make_current()
				else:
					projection_camera.transform = body_camera.transform
				_proj_yaw = rotation.y
				if head != null:
					_proj_pitch = head.rotation.x

		State.DEBUG_FLIGHT:
			velocity = Vector3.ZERO
			if debris_grabber != null and debris_grabber.is_grabbing:
				debris_grabber.release()

	if old_state != current_state:
		state_changed.emit(current_state)

func toggle_soul_projection() -> void:
	if current_state == State.BODY_CONTROL:
		set_state(State.SOUL_PROJECTION)
	elif current_state == State.SOUL_PROJECTION:
		set_state(State.BODY_CONTROL)

func get_active_camera() -> Camera3D:
	_ensure_nodes()
	if current_state == State.SOUL_PROJECTION:
		return projection_camera
	elif current_state == State.BODY_CONTROL:
		return body_camera
	else:
		if is_inside_tree() and get_viewport() != null:
			var cam: Camera3D = get_viewport().get_camera_3d()
			if cam != null:
				return cam
		return body_camera

func set_mouse_capture(captured: bool) -> void:
	_mouse_captured = captured
	if captured:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	else:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func toggle_mouse_capture() -> void:
	set_mouse_capture(not _mouse_captured)

## Returns true if a UI modal (like save/load blueprint) is currently active.
func _is_ui_modal_open() -> bool:
	if build_hud != null and build_hud.has_method("is_modal_open"):
		return build_hud.is_modal_open()
	return false

func _input(event: InputEvent) -> void:
	# If a UI modal is active, ESC closes it and clicks do not recapture mouse
	if _is_ui_modal_open():
		if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
			if build_hud != null and build_hud.has_method("close_all_modals"):
				build_hud.close_all_modals()
				get_viewport().set_input_as_handled()
		return

	# ESC releases cursor immediately
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			if _mouse_captured:
				set_mouse_capture(false)
				get_viewport().set_input_as_handled()
				return

	# Click anywhere in the viewport while cursor is visible to recapture it
	if not _mouse_captured and event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT or event.button_index == MOUSE_BUTTON_RIGHT:
			if current_state != State.DEBUG_FLIGHT:
				set_mouse_capture(true)
				get_viewport().set_input_as_handled()
				return

## Consume all mouse motion and keyboard gameplay events (but NOT when debug camera is active or modal is open)
func _unhandled_input(event: InputEvent) -> void:
	if current_state == State.DEBUG_FLIGHT or _is_ui_modal_open():
		return

	# Mouse look — requires captured cursor; no middle-mouse dragging in body modes
	if event is InputEventMouseMotion and _mouse_captured:
		_handle_mouse_look(event.relative)
		get_viewport().set_input_as_handled()
		return

	# Mouse clicks for building / recovery
	if event is InputEventMouseButton and event.pressed:
		if _mouse_captured:
			if event.button_index == MOUSE_BUTTON_LEFT:
				_handle_place_action()
				get_viewport().set_input_as_handled()
				return
			elif event.button_index == MOUSE_BUTTON_RIGHT:
				_handle_remove_action()
				get_viewport().set_input_as_handled()
				return
			elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
				_cycle_block_type(-1)
				return
			elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				_cycle_block_type(1)
				return

	# Keyboard hotkeys
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_TAB or event.is_action_pressed(&"toggle_mouse_capture"):
			toggle_mouse_capture()
			return
		elif event.is_action_pressed(&"interact") or event.keycode == KEY_E:
			_handle_interact_action()
			return
		elif event.is_action_pressed(&"recover_block") or event.keycode == KEY_R:
			_handle_recover_action()
			return
		elif event.is_action_pressed(&"throw_debris") or event.keycode == KEY_F:
			_handle_throw_action()
			return
		elif event.is_action_pressed(&"apply_cement") or event.keycode == KEY_G:
			_handle_cement_action()
			return
		elif event.is_action_pressed(&"save_blueprint") or event.keycode == KEY_K:
			_handle_save_blueprint_action()
			return
		elif event.is_action_pressed(&"load_blueprint") or event.keycode == KEY_L:
			_handle_load_blueprint_action()
			return
		elif event.is_action_pressed(&"soul_projection") or event.keycode == KEY_V or event.keycode == KEY_P:
			toggle_soul_projection()
		elif event.is_action_pressed(&"select_slot_1") or event.keycode == KEY_1:
			_select_type_by_index(0)
		elif event.is_action_pressed(&"select_slot_2") or event.keycode == KEY_2:
			_select_type_by_index(1)
		elif event.is_action_pressed(&"select_slot_3") or event.keycode == KEY_3:
			_select_type_by_index(2)
		elif event.is_action_pressed(&"select_slot_4") or event.keycode == KEY_4:
			_select_type_by_index(3)

func _get_build_hud() -> Node:
	if build_hud != null and is_instance_valid(build_hud):
		return build_hud
	if is_inside_tree():
		if get_parent() != null and get_parent().has_node("BuildHUD"):
			build_hud = get_parent().get_node("BuildHUD")
			return build_hud
		var root := get_tree().root
		if root != null:
			var found = root.find_child("BuildHUD", true, false)
			if found != null:
				build_hud = found
				return build_hud
	return null

func _handle_save_blueprint_action() -> void:
	save_blueprint_requested.emit()
	var hud := _get_build_hud()
	if hud != null and hud.has_method("open_save_blueprint_dialog"):
		hud.open_save_blueprint_dialog()

func _handle_load_blueprint_action() -> void:
	var anchor: Vector3i = target_place_cell if has_target else Vector3i.ZERO
	load_blueprint_requested.emit(anchor)
	var hud := _get_build_hud()
	if hud != null and hud.has_method("open_load_blueprint_dialog"):
		hud.open_load_blueprint_dialog(anchor)

func _handle_mouse_look(relative: Vector2) -> void:
	match current_state:
		State.BODY_CONTROL:
			_yaw -= relative.x * mouse_sensitivity
			_pitch = clampf(_pitch - relative.y * mouse_sensitivity, -1.48, 1.48)
			rotation.y = _yaw
			if head != null:
				head.rotation.x = _pitch

		State.SOUL_PROJECTION:
			if projection_camera != null:
				_proj_yaw -= relative.x * projection_mouse_sensitivity
				_proj_pitch = clampf(_proj_pitch - relative.y * projection_mouse_sensitivity, -1.48, 1.48)
				projection_camera.transform.basis = Basis(Vector3.UP, _proj_yaw) * Basis(Vector3.RIGHT, _proj_pitch)

func _cycle_block_type(delta: int) -> void:
	selected_type_index = (selected_type_index + delta + available_types.size()) % available_types.size()
	block_type_changed.emit(get_selected_type())

func _select_type_by_index(idx: int) -> void:
	if idx >= 0 and idx < available_types.size():
		selected_type_index = idx
		block_type_changed.emit(get_selected_type())

func _physics_process(delta: float) -> void:
	if _is_ui_modal_open():
		velocity.x = 0.0
		velocity.z = 0.0
		_update_raycast()
		return

	match current_state:
		State.BODY_CONTROL:
			_process_body_movement(delta)
		State.SOUL_PROJECTION:
			_process_projection_flight(delta)
		State.DEBUG_FLIGHT:
			pass

	_update_raycast()

	if (Input.is_action_pressed(&"apply_cement") or Input.is_key_pressed(KEY_G)) and current_state != State.DEBUG_FLIGHT:
		if debris_grabber == null or not debris_grabber.is_grabbing:
			_handle_cement_action()

func _process_body_movement(delta: float) -> void:
	# Gravity simulation
	if not is_on_floor():
		velocity.y -= gravity * delta
	else:
		velocity.y = maxf(velocity.y, 0.0)
		# Jump
		if Input.is_action_just_pressed(&"jump") or Input.is_key_pressed(KEY_SPACE):
			velocity.y = jump_velocity

	# Planar input vector
	var input_vec := Vector2.ZERO
	if Input.is_action_pressed(&"move_forward") or Input.is_key_pressed(KEY_W):
		input_vec.y -= 1.0
	if Input.is_action_pressed(&"move_backward") or Input.is_key_pressed(KEY_S):
		input_vec.y += 1.0
	if Input.is_action_pressed(&"move_left") or Input.is_key_pressed(KEY_A):
		input_vec.x -= 1.0
	if Input.is_action_pressed(&"move_right") or Input.is_key_pressed(KEY_D):
		input_vec.x += 1.0

	var direction := Vector3.ZERO
	if input_vec.length_squared() > 0.001:
		input_vec = input_vec.normalized()
		direction = (transform.basis * Vector3(input_vec.x, 0, input_vec.y)).normalized()

	var speed := walk_speed
	if Input.is_action_pressed(&"sprint") or Input.is_key_pressed(KEY_SHIFT):
		speed *= sprint_speed_multiplier

	velocity.x = direction.x * speed
	velocity.z = direction.z * speed

	move_and_slide()

	# Push dynamic RigidBody3D (debris) and unbonded grid blocks upon physical contact
	for i in get_slide_collision_count():
		var col := get_slide_collision(i)
		var collider := col.get_collider()
		if collider is RigidBody3D:
			var push_dir := -col.get_normal()
			push_dir.y = 0.0
			if push_dir.length_squared() > 0.001:
				push_dir = push_dir.normalized()
				collider.apply_central_impulse(push_dir * push_force * delta)
		elif collider is StaticBody3D:
			var shape_idx: int = col.get_collider_shape_index()
			var owner_id: int = collider.shape_find_owner(shape_idx)
			if owner_id >= 0:
				var owner_shape = collider.shape_owner_get_owner(owner_id)
				if owner_shape != null and owner_shape.has_meta("grid_cell"):
					var hit_cell: Vector3i = owner_shape.get_meta("grid_cell")
					var is_anchor: bool = (stability_system != null and stability_system.is_anchor_cell(hit_cell)) or (hit_cell.y <= 0)
					var joint_sys: Node = null
					if has_node("/root/JointSystem"):
						joint_sys = get_node("/root/JointSystem")
					if not is_anchor and joint_sys != null and not joint_sys.is_block_bonded(hit_cell):
						if orchestrator != null and orchestrator.has_method("push_unbonded_block"):
							var push_dir := -col.get_normal()
							push_dir.y = 0.0
							if push_dir.length_squared() > 0.001:
								push_dir = push_dir.normalized()
								orchestrator.call_deferred("push_unbonded_block", hit_cell, push_dir * 3.5)

	# Step-up mechanic for voxel terrain: climb ledges up to step_up_height
	if is_on_wall() and direction.length_squared() > 0.001:
		_try_step_up(direction, delta)

func _try_step_up(move_dir: Vector3, _delta: float) -> void:
	if not is_inside_tree():
		return
	var space := get_world_3d().direct_space_state
	if space == null:
		return

	var shape_rid := collision_shape.shape.get_rid() if collision_shape != null else RID()
	if not shape_rid.is_valid():
		return

	var test_up := global_position + Vector3.UP * step_up_height
	var test_fwd := test_up + move_dir * (capsule_radius + 0.05)
	var params := PhysicsRayQueryParameters3D.create(test_up, test_fwd)
	params.exclude = [get_rid()]
	var hit := space.intersect_ray(params)
	if not hit.is_empty():
		return  # Wall too high even at step_up height

	# Floor check below the stepped position
	var check_from := test_fwd
	var check_to := test_fwd + Vector3.DOWN * (step_up_height + 0.1)
	var floor_params := PhysicsRayQueryParameters3D.create(check_from, check_to)
	floor_params.exclude = [get_rid()]
	var floor_hit := space.intersect_ray(floor_params)
	if floor_hit.is_empty():
		return  # No floor to step onto

	var step_y: float = floor_hit.position.y - global_position.y
	if step_y > 0.01 and step_y <= step_up_height:
		global_position.y += step_y + 0.02
		velocity.y = 0.0

func _process_projection_flight(delta: float) -> void:
	if projection_camera == null:
		return

	# Body remains completely stationary in Soul Projection
	velocity = Vector3.ZERO

	var fly_vec := Vector3.ZERO
	var basis_cam := projection_camera.global_transform.basis

	if Input.is_action_pressed(&"move_forward") or Input.is_key_pressed(KEY_W):
		fly_vec -= basis_cam.z
	if Input.is_action_pressed(&"move_backward") or Input.is_key_pressed(KEY_S):
		fly_vec += basis_cam.z
	if Input.is_action_pressed(&"move_left") or Input.is_key_pressed(KEY_A):
		fly_vec -= basis_cam.x
	if Input.is_action_pressed(&"move_right") or Input.is_key_pressed(KEY_D):
		fly_vec += basis_cam.x

	# Space + Q only for vertical flight
	if Input.is_action_pressed(&"fly_up") or Input.is_key_pressed(KEY_SPACE):
		fly_vec += Vector3.UP
	if Input.is_action_pressed(&"fly_down") or Input.is_key_pressed(KEY_CTRL) or Input.is_key_pressed(KEY_Q):
		fly_vec -= Vector3.UP

	if fly_vec.length_squared() > 0.001:
		var speed := projection_speed
		if Input.is_action_pressed(&"sprint") or Input.is_key_pressed(KEY_SHIFT):
			speed *= projection_fast_multiplier
		projection_camera.global_position += fly_vec.normalized() * speed * delta

## Tests whether a grid cell coordinate overlaps the player's physical capsule in world space.
func is_cell_overlapping_player(cell: Vector3i, cell_size: float = 1.0) -> bool:
	var cell_min := Vector3(float(cell.x) * cell_size, float(cell.y) * cell_size, float(cell.z) * cell_size)
	var cell_size_vec := Vector3.ONE * cell_size
	var cell_aabb := AABB(cell_min, cell_size_vec)

	var feet_pos: Vector3 = global_position if is_inside_tree() else position
	var half_r: float = capsule_radius
	var p_min := Vector3(feet_pos.x - half_r, feet_pos.y, feet_pos.z - half_r)
	var p_size := Vector3(half_r * 2.0, capsule_height, half_r * 2.0)
	var player_aabb := AABB(p_min, p_size)

	return cell_aabb.intersects(player_aabb)

func _update_raycast() -> void:
	var grid := grid_system
	if grid == null and has_node("/root/GridSystem"):
		grid = get_node("/root/GridSystem")
	if grid == null:
		return

	var cam := get_active_camera()
	if cam == null or not is_instance_valid(cam):
		return

	var space_state := get_world_3d().direct_space_state
	var ray_origin: Vector3
	var ray_dir: Vector3

	if _mouse_captured:
		ray_origin = cam.global_position
		ray_dir = -cam.global_transform.basis.z
	else:
		var mouse_pos := get_viewport().get_mouse_position()
		ray_origin = cam.project_ray_origin(mouse_pos)
		ray_dir = cam.project_ray_normal(mouse_pos)

	var ray_end := ray_origin + ray_dir * max_ray_distance
	var query := PhysicsRayQueryParameters3D.create(ray_origin, ray_end)
	var excludes: Array[RID] = [get_rid()]
	# Exclude currently carried debris block so it doesn't block player's view/placement raycast
	if debris_grabber != null and debris_grabber.is_grabbing and is_instance_valid(debris_grabber._grabbed_island):
		excludes.append(debris_grabber._grabbed_island.get_rid())
	query.exclude = excludes

	var result := space_state.intersect_ray(query)

	if result.is_empty():
		has_target = false
		target_is_debris = false
		target_debris_island = null
		target_debris_cell = null
		target_face_dir = Vector3i.ZERO
		target_face_status = ""
		target_face_changed.emit(false, Vector3i.ZERO, Vector3i.ZERO, "")
		if preview_ghost != null and (debris_grabber == null or not debris_grabber.is_grabbing):
			preview_ghost.hide_preview()
		return

	has_target = true
	var hit_pos: Vector3 = result.position
	var hit_normal: Vector3 = result.normal
	var hit_collider: Object = result.collider
	var shape_idx: int = result.shape

	if hit_collider is StaticBody3D:
		target_is_debris = false
		target_debris_island = null
		target_debris_cell = null

		var owner_id: int = hit_collider.shape_find_owner(shape_idx)
		var col_shape: CollisionShape3D = null
		if owner_id >= 0:
			col_shape = hit_collider.shape_owner_get_owner(owner_id) as CollisionShape3D

		if col_shape != null and col_shape.has_meta("grid_cell"):
			var hit_cell: Vector3i = col_shape.get_meta("grid_cell")
			target_remove_cell = hit_cell
			target_face_dir = _normal_to_cell_offset(hit_normal)
			target_place_cell = hit_cell + target_face_dir
		else:
			target_place_cell = grid.world_to_cell(hit_pos + hit_normal * (grid.cell_size * 0.5))
			target_remove_cell = grid.world_to_cell(hit_pos - hit_normal * (grid.cell_size * 0.5))
			target_face_dir = _normal_to_cell_offset(hit_normal)

		var grid_valid: bool = grid.can_place_block(target_place_cell)
		var blocked_by_debris: bool = false
		if orchestrator != null:
			blocked_by_debris = orchestrator.is_cell_blocked_by_debris(target_place_cell, grid.cell_size)
		var overlaps_player: bool = is_cell_overlapping_player(target_place_cell, grid.cell_size)

		can_place_target = grid_valid and not blocked_by_debris and not overlaps_player

		var joint_sys: Node = null
		if has_node("/root/JointSystem"):
			joint_sys = get_node("/root/JointSystem")

		if joint_sys != null and grid.has_block(target_remove_cell):
			if joint_sys.is_face_coated(target_remove_cell, target_face_dir):
				target_face_status = "Surface Mortared (Reinforced)"
			else:
				target_face_status = "Uncoated Surface (Hold G to Paint Mortar)"
		else:
			target_face_status = ""

		# Append durability info for the targeted block.
		var block_data: BlockData = grid.get_block(target_remove_cell)
		if block_data != null:
			var pct: int = int(clampf(block_data.durability, 0.0, 1.0) * 100.0)
			var dur_label: String
			if pct >= 80:
				dur_label = "%d%% Integrity" % pct
			elif pct >= 40:
				dur_label = "%d%% Integrity (Damaged)" % pct
			else:
				dur_label = "%d%% Integrity (CRITICAL)" % pct
			if target_face_status.is_empty():
				target_face_status = dur_label
			else:
				target_face_status = target_face_status + "  |  " + dur_label

		target_face_changed.emit(true, target_remove_cell, target_face_dir, target_face_status)

	elif hit_collider is DebrisIsland:
		target_is_debris = true
		target_debris_island = hit_collider
		target_debris_cell = hit_collider.get_cell_from_shape_hit(shape_idx, hit_pos)

		if hit_collider.is_moving():
			can_place_target = false
			target_place_cell = Vector3i.ZERO
		else:
			target_place_cell = grid.world_to_cell(hit_pos + hit_normal * (grid.cell_size * 0.5))
			var grid_valid: bool = grid.can_place_block(target_place_cell)
			var held_island: DebrisIsland = debris_grabber.get_grabbed_island() if (debris_grabber != null and debris_grabber.is_grabbing) else null
			var blocked: bool = false
			if orchestrator != null:
				blocked = orchestrator.is_cell_blocked_by_debris(target_place_cell, grid.cell_size, held_island)
			var overlaps_player: bool = is_cell_overlapping_player(target_place_cell, grid.cell_size)

			can_place_target = grid_valid and not blocked and not overlaps_player

		# Display material and integrity percentage for the individual targeted debris block
		if target_debris_cell != null and hit_collider.constituent_blocks.has(target_debris_cell):
			var block_data: BlockData = hit_collider.constituent_blocks[target_debris_cell]
			var mat_name := BlockTypeCatalog.get_display_name(block_data.block_type)
			var max_dur: float = BlockTypeCatalog.get_max_durability(block_data.block_type)
			var ratio: float = block_data.durability / max_dur if max_dur > 0.0 else 0.0
			var pct: int = int(clampf(ratio, 0.0, 1.0) * 100.0)
			var dur_label: String
			if pct >= 80:
				dur_label = "%d%% Integrity" % pct
			elif pct >= 40:
				dur_label = "%d%% Integrity (Damaged)" % pct
			else:
				dur_label = "%d%% Integrity (CRITICAL)" % pct

			target_face_status = "Debris (%s)  |  %s" % [mat_name, dur_label]
			target_face_changed.emit(true, Vector3i.ZERO, Vector3i.ZERO, target_face_status)
		else:
			target_face_status = ""
			target_face_changed.emit(false, Vector3i.ZERO, Vector3i.ZERO, "")

	else:
		target_is_debris = false
		target_debris_island = null
		target_debris_cell = null
		target_place_cell = grid.world_to_cell(hit_pos + hit_normal * (grid.cell_size * 0.5))
		target_remove_cell = grid.world_to_cell(hit_pos - hit_normal * (grid.cell_size * 0.5))

		var grid_valid: bool = grid.can_place_block(target_place_cell)
		var blocked_by_debris: bool = false
		if orchestrator != null:
			blocked_by_debris = orchestrator.is_cell_blocked_by_debris(target_place_cell, grid.cell_size)
		var overlaps_player: bool = is_cell_overlapping_player(target_place_cell, grid.cell_size)

		can_place_target = grid_valid and not blocked_by_debris and not overlaps_player

	if preview_ghost != null:
		if debris_grabber != null and debris_grabber.is_grabbing:
			pass # DebrisGrabber updates the preview ghost for recovery
		elif target_is_debris and target_debris_island != null and target_debris_island.is_moving():
			preview_ghost.hide_preview()
		else:
			preview_ghost.update_preview(target_place_cell, can_place_target, grid.cell_size)

func _normal_to_cell_offset(normal: Vector3) -> Vector3i:
	var abs_norm := normal.abs()
	if abs_norm.y >= abs_norm.x and abs_norm.y >= abs_norm.z:
		return Vector3i(0, 1 if normal.y > 0 else -1, 0)
	elif abs_norm.x >= abs_norm.y and abs_norm.x >= abs_norm.z:
		return Vector3i(1 if normal.x > 0 else -1, 0, 0)
	else:
		return Vector3i(0, 0, 1 if normal.z > 0 else -1)

func _handle_interact_action() -> void:
	if debris_grabber == null:
		return
	if current_state != State.BODY_CONTROL:
		return

	if debris_grabber.is_grabbing:
		debris_grabber.release()
	else:
		if target_is_debris and is_instance_valid(target_debris_island) and target_debris_cell != null:
			var block_data: BlockData = null
			if target_debris_island.constituent_blocks.has(target_debris_cell):
				block_data = target_debris_island.constituent_blocks[target_debris_cell]
			debris_grabber.try_grab(target_debris_island, target_debris_cell, block_data)

func _handle_recover_action() -> void:
	if debris_grabber != null and debris_grabber.is_grabbing:
		debris_grabber.try_recover()

func _handle_place_action() -> void:
	_ensure_nodes()
	if debris_grabber != null and debris_grabber.is_grabbing:
		# When holding debris, placement action exclusively attempts to place the held debris block.
		# If the target position is invalid or the block is damaged (<= 50%), placement is safely
		# rejected without consuming, converting, dropping, duplicating, or modifying the held block.
		# Never fall through to placing fresh blocks from inventory while carrying debris.
		debris_grabber.try_place_to_grid()
		return

	if not has_target:
		return
	if target_is_debris and is_instance_valid(target_debris_island) and target_debris_island.is_moving():
		return
	if not can_place_target:
		return

	var grid := grid_system
	if grid == null and has_node("/root/GridSystem"):
		grid = get_node("/root/GridSystem")

	if grid != null:
		if is_cell_overlapping_player(target_place_cell, grid.cell_size):
			return
		if orchestrator != null and orchestrator.is_cell_blocked_by_debris(target_place_cell, grid.cell_size):
			return
		grid.place_block(target_place_cell, get_selected_type())

func _handle_remove_action() -> void:
	if debris_grabber != null and debris_grabber.is_grabbing:
		debris_grabber.release()
		return

	if not has_target:
		return

	if target_is_debris:
		if is_instance_valid(target_debris_island) and target_debris_cell != null:
			target_debris_island.remove_block(target_debris_cell)
	else:
		var grid := grid_system
		if grid == null and has_node("/root/GridSystem"):
			grid = get_node("/root/GridSystem")
		if grid != null and grid.has_block(target_remove_cell):
			grid.remove_block(target_remove_cell)

func _handle_throw_action() -> void:
	if debris_grabber == null:
		return
	if current_state != State.BODY_CONTROL:
		return
	if debris_grabber.is_grabbing:
		debris_grabber.try_throw()

func _handle_cement_action() -> void:
	if not has_target or target_is_debris:
		return
	if target_face_dir == Vector3i.ZERO:
		return

	var grid := grid_system
	if grid == null and has_node("/root/GridSystem"):
		grid = get_node("/root/GridSystem")
	if grid == null or not grid.has_block(target_remove_cell):
		return

	var joint_sys: Node = null
	if has_node("/root/JointSystem"):
		joint_sys = get_node("/root/JointSystem")
	if joint_sys == null:
		return

	if joint_sys.is_face_coated(target_remove_cell, target_face_dir):
		target_face_status = "Surface Mortared (Reinforced)"
		target_face_changed.emit(has_target, target_remove_cell, target_face_dir, target_face_status)
		return

	if not unlimited_cement and cement_count <= 0:
		target_face_status = "Mortar Depleted! (0 left)"
		target_face_changed.emit(has_target, target_remove_cell, target_face_dir, target_face_status)
		return

	if use_cement(1):
		var res: Dictionary = joint_sys.apply_mortar_brush(target_remove_cell, target_face_dir)
		var reinforced: Array = res.get("reinforced_joints", [])
		if not reinforced.is_empty():
			target_face_status = "Surface Mortared! (%d joints reinforced, %d left)" % [reinforced.size(), cement_count]
		else:
			target_face_status = "Surface Mortared! (Ready, %d left)" % cement_count
		target_face_changed.emit(has_target, target_remove_cell, target_face_dir, target_face_status)
