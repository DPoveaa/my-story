extends RigidBody3D

## Stylized pine tree: stands static until chopped, physically topples with leverage
## and directional impulse applied at the crown, and splits into logs on ground impact.

@export var health: int = 3
@export var trunk_height: float = 4.0
@export var log_length: float = 1.0
## Linear impulse applied at the crown to create natural felling leverage.
@export var fell_impulse: float = 18.0

const DEBRIS_LAYER: int = 4
const CHIP_LIFETIME: float = 0.55

var _fallen: bool = false
var _splitting: bool = false
var _fell_time: float = 0.0

func _ready() -> void:
	add_to_group("tree")
	freeze = true
	freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	collision_layer = 1
	collision_mask = 1
	can_sleep = true
	mass = 35.0
	gravity_scale = 1.2
	continuous_cd = true
	axis_lock_angular_x = false
	axis_lock_angular_y = false
	axis_lock_angular_z = false
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	## Crown-biased COM — top-heavy body cannot weeble-wobble upright.
	center_of_mass = Vector3(0.0, trunk_height * 0.8, 0.0)

## amount: axe damage. hit_direction: vector from player toward/away (tree - player).
func take_damage(amount: int, hit_direction: Vector3 = Vector3.ZERO) -> void:
	if health <= 0 or _fallen:
		return
	health -= amount
	if health > 0:
		_spawn_wood_chips()
		return
	_fell(hit_direction)

func _physics_process(delta: float) -> void:
	if global_position.y < -50.0:
		queue_free()
		return
	if _splitting or not _fallen:
		return

	_fell_time += delta
	# Fallback if tree has fallen completely flat onto the ground
	if _fell_time > 0.4 and global_transform.basis.y.dot(Vector3.UP) < 0.2:
		_split_into_logs()

func _spawn_wood_chips() -> void:
	var particles := GPUParticles3D.new()
	particles.amount = randi_range(10, 16)
	particles.lifetime = CHIP_LIFETIME
	particles.one_shot = true
	particles.explosiveness = 1.0
	particles.draw_passes = 1

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.45, 0.28, 0.12)
	mat.roughness = 0.95

	var box := BoxMesh.new()
	box.size = Vector3(0.06, 0.04, 0.05)
	box.material = mat
	particles.draw_pass_1 = box

	var pmat := ParticleProcessMaterial.new()
	pmat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pmat.emission_sphere_radius = 0.12
	pmat.direction = Vector3(0.0, 0.4, 0.0)
	pmat.spread = 180.0
	pmat.initial_velocity_min = 2.5
	pmat.initial_velocity_max = 5.5
	pmat.radial_velocity_min = 1.5
	pmat.radial_velocity_max = 3.5
	pmat.gravity = Vector3(0.0, -9.0, 0.0)
	pmat.angle_min = -180.0
	pmat.angle_max = 180.0
	pmat.angular_velocity_min = -180.0
	pmat.angular_velocity_max = 180.0
	pmat.scale_min = 0.6
	pmat.scale_max = 1.3
	particles.process_material = pmat

	var parent: Node = get_parent() if get_parent() != null else (get_tree().current_scene if is_inside_tree() else null)
	if parent == null:
		return
	parent.add_child(particles)
	particles.global_position = global_position + Vector3(0.0, trunk_height * 0.35, 0.0)
	particles.emitting = true

	if is_inside_tree():
		var timer := get_tree().create_timer(CHIP_LIFETIME + 0.3)
		timer.timeout.connect(func() -> void:
			if is_instance_valid(particles):
				particles.queue_free()
		)

func _fell(hit_direction: Vector3) -> void:
	if _fallen:
		return
	_fallen = true
	health = 0
	_fell_time = 0.0

	# Calculate horizontal falling direction away from the player chop
	var push_dir: Vector3 = hit_direction
	push_dir.y = 0.0
	if push_dir.length_squared() < 0.0001:
		push_dir = -global_transform.basis.z
	push_dir = push_dir.normalized()

	# Elevate tree base slightly on cut to free it from terrain collision entrapment
	global_position += Vector3.UP * 0.18 + push_dir * 0.06

	# Activate full dynamic physics simulation with continuous collision
	continuous_cd = true
	contact_monitor = true
	max_contacts_reported = 6
	collision_layer = 1
	collision_mask = 1
	# Unlock all angular axes so the tree can tip freely in any direction
	axis_lock_angular_x = false
	axis_lock_angular_y = false
	axis_lock_angular_z = false
	# Crown-biased COM — shifting weight 80% up makes the tree irreversibly top-heavy.
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0.0, trunk_height * 0.8, 0.0)
	freeze = false
	sleeping = false

	if not body_entered.is_connected(_on_body_entered):
		body_entered.connect(_on_body_entered)

	# 1. Apply strong lateral impulse near the crown for lever-arm effect
	var top_offset := Vector3(0.0, trunk_height * 0.85, 0.0)
	apply_impulse(push_dir * (fell_impulse * 2.5), top_offset)

	# 2. Massive torque impulse — a top-heavy body with 500 Nm·s CANNOT stand back up.
	var fall_dir: Vector3 = push_dir
	var torque_axis: Vector3 = fall_dir.cross(Vector3.UP).normalized()
	apply_torque_impulse(torque_axis * 500.0)

	# 3. Fallback timer (2.0 seconds) in case tree snags without triggering body_entered
	if is_inside_tree():
		var fall_timer := get_tree().create_timer(2.0)
		fall_timer.timeout.connect(func() -> void:
			if is_instance_valid(self) and _fallen and not _splitting:
				_split_into_logs()
		)

func _on_body_entered(body: Node) -> void:
	if _splitting or not _fallen:
		return
	# Ignore initial collision on frame 0 with static ground where tree was rooted
	if _fell_time < 0.25:
		return
	if body == self:
		return

	# Tree has impacted ground or terrain -> split into collectable logs
	_split_into_logs()

func _split_into_logs() -> void:
	if _splitting:
		return
	_splitting = true

	var parent: Node = get_parent()
	if parent == null and is_inside_tree():
		parent = get_tree().current_scene
	if parent == null:
		queue_free()
		return

	var num_logs: int = maxi(1, int(trunk_height / maxf(log_length, 0.1)))
	var tree_xform: Transform3D = global_transform
	var trunk_axis: Vector3 = tree_xform.basis.y

	for i in range(num_logs):
		var log_body := ChoppingBlock.make_log_body(log_length)
		parent.add_child(log_body)
		# Place along the current rotated local Y axis matching fallen trunk orientation
		var offset: float = log_length * (float(i) + 0.5)
		log_body.global_transform = Transform3D(tree_xform.basis, tree_xform.origin + trunk_axis * offset)
		# Inherit linear and angular momentum from falling tree for physical satisfaction
		log_body.linear_velocity = linear_velocity * 0.4 + Vector3(randf_range(-0.3, 0.3), 0.2, randf_range(-0.3, 0.3))
		log_body.angular_velocity = angular_velocity * 0.4

	queue_free()
