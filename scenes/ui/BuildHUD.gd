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
var voxel_world: Node = null
@export var blueprint_manager: Node = null

## Dynamically created label for raw material counts (no .tscn edit required).
var _raw_mats_label: Label = null
var _objective_label: Label = null

## View-distance controls (− / label / +).
var _view_panel: PanelContainer = null
var _view_label: Label = null
var _view_minus_btn: Button = null
var _view_plus_btn: Button = null

## Mining feedback + progress.
var _mine_panel: PanelContainer = null
var _mine_label: Label = null
var _mine_bar: ProgressBar = null
var _mine_feedback_label: Label = null
var _mine_feedback_timer: float = 0.0

## Collapsible controls reference panel.
var _controls_panel: PanelContainer = null
var _controls_body: VBoxContainer = null
var _controls_toggle: Button = null
var _controls_expanded: bool = true

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

func _init() -> void:
	if _save_modal == null:
		_create_blueprint_dialogs()

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

	_objective_label = Label.new()
	_objective_label.name = "ObjectiveLabel"
	_objective_label.text = ""
	_objective_label.visible = false
	_objective_label.add_theme_font_size_override("font_size", 14)
	_objective_label.add_theme_color_override("font_color", Color(0.35, 0.85, 1.0))

	var hbox := get_node_or_null("PanelTop/HBox")
	if hbox != null:
		hbox.add_child(_raw_mats_label)
		hbox.add_child(_objective_label)

	_visualizer = BlueprintVisualizerScript.new()
	_visualizer.name = "BlueprintVisualizer"
	add_child(_visualizer)

	if _save_modal == null:
		_create_blueprint_dialogs()

	if has_node("/root/InventoryManager"):
		var inv = get_node("/root/InventoryManager")
		if not inv.inventory_changed.is_connected(_on_inventory_changed):
			inv.inventory_changed.connect(_on_inventory_changed)
		_on_inventory_changed(inv.get_materials())

	if has_node("/root/SurvivalObjectiveManager"):
		var obj = get_node("/root/SurvivalObjectiveManager")
		if not obj.objective_updated.is_connected(_on_objective_updated):
			obj.objective_updated.connect(_on_objective_updated)
		if not obj.cycle_completed.is_connected(_on_objective_cycle_completed):
			obj.cycle_completed.connect(_on_objective_cycle_completed)
		_on_objective_updated(int(obj.current_stage), obj.current_progress, obj.get_target_for_stage(obj.current_stage), obj.get_objective_display_text())

	_create_view_distance_controls()
	_create_mining_hud()
	_create_controls_panel()
	if voxel_world != null:
		bind_voxel_world(voxel_world)

func _on_objective_updated(_stage: int, _cur: int, _target: int, desc: String) -> void:
	if _objective_label == null:
		return
	_objective_label.text = "[Goal: " + desc + "]"
	_objective_label.visible = true

func _on_objective_cycle_completed(cycle: int, reward_desc: String) -> void:
	if _objective_label == null:
		return
	_objective_label.text = "★ Cycle %d Complete! %s" % [cycle, reward_desc]
	_objective_label.visible = true

func _on_inventory_changed(materials: Dictionary) -> void:
	if _raw_mats_label == null:
		return
	if materials.is_empty():
		_raw_mats_label.visible = false
		return
	var parts: Array = []
	for mat in materials.keys():
		var count: int = int(materials[mat])
		parts.append("%s: %d" % [BlockTypeCatalog.get_display_name(StringName(mat)), count])
	_raw_mats_label.text = "Inv: " + " | ".join(parts)
	_raw_mats_label.visible = true

func bind_voxel_world(world: Node) -> void:
	voxel_world = world
	if voxel_world == null:
		return
	if voxel_world.has_signal("view_distance_changed"):
		if not voxel_world.view_distance_changed.is_connected(_on_view_distance_changed):
			voxel_world.view_distance_changed.connect(_on_view_distance_changed)
	_refresh_view_distance_label()

func _create_view_distance_controls() -> void:
	if _view_panel != null:
		return
	_view_panel = PanelContainer.new()
	_view_panel.name = "ViewDistancePanel"
	_view_panel.anchor_left = 1.0
	_view_panel.anchor_right = 1.0
	_view_panel.anchor_top = 0.0
	_view_panel.anchor_bottom = 0.0
	_view_panel.offset_left = -220.0
	_view_panel.offset_top = 52.0
	_view_panel.offset_right = -12.0
	_view_panel.offset_bottom = 96.0
	_view_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_view_panel)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 8)
	_view_panel.add_child(row)

	_view_minus_btn = Button.new()
	_view_minus_btn.text = "−"
	_view_minus_btn.custom_minimum_size = Vector2(36, 28)
	_view_minus_btn.tooltip_text = "Decrease view distance (− / [)"
	_view_minus_btn.pressed.connect(_on_view_minus_pressed)
	row.add_child(_view_minus_btn)

	_view_label = Label.new()
	_view_label.text = "View: --"
	_view_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_view_label.custom_minimum_size = Vector2(120, 0)
	_view_label.add_theme_font_size_override("font_size", 14)
	row.add_child(_view_label)

	_view_plus_btn = Button.new()
	_view_plus_btn.text = "+"
	_view_plus_btn.custom_minimum_size = Vector2(36, 28)
	_view_plus_btn.tooltip_text = "Increase view distance (+ / ])"
	_view_plus_btn.pressed.connect(_on_view_plus_pressed)
	row.add_child(_view_plus_btn)

func _on_view_minus_pressed() -> void:
	if voxel_world != null and voxel_world.has_method("adjust_view_distance_chunks"):
		voxel_world.adjust_view_distance_chunks(-1)

func _on_view_plus_pressed() -> void:
	if voxel_world != null and voxel_world.has_method("adjust_view_distance_chunks"):
		voxel_world.adjust_view_distance_chunks(1)

func _on_view_distance_changed(voxels: int, chunks: int) -> void:
	if _view_label == null:
		return
	_view_label.text = "View: %d (%dc)" % [voxels, chunks]

func _refresh_view_distance_label() -> void:
	if _view_label == null or voxel_world == null:
		return
	var voxels := 0
	var chunks := 0
	if voxel_world.has_method("get_view_distance_voxels"):
		voxels = int(voxel_world.get_view_distance_voxels())
	if voxel_world.has_method("get_view_distance_chunks"):
		chunks = int(voxel_world.get_view_distance_chunks())
	_view_label.text = "View: %d (%dc)" % [voxels, chunks]

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

func _process(delta: float) -> void:
	if grid_system != null and block_count_label != null:
		block_count_label.text = "Grid Blocks: %d" % grid_system.get_block_count()

	if orchestrator != null and debris_count_label != null:
		debris_count_label.text = "Active Debris: %d" % orchestrator.get_active_debris_count()

	if _mine_feedback_timer > 0.0:
		_mine_feedback_timer -= delta
		if _mine_feedback_timer <= 0.0 and _mine_feedback_label != null:
			_mine_feedback_label.visible = false

func _create_mining_hud() -> void:
	if _mine_panel != null:
		return
	_mine_panel = PanelContainer.new()
	_mine_panel.name = "MiningHudPanel"
	_mine_panel.anchor_left = 0.5
	_mine_panel.anchor_right = 0.5
	_mine_panel.anchor_top = 1.0
	_mine_panel.anchor_bottom = 1.0
	_mine_panel.offset_left = -160.0
	_mine_panel.offset_right = 160.0
	_mine_panel.offset_top = -110.0
	_mine_panel.offset_bottom = -52.0
	_mine_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mine_panel.visible = false
	add_child(_mine_panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	_mine_panel.add_child(vbox)

	_mine_label = Label.new()
	_mine_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_mine_label.add_theme_font_size_override("font_size", 15)
	_mine_label.add_theme_color_override("font_color", Color(0.95, 0.95, 0.9))
	_mine_label.text = "Target: —"
	vbox.add_child(_mine_label)

	_mine_bar = ProgressBar.new()
	_mine_bar.min_value = 0.0
	_mine_bar.max_value = 100.0
	_mine_bar.value = 0.0
	_mine_bar.show_percentage = true
	_mine_bar.custom_minimum_size = Vector2(280, 18)
	vbox.add_child(_mine_bar)

	_mine_feedback_label = Label.new()
	_mine_feedback_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_mine_feedback_label.add_theme_font_size_override("font_size", 14)
	_mine_feedback_label.add_theme_color_override("font_color", Color(0.45, 1.0, 0.55))
	_mine_feedback_label.visible = false
	_mine_feedback_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mine_feedback_label.anchor_left = 0.5
	_mine_feedback_label.anchor_right = 0.5
	_mine_feedback_label.anchor_top = 1.0
	_mine_feedback_label.anchor_bottom = 1.0
	_mine_feedback_label.offset_left = -180.0
	_mine_feedback_label.offset_right = 180.0
	_mine_feedback_label.offset_top = -140.0
	_mine_feedback_label.offset_bottom = -118.0
	add_child(_mine_feedback_label)

func set_mining_progress(active: bool, block_name: String, percent: int) -> void:
	if _mine_panel == null:
		return
	if not active:
		_mine_panel.visible = false
		if _mine_bar != null:
			_mine_bar.value = 0.0
		return
	_mine_panel.visible = true
	var pct: int = clampi(percent, 0, 100)
	if _mine_label != null:
		if pct > 0:
			_mine_label.text = "Mining %s [%d%%]" % [block_name, pct]
		else:
			_mine_label.text = "Target: %s" % block_name
	if _mine_bar != null:
		_mine_bar.value = float(pct)

func show_mine_feedback(block_type: StringName, amount: int = 1) -> void:
	if _mine_feedback_label == null:
		return
	var disp := BlockTypeCatalog.get_display_name(block_type)
	_mine_feedback_label.text = "+%d %s" % [amount, disp]
	_mine_feedback_label.visible = true
	_mine_feedback_timer = 1.6

func _create_controls_panel() -> void:
	if _controls_panel != null:
		return
	_controls_panel = PanelContainer.new()
	_controls_panel.name = "ControlsPanel"
	_controls_panel.anchor_left = 0.0
	_controls_panel.anchor_right = 0.0
	_controls_panel.anchor_top = 0.0
	_controls_panel.anchor_bottom = 0.0
	_controls_panel.offset_left = 12.0
	_controls_panel.offset_top = 52.0
	_controls_panel.offset_right = 292.0
	_controls_panel.offset_bottom = 420.0
	_controls_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_controls_panel)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 4)
	_controls_panel.add_child(root)

	_controls_toggle = Button.new()
	_controls_toggle.text = "Controls ▾"
	_controls_toggle.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_controls_toggle.pressed.connect(_toggle_controls_panel)
	root.add_child(_controls_toggle)

	_controls_body = VBoxContainer.new()
	_controls_body.add_theme_constant_override("separation", 2)
	root.add_child(_controls_body)

	for line in _build_controls_lines():
		var lbl := Label.new()
		lbl.text = line
		lbl.add_theme_font_size_override("font_size", 12)
		lbl.add_theme_color_override("font_color", Color(0.88, 0.9, 0.92))
		_controls_body.add_child(lbl)

func _toggle_controls_panel() -> void:
	_controls_expanded = not _controls_expanded
	if _controls_body != null:
		_controls_body.visible = _controls_expanded
	if _controls_toggle != null:
		_controls_toggle.text = "Controls ▾" if _controls_expanded else "Controls ▸"
	if _controls_panel != null:
		_controls_panel.offset_bottom = 420.0 if _controls_expanded else 88.0

func _build_controls_lines() -> PackedStringArray:
	var lines: PackedStringArray = PackedStringArray()
	lines.append("Move: %s" % _action_keys("move_forward", "move_left", "move_backward", "move_right"))
	lines.append("Jump / Sprint: %s / %s" % [_action_keys("jump"), _action_keys("sprint")])
	lines.append("Toggle fly: F / double-Space")
	lines.append("Fly up/down: %s / %s" % [_action_keys("fly_up"), _action_keys("fly_down")])
	lines.append("Soul Projection: %s" % _action_keys("soul_projection"))
	lines.append("Mouse capture: %s" % _action_keys("toggle_mouse_capture"))
	lines.append("Mine (hold): %s" % _action_keys("remove_block"))
	lines.append("Place / Remove block: %s / %s" % [_action_keys("place_block"), _action_keys("remove_block")])
	lines.append("Materials: %s" % _action_keys("select_slot_1", "select_slot_2", "select_slot_3", "select_slot_4"))
	lines.append("Mortar brush: %s" % _action_keys("apply_cement"))
	lines.append("Debris grab/drop: %s" % _action_keys("interact"))
	lines.append("Throw / Recover: %s / %s" % [_action_keys("throw_debris"), _action_keys("recover_block")])
	lines.append("Blueprints: %s / %s" % [_action_keys("save_blueprint"), _action_keys("load_blueprint")])
	lines.append("Debug camera: %s" % _action_keys("debug_camera"))
	lines.append("View distance: + / −  (or [ / ])")
	return lines

func _action_keys(action1: StringName, action2: StringName = &"", action3: StringName = &"", action4: StringName = &"") -> String:
	var parts: PackedStringArray = PackedStringArray()
	for action in [action1, action2, action3, action4]:
		if action == &"":
			continue
		var label := _format_action_events(action)
		if not label.is_empty():
			parts.append(label)
	if parts.is_empty():
		return "—"
	if action1 == &"move_forward" and parts.size() >= 4:
		return "%s%s%s%s" % [parts[0], parts[1], parts[2], parts[3]]
	return " / ".join(parts)

func _format_action_events(action: StringName) -> String:
	if not InputMap.has_action(action):
		return String(action)
	var uniq: PackedStringArray = PackedStringArray()
	for ev in InputMap.action_get_events(action):
		var label := ""
		if ev is InputEventKey:
			var key_ev := ev as InputEventKey
			var code: Key = key_ev.physical_keycode if key_ev.physical_keycode != KEY_NONE else key_ev.keycode
			label = OS.get_keycode_string(code)
		elif ev is InputEventMouseButton:
			var btn := (ev as InputEventMouseButton).button_index
			match btn:
				MOUSE_BUTTON_LEFT: label = "LMB"
				MOUSE_BUTTON_RIGHT: label = "RMB"
				MOUSE_BUTTON_MIDDLE: label = "MMB"
				_: label = "Mouse%d" % int(btn)
		if not label.is_empty() and not uniq.has(label):
			uniq.append(label)
	if uniq.is_empty():
		return String(action)
	return "/".join(uniq)

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
	if _save_info_label != null:
		_save_info_label.text = "Bounded Area: (%d,%d,%d) to (%d,%d,%d)" % [
			min_cell.x, min_cell.y, min_cell.z, max_cell.x, max_cell.y, max_cell.z
		]
	if _save_feedback_label != null:
		_save_feedback_label.text = ""
	if _save_btn != null:
		_save_btn.disabled = false

## Opens the Save Blueprint dialog, releases mouse capture, and focuses input.
func open_save_blueprint_dialog() -> void:
	close_all_modals()
	if _save_modal == null:
		_create_blueprint_dialogs()
	_save_confirm_overwrite = false
	if _save_btn != null:
		_save_btn.text = "Save"
	if not _has_area_selected:
		var count: int = grid_system.get_block_count() if grid_system != null else 0
		if count == 0:
			if _save_info_label != null:
				_save_info_label.text = "Structure to Save: 0 block(s) in grid"
			if _save_feedback_label != null:
				_save_feedback_label.text = "Grid is empty. Place blocks before saving."
			if _save_btn != null:
				_save_btn.disabled = true
		else:
			if _save_info_label != null:
				_save_info_label.text = "Structure to Save: %d block(s) in grid" % count
			if _save_feedback_label != null:
				_save_feedback_label.text = ""
			if _save_btn != null:
				_save_btn.disabled = false
	else:
		if _save_feedback_label != null:
			_save_feedback_label.text = ""
		if _save_btn != null:
			_save_btn.disabled = false
	if _save_modal != null:
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
		_create_blueprint_dialogs()

	if _anchor_x != null:
		_anchor_x.value = anchor.x
	if _anchor_y != null:
		_anchor_y.value = anchor.y
	if _anchor_z != null:
		_anchor_z.value = anchor.z
	if _load_feedback_label != null:
		_load_feedback_label.text = ""
	_refresh_blueprint_list()

	if _load_modal != null:
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

	if not plan.required_materials.is_empty():
		details += "\nRequired:"
		var inv_mgr = get_node_or_null("/root/InventoryManager")
		for mat in plan.required_materials.keys():
			var req: int = plan.required_materials[mat]
			var avail: int = inv_mgr.get_material_count(mat) if inv_mgr != null else 0
			var mat_name := BlockTypeCatalog.get_display_name(mat)
			details += " %s: %d (avail %d) |" % [mat_name, req, avail]
		details = details.trim_suffix(" |")

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
		_load_feedback_label.text = "Cannot place [%s]: %d conflict(s)%s" % [reason, conflicts.size(), conflict_str]
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
