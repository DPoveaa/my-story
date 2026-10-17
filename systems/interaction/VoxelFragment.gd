class_name VoxelFragment
extends RigidBody3D

## Mined voxel fragment — uses native BoxMesh and BoxShape3D primitives,
## merges on contact with other fragments, auto-sleeps, and despawns in void.

const SLEEP_SPEED: float = 0.1
const MAX_SCALE: float = 3.0

var _is_merging: bool = false
## Tracks cumulative resource value; increments on merge so survivors only grow
var resource_value: int = 1

func _ready() -> void:
	can_sleep = true
	sleeping = false
	continuous_cd = true
	contact_monitor = true
	max_contacts_reported = 2
	mass = 5.0
	gravity_scale = 2.5
	linear_damp = 3.0
	angular_damp = 3.0

	# Randomize initial rotation if unrotated
	if rotation == Vector3.ZERO:
		rotation = Vector3(randf() * TAU, randf() * TAU, randf() * TAU)

	if not body_entered.is_connected(_on_body_entered):
		body_entered.connect(_on_body_entered)

func _physics_process(_delta: float) -> void:
	if global_position.y < -50.0:
		queue_free()
		return
	if freeze:
		return
	if linear_velocity.length() < SLEEP_SPEED and angular_velocity.length() < SLEEP_SPEED:
		if get_contact_count() > 0:
			sleeping = true

func _on_body_entered(body: Node) -> void:
	if _is_merging or is_queued_for_deletion():
		return
	if body is VoxelFragment and is_instance_valid(body) and not body.is_queued_for_deletion() and not body._is_merging:
		# Determine survivor: the one with the higher get_instance_id()
		if get_instance_id() > body.get_instance_id():
			# Accumulate resource_value from absorbed fragment
			resource_value += body.resource_value
			# Scale survivor based solely on own accumulated value — never shrinks
			scale = Vector3.ONE * minf(1.0 + float(resource_value) * 0.15, MAX_SCALE)
			mass += body.mass
			body._is_merging = true
			body.call_deferred("queue_free")
