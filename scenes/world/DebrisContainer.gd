class_name DebrisContainer
extends Node3D

## Universal Debris Container & Void Deletion manager.
## Tracks and cleans up debris, fragments, and items that fall into the void.

func _physics_process(_delta: float) -> void:
	if global_position.y < -50.0:
		queue_free()
		return

	# Void Kill for all child rigidbodies and debris objects
	for child in get_children():
		if child is Node3D and child.global_position.y < -50.0:
			child.queue_free()
