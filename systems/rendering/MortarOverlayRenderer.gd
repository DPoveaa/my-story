class_name MortarOverlayRenderer
extends Node3D

## Visual overlay manager for mortar-coated block faces.
## Creates a thin raised panel on each mortared face so players can see exactly
## which faces have been coated, without tinting the whole block.
##
## Design:
## - One MeshInstance3D (a very thin BoxMesh slice) per mortared face.
## - Mesh is offset 0.002 m outside the block face to eliminate z-fighting.
## - Mesh occupies 96% of the face area to leave a subtle gap at block edges.
## - Mortar material: sandy-cream color, high roughness, opaque — fits the
##   existing block art style and is unmistakably different from the block base.
## - Overlays are created/removed reactively via JointSystem and GridSystem signals.
## - No per-frame updates: all state changes are event-driven.

@export var joint_system: Node
@export var grid_system: Node

## Sandy/cream mortar colour that contrasts clearly against all four block types.
const MORTAR_COLOR: Color = Color(0.84, 0.77, 0.61, 1.0)
const MORTAR_ROUGHNESS: float = 0.97
const FACE_COVERAGE: float = 0.96   # Fraction of cell face the overlay covers
const OVERLAY_THICKNESS: float = 0.03 # Metres — thin enough to read as a surface coat
const Z_OFFSET: float = 0.002       # Extra clearance beyond face edge to prevent z-fighting

## Single shared material instance for all overlays (avoids per-face material spam).
var _mortar_mat: StandardMaterial3D

## Dictionary[String, MeshInstance3D] — key matches JointSystem face key format.
var _overlays: Dictionary = {}

## Cached cell_size updated from GridSystem.
var _cell_size: float = 1.0

func _ready() -> void:
	if joint_system == null and has_node("/root/JointSystem"):
		joint_system = get_node("/root/JointSystem")
	if grid_system == null and has_node("/root/GridSystem"):
		grid_system = get_node("/root/GridSystem")

	_build_mortar_material()

	if grid_system != null:
		_cell_size = grid_system.cell_size
		if not grid_system.block_removed.is_connected(_on_block_removed):
			grid_system.block_removed.connect(_on_block_removed)
		if not grid_system.blocks_removed_batch.is_connected(_on_blocks_removed_batch):
			grid_system.blocks_removed_batch.connect(_on_blocks_removed_batch)
		if not grid_system.grid_cleared.is_connected(_on_grid_cleared):
			grid_system.grid_cleared.connect(_on_grid_cleared)

	if joint_system != null:
		if not joint_system.face_coated.is_connected(_on_face_coated):
			joint_system.face_coated.connect(_on_face_coated)

func _build_mortar_material() -> void:
	_mortar_mat = StandardMaterial3D.new()
	_mortar_mat.albedo_color = MORTAR_COLOR
	_mortar_mat.roughness = MORTAR_ROUGHNESS
	_mortar_mat.metallic = 0.0
	_mortar_mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_ALWAYS
	_mortar_mat.cull_mode = BaseMaterial3D.CULL_BACK

# ==============================================================================
# FACE KEY  (mirrors JointSystem._face_key format)
# ==============================================================================

func _face_key(cell: Vector3i, face_dir: Vector3i) -> String:
	return "%d,%d,%d:%d,%d,%d" % [cell.x, cell.y, cell.z, face_dir.x, face_dir.y, face_dir.z]

# ==============================================================================
# OVERLAY GEOMETRY
# ==============================================================================

## Returns the overlay BoxMesh size for a given face direction.
## One axis is OVERLAY_THICKNESS; the other two span FACE_COVERAGE of the cell.
func _overlay_box_size(face_dir: Vector3i, cs: float) -> Vector3:
	var face: float = cs * FACE_COVERAGE
	var thick: float = OVERLAY_THICKNESS
	if face_dir.x != 0:
		return Vector3(thick, face, face)
	elif face_dir.y != 0:
		return Vector3(face, thick, face)
	else:
		return Vector3(face, face, thick)

## Returns the world-space position of the overlay mesh centre.
func _overlay_position(cell: Vector3i, face_dir: Vector3i, cs: float) -> Vector3:
	var block_center := Vector3(
		(float(cell.x) + 0.5) * cs,
		(float(cell.y) + 0.5) * cs,
		(float(cell.z) + 0.5) * cs
	)
	var face_center := block_center + Vector3(face_dir) * (cs * 0.5)
	var outward := Vector3(face_dir).normalized() * (Z_OFFSET + OVERLAY_THICKNESS * 0.5)
	return face_center + outward

func _create_overlay(cell: Vector3i, face_dir: Vector3i) -> void:
	var fk := _face_key(cell, face_dir)
	if _overlays.has(fk):
		return  # Idempotent: already visible

	var cs: float = _cell_size
	if grid_system != null:
		cs = grid_system.cell_size

	var mesh_inst := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = _overlay_box_size(face_dir, cs)
	box.material = _mortar_mat
	mesh_inst.mesh = box
	mesh_inst.position = _overlay_position(cell, face_dir, cs)
	add_child(mesh_inst)
	_overlays[fk] = mesh_inst

func _remove_overlay(cell: Vector3i, face_dir: Vector3i) -> void:
	var fk := _face_key(cell, face_dir)
	if _overlays.has(fk):
		var mesh_inst: MeshInstance3D = _overlays[fk]
		if is_instance_valid(mesh_inst):
			mesh_inst.queue_free()
		_overlays.erase(fk)

func _remove_all_overlays_for_cell(cell: Vector3i) -> void:
	var dirs: Array[Vector3i] = [
		Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
		Vector3i(0, 1, 0), Vector3i(0, -1, 0),
		Vector3i(0, 0, 1), Vector3i(0, 0, -1)
	]
	for d in dirs:
		_remove_overlay(cell, d)

# ==============================================================================
# SIGNAL HANDLERS
# ==============================================================================

func _on_face_coated(cell: Vector3i, face_dir: Vector3i) -> void:
	_create_overlay(cell, face_dir)

func _on_block_removed(cell: Vector3i, _data: BlockData) -> void:
	_remove_all_overlays_for_cell(cell)

func _on_blocks_removed_batch(cells: Array, _data_map: Dictionary) -> void:
	for c_var in cells:
		_remove_all_overlays_for_cell(c_var)

func _on_grid_cleared() -> void:
	for mesh_inst in _overlays.values():
		if is_instance_valid(mesh_inst):
			mesh_inst.queue_free()
	_overlays.clear()

# ==============================================================================
# QUERIES (used by tests)
# ==============================================================================

## Returns true if a visible overlay exists for this specific face.
func has_overlay(cell: Vector3i, face_dir: Vector3i) -> bool:
	var fk := _face_key(cell, face_dir)
	return _overlays.has(fk) and is_instance_valid(_overlays[fk])

## Returns the number of active overlays.
func get_overlay_count() -> int:
	return _overlays.size()

## Returns the overlay MeshInstance3D for a face, or null.
func get_overlay(cell: Vector3i, face_dir: Vector3i) -> MeshInstance3D:
	var fk := _face_key(cell, face_dir)
	return _overlays.get(fk, null)
