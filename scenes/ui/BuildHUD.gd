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

var grid_system: Node
var orchestrator: CollapseOrchestrator

## Dynamically created label for raw material counts (no .tscn edit required).
var _raw_mats_label: Label = null

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
			if "Depleted" in status_text or "Insufficient" in status_text:
				target_info_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
			elif "Mortared" in status_text or "Bonded" in status_text or "Ready" in status_text:
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
