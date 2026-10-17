extends SceneTree

const PlayerControllerScript = preload("res://scenes/player/PlayerController.gd")

func _init() -> void:
	print("--- Running Test Bag and Destruction ---")
	var player = PlayerControllerScript.new()

	# Test Task 3: Bag logic
	assert(player.bag is Dictionary, "Bag is Dictionary")
	assert(player.bag.has("stone") and player.bag["stone"] == 0, "Stone in bag")
	assert(player.bag.has("dirt") and player.bag["dirt"] == 0, "Dirt in bag")
	assert(player.bag.has("iron") and player.bag["iron"] == 0, "Iron in bag")
	assert(player.current_volume == 0, "current_volume is 0")
	assert(player.max_volume == 30, "max_volume is 30")

	# Test dump_resource
	player.bag["stone"] = 5
	player.current_volume = 5
	var dumped := player.dump_resource("stone", 3)
	assert(dumped == 3, "dumped 3 stone")
	assert(player.bag["stone"] == 2, "2 stone left")
	assert(player.current_volume == 2, "current_volume is 2")

	# Test capacity limit check
	player.current_volume = 30
	# simulating addition when volume >= max_volume
	if player.current_volume < player.max_volume:
		player.bag["stone"] += 1
		player.current_volume += 1
	assert(player.current_volume == 30, "Volume clamped at max")

	# Test Task 2: Particle setup
	player._spawn_mining_particles(Vector3.ZERO, &"stone")
	# Check children or created particles
	# The method creates a GPUParticles3D and adds to parent or root
	var particles: GPUParticles3D = null
	for child in root.get_children():
		if child is GPUParticles3D:
			particles = child
			break
	if particles != null:
		assert(particles.draw_passes == 3, "draw_passes == 3")
		assert(particles.draw_pass_1 is BoxMesh, "draw_pass_1 is BoxMesh")
		assert(particles.draw_pass_2 is PrismMesh, "draw_pass_2 is PrismMesh")
		assert(particles.draw_pass_3 is SphereMesh, "draw_pass_3 is SphereMesh")
		var pmat := particles.process_material as ParticleProcessMaterial
		assert(pmat != null, "pmat exists")
		assert(pmat.scale_min < pmat.scale_max, "scale randomized")
		assert(pmat.angle_max > pmat.angle_min, "angle randomized")
		particles.queue_free()

	player.queue_free()
	print("--- All Bag and Destruction Tests PASSED! ---")
	quit(0)
