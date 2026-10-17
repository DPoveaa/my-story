class_name VoxelFragment
extends RigidBody3D

## Lightweight mined voxel fragment.
## - No per-frame polling: void cleanup and lifetime are managed centrally.
## - No contact monitoring or CCD (fragments are small and fast-sleeping).
## - No merge logic: PlayerController caps the total body count instead.
## - resource_value carries the collectible yield; vacuum collection reads it.

## Total resource units this fragment represents (≥1; aggregated when overflow is collected).
var resource_value: int = 1

func _ready() -> void:
	can_sleep = true
	sleeping = false
	continuous_cd = false
	contact_monitor = false
	max_contacts_reported = 0
	mass = 0.2
	gravity_scale = 1.3
	linear_damp = 2.0
	angular_damp = 2.5

	# Randomize initial rotation only if rotation is zero and not specifically preserved
	if not bool(get_meta("preserve_rotation", false)) and rotation == Vector3.ZERO:
		rotation = Vector3(randf() * TAU, randf() * TAU, randf() * TAU)

func is_settled() -> bool:
	if freeze:
		return true
	if sleeping:
		return true
	return linear_velocity.length_squared() < 0.04 and angular_velocity.length_squared() < 0.04
