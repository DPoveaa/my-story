class_name ChoppingBlock
extends StaticBody3D

## Crafted stump: accept a carried log, chop into 2 upright planks, or dismantle via radial.

const RESOURCE_LAYER: int = 4
const DEBRIS_LAYER: int = 8
const RESOURCE_COLLISION_MASK: int = 1 | RESOURCE_LAYER | DEBRIS_LAYER
const DEBRIS_COLLISION_MASK: int = 1 | RESOURCE_LAYER | DEBRIS_LAYER

## Canonical wood dimensions (shared by spawn, hand, drop, and pallet visuals).
const LOG_LENGTH: float = 1.0
const LOG_RADIUS: float = 0.22
const PLANK_SIZE: Vector3 = Vector3(0.08, 0.70, 0.22)

@export var has_log: bool = false

@onready var visual_log: MeshInstance3D = $VisualLog

var reserved_worker: Node = null

func _ready() -> void:
	add_to_group("crafting_stations")
	add_to_group("chopping_blocks")
	collision_layer = 1
	collision_mask = 0
	if visual_log != null:
		visual_log.visible = has_log
	call_deferred("_notify_astar")

func _exit_tree() -> void:
	release_reservation()
	call_deferred("_notify_astar")

func _notify_astar() -> void:
	if not is_inside_tree():
		return
	var root := get_tree().root
	var astar_mgr: Node = root.find_child("AStarGridManager", true, false)
	if astar_mgr != null and astar_mgr.has_method("notify_bounds_changed"):
		var aabb := AABB(global_position + Vector3(-0.7, -0.05, -0.7), Vector3(1.4, 0.65, 1.4))
		astar_mgr.notify_bounds_changed(aabb)

func can_accept_log(for_worker: Node = null) -> bool:
	if has_log:
		return false
	if reserved_worker != null:
		if not is_instance_valid(reserved_worker) or not (reserved_worker is Node and (reserved_worker as Node).is_inside_tree()):
			reserved_worker = null
		elif for_worker != null and reserved_worker == for_worker:
			return true
		else:
			return false
	if has_meta("worker_reserved_by"):
		var w = get_meta("worker_reserved_by")
		if w is Node:
			if not is_instance_valid(w) or not (w as Node).is_inside_tree():
				set_meta("worker_reserved_by", null)
			elif for_worker != null and w == for_worker:
				return true
			else:
				return false
		elif w == null:
			pass
		else:
			set_meta("worker_reserved_by", null)

	# Clean up any stale worker_assigned metadata if there is no valid active reservation
	if reserved_worker == null and (not has_meta("worker_reserved_by") or get_meta("worker_reserved_by") == null):
		if has_meta("worker_assigned") and bool(get_meta("worker_assigned")):
			set_meta("worker_assigned", false)

	return true

func reserve(worker: Node) -> bool:
	if not can_accept_log(worker):
		return false
	reserved_worker = worker
	set_meta("worker_reserved_by", worker)
	set_meta("worker_assigned", true)
	return true

func release_reservation(worker: Node = null) -> void:
	if worker == null or reserved_worker == worker or (has_meta("worker_reserved_by") and get_meta("worker_reserved_by") == worker):
		reserved_worker = null
		set_meta("worker_reserved_by", null)
		set_meta("worker_assigned", false)

func try_place_log() -> bool:
	if has_log:
		return false
	has_log = true
	if visual_log != null:
		visual_log.visible = true
	reserved_worker = null
	set_meta("worker_reserved_by", null)
	set_meta("worker_assigned", false)
	return true

func try_chop() -> bool:
	if not has_log:
		return false
	has_log = false
	if visual_log != null:
		visual_log.visible = false
	wake_nearby_bodies(get_tree(), global_position, 2.5)
	_spawn_planks_neat(2)
	return true

func dismantle() -> void:
	var parent: Node = get_parent()
	if parent == null and is_inside_tree():
		parent = get_tree().current_scene
	if parent != null:
		if has_log:
			var placed_log := make_log_body()
			parent.add_child(placed_log)
			placed_log.global_position = global_position + Vector3(0.0, 0.6, 0.0)
			placed_log.linear_velocity = Vector3(randf_range(-0.5, 0.5), 1.0, randf_range(-0.5, 0.5))
		var refund_log := make_log_body()
		parent.add_child(refund_log)
		refund_log.global_position = global_position + Vector3(0.0, 0.3, 0.0)
		refund_log.linear_velocity = Vector3(randf_range(-0.5, 0.5), 1.0, randf_range(-0.5, 0.5))
	wake_nearby_bodies(get_tree(), global_position, 2.5)
	queue_free()

## Whenever a Log is picked up or destroyed, run the same "Wake Up" SphereCast (radius 2.5m)
## used for the voxel ground. Set sleeping = false and apply a tiny downward impulse to any RigidBody3D detected.
static func wake_nearby_bodies(tree: SceneTree, center: Vector3, radius: float = 2.5) -> void:
	if tree == null:
		return
	_wake_nearby_bodies_async(tree, center, radius)

static func _wake_nearby_bodies_async(tree: SceneTree, center: Vector3, radius: float) -> void:
	if tree == null or not is_instance_valid(tree):
		return
	await tree.physics_frame
	if tree == null or not is_instance_valid(tree):
		return
	var root: Window = tree.root
	if root != null and is_instance_valid(root):
		var world_3d: World3D = root.get_world_3d()
		if world_3d != null and world_3d.space.is_valid():
			var direct_state: PhysicsDirectSpaceState3D = world_3d.direct_space_state
			if direct_state != null:
				var sphere := SphereShape3D.new()
				sphere.radius = radius

				var query := PhysicsShapeQueryParameters3D.new()
				query.shape = sphere
				query.transform = Transform3D(Basis(), center)
				query.collide_with_bodies = true
				query.collide_with_areas = false
				query.collision_mask = 0xFFFFFFFF

				var results: Array[Dictionary] = direct_state.intersect_shape(query, 64)
				var woken: Dictionary = {}
				for res in results:
					var collider: Object = res.get("collider", null)
					if collider is RigidBody3D:
						var rb := collider as RigidBody3D
						if not woken.has(rb):
							woken[rb] = true
							rb.sleeping = false
							var jitter_x: float = randf_range(-0.02, 0.02)
							var jitter_z: float = randf_range(-0.02, 0.02)
							rb.apply_central_impulse(Vector3(jitter_x, -0.1, jitter_z))

	# Scene-tree fallback for log/plank/debris groups in radius
	var r2: float = radius * radius
	for grp in [&"logs", &"planks", &"debris", &"fragments"]:
		for node in tree.get_nodes_in_group(grp):
			if is_instance_valid(node) and node is RigidBody3D:
				var rb := node as RigidBody3D
				if rb.global_position.distance_squared_to(center) <= r2:
					rb.sleeping = false
					rb.apply_central_impulse(Vector3(randf_range(-0.02, 0.02), -0.1, randf_range(-0.02, 0.02)))

## Two upright planks side-by-side on the stump — no impulse; manual-carry only.
func _spawn_planks_neat(count: int) -> void:
	var parent: Node = get_parent()
	if parent == null and is_inside_tree():
		parent = get_tree().current_scene
	if parent == null:
		return
	for i in range(count):
		var plank := make_plank_body()
		parent.add_child(plank)
		var x_pos: float = -0.05 + (float(i) * 0.10)
		var y_pos: float = 0.55 + (PLANK_SIZE.y * 0.5) + 0.015
		var local_offset := Vector3(x_pos, y_pos, 0.0)
		plank.global_transform = Transform3D(global_transform.basis, global_transform * local_offset)
		plank.linear_velocity = Vector3.ZERO
		plank.angular_velocity = Vector3.ZERO

static func make_log_body(length: float = LOG_LENGTH) -> RigidBody3D:
	var log_body := RigidBody3D.new()
	log_body.name = "PineLog"
	log_body.add_to_group("debris")
	log_body.add_to_group("logs")
	log_body.set_meta("is_log", true)
	log_body.set_meta("carry_type", "log")
	log_body.set_meta("material", "log")
	log_body.collision_layer = RESOURCE_LAYER
	log_body.collision_mask = RESOURCE_COLLISION_MASK
	log_body.mass = 2.5
	log_body.can_sleep = true
	log_body.linear_damp = 1.0
	log_body.angular_damp = 1.6
	log_body.continuous_cd = true

	# Wake stacked logs if this log is destroyed / despawned
	log_body.tree_exiting.connect(func() -> void:
		if is_instance_valid(log_body):
			var pos: Vector3 = log_body.global_position
			var t: SceneTree = log_body.get_tree()
			if t != null:
				ChoppingBlock.wake_nearby_bodies(t, pos, 2.5)
	)

	var cyl := CylinderMesh.new()
	cyl.top_radius = LOG_RADIUS * 0.95
	cyl.bottom_radius = LOG_RADIUS
	cyl.height = length * 0.92
	cyl.radial_segments = 10
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.42, 0.28, 0.14)
	mat.roughness = 0.9
	cyl.material = mat

	var mesh_inst := MeshInstance3D.new()
	mesh_inst.mesh = cyl
	log_body.add_child(mesh_inst)

	var shape := CylinderShape3D.new()
	shape.radius = LOG_RADIUS
	shape.height = length * 0.92
	var col := CollisionShape3D.new()
	col.shape = shape
	log_body.add_child(col)
	return log_body

static func make_plank_body() -> RigidBody3D:
	var body := RigidBody3D.new()
	body.name = "Plank"
	body.add_to_group("debris")
	body.add_to_group("planks")
	body.set_meta("is_plank", true)
	body.set_meta("carry_type", "plank")
	body.set_meta("material", "plank")
	body.collision_layer = RESOURCE_LAYER
	body.collision_mask = RESOURCE_COLLISION_MASK
	body.mass = 0.8
	body.can_sleep = true
	body.linear_damp = 1.0
	body.angular_damp = 1.4
	body.continuous_cd = true

	# Wake stacked logs/planks if this plank is destroyed / despawned
	body.tree_exiting.connect(func() -> void:
		if is_instance_valid(body):
			var pos: Vector3 = body.global_position
			var t: SceneTree = body.get_tree()
			if t != null:
				ChoppingBlock.wake_nearby_bodies(t, pos, 2.5)
	)

	var box := BoxMesh.new()
	box.size = PLANK_SIZE
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.72, 0.55, 0.28)
	mat.roughness = 0.85
	box.material = mat

	var mesh_inst := MeshInstance3D.new()
	mesh_inst.mesh = box
	body.add_child(mesh_inst)

	var shape := BoxShape3D.new()
	shape.size = PLANK_SIZE
	var col := CollisionShape3D.new()
	col.shape = shape
	body.add_child(col)
	return body
