extends Node

## Manages input action mappings and bindings across the project.
## Guarantees standard input actions exist in all environments (runtime, headless, tests).

func _ready() -> void:
	setup_default_input_actions()

func setup_default_input_actions() -> void:
	# WASD Movement
	_add_key_action(&"move_forward", KEY_W)
	_add_key_action(&"move_backward", KEY_S)
	_add_key_action(&"move_left", KEY_A)
	_add_key_action(&"move_right", KEY_D)

	# Locomotion Modifiers
	_add_key_action(&"jump", KEY_SPACE)
	_add_key_action(&"sprint", KEY_SHIFT)

	# 3D Flight / Soul Projection Vertical Movement
	_add_key_action(&"fly_up", KEY_SPACE)
	_add_key_action(&"fly_down", KEY_CTRL)
	_add_key_action(&"fly_down", KEY_Q)

	# Interaction: Grab/Release/Recover/Throw debris block
	_add_key_action(&"interact", KEY_E)
	_add_key_action(&"recover_block", KEY_R)
	_add_key_action(&"throw_debris", KEY_F)
	_add_key_action(&"apply_cement", KEY_G)

	# Abilities and Modes
	_add_key_action(&"soul_projection", KEY_V)
	_add_key_action(&"soul_projection", KEY_P)
	_add_key_action(&"debug_camera", KEY_F1)

	# Construction Blueprints
	_add_key_action(&"save_blueprint", KEY_K)
	_add_key_action(&"load_blueprint", KEY_L)

	# Interaction — LMB = break/remove, RMB = place
	_set_mouse_action(&"remove_block", MOUSE_BUTTON_LEFT)
	_set_mouse_action(&"place_block", MOUSE_BUTTON_RIGHT)
	_add_key_action(&"toggle_mouse_capture", KEY_TAB)
	_add_key_action(&"toggle_mouse_capture", KEY_ESCAPE)

	# Material Selection Slots
	_add_key_action(&"select_slot_1", KEY_1)
	_add_key_action(&"select_slot_2", KEY_2)
	_add_key_action(&"select_slot_3", KEY_3)
	_add_key_action(&"select_slot_4", KEY_4)

	# View distance (+ / − and bracket aliases)
	_add_key_action(&"view_distance_up", KEY_EQUAL)
	_add_key_action(&"view_distance_up", KEY_KP_ADD)
	_add_key_action(&"view_distance_up", KEY_BRACKETRIGHT)
	_add_key_action(&"view_distance_down", KEY_MINUS)
	_add_key_action(&"view_distance_down", KEY_KP_SUBTRACT)
	_add_key_action(&"view_distance_down", KEY_BRACKETLEFT)

func _add_key_action(action: StringName, keycode: Key) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)

	# Check if this key event is already registered
	for existing in InputMap.action_get_events(action):
		if existing is InputEventKey and (existing.physical_keycode == keycode or existing.keycode == keycode):
			return

	var ev := InputEventKey.new()
	ev.physical_keycode = keycode
	ev.keycode = keycode
	InputMap.action_add_event(action, ev)

func _add_mouse_action(action: StringName, button_index: MouseButton) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)

	for existing in InputMap.action_get_events(action):
		if existing is InputEventMouseButton and existing.button_index == button_index:
			return

	var ev := InputEventMouseButton.new()
	ev.button_index = button_index
	InputMap.action_add_event(action, ev)

func _set_mouse_action(action: StringName, button_index: MouseButton) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	else:
		for existing in InputMap.action_get_events(action):
			if existing is InputEventMouseButton:
				InputMap.action_erase_event(action, existing)
	var ev := InputEventMouseButton.new()
	ev.button_index = button_index
	InputMap.action_add_event(action, ev)
