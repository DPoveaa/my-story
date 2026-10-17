class_name Pallet
extends StaticBody3D

## Slatted crafting pallet (2.2×2.2 m): Castle Story crate fill + dimension-based wood stacks.
## Absorbs matching logs/planks/fragments mid-flight via CatchZone; auto-crafts dirt/stone batches.

const RESOURCE_LAYER: int = 4
const DEBRIS_LAYER: int = 8
const RESOURCE_COLLISION_MASK: int = 1 | RESOURCE_LAYER | DEBRIS_LAYER
const DEBRIS_COLLISION_MASK: int = 1 | RESOURCE_LAYER | DEBRIS_LAYER
const FRAGMENTS_PER_BLOCK: int = ResourceBalance.FRAGMENTS_PER_BLOCK
const CRAFT_BATCH_BLOCKS: int = ResourceBalance.PALLET_CRAFT_BATCH_BLOCKS
const FRAGMENT_WITHDRAW_BATCH: int = ResourceBalance.PALLET_WITHDRAW_BATCH
const MAX_VISUAL_PILE: int = 64
const FILL_MAX_HEIGHT: float = 2.0
const PALLET_DECK_Y: float = 0.2
const PALLET_SIZE: float = 2.2
## Canonical stacking mesh sizes (AABB source of truth for layout).
const STACK_PLANK_SIZE: Vector3 = Vector3(0.8, 0.1, 0.25)
const STACK_LOG_RADIUS: float = 0.2
const STACK_LOG_LENGTH: float = 1.0

var assigned_material: String = ""
var stored_materials: Dictionary = {
	"dirt": 0,
	"grass": 0,
	"stone": 0,
	"plank": 0,
	"log": 0,
}

@onready var catch_zone: Area3D = $CatchZone
@onready var status_label: Label3D = $StatusLabel
@onready var fill_volume: MeshInstance3D = $FillVolume
@onready var fill_collision: StaticBody3D = $FillCollision
@onready var crate_frame: Node3D = $CrateFrame
var _stack_root: Node3D = null
var _fill_blocks_root: Node3D = null
var _fill_mat: StandardMaterial3D = null
var _auto_converted: bool = false
var _fill_tween: Tween = null
var _fill_visual_height: float = 0.001

func _ready() -> void:
	add_to_group("crafting_stations")
	add_to_group("pallets")
	collision_layer = 1
	collision_mask = 0
	_ensure_stack_root()
	_ensure_fill_material()
	_set_crate_frame_visible(false)
	if catch_zone != null:
		catch_zone.monitoring = true
		catch_zone.monitorable = false
		catch_zone.collision_layer = 0
		catch_zone.collision_mask = RESOURCE_LAYER | DEBRIS_LAYER
		if not catch_zone.body_entered.is_connected(_on_catch_zone_body_entered):
			catch_zone.body_entered.connect(_on_catch_zone_body_entered)
	_update_label()
	_rebuild_stack_visuals()
	_update_fill_volume()
	call_deferred("_absorb_overlapping_catch_bodies")
	call_deferred("_notify_astar")

var active_reservations: Dictionary = {}

func _exit_tree() -> void:
	active_reservations.clear()
	set_meta("worker_assigned", false)
	call_deferred("_notify_astar")

func _notify_astar() -> void:
	if not is_inside_tree():
		return
	var root := get_tree().root
	var astar_mgr: Node = root.find_child("AStarGridManager", true, false)
	if astar_mgr != null and astar_mgr.has_method("notify_bounds_changed"):
		var aabb := AABB(global_position - Vector3(1.5, 0.2, 1.5), Vector3(3.0, 2.5, 3.0))
		astar_mgr.notify_bounds_changed(aabb)

func _process(_delta: float) -> void:
	_check_block_reset()

func _check_block_reset() -> void:
	if not _auto_converted:
		return
	if _fill_blocks_root == null:
		return
	var active_count: int = 0
	for child in _fill_blocks_root.get_children():
		if is_instance_valid(child) and not child.is_queued_for_deletion():
			active_count += 1
	if active_count == 0:
		_clear_assignment()
		_refresh_visuals()

func _absorb_overlapping_catch_bodies() -> void:
	if catch_zone == null:
		return
	for body in catch_zone.get_overlapping_bodies():
		if body is Node3D:
			_on_catch_zone_body_entered(body as Node3D)

func _ensure_stack_root() -> void:
	_stack_root = get_node_or_null("StackVisuals") as Node3D
	if _stack_root == null:
		_stack_root = Node3D.new()
		_stack_root.name = "StackVisuals"
		_stack_root.position = Vector3(0.0, PALLET_DECK_Y, 0.0)
		add_child(_stack_root)
	_fill_blocks_root = get_node_or_null("FillBlocks") as Node3D
	if _fill_blocks_root == null:
		_fill_blocks_root = Node3D.new()
		_fill_blocks_root.name = "FillBlocks"
		_fill_blocks_root.position = Vector3(0.0, PALLET_DECK_Y, 0.0)
		add_child(_fill_blocks_root)

func _ensure_fill_material() -> void:
	if fill_volume == null:
		return
	if _fill_mat == null:
		_fill_mat = _make_blended_soil_material(0.0)
	fill_volume.material_override = _fill_mat

func _make_blended_soil_material(grass_ratio: float = 0.0) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.roughness = 0.95
	mat.metallic = 0.0
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL

	var dirt_col := Color(0.4, 0.25, 0.1)
	var grass_col := Color(0.2, 0.6, 0.2)
	mat.albedo_color = dirt_col.lerp(grass_col, grass_ratio)

	var noise := FastNoiseLite.new()
	noise.seed = 17
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.11
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 4

	var ramp := Gradient.new()
	ramp.offsets = PackedFloat32Array([0.0, 0.35, 0.62, 0.82, 1.0])
	ramp.colors = PackedColorArray([
		Color(0.3, 0.18, 0.08).lerp(Color(0.12, 0.42, 0.12), grass_ratio),
		dirt_col.lerp(grass_col, grass_ratio),
		Color(0.48, 0.32, 0.14).lerp(Color(0.28, 0.72, 0.25), grass_ratio),
		Color(0.35, 0.22, 0.09).lerp(Color(0.15, 0.5, 0.15), grass_ratio),
		Color(0.25, 0.55, 0.18).lerp(Color(0.35, 0.8, 0.3), grass_ratio),
	])

	var noise_tex := NoiseTexture2D.new()
	noise_tex.width = 128
	noise_tex.height = 128
	noise_tex.seamless = true
	noise_tex.noise = noise
	noise_tex.color_ramp = ramp
	mat.albedo_texture = noise_tex
	mat.uv1_scale = Vector3(2.5, 2.5, 2.5)
	return mat

func _make_stone_noise_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.roughness = 0.92
	mat.metallic = 0.0
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	mat.albedo_color = Color(0.52, 0.52, 0.54, 1.0)

	var noise := FastNoiseLite.new()
	noise.seed = 91
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.14
	noise.fractal_octaves = 3

	var ramp := Gradient.new()
	ramp.offsets = PackedFloat32Array([0.0, 0.45, 0.75, 1.0])
	ramp.colors = PackedColorArray([
		Color(0.40, 0.40, 0.42),
		Color(0.52, 0.52, 0.54),
		Color(0.58, 0.58, 0.60),
		Color(0.46, 0.46, 0.48),
	])

	var noise_tex := NoiseTexture2D.new()
	noise_tex.width = 128
	noise_tex.height = 128
	noise_tex.seamless = true
	noise_tex.noise = noise
	noise_tex.color_ramp = ramp
	mat.albedo_texture = noise_tex
	mat.uv1_scale = Vector3(2.0, 2.0, 2.0)
	return mat

func _set_crate_frame_visible(show_frame: bool) -> void:
	if crate_frame == null:
		crate_frame = get_node_or_null("CrateFrame") as Node3D
	if crate_frame == null:
		return
	crate_frame.visible = show_frame
	for child in crate_frame.get_children():
		if child is CanvasItem or child is Node3D:
			child.visible = show_frame

func _on_catch_zone_body_entered(body: Node3D) -> void:
	if body == null or not is_instance_valid(body):
		return
	if body is CollisionObject3D and (body as CollisionObject3D).collision_layer == 0:
		return
	if body is RigidBody3D and (body as RigidBody3D).freeze and not body.is_in_group("fragments"):
		var p: Node = body.get_parent()
		if p is Marker3D:
			return
	if body.has_meta("vacuum_pull") and bool(body.get_meta("vacuum_pull")):
		return
	if body.is_in_group("craft_blocks") or (body.has_meta("is_craft_block") and bool(body.get_meta("is_craft_block"))):
		return
	var mat: String = _resolve_body_material(body)
	if mat.is_empty():
		return
	if not _try_accept_material(mat):
		return
	body.queue_free()

func _resolve_body_material(body: Node3D) -> String:
	if body.has_meta("material"):
		var m: String = String(body.get_meta("material"))
		if _is_storable(m):
			return m
	if body.has_meta("carry_type"):
		var c: String = String(body.get_meta("carry_type"))
		if _is_storable(c):
			return c
	if body.has_meta("fragment_type"):
		var f: String = String(body.get_meta("fragment_type"))
		if _is_storable(f):
			return f
	if body.is_in_group("logs"):
		return "log"
	if body.is_in_group("planks"):
		return "plank"
	if body.is_in_group("fragments"):
		return "stone"
	return ""

## Grass maps to soil group along with dirt.
func _normalize_material(mat: String) -> String:
	if mat == "grass":
		return "dirt"
	return mat

func _is_storable(mat: String) -> bool:
	if mat == "plank" or mat == "log":
		return true
	return BlockTypeCatalog.has_type(StringName(mat))

func _is_fragment_type(mat: String) -> bool:
	return mat == "dirt" or mat == "grass" or mat == "stone"

func _materials_compatible(incoming: String, assigned: String) -> bool:
	if assigned.is_empty():
		return true
	var inc_soil: bool = (incoming == "dirt" or incoming == "grass")
	var asn_soil: bool = (assigned == "dirt" or assigned == "grass")
	if inc_soil and asn_soil:
		return true
	return incoming == assigned

## Manual deposit of a carried plank, log, or ANY 1x1x1 building block (called by player interact).
func try_store(carry_type: String) -> bool:
	if carry_type == "plank" or carry_type == "log":
		return _try_accept_material(carry_type)
	if _is_storable(carry_type):
		return _try_store_building_block(carry_type)
	return false

func _try_store_building_block(block_type: String) -> bool:
	if not _is_storable(block_type):
		return false
	if not assigned_material.is_empty() and not _materials_compatible(block_type, assigned_material):
		return false
	if not _auto_converted and not assigned_material.is_empty() and _get_assigned_count() > 0 and (assigned_material == "plank" or assigned_material == "log"):
		return false
	_ensure_stack_root()
	var current_blocks: Array[Node] = []
	for child in _fill_blocks_root.get_children():
		if is_instance_valid(child) and not child.is_queued_for_deletion():
			current_blocks.append(child)
	if current_blocks.size() >= 8:
		return false
	if assigned_material.is_empty():
		assigned_material = block_type
	_auto_converted = true
	_set_crate_frame_visible(false)
	if _fill_tween != null and _fill_tween.is_valid():
		_fill_tween.kill()
	_apply_fill_height(0.001, false)

	var slot: int = current_blocks.size()
	var y: int = slot / 4
	var in_layer: int = slot % 4
	var x: int = in_layer % 2
	var z: int = in_layer / 2

	var body := make_craft_block_body(block_type)
	body.freeze = true
	body.sleeping = true
	body.linear_velocity = Vector3.ZERO
	body.angular_velocity = Vector3.ZERO
	body.set_meta("pallet_craft_block", true)
	_fill_blocks_root.add_child(body)
	body.position = Vector3(
		(float(x) - 0.5) * 1.0,
		float(y) * 1.0 + 0.5,
		(float(z) - 0.5) * 1.0
	)
	stored_materials[block_type] = int(stored_materials.get(block_type, 0)) + FRAGMENTS_PER_BLOCK
	_refresh_visuals()
	return true

## Withdraw 1 log/plank or a batch of dirt/stone fragments. Returns {material, kind, count}.
func try_withdraw() -> Dictionary:
	if assigned_material.is_empty():
		return {}
	if _auto_converted:
		return {}
	var count: int = _get_assigned_count()
	if count <= 0:
		_clear_assignment()
		_refresh_visuals()
		return {}
	var mat: String = assigned_material
	if mat == "log" or mat == "plank":
		stored_materials[mat] = count - 1
		_clear_if_empty()
		_refresh_visuals()
		return {"material": mat, "kind": "item", "count": 1}

	var batch: int = mini(FRAGMENT_WITHDRAW_BATCH, count)
	var withdraw_mat: String = mat
	if mat == "dirt" or mat == "grass":
		var g_count: int = int(stored_materials.get("grass", 0))
		if g_count >= batch:
			stored_materials["grass"] = g_count - batch
			withdraw_mat = "grass"
		elif g_count > 0:
			stored_materials["grass"] = 0
			var rem: int = batch - g_count
			stored_materials["dirt"] = maxi(0, int(stored_materials.get("dirt", 0)) - rem)
			withdraw_mat = "grass"
		else:
			stored_materials["dirt"] = maxi(0, int(stored_materials.get("dirt", 0)) - batch)
			withdraw_mat = "dirt"
	else:
		stored_materials[mat] = count - batch

	_clear_if_empty()
	_refresh_visuals()
	return {"material": withdraw_mat, "kind": "fragments", "count": batch}

func can_withdraw() -> bool:
	if assigned_material.is_empty() or _auto_converted:
		return false
	return _get_assigned_count() > 0

func get_total_reserved_amount(for_worker: Node = null) -> int:
	var total: int = 0
	var stale_keys: Array = []
	for w in active_reservations.keys():
		if not is_instance_valid(w) or not (w is Node and (w as Node).is_inside_tree()):
			stale_keys.append(w)
			continue
		if for_worker != null and w == for_worker:
			continue
		var res: Dictionary = active_reservations[w]
		total += int(res.get("amount", 0))
	for w in stale_keys:
		active_reservations.erase(w)
	return total

func get_effective_assigned_material() -> String:
	if not assigned_material.is_empty():
		return assigned_material
	for w in active_reservations.keys():
		if is_instance_valid(w) and (w as Node).is_inside_tree():
			var mat: String = String(active_reservations[w].get("material", ""))
			if not mat.is_empty():
				return mat
	return ""

func get_capacity(item_material: String) -> int:
	if _is_fragment_type(item_material):
		return FRAGMENTS_PER_BLOCK * CRAFT_BATCH_BLOCKS
	elif item_material == "log":
		return 32
	return 64

func get_remaining_capacity(item_material: String, for_worker: Node = null) -> int:
	if not _is_storable(item_material) or _auto_converted:
		return 0
	var eff_mat: String = get_effective_assigned_material()
	if not eff_mat.is_empty() and not _materials_compatible(item_material, eff_mat):
		return 0
	var cap: int = get_capacity(item_material)
	var current: int = _get_assigned_count() + get_total_reserved_amount(for_worker)
	return maxi(0, cap - current)

func can_accept_material(item_material: String, amount: int = 1, for_worker: Node = null) -> bool:
	if amount <= 0 or not _is_storable(item_material):
		return false
	if _auto_converted:
		return false
	var eff_mat: String = get_effective_assigned_material()
	if not eff_mat.is_empty() and not _materials_compatible(item_material, eff_mat):
		return false
	var cap: int = get_capacity(item_material)
	var reserved_others: int = get_total_reserved_amount(for_worker)
	if _get_assigned_count() + reserved_others + amount > cap:
		return false
	return true

func reserve(worker: Node, mat: String, amount: int) -> bool:
	if not can_accept_material(mat, amount, worker):
		return false
	active_reservations[worker] = {"material": mat, "amount": amount}
	set_meta("worker_assigned", true)
	return true

func release_reservation(worker: Node = null) -> void:
	if worker != null and active_reservations.has(worker):
		active_reservations.erase(worker)
	elif worker == null:
		active_reservations.clear()
	if active_reservations.is_empty():
		set_meta("worker_assigned", false)

func refund_material(item_material: String, amount: int) -> bool:
	if amount <= 0 or item_material.is_empty():
		return false
	return _try_accept_material_amount(item_material, amount)

func _try_accept_material(item_material: String) -> bool:
	return _try_accept_material_amount(item_material, 1)

func _try_accept_material_amount(item_material: String, amount: int) -> bool:
	if amount <= 0 or not _is_storable(item_material) or _auto_converted:
		return false
	if not assigned_material.is_empty() and not _materials_compatible(item_material, assigned_material):
		return false
	var cap: int = get_capacity(item_material)
	if _get_assigned_count() + amount > cap:
		return false
	if assigned_material == "":
		assigned_material = item_material
	stored_materials[item_material] = int(stored_materials.get(item_material, 0)) + amount
	_refresh_visuals()
	_try_auto_convert_full()
	return true

func _refresh_visuals() -> void:
	_update_label()
	_rebuild_stack_visuals()
	_update_fill_volume()
	_update_crate_frame_state()

func _clear_if_empty() -> void:
	if assigned_material.is_empty():
		return
	if _get_assigned_count() <= 0:
		_clear_assignment()

func _clear_assignment() -> void:
	assigned_material = ""
	_auto_converted = false
	stored_materials.clear()
	for k in ["dirt", "grass", "stone", "plank", "log"]:
		stored_materials[k] = 0

func _get_assigned_count() -> int:
	if assigned_material.is_empty():
		return 0
	if assigned_material == "dirt" or assigned_material == "grass":
		return int(stored_materials.get("dirt", 0)) + int(stored_materials.get("grass", 0))
	return int(stored_materials.get(assigned_material, 0))

## Spend FRAGMENTS_PER_BLOCK * 8 of assigned dirt/stone and spawn a 2x2x2 grid of blocks.
func craft_batch(type: String) -> bool:
	var is_soil_target: bool = (type == "dirt" or type == "grass")
	var is_soil_assigned: bool = (assigned_material == "dirt" or assigned_material == "grass")
	if not is_soil_target and type != "stone":
		return false
	if assigned_material.is_empty() or _auto_converted:
		return false
	if is_soil_target != is_soil_assigned and type != assigned_material:
		return false
	var required_count: int = FRAGMENTS_PER_BLOCK * CRAFT_BATCH_BLOCKS
	if _get_assigned_count() < required_count:
		return false

	if is_soil_target:
		var rem: int = required_count
		var g_count: int = int(stored_materials.get("grass", 0))
		var d_count: int = int(stored_materials.get("dirt", 0))
		var sub_g: int = mini(rem, g_count)
		stored_materials["grass"] = g_count - sub_g
		rem -= sub_g
		if rem > 0:
			stored_materials["dirt"] = maxi(0, d_count - rem)
	else:
		stored_materials[type] = int(stored_materials.get(type, 0)) - required_count

	_clear_if_empty()
	_refresh_visuals()
	_spawn_craft_grid(type)
	return true

func get_craft_required_count() -> int:
	return ResourceBalance.PALLET_CRAFT_REQUIRED_UNITS

func can_craft_assigned() -> bool:
	if assigned_material != "dirt" and assigned_material != "grass" and assigned_material != "stone":
		return false
	return _get_assigned_count() >= get_craft_required_count()

func _update_label() -> void:
	if status_label == null:
		return
	if assigned_material.is_empty():
		status_label.text = "Empty Pallet\n(Assign with E / fragments)"
	elif _auto_converted:
		status_label.text = "Blocks Ready\n(E: Pick up)"
	elif assigned_material == "dirt" or assigned_material == "grass":
		var d: int = int(stored_materials.get("dirt", 0))
		var g: int = int(stored_materials.get("grass", 0))
		if g > 0 and d > 0:
			status_label.text = "Soil (D:%d G:%d): %d" % [d, g, d + g]
		elif g > 0:
			status_label.text = "Grass: %d" % g
		else:
			status_label.text = "Dirt: %d" % d
	else:
		status_label.text = "%s: %d" % [
			assigned_material.capitalize(),
			_get_assigned_count(),
		]

func _update_crate_frame_state() -> void:
	var show_frame: bool = (
		not _auto_converted
		and _is_fragment_type(assigned_material)
		and _get_assigned_count() > 0
	)
	_set_crate_frame_visible(show_frame)

func _rebuild_stack_visuals() -> void:
	_ensure_stack_root()
	for child in _stack_root.get_children():
		child.queue_free()
	if assigned_material.is_empty() or _auto_converted:
		return
	if _is_fragment_type(assigned_material):
		return
	var count: int = int(stored_materials.get(assigned_material, 0))
	if count <= 0:
		return
	match assigned_material:
		"plank":
			_build_plank_stack(count)
		"log":
			_build_log_stack(count)

func _material_color(mat: String) -> Color:
	match mat:
		"log": return Color(0.42, 0.28, 0.14)
		"plank": return Color(0.62, 0.45, 0.25)
		"stone": return Color(0.50, 0.50, 0.52)
		"dirt": return Color(0.49, 0.35, 0.22)
		_: return Color(0.55, 0.50, 0.45)

## Neat parallel plank rows (no cross pattern), sized from mesh AABB.
func _build_plank_stack(count: int) -> void:
	var visual_count: int = mini(count, MAX_VISUAL_PILE)
	var mat3d := StandardMaterial3D.new()
	mat3d.albedo_color = _material_color("plank")
	mat3d.roughness = 0.9

	var box := BoxMesh.new()
	box.size = STACK_PLANK_SIZE
	var dim: Vector3 = box.get_aabb().size
	var gap: float = 0.02
	var usable: float = PALLET_SIZE - 0.15
	var cols: int = maxi(1, int(floor(usable / (dim.x + gap))))
	var rows: int = maxi(1, int(floor(usable / (dim.z + gap))))
	var layer_cap: int = cols * rows
	var pitch_x: float = dim.x + gap
	var pitch_z: float = dim.z + gap
	var origin_x: float = -0.5 * (float(cols - 1) * pitch_x)
	var origin_z: float = -0.5 * (float(rows - 1) * pitch_z)

	for i in range(visual_count):
		var layer: int = i / layer_cap
		var in_layer: int = i % layer_cap
		var cx: int = in_layer % cols
		var cz: int = in_layer / cols
		var mesh_inst := MeshInstance3D.new()
		var mbox := BoxMesh.new()
		mbox.size = STACK_PLANK_SIZE
		mbox.material = mat3d
		mesh_inst.mesh = mbox
		mesh_inst.position = Vector3(
			origin_x + float(cx) * pitch_x,
			float(layer) * dim.y + dim.y * 0.5,
			origin_z + float(cz) * pitch_z
		)
		_stack_root.add_child(mesh_inst)

## Two parallel log rows along the pallet, stacked by diameter AABB.
func _build_log_stack(count: int) -> void:
	var visual_count: int = mini(count, MAX_VISUAL_PILE)
	var mat3d := StandardMaterial3D.new()
	mat3d.albedo_color = _material_color("log")
	mat3d.roughness = 0.9

	var cyl := CylinderMesh.new()
	cyl.top_radius = STACK_LOG_RADIUS * 0.95
	cyl.bottom_radius = STACK_LOG_RADIUS
	cyl.height = STACK_LOG_LENGTH
	cyl.radial_segments = 10
	# Default cylinder AABB is upright (Y); after Z=90° length runs along X.
	var local_aabb: AABB = cyl.get_aabb()
	var rot := Basis.from_euler(Vector3(0.0, 0.0, deg_to_rad(90.0)))
	var xf := Transform3D(rot, Vector3.ZERO)
	var world_aabb: AABB = xf * local_aabb
	var dim: Vector3 = world_aabb.size
	var diameter: float = maxf(dim.y, dim.z)
	var gap: float = 0.04
	var row_count: int = 2
	var per_row: int = maxi(1, int(floor((PALLET_SIZE - 0.2) / (diameter + gap))))
	var pitch: float = diameter + gap
	var row_spacing: float = diameter + 0.06
	var origin_z: float = -0.5 * float(row_count - 1) * row_spacing
	var origin_x: float = -0.5 * float(per_row - 1) * pitch

	for i in range(visual_count):
		var layer: int = i / (row_count * per_row)
		var in_layer: int = i % (row_count * per_row)
		var row: int = in_layer / per_row
		var slot: int = in_layer % per_row
		var mesh_inst := MeshInstance3D.new()
		var mcyl := CylinderMesh.new()
		mcyl.top_radius = STACK_LOG_RADIUS * 0.95
		mcyl.bottom_radius = STACK_LOG_RADIUS
		mcyl.height = STACK_LOG_LENGTH
		mcyl.radial_segments = 10
		mcyl.material = mat3d
		mesh_inst.mesh = mcyl
		mesh_inst.rotation_degrees = Vector3(0.0, 0.0, 90.0)
		mesh_inst.position = Vector3(
			origin_x + float(slot) * pitch,
			float(layer) * diameter + diameter * 0.5,
			origin_z + float(row) * row_spacing
		)
		_stack_root.add_child(mesh_inst)

func _apply_fill_height(height: float, show_fill: bool) -> void:
	_fill_visual_height = height
	if fill_volume == null:
		return
	fill_volume.visible = show_fill
	fill_volume.scale = Vector3(1.0, height, 1.0)
	fill_volume.position = Vector3(0.0, PALLET_DECK_Y + height * 0.5, 0.0)
	var fill_col := get_node_or_null("FillCollision/CollisionShape3D") as CollisionShape3D
	if fill_col != null:
		fill_col.disabled = not show_fill
		fill_col.position = Vector3(0.0, PALLET_DECK_Y + height * 0.5, 0.0)
		fill_col.scale = Vector3.ONE
		if fill_col.shape is BoxShape3D:
			(fill_col.shape as BoxShape3D).size = Vector3(2.0, maxf(height, 0.01), 2.0)

func _update_fill_volume() -> void:
	_ensure_fill_material()
	if fill_volume == null:
		return
	if _auto_converted or assigned_material.is_empty() or not _is_fragment_type(assigned_material):
		if _fill_tween != null and _fill_tween.is_valid():
			_fill_tween.kill()
		_apply_fill_height(0.001, false)
		_update_crate_frame_state()
		return

	if assigned_material == "stone":
		_fill_mat = _make_stone_noise_material()
	else:
		var dirt_count: int = int(stored_materials.get("dirt", 0))
		var grass_count: int = int(stored_materials.get("grass", 0))
		var total_soil: int = dirt_count + grass_count
		var grass_ratio: float = 0.0
		if total_soil > 0:
			grass_ratio = clampf(float(grass_count) / float(total_soil), 0.0, 1.0)
		_fill_mat = _make_blended_soil_material(grass_ratio)
	fill_volume.material_override = _fill_mat

	var count: int = _get_assigned_count()
	var capacity: int = FRAGMENTS_PER_BLOCK * CRAFT_BATCH_BLOCKS
	var ratio: float = clampf(float(count) / float(capacity), 0.0, 1.0)
	var target_h: float = maxf(ratio * FILL_MAX_HEIGHT, 0.001)
	var show_fill: bool = count > 0
	_update_crate_frame_state()
	if _fill_tween != null and _fill_tween.is_valid():
		_fill_tween.kill()
	_fill_tween = create_tween()
	_fill_tween.tween_method(
		func(h: float) -> void: _apply_fill_height(h, show_fill),
		_fill_visual_height,
		target_h,
		0.28
	).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)

func _try_auto_convert_full() -> void:
	if _auto_converted:
		return
	if not _is_fragment_type(assigned_material):
		return
	var capacity: int = FRAGMENTS_PER_BLOCK * CRAFT_BATCH_BLOCKS
	if _get_assigned_count() < capacity:
		return
	var block_type: String = "dirt"
	if assigned_material == "stone":
		block_type = "stone"
		stored_materials["stone"] = 0
	else:
		var dirt_count: int = int(stored_materials.get("dirt", 0))
		var grass_count: int = int(stored_materials.get("grass", 0))
		block_type = "grass" if grass_count > dirt_count else "dirt"
		stored_materials["dirt"] = 0
		stored_materials["grass"] = 0
	_auto_converted = true
	assigned_material = block_type
	# Hide crate frame + fill volume, spawn grabbable blocks on open flat pallet.
	_set_crate_frame_visible(false)
	if _fill_tween != null and _fill_tween.is_valid():
		_fill_tween.kill()
	_apply_fill_height(0.001, false)
	_spawn_grabbable_fill_blocks(block_type)
	_rebuild_stack_visuals()
	_update_label()

func _spawn_grabbable_fill_blocks(type: String) -> void:
	_ensure_stack_root()
	for child in _fill_blocks_root.get_children():
		child.queue_free()
	var half: float = 0.5
	for y in range(2):
		for z in range(2):
			for x in range(2):
				var body := make_craft_block_body(type)
				body.freeze = true
				body.sleeping = true
				body.linear_velocity = Vector3.ZERO
				body.angular_velocity = Vector3.ZERO
				body.set_meta("pallet_craft_block", true)
				_fill_blocks_root.add_child(body)
				body.position = Vector3(
					(float(x) - 0.5) * 1.0,
					float(y) * 1.0 + half,
					(float(z) - 0.5) * 1.0
				)

func _spawn_craft_grid(type: String) -> void:
	var parent: Node = get_parent()
	if parent == null and is_inside_tree():
		parent = get_tree().current_scene
	if parent == null:
		return
	var deck_anchor: Vector3 = global_transform * Vector3(0.0, PALLET_DECK_Y + 0.5, 0.0)
	var base_center: Vector3 = TerrainBlockyLibrary.snap_world_to_grid_center(deck_anchor)
	for y in range(2):
		for z in range(2):
			for x in range(2):
				var block := make_craft_block_body(type)
				parent.add_child(block)
				var center := Vector3(
					base_center.x + (float(x) - 0.5),
					base_center.y + float(y),
					base_center.z + (float(z) - 0.5)
				)
				center = TerrainBlockyLibrary.snap_world_to_grid_center(center)
				block.global_transform = Transform3D(Basis.IDENTITY, center)
				block.linear_velocity = Vector3.ZERO
				block.angular_velocity = Vector3.ZERO

static func make_craft_block_body(type: String) -> RigidBody3D:
	var body := RigidBody3D.new()
	body.name = "%sBlock" % type.capitalize()
	body.add_to_group("debris")
	body.add_to_group("craft_blocks")
	body.set_meta("carry_type", type)
	body.set_meta("material", type)
	body.set_meta("is_craft_block", true)
	body.collision_layer = 1 | RESOURCE_LAYER
	body.collision_mask = RESOURCE_COLLISION_MASK
	body.mass = 1.5
	body.can_sleep = true
	body.linear_damp = 0.5
	body.angular_damp = 0.6
	body.continuous_cd = true
	# FIX: Start frozen so placed blocks stick to surfaces (mortar behaviour).
	# Caller must explicitly set freeze=false when the block needs to be a loose physics object.
	body.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	body.freeze = true

	var box := BoxMesh.new()
	box.size = Vector3(1.0, 1.0, 1.0)
	box.material = TerrainBlockyLibrary.get_shared_material(StringName(type))

	var mesh_inst := MeshInstance3D.new()
	mesh_inst.mesh = box
	body.add_child(mesh_inst)

	var shape := BoxShape3D.new()
	shape.size = Vector3(1.0, 1.0, 1.0)
	var col := CollisionShape3D.new()
	col.shape = shape
	body.add_child(col)
	return body

func dismantle() -> void:
	var parent: Node = get_parent()
	if parent == null and is_inside_tree():
		parent = get_tree().current_scene
	if parent != null:
		# 1. Safely dump stored block instances in _fill_blocks_root
		if _fill_blocks_root != null:
			for child in _fill_blocks_root.get_children():
				if is_instance_valid(child) and child is RigidBody3D:
					var block := child as RigidBody3D
					var gpos := block.global_position
					_fill_blocks_root.remove_child(block)
					parent.add_child(block)
					block.global_position = gpos
					block.freeze = false
					block.sleeping = false
					block.linear_velocity = Vector3(randf_range(-0.6, 0.6), 1.2, randf_range(-0.6, 0.6))
		# 2. Dump stored planks
		var plank_n: int = int(stored_materials.get("plank", 0))
		for i in range(plank_n):
			var p := ChoppingBlock.make_plank_body()
			parent.add_child(p)
			p.global_position = global_position + Vector3(randf_range(-0.4, 0.4), 0.4 + float(i) * 0.05, randf_range(-0.4, 0.4))
			p.linear_velocity = Vector3(randf_range(-0.5, 0.5), 1.0, randf_range(-0.5, 0.5))
		# 3. Dump stored logs
		var log_n: int = int(stored_materials.get("log", 0))
		for i in range(log_n):
			var l := ChoppingBlock.make_log_body()
			parent.add_child(l)
			l.global_position = global_position + Vector3(randf_range(-0.4, 0.4), 0.5 + float(i) * 0.1, randf_range(-0.4, 0.4))
			l.linear_velocity = Vector3(randf_range(-0.5, 0.5), 1.0, randf_range(-0.5, 0.5))
		# 4. Dump stored loose soil/stone fragments
		if not _auto_converted:
			for mat in ["dirt", "grass", "stone"]:
				var count: int = int(stored_materials.get(mat, 0))
				while count >= FRAGMENTS_PER_BLOCK:
					var cb := make_craft_block_body(mat)
					parent.add_child(cb)
					cb.global_position = global_position + Vector3(randf_range(-0.5, 0.5), 0.6, randf_range(-0.5, 0.5))
					cb.freeze = false
					cb.sleeping = false
					cb.linear_velocity = Vector3(randf_range(-0.6, 0.6), 1.2, randf_range(-0.6, 0.6))
					count -= FRAGMENTS_PER_BLOCK
		# 5. Refund construction materials: 4 Planks for Pallet onto the floor
		for i in range(4):
			var ref_plank := ChoppingBlock.make_plank_body()
			parent.add_child(ref_plank)
			ref_plank.global_position = global_position + Vector3(randf_range(-0.4, 0.4), 0.3 + float(i) * 0.05, randf_range(-0.4, 0.4))
			ref_plank.linear_velocity = Vector3(randf_range(-0.5, 0.5), 1.0, randf_range(-0.5, 0.5))
	queue_free()
