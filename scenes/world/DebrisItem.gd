class_name DebrisItem
extends RigidBody3D

## Dynamic rigid debris / log / craft block with universal Void Kill check.

func _physics_process(_delta: float) -> void:
	if global_position.y < -50.0:
		queue_free()
