class_name GameWorld
extends Node3D

## Main test world scene for Milestone 1.
## Demonstrates grid-based block building, support calculations, presets, and physics collapse.

@onready var grid_renderer: GridRenderer = $GridRenderer
@onready var preview_ghost: PreviewGhost = $PreviewGhost
@onready var collapse_orchestrator: CollapseOrchestrator = $CollapseOrchestrator
@onready var debris_container: Node3D = $DebrisContainer
@onready var build_camera: BuildCamera = $BuildCamera
@onready var build_hud: BuildHUD = $BuildHUD

var grid_system: GridSystem
var stability_system: StabilitySystem

func _ready() -> void:
	if grid_system == null and has_node("/root/GridSystem"):
		grid_system = get_node("/root/GridSystem")
	if stability_system == null and has_node("/root/StabilitySystem"):
		stability_system = get_node("/root/StabilitySystem")

	# Wire HUD
	if build_hud != null:
		build_hud.grid_system = grid_system
		build_hud.orchestrator = collapse_orchestrator
		if build_camera != null:
			build_camera.block_type_changed.connect(build_hud.set_selected_block_type)
			build_hud.set_selected_block_type(build_camera.get_selected_type())

	# Build an initial demonstration structure so the player immediately sees content
	spawn_test_tower(Vector3i(0, 0, 0))

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_T:
			spawn_test_tower(Vector3i(0, 0, 0))
		elif event.keycode == KEY_B:
			spawn_test_bridge(Vector3i(-5, 0, -5))
		elif event.keycode == KEY_A:
			spawn_test_arch(Vector3i(6, 0, 0))
		elif event.keycode == KEY_C:
			clear_world()

## Spawns a tall test tower with an overhanging observation platform.
## Demonstrates vertical support and dramatic collapse when base blocks are destroyed.
func spawn_test_tower(origin: Vector3i = Vector3i.ZERO) -> void:
	if grid_system == null:
		return

	# 2x2 Pillar, 7 blocks tall
	for y in range(0, 7):
		for x in range(0, 2):
			for z in range(0, 2):
				var cell := origin + Vector3i(x, y, z)
				grid_system.place_block(cell, &"stone")

	# 4x4 Overhanging platform at top (y = 7)
	for x in range(-1, 3):
		for z in range(-1, 3):
			var cell := origin + Vector3i(x, 7, z)
			grid_system.place_block(cell, &"wood")

	# 4 crenellations/parapets on platform rim (y = 8)
	var battlements := [
		origin + Vector3i(-1, 8, -1),
		origin + Vector3i(2, 8, -1),
		origin + Vector3i(-1, 8, 2),
		origin + Vector3i(2, 8, 2)
	]
	for c in battlements:
		grid_system.place_block(c, &"brick")

## Spawns a bridge between two pillars.
## Demonstrates lateral support propagation: horizontal walkway supported by pillars.
func spawn_test_bridge(origin: Vector3i = Vector3i.ZERO) -> void:
	if grid_system == null:
		return

	# Left Pillar (height 5)
	for y in range(0, 5):
		grid_system.place_block(origin + Vector3i(0, y, 0), &"stone")

	# Right Pillar (height 5, distance 6 blocks away)
	for y in range(0, 5):
		grid_system.place_block(origin + Vector3i(6, y, 0), &"stone")

	# Walkway spanning between pillars (y = 4)
	for x in range(1, 6):
		grid_system.place_block(origin + Vector3i(x, 4, 0), &"wood")

## Spawns a rounded stone archway.
func spawn_test_arch(origin: Vector3i = Vector3i.ZERO) -> void:
	if grid_system == null:
		return

	# Left column
	for y in range(0, 4):
		grid_system.place_block(origin + Vector3i(0, y, 0), &"brick")

	# Right column
	for y in range(0, 4):
		grid_system.place_block(origin + Vector3i(4, y, 0), &"brick")

	# Arch curves and keystone
	grid_system.place_block(origin + Vector3i(1, 4, 0), &"stone")
	grid_system.place_block(origin + Vector3i(2, 5, 0), &"gold") # Keystone
	grid_system.place_block(origin + Vector3i(3, 4, 0), &"stone")

## Clears all blocks and active debris.
func clear_world() -> void:
	if grid_system != null:
		grid_system.clear()
	if collapse_orchestrator != null:
		collapse_orchestrator.clear_all_debris()
