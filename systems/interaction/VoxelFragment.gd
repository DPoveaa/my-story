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
	mass = 0.08
	gravity_scale = 2.0
	linear_damp = 2.5
	angular_damp = 3.0

	# Randomize initial rotation so pieces look varied immediately.
	if rotation == Vector3.ZERO:
		rotation = Vector3(randf() * TAU, randf() * TAU, randf() * TAU)
