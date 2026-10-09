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

var grid_system: Node
var orchestrator: CollapseOrchestrator

func _ready() -> void:
	if grid_system == null and has_node("/root/GridSystem"):
		grid_system = get_node("/root/GridSystem")

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
			prompt_label.text = "[HOLDING %s] E: Drop  |  R / LMB: Recover" % mat_name.to_upper()
			prompt_label.visible = true
		else:
			prompt_label.visible = false

func _process(_delta: float) -> void:
	if grid_system != null and block_count_label != null:
		block_count_label.text = "Grid Blocks: %d" % grid_system.get_block_count()

	if orchestrator != null and debris_count_label != null:
		debris_count_label.text = "Active Debris: %d" % orchestrator.get_active_debris_count()
