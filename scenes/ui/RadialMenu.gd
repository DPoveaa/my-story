extends Control

## AAA Radial Menu with Generous Center Preview Hub.
## Angle-based radial menu using a virtual cursor while leaving MOUSE_MODE_CAPTURED intact.
## Hold RMB to aim pie slice; release RMB to confirm affordable option or cancel if unaffordable.

signal option_selected(option_name: String)
signal cancelled()

@export var ring_radius: float = 245.0
@export var inner_radius: float = 125.0
@export var virtual_clamp: float = 220.0

var virtual_mouse: Vector2 = Vector2.ZERO
var hovered_option: String = ""
var _options: Array = []
var _hovered_index: int = 0
var _open: bool = false

func _ready() -> void:
	top_level = true
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	z_index = 80
	set_process(true)
	set_process_input(true)
	if get_viewport() != null:
		get_viewport().size_changed.connect(_fit_viewport)
	_fit_viewport()
	queue_redraw()

func _fit_viewport() -> void:
	if not is_inside_tree() or get_viewport() == null:
		return
	var vr: Rect2 = get_viewport().get_visible_rect()
	position = vr.position
	size = vr.size

func open(options: Array, _center: Vector2 = Vector2.ZERO) -> void:
	_options = options.duplicate()
	virtual_mouse = Vector2.ZERO
	_hovered_index = 0
	hovered_option = _option_id(_options[0]) if not _options.is_empty() else ""
	_open = true
	visible = true
	_fit_viewport()
	queue_redraw()

func _option_id(opt: Variant) -> String:
	if opt is Dictionary:
		if opt.has("id"):
			return str(opt["id"])
		if opt.has("text"):
			return str(opt["text"])
		if opt.has("label"):
			return str(opt["label"])
		return ""
	return str(opt)

func _option_label(opt: Variant) -> String:
	if opt is Dictionary:
		if opt.has("text"):
			return str(opt["text"])
		if opt.has("label"):
			return str(opt["label"])
		if opt.has("id"):
			return str(opt["id"])
		return ""
	return str(opt)

func _option_enabled(opt: Variant) -> bool:
	if opt is Dictionary and opt.has("enabled"):
		return bool(opt["enabled"])
	return true

func _get_short_title(opt: Variant) -> String:
	var raw: String = ""
	if opt is Dictionary:
		if opt.has("short_title"):
			return str(opt["short_title"])
		if opt.has("id"):
			raw = str(opt["id"])
		elif opt.has("text"):
			raw = str(opt["text"])
		elif opt.has("label"):
			raw = str(opt["label"])
	else:
		raw = str(opt)

	var paren_pos: int = raw.find("(")
	if paren_pos != -1:
		raw = raw.substr(0, paren_pos).strip_edges()
	var arrow_pos: int = raw.find("→")
	if arrow_pos != -1:
		raw = raw.substr(0, arrow_pos).strip_edges()

	if raw == "Craft Stone Blocks":
		return "Craft Stone"
	if raw == "Craft Dirt Blocks":
		return "Craft Dirt"
	if raw == "Dismantle Station":
		return "Dismantle"
	if raw == "Spawn Worker":
		return "Worker"
	return raw

func _get_full_title(opt: Variant) -> String:
	if opt is Dictionary and opt.has("id"):
		return str(opt["id"])
	return _get_short_title(opt)

func _get_player() -> Node:
	var p: Node = get_parent()
	if p != null and (p.has_method("_held_count_of") or p.has_method("_held_is_type")):
		return p
	if p != null and p.get_parent() != null:
		var grand: Node = p.get_parent()
		if grand.has_method("_held_count_of"):
			return grand
	return p

func _parse_cost_number(text: String, default_val: int) -> int:
	var idx: int = text.find("Cost:")
	if idx != -1:
		var sub: String = text.substr(idx + 5).strip_edges()
		var num_str: String = ""
		for ch in sub:
			if ch >= "0" and ch <= "9":
				num_str += ch
			elif not num_str.is_empty():
				break
		if not num_str.is_empty():
			return num_str.to_int()
	return default_val

func _get_resource_checklist(opt: Variant) -> Array:
	var list: Array = []
	var opt_id: String = _option_id(opt)
	var opt_text: String = _option_label(opt)
	var player: Node = _get_player()
	var base_enabled: bool = _option_enabled(opt)

	if opt is Dictionary and opt.has("checklist") and opt["checklist"] is Array:
		for item in opt["checklist"]:
			if item is Dictionary:
				var c: int = int(item.get("current", 0))
				var r: int = int(item.get("required", 1))
				var nm: String = str(item.get("name", "Item"))
				var met: bool = bool(item.get("met", c >= r))
				list.append({
					"name": nm,
					"current": c,
					"required": r,
					"met": met,
					"display_text": "%s: %d / %d" % [nm, c, r]
				})
		if not list.is_empty():
			return list

	if opt_id == "Chopping Block":
		var current_logs: int = 0
		if player != null and player.has_method("_held_count_of"):
			current_logs = int(player.call("_held_count_of", "log"))
		elif player != null and player.has_method("_held_is_type") and bool(player.call("_held_is_type", "log")):
			current_logs = 1
		else:
			current_logs = 1 if base_enabled else 0
		var req: int = 1
		list.append({
			"name": "Logs",
			"current": current_logs,
			"required": req,
			"met": current_logs >= req,
			"display_text": "Logs: %d / %d" % [current_logs, req]
		})
		return list

	if opt_id == "Pallet":
		var current_planks: int = 0
		if player != null and player.has_method("_held_count_of"):
			current_planks = int(player.call("_held_count_of", "plank"))
		else:
			current_planks = 4 if base_enabled else 0
		var req: int = 4
		list.append({
			"name": "Planks",
			"current": current_planks,
			"required": req,
			"met": current_planks >= req,
			"display_text": "Planks: %d / %d" % [current_planks, req]
		})
		return list

	if opt_id == "Spawn Worker":
		var current_planks: int = 0
		var current_logs: int = 0
		if player != null and player.has_method("_held_count_of"):
			current_planks = int(player.call("_held_count_of", "plank"))
			current_logs = int(player.call("_held_count_of", "log"))
		elif player != null and player.has_method("_held_is_type") and bool(player.call("_held_is_type", "log")):
			current_logs = 1
		var met: bool = current_planks >= 2 or current_logs >= 1
		list.append({
			"name": "Planks / Log",
			"current": current_planks if current_planks >= 2 else current_logs,
			"required": 2 if current_planks >= 2 else 1,
			"met": met,
			"display_text": "2 Planks or 1 Log"
		})
		return list

	if opt_id == "Chop Log":
		var has_log: bool = false
		if player != null and is_instance_valid(player.get("target_chopping_block")):
			has_log = bool(player.target_chopping_block.get("has_log"))
		else:
			has_log = base_enabled
		var cur: int = 1 if has_log else 0
		list.append({
			"name": "Log on Station",
			"current": cur,
			"required": 1,
			"met": has_log,
			"display_text": "Log on Station: %d / 1" % [cur]
		})
		return list

	if opt_id == "Dismantle Station":
		list.append({
			"name": "Cost",
			"current": 0,
			"required": 0,
			"met": true,
			"display_text": "Cost: Free (Refunds Items)"
		})
		return list

	if opt_id.begins_with("Craft Stone"):
		var req_stone: int = _parse_cost_number(opt_text, 64)
		var stored_stone: int = 0
		if player != null and is_instance_valid(player.get("target_pallet")):
			var stored: Variant = player.target_pallet.get("stored_materials")
			if stored is Dictionary:
				stored_stone = int(stored.get("stone", 0))
		else:
			stored_stone = req_stone if base_enabled else 0
		list.append({
			"name": "Stone",
			"current": stored_stone,
			"required": req_stone,
			"met": stored_stone >= req_stone and base_enabled,
			"display_text": "Stone: %d / %d" % [stored_stone, req_stone]
		})
		return list

	if opt_id.begins_with("Craft Dirt"):
		var req_dirt: int = _parse_cost_number(opt_text, 64)
		var stored_dirt: int = 0
		if player != null and is_instance_valid(player.get("target_pallet")):
			var stored: Variant = player.target_pallet.get("stored_materials")
			if stored is Dictionary:
				stored_dirt = int(stored.get("dirt", 0))
		else:
			stored_dirt = req_dirt if base_enabled else 0
		list.append({
			"name": "Dirt",
			"current": stored_dirt,
			"required": req_dirt,
			"met": stored_dirt >= req_dirt and base_enabled,
			"display_text": "Dirt: %d / %d" % [stored_dirt, req_dirt]
		})
		return list

	var parsed_cost: int = _parse_cost_number(opt_text, -1)
	if parsed_cost > 0:
		var cur: int = parsed_cost if base_enabled else 0
		list.append({
			"name": "Materials",
			"current": cur,
			"required": parsed_cost,
			"met": base_enabled,
			"display_text": "Materials: %d / %d" % [cur, parsed_cost]
		})
		return list

	list.append({
		"name": "Requirements",
		"current": 1 if base_enabled else 0,
		"required": 1,
		"met": base_enabled,
		"display_text": "Requirements Met" if base_enabled else "Insufficient Resources"
	})
	return list

func _is_slice_affordable(index: int) -> bool:
	if index < 0 or index >= _options.size():
		return false
	var opt: Variant = _options[index]
	var checklist: Array = _get_resource_checklist(opt)
	if not checklist.is_empty():
		for item in checklist:
			if not bool(item.get("met", true)):
				return false
		return true
	return _option_enabled(opt)

func _process(_delta: float) -> void:
	if not _open or _options.is_empty():
		return
	_update_hovered_from_angle()
	queue_redraw()

func _update_hovered_from_angle() -> void:
	var count: int = _options.size()
	if count <= 0:
		hovered_option = ""
		_hovered_index = -1
		return
	if virtual_mouse.length_squared() < 16.0:
		_hovered_index = clampi(_hovered_index, 0, count - 1)
		hovered_option = _option_id(_options[_hovered_index])
		return
	var angle: float = atan2(virtual_mouse.y, virtual_mouse.x)
	var normalized: float = fposmod(angle + PI * 0.5, TAU)
	_hovered_index = int(floor(normalized / TAU * float(count))) % count
	hovered_option = _option_id(_options[_hovered_index])

func _input(event: InputEvent) -> void:
	if not _open:
		return

	if event is InputEventMouseMotion:
		virtual_mouse += event.relative
		if virtual_mouse.length() > virtual_clamp:
			virtual_mouse = virtual_mouse.normalized() * virtual_clamp
		get_viewport().set_input_as_handled()
		return

	if event is InputEventMouseButton \
	and not event.pressed \
	and event.button_index == MOUSE_BUTTON_RIGHT:
		_confirm_selection()
		get_viewport().set_input_as_handled()
		return

	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		_open = false
		cancelled.emit()
		queue_free()
		get_viewport().set_input_as_handled()

func _confirm_selection() -> void:
	_update_hovered_from_angle()
	var chosen: String = hovered_option
	var affordable: bool = _is_slice_affordable(_hovered_index)
	_open = false
	if not chosen.is_empty() and affordable:
		option_selected.emit(chosen)
	else:
		cancelled.emit()
	queue_free()

func _draw() -> void:
	if not _open:
		return
	var center: Vector2 = size * 0.5
	var count: int = _options.size()

	# Dark full-screen focus vignette
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.02, 0.03, 0.05, 0.45))

	# Outer subtle wheel halo
	draw_circle(center, ring_radius + 4.0, Color(0.04, 0.05, 0.08, 0.35))

	# Render Outer Pie Slices
	if count > 0:
		var slice: float = TAU / float(count)
		var gap: float = 0.032 if count > 1 else 0.0

		for i in range(count):
			var start: float = -PI * 0.5 + slice * float(i)
			var end: float = start + slice
			var is_hovered: bool = (i == _hovered_index)
			var affordable: bool = _is_slice_affordable(i)
			var opt: Variant = _options[i]

			var col_fill: Color
			var col_border: Color
			var border_width: float = 1.5
			var alpha_mod: float = 1.0

			if not affordable:
				if is_hovered:
					col_fill = Color(0.24, 0.10, 0.10, 0.40)
					col_border = Color(0.85, 0.35, 0.35, 0.75)
					border_width = 2.4
					alpha_mod = 0.55
				else:
					col_fill = Color(0.10, 0.10, 0.12, 0.22)
					col_border = Color(0.24, 0.24, 0.28, 0.25)
					border_width = 1.0
					alpha_mod = 0.30
			elif is_hovered:
				col_fill = Color(0.14, 0.46, 0.90, 0.68)
				col_border = Color(0.50, 0.85, 1.0, 0.95)
				border_width = 3.0
				alpha_mod = 1.0
			else:
				col_fill = Color(0.13, 0.16, 0.22, 0.62)
				col_border = Color(0.28, 0.35, 0.45, 0.60)
				border_width = 1.5
				alpha_mod = 0.85

			_draw_annular_sector(center, inner_radius + 4.0, ring_radius - 2.0, start + gap, end - gap, col_fill, col_border, border_width)

			if is_hovered and affordable:
				draw_arc(center, ring_radius + 1.0, start + gap, end - gap, 32, Color(0.65, 0.92, 1.0, 0.9), 3.0, true)

			var mid_angle: float = (start + end) * 0.5
			var mid_r: float = (inner_radius + ring_radius) * 0.5
			var radial_dir: Vector2 = Vector2(cos(mid_angle), sin(mid_angle))

			# Mini Icon on Outer Slice (Closer to center hub)
			var icon_pos: Vector2 = center + radial_dir * (mid_r - 20.0)
			_draw_structure_icon(icon_pos, 14.0, _option_id(opt), false, affordable, alpha_mod)

			# Short Title on Outer Slice (Further outward, clean without cost clutter)
			var label_pos: Vector2 = center + radial_dir * (mid_r + 20.0)
			var short_title: String = _get_short_title(opt)
			var font := ThemeDB.fallback_font
			var font_size: int = 15 if is_hovered else 14
			var text_col: Color
			if not affordable:
				text_col = Color(0.75, 0.65, 0.65, alpha_mod)
			elif is_hovered:
				text_col = Color(1.0, 1.0, 1.0, 1.0)
			else:
				text_col = Color(0.88, 0.90, 0.94, 0.85)

			_draw_centered_text(font, label_pos, short_title, font_size, text_col)

	# Generous Center Hub Drawing
	_draw_center_hub(center)

	# Virtual Cursor Aim Pip (Drawn outside center hub to avoid obstructing text)
	_draw_aim_indicator(center)

func _draw_center_hub(center: Vector2) -> void:
	var font := ThemeDB.fallback_font

	# Hub drop shadow & background disc
	draw_circle(center, inner_radius + 3.0, Color(0.0, 0.0, 0.0, 0.55))
	draw_circle(center, inner_radius, Color(0.07, 0.09, 0.13, 0.96))

	var has_hovered: bool = _hovered_index >= 0 and _hovered_index < _options.size()
	var affordable: bool = _is_slice_affordable(_hovered_index) if has_hovered else true

	# Center Hub Border Ring
	var ring_color: Color
	if not has_hovered:
		ring_color = Color(0.24, 0.30, 0.40, 0.65)
	elif affordable:
		ring_color = Color(0.35, 0.75, 1.0, 0.88)
	else:
		ring_color = Color(0.92, 0.35, 0.35, 0.85)

	draw_arc(center, inner_radius, 0.0, TAU, 64, ring_color, 2.5, true)

	if not has_hovered:
		_draw_centered_text(font, center + Vector2(0.0, -10.0), "SELECT STRUCTURE", 16, Color(0.7, 0.75, 0.85, 0.7))
		_draw_centered_text(font, center + Vector2(0.0, 14.0), "Aim with mouse", 12, Color(0.5, 0.55, 0.65, 0.55))
		return

	var opt: Variant = _options[_hovered_index]
	var opt_id: String = _option_id(opt)

	# a) Top/Center: Visual Preview of the Selected Structure
	var preview_center: Vector2 = Vector2(center.x, center.y - 48.0)
	var ped_col := Color(0.11, 0.14, 0.20, 0.85)
	var ped_border := Color(0.35, 0.65, 0.95, 0.65) if affordable else Color(0.85, 0.32, 0.32, 0.55)
	draw_circle(preview_center, 34.0, ped_col)
	draw_arc(preview_center, 34.0, 0.0, TAU, 48, ped_border, 1.5, true)
	_draw_structure_icon(preview_center, 25.0, opt_id, true, affordable, 1.0)

	# b) Middle: Clean, Large Structure Title
	var title_str: String = _get_full_title(opt)
	var title_col: Color = Color(1.0, 1.0, 1.0, 1.0) if affordable else Color(0.95, 0.75, 0.75, 0.95)
	_draw_centered_text(font, Vector2(center.x, center.y + 6.0), title_str, 18, title_col)

	# Decorative Separator Line
	draw_line(Vector2(center.x - 46.0, center.y + 18.0), Vector2(center.x + 46.0, center.y + 18.0), Color(0.38, 0.48, 0.62, 0.40), 1.0)

	# c) Bottom: Resource Checklist (Green if met, Red if insufficient)
	var checklist: Array = _get_resource_checklist(opt)
	var cur_y: float = center.y + 34.0
	for item in checklist:
		var met: bool = bool(item.get("met", false))
		var item_col: Color = Color(0.32, 0.96, 0.48, 1.0) if met else Color(1.0, 0.38, 0.38, 1.0)
		var bullet: String = "✓ " if met else "✕ "
		var line_text: String = bullet + str(item.get("display_text", ""))
		_draw_centered_text(font, Vector2(center.x, cur_y), line_text, 14, item_col)
		cur_y += 18.0

	# Subtext Action Badge
	var badge_text: String = "RELEASE RMB TO PLACE" if affordable else "INSUFFICIENT RESOURCES"
	var badge_col: Color = Color(0.42, 0.88, 0.58, 0.85) if affordable else Color(1.0, 0.42, 0.42, 0.85)
	_draw_centered_text(font, Vector2(center.x, center.y + 84.0), badge_text, 11, badge_col)

func _draw_aim_indicator(center: Vector2) -> void:
	if virtual_mouse.length() < 12.0:
		return
	var dir: Vector2 = virtual_mouse.normalized()
	var ray_start: Vector2 = center + dir * (inner_radius + 4.0)
	var ray_end: Vector2 = center + virtual_mouse.limit_length(ring_radius - 8.0)
	draw_line(ray_start, ray_end, Color(1.0, 0.90, 0.35, 0.55), 2.0)
	draw_circle(ray_end, 5.0, Color(1.0, 0.92, 0.40, 0.95))

func _draw_centered_text(font: Font, center_pos: Vector2, text: String, font_size: int, color: Color) -> void:
	var sz: Vector2 = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
	var ascent: float = font.get_ascent(font_size)
	var pos: Vector2 = Vector2(center_pos.x - sz.x * 0.5, center_pos.y + ascent * 0.35)
	draw_string(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)

func _draw_annular_sector(center: Vector2, r_inner: float, r_outer: float, start: float, end: float, fill_color: Color, border_color: Color, border_width: float) -> void:
	var steps: int = maxi(8, int(ceil(absf(end - start) / (PI / 28.0))))
	var points := PackedVector2Array()

	for s in range(steps + 1):
		var t: float = lerpf(start, end, float(s) / float(steps))
		points.append(center + Vector2(cos(t), sin(t)) * r_outer)

	for s in range(steps, -1, -1):
		var t2: float = lerpf(start, end, float(s) / float(steps))
		points.append(center + Vector2(cos(t2), sin(t2)) * r_inner)

	if points.size() >= 3:
		draw_colored_polygon(points, fill_color)
		if border_color.a > 0.0 and border_width > 0.0:
			var border_pts := points.duplicate()
			border_pts.append(points[0])
			draw_polyline(border_pts, border_color, border_width, true)

func _draw_structure_icon(pos: Vector2, r: float, opt_id: String, is_large: bool, affordable: bool, alpha: float = 1.0) -> void:
	var id_lower: String = opt_id.to_lower()
	if id_lower.contains("chopping block"):
		_draw_icon_chopping_block(pos, r, is_large, affordable, alpha)
	elif id_lower.contains("pallet"):
		_draw_icon_pallet(pos, r, is_large, affordable, alpha)
	elif id_lower.contains("worker"):
		_draw_icon_worker(pos, r, is_large, affordable, alpha)
	elif id_lower.contains("chop"):
		_draw_icon_chop(pos, r, is_large, affordable, alpha)
	elif id_lower.contains("dismantle"):
		_draw_icon_dismantle(pos, r, is_large, affordable, alpha)
	elif id_lower.contains("stone"):
		_draw_icon_block(pos, r, true, is_large, affordable, alpha)
	elif id_lower.contains("dirt"):
		_draw_icon_block(pos, r, false, is_large, affordable, alpha)
	else:
		_draw_icon_block(pos, r, true, is_large, affordable, alpha)

func _draw_icon_worker(pos: Vector2, r: float, _is_large: bool, affordable: bool, alpha: float) -> void:
	var tint: Color = Color(1, 1, 1, alpha) if affordable else Color(0.7, 0.7, 0.75, alpha * 0.7)
	var body_col: Color = Color(0.95, 0.55, 0.15) * tint
	var visor_col: Color = Color(0.1, 0.85, 1.0) * tint
	var ant_col: Color = Color(0.85, 0.88, 0.95) * tint
	draw_line(pos + Vector2(0.0, -r * 0.4), pos + Vector2(0.0, -r * 0.8), ant_col, maxf(1.5, r * 0.12))
	draw_circle(pos + Vector2(0.0, -r * 0.8), maxf(2.0, r * 0.15), visor_col)
	_draw_ellipse(pos + Vector2(0.0, 0.05 * r), r * 0.65, r * 0.55, body_col)
	draw_rect(Rect2(pos.x - r * 0.4, pos.y - r * 0.15, r * 0.8, r * 0.3), visor_col)

func _draw_icon_chopping_block(pos: Vector2, r: float, is_large: bool, affordable: bool, alpha: float) -> void:
	var tint: Color = Color(1, 1, 1, alpha) if affordable else Color(0.7, 0.7, 0.75, alpha * 0.7)
	var bark_col: Color = Color(0.44, 0.29, 0.16) * tint
	var bark_dark: Color = Color(0.28, 0.18, 0.10) * tint
	var top_col: Color = Color(0.78, 0.62, 0.42) * tint
	var ring_col: Color = Color(0.60, 0.46, 0.30) * tint

	var body_pts := PackedVector2Array([
		pos + Vector2(-r * 0.65, -r * 0.15),
		pos + Vector2(r * 0.65, -r * 0.15),
		pos + Vector2(r * 0.80, r * 0.65),
		pos + Vector2(-r * 0.80, r * 0.65)
	])
	draw_colored_polygon(body_pts, bark_col)

	draw_line(pos + Vector2(-r * 0.25, -r * 0.12), pos + Vector2(-r * 0.30, r * 0.65), bark_dark, maxf(1.0, r * 0.08))
	draw_line(pos + Vector2(r * 0.25, -r * 0.12), pos + Vector2(r * 0.30, r * 0.65), bark_dark, maxf(1.0, r * 0.08))

	_draw_ellipse(pos + Vector2(0.0, -r * 0.15), r * 0.65, r * 0.28, top_col)
	_draw_ellipse_outline(pos + Vector2(0.0, -r * 0.15), r * 0.42, r * 0.18, ring_col, maxf(1.0, r * 0.06))
	_draw_ellipse(pos + Vector2(0.0, -r * 0.15), r * 0.15, r * 0.07, ring_col)

	var blade_col: Color = Color(0.85, 0.88, 0.95) * tint
	var handle_col: Color = Color(0.55, 0.35, 0.18) * tint
	var h_start := pos + Vector2(-r * 0.08, -r * 0.15)
	var h_end := pos + Vector2(-r * 0.50, -r * 0.75)
	draw_line(h_start, h_end, handle_col, maxf(1.5, r * 0.12))
	var head_pts := PackedVector2Array([
		pos + Vector2(-r * 0.05, -r * 0.12),
		pos + Vector2(-r * 0.32, -r * 0.46),
		pos + Vector2(-r * 0.10, -r * 0.50),
		pos + Vector2(r * 0.15, -r * 0.22)
	])
	draw_colored_polygon(head_pts, blade_col)

func _draw_icon_pallet(pos: Vector2, r: float, is_large: bool, affordable: bool, alpha: float) -> void:
	var tint: Color = Color(1, 1, 1, alpha) if affordable else Color(0.7, 0.7, 0.75, alpha * 0.7)
	var wood_base: Color = Color(0.42, 0.28, 0.15) * tint
	var plank_col: Color = Color(0.72, 0.54, 0.34) * tint
	var plank_hi: Color = Color(0.84, 0.66, 0.46) * tint
	var plank_shadow: Color = Color(0.32, 0.20, 0.10) * tint
	var nail_col: Color = Color(0.25, 0.22, 0.20) * tint

	var block_w: float = r * 0.25
	var block_h: float = r * 0.28
	var by: float = pos.y + r * 0.40
	for bx_norm in [-0.75, 0.0, 0.75]:
		var bx: float = pos.x + bx_norm * r * 0.75 - block_w * 0.5
		draw_rect(Rect2(bx, by, block_w, block_h), wood_base)

	var plank_w: float = r * 1.8
	var plank_h: float = r * 0.22
	var gap: float = r * 0.08
	var total_h: float = 4.0 * plank_h + 3.0 * gap
	var start_y: float = pos.y - total_h * 0.5 - r * 0.05
	var px: float = pos.x - plank_w * 0.5

	for p in range(4):
		var py: float = start_y + float(p) * (plank_h + gap)
		draw_rect(Rect2(px, py + 1.0, plank_w, plank_h), plank_shadow)
		draw_rect(Rect2(px, py, plank_w, plank_h), plank_col)
		draw_line(Vector2(px, py), Vector2(px + plank_w, py), plank_hi, maxf(1.0, r * 0.05))
		if is_large:
			for nx in [px + r * 0.15, pos.x, px + plank_w - r * 0.15]:
				draw_circle(Vector2(nx, py + plank_h * 0.5), maxf(1.0, r * 0.04), nail_col)

func _draw_icon_chop(pos: Vector2, r: float, is_large: bool, affordable: bool, alpha: float) -> void:
	var tint: Color = Color(1, 1, 1, alpha) if affordable else Color(0.7, 0.7, 0.75, alpha * 0.7)
	var bark_col: Color = Color(0.44, 0.28, 0.16) * tint
	var bark_dark: Color = Color(0.28, 0.18, 0.10) * tint
	var bark_hi: Color = Color(0.58, 0.40, 0.24) * tint
	var cut_wood: Color = Color(0.80, 0.64, 0.44) * tint
	var cut_ring: Color = Color(0.62, 0.48, 0.32) * tint
	var cut_pith: Color = Color(0.48, 0.34, 0.20) * tint
	var handle_col: Color = Color(0.68, 0.46, 0.26) * tint
	var steel_body: Color = Color(0.52, 0.56, 0.64) * tint
	var steel_bevel: Color = Color(0.92, 0.95, 1.0) * tint
	var steel_dark: Color = Color(0.32, 0.35, 0.42) * tint

	# 1. Horizontal log base
	var log_lx: float = pos.x - r * 0.66
	var log_rx: float = pos.x + r * 0.52
	var log_y: float = pos.y + r * 0.13
	var log_h: float = r * 0.38
	var log_cy: float = log_y + log_h * 0.5

	# Log Bark cylinder
	draw_rect(Rect2(log_lx, log_y, log_rx - log_lx, log_h), bark_col)
	_draw_ellipse(Vector2(log_lx, log_cy), r * 0.10, log_h * 0.5, bark_dark)
	draw_line(Vector2(log_lx, log_y), Vector2(log_rx, log_y), bark_hi, maxf(1.0, r * 0.05))
	draw_line(Vector2(log_lx + r * 0.15, log_cy - r * 0.05), Vector2(log_lx + r * 0.42, log_cy - r * 0.05), bark_dark, maxf(1.0, r * 0.04))

	# Right log end cross-section
	_draw_ellipse(Vector2(log_rx, log_cy), r * 0.15, log_h * 0.5, cut_wood)
	_draw_ellipse_outline(Vector2(log_rx, log_cy), r * 0.09, log_h * 0.32, cut_ring, maxf(1.0, r * 0.04))
	draw_circle(Vector2(log_rx, log_cy), maxf(1.0, r * 0.04), cut_pith)

	# V-Notch cut where the axe strikes
	var notch_pts := PackedVector2Array([
		Vector2(pos.x - r * 0.14, log_y),
		Vector2(pos.x - r * 0.02, log_y + r * 0.15),
		Vector2(pos.x + r * 0.10, log_y)
	])
	draw_colored_polygon(notch_pts, cut_wood)
	draw_line(Vector2(pos.x - r * 0.14, log_y), Vector2(pos.x - r * 0.02, log_y + r * 0.15), cut_ring, maxf(1.0, r * 0.04))

	# 2. Axe Handle (angled cleanly from top-left into notch)
	var h_start := pos + Vector2(-r * 0.52, -r * 0.70)
	var h_end := pos + Vector2(r * 0.12, log_y + r * 0.12)
	draw_line(h_start, h_end, handle_col, maxf(2.0, r * 0.12))
	draw_circle(h_start, maxf(1.5, r * 0.08), handle_col * 0.85)

	# 3. Axe Head (iron axe head mounted on handle striking down)
	var p_poll_top := pos + Vector2(-r * 0.22, -r * 0.28)
	var p_poll_bot := pos + Vector2(-r * 0.26, -r * 0.19)
	var p_blade_top := pos + Vector2(r * 0.24, -r * 0.05)
	var p_blade_tip := pos + Vector2(r * 0.02, log_y + r * 0.14)
	var p_eye_bot := pos + Vector2(r * 0.04, -r * 0.02)

	var head_poly := PackedVector2Array([
		p_poll_top,
		p_blade_top,
		p_blade_tip,
		p_eye_bot,
		p_poll_bot
	])
	draw_colored_polygon(head_poly, steel_body)
	draw_line(p_poll_top, p_poll_bot, steel_dark, maxf(1.5, r * 0.10))

	# Sharpened cutting edge / bevel highlight
	var bevel_poly := PackedVector2Array([
		pos + Vector2(r * 0.13, -r * 0.07),
		p_blade_top,
		p_blade_tip,
		pos + Vector2(0.0, log_y + r * 0.04)
	])
	draw_colored_polygon(bevel_poly, steel_bevel)

	# 4. Flying wood chips from the chop impact
	var chip1 := PackedVector2Array([
		pos + Vector2(r * 0.22, r * 0.04),
		pos + Vector2(r * 0.32, r * 0.01),
		pos + Vector2(r * 0.26, r * 0.10)
	])
	draw_colored_polygon(chip1, cut_wood)

	var chip2 := PackedVector2Array([
		pos + Vector2(-r * 0.18, r * 0.04),
		pos + Vector2(-r * 0.26, 0.0),
		pos + Vector2(-r * 0.21, r * 0.10)
	])
	draw_colored_polygon(chip2, cut_wood)

func _draw_icon_dismantle(pos: Vector2, r: float, is_large: bool, affordable: bool, alpha: float) -> void:
	var tint: Color = Color(1, 1, 1, alpha)
	var tool_col: Color = Color(0.85, 0.88, 0.92) * tint
	var accent_col: Color = Color(1.0, 0.72, 0.25) * tint
	draw_line(pos + Vector2(-r * 0.65, r * 0.65), pos + Vector2(r * 0.65, -r * 0.65), tool_col, maxf(2.0, r * 0.14))
	draw_line(pos + Vector2(r * 0.65, r * 0.65), pos + Vector2(-r * 0.65, -r * 0.65), accent_col, maxf(2.0, r * 0.14))
	_draw_ellipse(pos + Vector2(r * 0.65, -r * 0.65), r * 0.25, r * 0.25, tool_col)
	draw_circle(pos + Vector2(r * 0.65, -r * 0.65), r * 0.12, Color(0.1, 0.12, 0.15, alpha))
	var h_pts := PackedVector2Array([
		pos + Vector2(-r * 0.85, -r * 0.6),
		pos + Vector2(-r * 0.45, -r * 0.8),
		pos + Vector2(-r * 0.35, -r * 0.6),
		pos + Vector2(-r * 0.75, -r * 0.4)
	])
	draw_colored_polygon(h_pts, accent_col)

func _draw_icon_block(pos: Vector2, r: float, is_stone: bool, is_large: bool, affordable: bool, alpha: float) -> void:
	var tint: Color = Color(1, 1, 1, alpha) if affordable else Color(0.7, 0.7, 0.75, alpha * 0.7)
	var top_col: Color = (Color(0.72, 0.76, 0.82) if is_stone else Color(0.35, 0.82, 0.32)) * tint
	var left_col: Color = (Color(0.52, 0.56, 0.62) if is_stone else Color(0.50, 0.34, 0.20)) * tint
	var right_col: Color = (Color(0.36, 0.39, 0.45) if is_stone else Color(0.36, 0.24, 0.14)) * tint

	var c := pos
	var p_top := c + Vector2(0.0, -r * 0.75)
	var p_mid := c + Vector2(0.0, -r * 0.05)
	var p_bot := c + Vector2(0.0, r * 0.65)
	var p_l := c + Vector2(-r * 0.7, -r * 0.4)
	var p_r := c + Vector2(r * 0.7, -r * 0.4)
	var p_bl := c + Vector2(-r * 0.7, r * 0.3)
	var p_br := c + Vector2(r * 0.7, r * 0.3)

	draw_colored_polygon(PackedVector2Array([p_top, p_r, p_mid, p_l]), top_col)
	draw_colored_polygon(PackedVector2Array([p_l, p_mid, p_bot, p_bl]), left_col)
	draw_colored_polygon(PackedVector2Array([p_mid, p_r, p_br, p_bot]), right_col)

	draw_line(p_top, p_r, Color(1, 1, 1, 0.35 * alpha), 1.0)
	draw_line(p_top, p_l, Color(1, 1, 1, 0.35 * alpha), 1.0)
	draw_line(p_l, p_mid, Color(1, 1, 1, 0.2 * alpha), 1.0)
	draw_line(p_mid, p_bot, Color(0, 0, 0, 0.3 * alpha), 1.0)

func _draw_ellipse(center: Vector2, rx: float, ry: float, color: Color, segments: int = 24) -> void:
	var pts := PackedVector2Array()
	for i in range(segments):
		var a: float = TAU * float(i) / float(segments)
		pts.append(center + Vector2(cos(a) * rx, sin(a) * ry))
	draw_colored_polygon(pts, color)

func _draw_ellipse_outline(center: Vector2, rx: float, ry: float, color: Color, width: float = 1.0, segments: int = 24) -> void:
	var pts := PackedVector2Array()
	for i in range(segments + 1):
		var a: float = TAU * float(i % segments) / float(segments)
		pts.append(center + Vector2(cos(a) * rx, sin(a) * ry))
	draw_polyline(pts, color, width, true)
