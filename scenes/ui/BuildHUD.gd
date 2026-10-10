class_name BuildHUD
extends CanvasLayer

## In-game overlay showing crosshair, active block selection, status stats, and keybinds.
## M2.1: Includes carried block indicator and non-blocking mouse filters.

@onready var crosshair: Label = $Crosshair
@onready var mode_label: Label = $PanelTop/HBox/ModeLabel
@onready var selected_type_label: Label = $PanelTop/HBox/SelectedTypeLabel
@onready var block_count_label: Label = $PanelTop/HBox/BlockCountLabel
@onready var debris_count_label: Label = $PanelTop/HBox/DebrisCountLabel
@onready var color_rect_badge: ColorRect = $PanelTop/HBox/ColorBadge
@onready var prompt_label: Label = get_node_or_null("PanelTop/HBox/PromptLabel")
@onready var cement_label: Label = get_node_or_null("PanelTop/HBox/CementLabel")
@onready var target_info_label: Label = get_node_or_null("PanelTop/HBox/TargetInfoLabel")

const BlueprintVisualizerScript = preload("res://systems/rendering/BlueprintVisualizer.gd")

var _visualizer: Node = null

var grid_system: Node
var orchestrator: CollapseOrchestrator
var player: CharacterBody3D = null
@export var blueprint_manager: Node = null

## Dynamically created label for raw material counts (no .tscn edit required).
var _raw_mats_label: Label = null

## Blueprint Save Modal Nodes
var _save_modal: PanelContainer = null
var _save_name_input: LineEdit = null
var _save_info_label: Label = null
var _save_feedback_label: Label = null
var _save_btn: Button = null
var _save_confirm_overwrite: bool = false
var _save_min_cell: Vector3i = Vector3i.ZERO
var _save_max_cell: Vector3i = Vector3i.ZERO
var _has_area_selected: bool = false

## Blueprint Load Modal Nodes
var _load_modal: PanelContainer = null
var _load_item_list: ItemList = null
var _load_details_label: Label = null
var _load_feedback_label: Label = null
var _anchor_x: SpinBox = null
var _anchor_y: SpinBox = null
var _anchor_z: SpinBox = null
var _replace_checkbox: CheckBox = null
var _load_place_btn: Button = null
var _load_inspect_btn: Button = null
var _load_reconstruct_btn: Button = null
var _load_delete_btn: Button = null

func _ready() -> void:
	if grid_system == null and has_node("/root/GridSystem"):
		grid_system = get_node("/root/GridSystem")
	# Create raw materials label dynamically so no .tscn modification is needed.
	_raw_mats_label = Label.new()
	_raw_mats_label.name = "RawMatsLabel"
	_raw_mats_label.text = ""
	_raw_mats_label.visible = false
	_raw_mats_label.add_theme_font_size_override("font_size", 14)
	_raw_mats_label.add_theme_color_override("font_color", Color(0.95, 0.80, 0.40))
	var hbox := get_node_or_null("PanelTop/HBox")
	if hbox != null:
		hbox.add_child(_raw_mats_label)

	_visualizer = BlueprintVisualizerScript.new()
	_visualizer.name = "BlueprintVisualizer"
	add_child(_visualizer)

	if _save_modal == null:
		_create_blueprint_dialogs()

func set_cement(current: int, max_val: int) -> void:
	if cement_label == null:
		cement_label = get_node_or_null("PanelTop/HBox/CementLabel")
	if cement_label != null:
		cement_label.text = "Mortar: %d/%d" % [current, max_val]

func set_target_face_info(has_target: bool, _cell: Vector3i, _face_dir: Vector3i, status_text: String) -> void:
	if target_info_label == null:
		target_info_label = get_node_or_null("PanelTop/HBox/TargetInfoLabel")
	if target_info_label != null:
		if has_target and not status_text.is_empty():
			target_info_label.text = "[%s]" % status_text
			target_info_label.visible = true
			if "CRITICAL" in status_text or "Depleted" in status_text or "Insufficient" in status_text:
				target_info_label.add_theme_color_override("font_color", Color(1.0, 0.25, 0.25))
			elif "Damaged" in status_text:
				target_info_label.add_theme_color_override("font_color", Color(1.0, 0.6, 0.1))
			elif "Mortared" in status_text or "Bonded" in status_text or "Ready" in status_text or "Integrity" in status_text:
				target_info_label.add_theme_color_override("font_color", Color(0.3, 1.0, 0.4))
			else:
				target_info_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))
		else:
			target_info_label.visible = false

func set_player_mode(mode_text: String) -> void:
	if mode_label != null:
		mode_label.text = "Mode: " + mode_text

func set_player_state(state: int) -> void:
	match state:
		0: # BODY_CONTROL
			set_player_mode("Body (1st Person)")
		1: # SOUL_PROJECTION
			set_player_mode("Soul Projection")
		2: # DEBUG_FLIGHT
			set_player_mode("Debug Free Camera")

func set_selected_block_type(type_id: StringName) -> void:
	if selected_type_label != null:
		selected_type_label.text = "Material: " + BlockTypeCatalog.get_display_name(type_id)
	if color_rect_badge != null:
		color_rect_badge.color = BlockTypeCatalog.get_color(type_id)

func set_carried_block(is_carrying: bool, block_type: StringName) -> void:
	if prompt_label == null:
		prompt_label = get_node_or_null("PanelTop/HBox/PromptLabel")
	if prompt_label != null:
		if is_carrying:
			var mat_name := BlockTypeCatalog.get_display_name(block_type)
			prompt_label.text = "[HOLDING %s] E: Drop  |  F: Throw  |  LMB: Place  |  R: Recover" % mat_name.to_upper()
			prompt_label.visible = true
		else:
			prompt_label.visible = false

func _process(_delta: float) -> void:
	if grid_system != null and block_count_label != null:
		block_count_label.text = "Grid Blocks: %d" % grid_system.get_block_count()

	if orchestrator != null and debris_count_label != null:
		debris_count_label.text = "Active Debris: %d" % orchestrator.get_active_debris_count()

## Updates the raw materials HUD label.
## Called via signal raw_materials_changed(materials: Dictionary).
func set_raw_materials(materials: Dictionary) -> void:
	if _raw_mats_label == null:
		return
	if materials.is_empty():
		_raw_mats_label.visible = false
		return
	var parts: Array = []
	for mat_type in materials.keys():
		var count: int = materials[mat_type]
		if count > 0:
			parts.append("%s x%d" % [BlockTypeCatalog.get_display_name(mat_type), count])
	if parts.is_empty():
		_raw_mats_label.visible = false
		return
	_raw_mats_label.text = "Raw: " + ", ".join(parts)
	_raw_mats_label.visible = true

# ==============================================================================
# BLUEPRINT MODAL DIALOGS & CONTROLS
# ==============================================================================

## Returns true if either the Save or Load blueprint modal is currently open.
func is_modal_open() -> bool:
	return (_save_modal != null and _save_modal.visible) or (_load_modal != null and _load_modal.visible)

## Closes all blueprint modals and restores mouse capture.
func close_all_modals() -> void:
	if _save_modal != null:
		_save_modal.visible = false
	if _load_modal != null:
		_load_modal.visible = false
	_has_area_selected = false
	_save_min_cell = Vector3i.ZERO
	_save_max_cell = Vector3i.ZERO
	if _visualizer != null:
		_visualizer.clear_visuals()
	if player != null and player.has_method("set_mouse_capture"):
		player.set_mouse_capture(true)

## Opens the Save Blueprint dialog for a bounded area.
func open_save_blueprint_dialog_bounded(min_cell: Vector3i, max_cell: Vector3i) -> void:
	open_save_blueprint_dialog()
	_save_min_cell = min_cell
	_save_max_cell = max_cell
	_has_area_selected = true
	_save_info_label.text = "Bounded Area: (%d,%d,%d) to (%d,%d,%d)" % [
		min_cell.x, min_cell.y, min_cell.z, max_cell.x, max_cell.y, max_cell.z
	]

## Opens the Save Blueprint dialog, releases mouse capture, and focuses input.
func open_save_blueprint_dialog() -> void:
	close_all_modals()
	if _save_modal == null:
		return
	_save_confirm_overwrite = false
	if _save_btn != null:
		_save_btn.text = "Save"
	if not _has_area_selected:
		var count: int = grid_system.get_block_count() if grid_system != null else 0
		_save_info_label.text = "Structure to Save: %d block(s) in grid" % count
	_save_feedback_label.text = ""
	_save_btn.disabled = false
	_save_modal.visible = true
	if player != null and player.has_method("set_mouse_capture"):
		player.set_mouse_capture(false)
	if _save_name_input != null and _save_name_input.is_inside_tree():
		_save_name_input.grab_focus()
		_save_name_input.select_all()

## Opens the Load Blueprint dialog at the specified grid anchor.
func open_load_blueprint_dialog(anchor: Vector3i = Vector3i.ZERO) -> void:
	close_all_modals()
	if _load_modal == null:
		return

	_anchor_x.value = anchor.x
	_anchor_y.value = anchor.y
	_anchor_z.value = anchor.z
	_load_feedback_label.text = ""
	_refresh_blueprint_list()

	_load_modal.visible = true
	if player != null and player.has_method("set_mouse_capture"):
		player.set_mouse_capture(false)

func _create_blueprint_dialogs() -> void:
	_create_save_modal()
	_create_load_modal()

func _make_modal_panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.12, 0.16, 0.95)
	style.border_color = Color(0.25, 0.5, 0.8, 0.9)
	style.set_border_width_all(2)
	style.set_corner_radius_all(8)
	style.content_margin_left = 18
	style.content_margin_right = 18
	style.content_margin_top = 16
	style.content_margin_bottom = 16
	return style

func _create_save_modal() -> void:
	_save_modal = PanelContainer.new()
	_save_modal.name = "SaveBlueprintModal"
	_save_modal.add_theme_stylebox_override("panel", _make_modal_panel_style())
	_save_modal.custom_minimum_size = Vector2(480, 240)
	_save_modal.anchor_left = 0.5
	_save_modal.anchor_top = 0.5
	_save_modal.anchor_right = 0.5
	_save_modal.anchor_bottom = 0.5
	_save_modal.offset_left = -240
	_save_modal.offset_top = -120
	_save_modal.offset_right = 240
	_save_modal.offset_bottom = 120
	_save_modal.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_save_modal.grow_vertical = Control.GROW_DIRECTION_BOTH
	_save_modal.z_index = 10
	_save_modal.visible = false
	add_child(_save_modal)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	_save_modal.add_child(vbox)

	var title := Label.new()
	title.text = "SAVE BLUEPRINT"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", Color(0.35, 0.85, 1.0))
	vbox.add_child(title)

	_save_info_label = Label.new()
	_save_info_label.text = "Structure to Save: 0 block(s) in grid"
	_save_info_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_save_info_label.add_theme_font_size_override("font_size", 13)
	_save_info_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	vbox.add_child(_save_info_label)

	var name_hbox := HBoxContainer.new()
	name_hbox.add_theme_constant_override("separation", 8)
	vbox.add_child(name_hbox)

	var lbl_name := Label.new()
	lbl_name.text = "Name:"
	name_hbox.add_child(lbl_name)

	_save_name_input = LineEdit.new()
	_save_name_input.text = "my_blueprint"
	_save_name_input.placeholder_text = "Enter blueprint name"
	_save_name_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_save_name_input.text_submitted.connect(func(_t: String) -> void: _on_save_confirm_pressed())
	_save_name_input.text_changed.connect(func(_t: String) -> void:
		_save_confirm_overwrite = false
		if _save_btn != null:
			_save_btn.text = "Save"
	)
	name_hbox.add_child(_save_name_input)

	_save_feedback_label = Label.new()
	_save_feedback_label.text = ""
	_save_feedback_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_save_feedback_label.add_theme_font_size_override("font_size", 13)
	_save_feedback_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(_save_feedback_label)

	var btns_hbox := HBoxContainer.new()
	btns_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	btns_hbox.add_theme_constant_override("separation", 16)
	vbox.add_child(btns_hbox)

	_save_btn = Button.new()
	_save_btn.text = "Save"
	_save_btn.custom_minimum_size = Vector2(110, 32)
	_save_btn.pressed.connect(_on_save_confirm_pressed)
	btns_hbox.add_child(_save_btn)

	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.custom_minimum_size = Vector2(110, 32)
	cancel_btn.pressed.connect(close_all_modals)
	btns_hbox.add_child(cancel_btn)

func _create_load_modal() -> void:
	_load_modal = PanelContainer.new()
	_load_modal.name = "LoadBlueprintModal"
	_load_modal.add_theme_stylebox_override("panel", _make_modal_panel_style())
	_load_modal.custom_minimum_size = Vector2(560, 420)
	_load_modal.anchor_left = 0.5
	_load_modal.anchor_top = 0.5
	_load_modal.anchor_right = 0.5
	_load_modal.anchor_bottom = 0.5
	_load_modal.offset_left = -280
	_load_modal.offset_top = -210
	_load_modal.offset_right = 280
	_load_modal.offset_bottom = 210
	_load_modal.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_load_modal.grow_vertical = Control.GROW_DIRECTION_BOTH
	_load_modal.z_index = 10
	_load_modal.visible = false
	add_child(_load_modal)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	_load_modal.add_child(vbox)

	var title := Label.new()
	title.text = "LOAD BLUEPRINT"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", Color(0.35, 0.85, 1.0))
	vbox.add_child(title)

	_load_item_list = ItemList.new()
	_load_item_list.custom_minimum_size = Vector2(0, 130)
	_load_item_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_load_item_list.item_selected.connect(_on_blueprint_item_selected)
	vbox.add_child(_load_item_list)

	_load_details_label = Label.new()
	_load_details_label.text = "Select a blueprint from the list above."
	_load_details_label.add_theme_font_size_override("font_size", 13)
	_load_details_label.add_theme_color_override("font_color", Color(0.9, 0.82, 0.4))
	vbox.add_child(_load_details_label)

	var anchor_hbox := HBoxContainer.new()
	anchor_hbox.add_theme_constant_override("separation", 6)
	vbox.add_child(anchor_hbox)

	var lbl_anchor := Label.new()
	lbl_anchor.text = "Grid Anchor:"
	anchor_hbox.add_child(lbl_anchor)

	var lx := Label.new()
	lx.text = "X:"
	anchor_hbox.add_child(lx)
	_anchor_x = SpinBox.new()
	_anchor_x.min_value = -999
	_anchor_x.max_value = 999
	_anchor_x.step = 1
	_anchor_x.value_changed.connect(func(_val: float) -> void: _on_anchor_changed())
	anchor_hbox.add_child(_anchor_x)

	var ly := Label.new()
	ly.text = "Y:"
	anchor_hbox.add_child(ly)
	_anchor_y = SpinBox.new()
	_anchor_y.min_value = -999
	_anchor_y.max_value = 999
	_anchor_y.step = 1
	_anchor_y.value_changed.connect(func(_val: float) -> void: _on_anchor_changed())
	anchor_hbox.add_child(_anchor_y)

	var lz := Label.new()
	lz.text = "Z:"
	anchor_hbox.add_child(lz)
	_anchor_z = SpinBox.new()
	_anchor_z.min_value = -999
	_anchor_z.max_value = 999
	_anchor_z.step = 1
	_anchor_z.value_changed.connect(func(_val: float) -> void: _on_anchor_changed())
	anchor_hbox.add_child(_anchor_z)

	var btn_aim := Button.new()
	btn_aim.text = "Target Cell"
	btn_aim.tooltip_text = "Set anchor to current crosshair aim position"
	btn_aim.pressed.connect(_on_use_aim_pressed)
	anchor_hbox.add_child(btn_aim)

	_replace_checkbox = CheckBox.new()
	_replace_checkbox.text = "Allow Replacing Existing Blocks"
	_replace_checkbox.tooltip_text = "If checked, removes occupied blocks at target position prior to placement."
	vbox.add_child(_replace_checkbox)

	_load_feedback_label = Label.new()
	_load_feedback_label.text = ""
	_load_feedback_label.add_theme_font_size_override("font_size", 13)
	_load_feedback_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(_load_feedback_label)

	var btns_hbox := HBoxContainer.new()
	btns_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	btns_hbox.add_theme_constant_override("separation", 14)
	vbox.add_child(btns_hbox)

	_load_place_btn = Button.new()
	_load_place_btn.text = "Place Blueprint"
	_load_place_btn.custom_minimum_size = Vector2(130, 32)
	_load_place_btn.pressed.connect(_on_load_confirm_pressed)
	btns_hbox.add_child(_load_place_btn)

	_load_inspect_btn = Button.new()
	_load_inspect_btn.text = "Inspect Plan"
	_load_inspect_btn.custom_minimum_size = Vector2(110, 32)
	_load_inspect_btn.pressed.connect(_on_inspect_plan_pressed)
	btns_hbox.add_child(_load_inspect_btn)

	_load_reconstruct_btn = Button.new()
	_load_reconstruct_btn.text = "Reconstruct Cell"
	_load_reconstruct_btn.tooltip_text = "Reconstructs the next buildable missing block in this blueprint."
	_load_reconstruct_btn.custom_minimum_size = Vector2(120, 32)
	_load_reconstruct_btn.pressed.connect(_on_reconstruct_cell_pressed)
	btns_hbox.add_child(_load_reconstruct_btn)

	var update_area_btn := Button.new()
	update_area_btn.text = "Update Area"
	update_area_btn.tooltip_text = "Explicitly update the saved blueprint layout from current live world blocks inside its area."
	update_area_btn.custom_minimum_size = Vector2(110, 32)
	update_area_btn.pressed.connect(_on_update_area_pressed)
	btns_hbox.add_child(update_area_btn)

	_load_delete_btn = Button.new()
	_load_delete_btn.text = "Delete"
	_load_delete_btn.custom_minimum_size = Vector2(90, 32)
	_load_delete_btn.pressed.connect(_on_delete_blueprint_pressed)
	btns_hbox.add_child(_load_delete_btn)

	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.custom_minimum_size = Vector2(90, 32)
	cancel_btn.pressed.connect(close_all_modals)
	btns_hbox.add_child(cancel_btn)

func _get_blueprint_manager() -> Node:
	if blueprint_manager != null:
		return blueprint_manager
	if is_inside_tree() and has_node("/root/BlueprintManager"):
		return get_node("/root/BlueprintManager")
	return null

func _refresh_blueprint_list() -> void:
	_load_item_list.clear()
	var bp_mgr := _get_blueprint_manager()
	if bp_mgr == null:
		_load_details_label.text = "BlueprintManager autoload not found."
		_load_place_btn.disabled = true
		_load_delete_btn.disabled = true
		return

	var names: Array[String] = bp_mgr.list_blueprints()
	if names.is_empty():
		_load_details_label.text = "No saved blueprints found in user://blueprints/"
		_load_place_btn.disabled = true
		_load_delete_btn.disabled = true
		return

	for n in names:
		_load_item_list.add_item(n)

	_load_place_btn.disabled = false
	_load_delete_btn.disabled = false
	_load_item_list.select(0)
	_on_blueprint_item_selected(0)

func _on_blueprint_item_selected(index: int) -> void:
	if index < 0 or index >= _load_item_list.item_count:
		return
	var bp_name: String = _load_item_list.get_item_text(index)
	var bp_mgr := _get_blueprint_manager()
	if bp_mgr == null:
		return

	var bp = bp_mgr.load_blueprint(bp_name)
	if bp != null:
		var dims: Vector3i = bp.get_dimensions()
		var anchor := Vector3i(int(_anchor_x.value), int(_anchor_y.value), int(_anchor_z.value))
		var plan = bp_mgr.plan_reconstruction(bp, anchor, player) if bp_mgr.has_method("plan_reconstruction") else null
		if plan != null:
			_load_details_label.text = "Blueprint: %s (%dx%dx%d) | PRESENT: %d | MISSING: %d | CONFLICT: %d | INVALID: %d" % [
				bp.name, dims.x, dims.y, dims.z,
				plan.present_count, plan.missing_count, plan.conflict_count, plan.invalid_count
			]
		else:
			_load_details_label.text = "Blueprint: %s  |  Blocks: %d  |  Size: %dx%dx%d  |  Joints: %d" % [
				bp.name, bp.get_block_count(), dims.x, dims.y, dims.z, bp.joints.size()
			]

func _on_inspect_plan_pressed() -> void:
	var selected_items: PackedInt32Array = _load_item_list.get_selected_items()
	if selected_items.is_empty():
		_load_feedback_label.text = "Select a blueprint to inspect."
		_load_feedback_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
		return

	var bp_name: String = _load_item_list.get_item_text(selected_items[0])
	var bp_mgr := _get_blueprint_manager()
	if bp_mgr == null:
		return

	var bp = bp_mgr.load_blueprint(bp_name)
	if bp == null:
		return

	var anchor := Vector3i(int(_anchor_x.value), int(_anchor_y.value), int(_anchor_z.value))
	var plan = bp_mgr.plan_reconstruction(bp, anchor, player)
	if plan == null:
		return

	var details := "Reconstruction Plan [%s] at (%d,%d,%d):\nPRESENT: %d | MISSING: %d | CONFLICT: %d | INVALID: %d" % [
		bp.name, anchor.x, anchor.y, anchor.z,
		plan.present_count, plan.missing_count, plan.conflict_count, plan.invalid_count
	]

	if plan.conflict_count > 0:
		var conflicts: Array[Dictionary] = plan.get_conflict_entries()
		var first_conf: Dictionary = conflicts[0]
		details += "\nConflict at %s: %s" % [str(first_conf.get("world_cell", Vector3i.ZERO)), first_conf.get("reason", "UNKNOWN")]
	elif plan.invalid_count > 0:
		var invalids: Array[Dictionary] = plan.get_invalid_entries()
		var first_inv: Dictionary = invalids[0]
		details += "\nInvalid at %s: Out of Bounds" % str(first_inv.get("world_cell", Vector3i.ZERO))

	_load_feedback_label.text = details
	if plan.is_fully_intact():
		_load_feedback_label.add_theme_color_override("font_color", Color(0.3, 1.0, 0.4))
	elif plan.is_ready_for_reconstruction():
		_load_feedback_label.add_theme_color_override("font_color", Color(0.4, 0.85, 1.0))
	else:
		_load_feedback_label.add_theme_color_override("font_color", Color(1.0, 0.7, 0.2))

	if _visualizer != null:
		_visualizer.render_plan(plan, grid_system.cell_size if grid_system != null else 1.0)

func _on_reconstruct_cell_pressed() -> void:
	var selected_items: PackedInt32Array = _load_item_list.get_selected_items()
	if selected_items.is_empty():
		_load_feedback_label.text = "Select a blueprint to reconstruct."
		_load_feedback_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
		return

	var bp_name: String = _load_item_list.get_item_text(selected_items[0])
	var bp_mgr := _get_blueprint_manager()
	if bp_mgr == null:
		return

	var bp = bp_mgr.load_blueprint(bp_name)
	if bp == null:
		return

	var anchor := Vector3i(int(_anchor_x.value), int(_anchor_y.value), int(_anchor_z.value))
	var plan = bp_mgr.plan_reconstruction(bp, anchor, player)
	if plan == null:
		return

	var missing_entries: Array[Dictionary] = plan.get_missing_entries()
	if missing_entries.is_empty():
		if plan.is_fully_intact():
			_load_feedback_label.text = "✓ Blueprint is fully intact! All blocks present."
			_load_feedback_label.add_theme_color_override("font_color", Color(0.3, 1.0, 0.4))
		else:
			_load_feedback_label.text = "No buildable missing cells. Resolve conflicts (%d) or invalid cells (%d) first!" % [
				plan.conflict_count, plan.invalid_count
			]
			_load_feedback_label.add_theme_color_override("font_color", Color(1.0, 0.7, 0.2))
		return

	# Reconstruct the first buildable missing cell
	var first_missing: Dictionary = missing_entries[0]
	var target_cell: Vector3i = first_missing.get("world_cell", Vector3i.ZERO)
	var res: Dictionary = bp_mgr.reconstruct_single_cell(bp, anchor, target_cell, player)

	if res.get("success", false):
		var exp_mat: StringName = first_missing.get("expected_type", &"stone")
		var mat_display := BlockTypeCatalog.get_display_name(exp_mat)
		_load_feedback_label.text = "✓ Reconstructed [%s] block at %s!" % [mat_display, str(target_cell)]
		_load_feedback_label.add_theme_color_override("font_color", Color(0.3, 1.0, 0.4))

		var updated_plan = res.get("plan", null)
		if updated_plan != null:
			if _visualizer != null:
				_visualizer.render_plan(updated_plan, grid_system.cell_size if grid_system != null else 1.0)
			var dims: Vector3i = bp.get_dimensions()
			_load_details_label.text = "Blueprint: %s (%dx%dx%d) | PRESENT: %d | MISSING: %d | CONFLICT: %d | INVALID: %d" % [
				bp.name, dims.x, dims.y, dims.z,
				updated_plan.present_count, updated_plan.missing_count, updated_plan.conflict_count, updated_plan.invalid_count
			]
	else:
		var reason: String = res.get("reason", "UNKNOWN")
		_load_feedback_label.text = "Cannot reconstruct at %s: %s" % [str(target_cell), reason]
		_load_feedback_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))

func _on_anchor_changed() -> void:
	var selected_items: PackedInt32Array = _load_item_list.get_selected_items()
	if selected_items.is_empty():
		return
	_on_blueprint_item_selected(selected_items[0])

func _on_update_area_pressed() -> void:
	var selected_items: PackedInt32Array = _load_item_list.get_selected_items()
	if selected_items.is_empty():
		_load_feedback_label.text = "Select a blueprint to update."
		_load_feedback_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
		return

	var bp_name: String = _load_item_list.get_item_text(selected_items[0])
	var bp_mgr := _get_blueprint_manager()
	if bp_mgr == null:
		return

	var ok: bool = bp_mgr.update_registered_blueprint_from_world(bp_name)
	if ok:
		_load_feedback_label.text = "✓ Blueprint '%s' updated from current area!" % bp_name
		_load_feedback_label.add_theme_color_override("font_color", Color(0.3, 1.0, 0.4))
		_on_blueprint_item_selected(selected_items[0])
	else:
		_load_feedback_label.text = "Failed to update blueprint '%s'." % bp_name
		_load_feedback_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))

func _on_use_aim_pressed() -> void:
	if player != null and player.has_target:
		_anchor_x.value = player.target_place_cell.x
		_anchor_y.value = player.target_place_cell.y
		_anchor_z.value = player.target_place_cell.z
		_load_feedback_label.text = "Anchor set to targeted cell: (%d, %d, %d)" % [
			player.target_place_cell.x, player.target_place_cell.y, player.target_place_cell.z
		]
		_load_feedback_label.add_theme_color_override("font_color", Color(0.4, 0.85, 1.0))
	else:
		_anchor_x.value = 0
		_anchor_y.value = 0
		_anchor_z.value = 0
		_load_feedback_label.text = "No raycast target. Anchor set to (0, 0, 0)."
		_load_feedback_label.add_theme_color_override("font_color", Color(1.0, 0.8, 0.3))

func _on_save_confirm_pressed() -> void:
	var bp_mgr := _get_blueprint_manager()
	if bp_mgr == null:
		_save_feedback_label.text = "Error: BlueprintManager not found"
		_save_feedback_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
		return

	var raw_name: String = _save_name_input.text.strip_edges()
	if raw_name.is_empty():
		_save_feedback_label.text = "Please enter a valid blueprint name."
		_save_feedback_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
		return

	if bp_mgr.has_blueprint(raw_name) and not _save_confirm_overwrite:
		_save_confirm_overwrite = true
		_save_btn.text = "Confirm Overwrite"
		_save_feedback_label.text = "Blueprint '%s' already exists! Click 'Confirm Overwrite' to replace it." % raw_name
		_save_feedback_label.add_theme_color_override("font_color", Color(1.0, 0.7, 0.2))
		return

	var bp: BlueprintData = null
	if _has_area_selected:
		bp = bp_mgr.capture_blueprint_area(raw_name, _save_min_cell, _save_max_cell)
	else:
		bp = bp_mgr.capture_blueprint(raw_name)

	if bp == null:
		_save_feedback_label.text = "Failed to capture blueprint: no blocks found in selection."
		_save_feedback_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
		return

	var ok: bool = bp_mgr.save_blueprint(bp, true)
	if ok:
		_save_confirm_overwrite = false
		_save_btn.text = "Save"
		_save_feedback_label.text = "✓ Blueprint '%s' saved successfully (%d blocks)!" % [bp.name, bp.get_block_count()]
		_save_feedback_label.add_theme_color_override("font_color", Color(0.3, 1.0, 0.4))
		if is_inside_tree() and get_tree() != null:
			var timer := get_tree().create_timer(0.6)
			timer.timeout.connect(close_all_modals)
		else:
			close_all_modals()
	else:
		_save_feedback_label.text = "Failed to save blueprint file."
		_save_feedback_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))

func _on_load_confirm_pressed() -> void:
	var selected_items: PackedInt32Array = _load_item_list.get_selected_items()
	if selected_items.is_empty():
		_load_feedback_label.text = "Please select a blueprint to load."
		_load_feedback_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
		return

	var bp_name: String = _load_item_list.get_item_text(selected_items[0])
	var bp_mgr := _get_blueprint_manager()
	if bp_mgr == null:
		_load_feedback_label.text = "Error: BlueprintManager not found."
		_load_feedback_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
		return

	var bp = bp_mgr.load_blueprint(bp_name)
	if bp == null:
		_load_feedback_label.text = "Failed to load blueprint file '%s'." % bp_name
		_load_feedback_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
		return

	var anchor := Vector3i(int(_anchor_x.value), int(_anchor_y.value), int(_anchor_z.value))
	var allow_rep: bool = _replace_checkbox.button_pressed

	# Reusing BlueprintManager.validate_placement directly
	var val: Dictionary = bp_mgr.validate_placement(bp, anchor, allow_rep, player)
	if not val.get("valid", false):
		var reason: String = val.get("reason", "UNKNOWN")
		var conflicts: Array = val.get("conflicts", [])
		var conflict_str := ""
		if not conflicts.is_empty():
			var sample: Array = conflicts.slice(0, 3)
			conflict_str = " (at %s%s)" % [str(sample), "..." if conflicts.size() > 3 else ""]
		var reason_msg := reason
		match reason:
			"OUT_OF_BOUNDS": reason_msg = "Exceeds grid boundaries"
			"CELL_OCCUPIED": reason_msg = "Conflicts with existing static structure"
			"DEBRIS_COLLISION": reason_msg = "Obstructed by fallen debris"
			"PLAYER_OVERLAP": reason_msg = "Overlaps player position"
			"EMPTY_BLUEPRINT": reason_msg = "Blueprint is empty"
		_load_feedback_label.text = "Cannot place [%s]: %d conflict(s)%s" % [reason_msg, conflicts.size(), conflict_str]
		_load_feedback_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
		return

	# Apply placement
	var res: Dictionary = bp_mgr.apply_blueprint(bp, anchor, allow_rep, player)
	if res.get("success", false):
		_load_feedback_label.text = "✓ Blueprint '%s' placed successfully at (%d, %d, %d)!" % [
			bp.name, anchor.x, anchor.y, anchor.z
		]
		_load_feedback_label.add_theme_color_override("font_color", Color(0.3, 1.0, 0.4))
		if is_inside_tree() and get_tree() != null:
			var timer := get_tree().create_timer(0.6)
			timer.timeout.connect(close_all_modals)
		else:
			close_all_modals()
	else:
		_load_feedback_label.text = "Failed to apply blueprint: %s" % res.get("reason", "")
		_load_feedback_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))

func _on_delete_blueprint_pressed() -> void:
	var selected_items: PackedInt32Array = _load_item_list.get_selected_items()
	if selected_items.is_empty():
		return
	var bp_name: String = _load_item_list.get_item_text(selected_items[0])
	var bp_mgr := _get_blueprint_manager()
	if bp_mgr != null:
		bp_mgr.delete_blueprint(bp_name)
		_load_feedback_label.text = "Deleted blueprint '%s'." % bp_name
		_load_feedback_label.add_theme_color_override("font_color", Color(1.0, 0.8, 0.2))
		_refresh_blueprint_list()
