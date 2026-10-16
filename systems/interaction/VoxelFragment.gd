extends RigidBody3D

## Mined voxel fragment — auto-sleeps when settled; despawns if it falls into the void.

const SLEEP_SPEED: float = 0.1

func _ready() -> void:
	can_sleep = true
	sleeping = false
	continuous_cd = true
	contact_monitor = true
	max_contacts_reported = 4
	mass = 0.05
	gravity_scale = 1.2
	linear_damp = 3.0
	angular_damp = 3.0

func _physics_process(_delta: float) -> void:
	if global_position.y < -50.0:
		queue_free()
		return
	if freeze:
		return
	if linear_velocity.length() < SLEEP_SPEED and angular_velocity.length() < SLEEP_SPEED:
		if get_contact_count() > 0:
			sleeping = true
