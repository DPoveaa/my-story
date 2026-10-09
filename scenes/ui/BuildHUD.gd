class_name BuildHUD
extends CanvasLayer

## In-game overlay showing crosshair, active block selection, status stats, and keybinds.

@onready var crosshair: Label = $Crosshair
@onready var selected_type_label: Label = $PanelTop/HBox/SelectedTypeLabel
@onready var block_count_label: Label = $PanelTop/HBox/BlockCountLabel
@onready var debris_count_label: Label = $PanelTop/HBox/DebrisCountLabel
@onready var color_rect_badge: ColorRect = $PanelTop/HBox/ColorBadge

var grid_system: GridSystem
var orchestrator: CollapseOrchestrator

func _ready() -> void:
	if grid_system == null and has_node("/root/GridSystem"):
		grid_system = get_node("/root/GridSystem")

func set_selected_block_type(type_id: StringName) -> void:
	if selected_type_label != null:
		selected_type_label.text = "Material: " + BlockTypeCatalog.get_display_name(type_id)
	if color_rect_badge != null:
		color_rect_badge.color = BlockTypeCatalog.get_color(type_id)

func _process(_delta: float) -> void:
	if grid_system != null and block_count_label != null:
		block_count_label.text = "Grid Blocks: %d" % grid_system.get_block_count()

	if orchestrator != null and debris_count_label != null:
		debris_count_label.text = "Active Debris: %d" % orchestrator.get_active_debris_count()
