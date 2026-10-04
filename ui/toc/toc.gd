class_name TocPanel
extends Control
## Table of contents overlay: nested chapter tree + search filter + return
## point + no-save toggle. Rows live in a Tree (collapse/expand; native
## touch drag-scroll with inertia). A release without movement jumps to the
## chapter (the fold arrow only collapses); pull-down at scroll 0 — on the
## tree or below the search (Dim margins) — closes the overlay.
## TocScroll band: coarse vertical drag scrolls row by row at sensitivity.

signal chapter_selected(seq: int)
signal close_requested
signal return_requested
signal save_toggle_requested

const CURRENT_COLOR := Color(1.0, 0.84, 0.2, 1.0)  # gold: current chapter
const DRAG_THRESHOLD := 8.0      # px before a press becomes a scroll drag
const SCROLL_SENSITIVITY := 4.0  # TocScroll band: drag px → scroll px
const ROW_STEP := 56.0           # band px per row step (≈ tree row pitch)
const DISMISS_THRESHOLD := 80.0  # px of pull-down to dismiss

@onready var _dim: ColorRect = %Dim
@onready var _close_button: Button = %CloseButton
@onready var _save_button: Button = %SaveToggleButton
@onready var _tree: Tree = %Tree
@onready var _return_button: Button = %ReturnButton
@onready var _search: LineEdit = %Search
@onready var _toc_scroll: Control = %TocScroll

# Release-based jump: the Tree selects/collapses at PRESS, so we act at
# release against the press snapshot (a fold toggle then reads as "not a
# tap"). The gui_input signal fires before the Tree consumes the event.
var _drag_moved := false
var _press_pos := Vector2.ZERO
var _press_item: TreeItem = null
var _press_item_collapsed := false
var _press_scroll_y := 0.0

# TocScroll band: row-by-row scroll pointer (persists across gestures).
var _band_item: TreeItem = null
var _band_steps := 0
var _band_dragging := false
var _band_start := Vector2.ZERO

# Dim pull-down dismiss (tap closes on release without movement).
var _dim_pressed := false
var _dim_moved := false
var _dim_start := Vector2.ZERO

# Built rows (pre-order) for search/filter; _current_item = gold row.
var _all_items: Array[TreeItem] = []
var _all_depths: Array[int] = []
var _all_titles: Array[String] = []
var _current_item: TreeItem = null


func _ready() -> void:
	_dim.gui_input.connect(_on_dim_input)
	_close_button.pressed.connect(func() -> void: close_requested.emit())
	_save_button.pressed.connect(func() -> void: save_toggle_requested.emit())
	_return_button.pressed.connect(func() -> void: return_requested.emit())
	_search.text_changed.connect(_on_search_changed)
	_tree.gui_input.connect(_on_tree_input)
	_toc_scroll.gui_input.connect(_on_toc_scroll_gui_input)


func open(
	entries: Array[Dictionary], current_seq: int, return_text: String, save_on: bool
) -> void:
	_drag_moved = false
	_press_item = null
	_dim_pressed = false
	_dim_moved = false
	_band_dragging = false
	_rebuild(entries, current_seq)
	_search.text = ""
	_return_button.visible = not return_text.is_empty()
	_return_button.text = return_text
	set_save_state(save_on)
	visible = true
	if _current_item != null:
		# One frame late: the rows need their final layout.
		_tree.call_deferred("scroll_to_item", _current_item, true)


func close() -> void:
	visible = false
	_search.text = ""


func is_open() -> bool:
	return visible


func set_save_state(save_on: bool) -> void:
	_save_button.text = "Save position: ON" if save_on else "Save position: OFF"


func _rebuild(entries: Array[Dictionary], current_seq: int) -> void:
	_tree.clear()
	_all_items.clear()
	_all_depths.clear()
	_all_titles.clear()
	_current_item = null
	var root := _tree.create_item()  # invisible (hide_root)
	var stack: Array[TreeItem] = [root]
	for entry: Dictionary in entries:
		var seq := int(entry.get("seq", -1))
		var title := str(entry.get("title", ""))  # display-ready from Db.get_toc
		if title.is_empty():
			title = "—"
		# Pre-order: depth never jumps by more than 1; clamp malformed rows.
		var depth := clampi(int(entry.get("depth", 0)), 0, stack.size() - 1)
		var item := _tree.create_item(stack[depth])
		item.set_text(0, title)
		item.set_metadata(0, seq)
		if seq == current_seq:
			item.set_custom_color(0, CURRENT_COLOR)
			_current_item = item
		stack.resize(depth + 1)
		stack.append(item)
		_all_items.append(item)
		_all_depths.append(depth)
		_all_titles.append(title)
	_apply_collapse_default()
	_band_item = _current_item if _current_item != null else null
	if _band_item == null and not _all_items.is_empty():
		_band_item = _all_items[0]


## Default view: top-level rows only (parents collapsed), except the path
## down to the current chapter.
func _apply_collapse_default() -> void:
	for item: TreeItem in _all_items:
		if item.get_child_count() > 0:
			item.collapsed = true
	if _current_item == null:
		return
	var parent := _current_item.get_parent()
	while parent != null and parent != _tree.get_root():
		parent.collapsed = false
		parent = parent.get_parent()


## Press snapshot + pull-down dismiss. The Tree itself does the native
## drag-scroll (touch + inertia, 1:1); we only track it for the tap guard.
func _on_tree_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_drag_moved = false
			_press_pos = event.position
			_press_item = _tree.get_item_at_position(event.position)
			_press_item_collapsed = (
				_press_item.collapsed if _press_item != null else false
			)
			_press_scroll_y = _tree.get_scroll().y
		else:
			_finish_tree_tap(event.position)
		return
	if event is InputEventMouseMotion and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
		var dx: float = event.position.x - _press_pos.x
		var dy: float = event.position.y - _press_pos.y
		if _press_scroll_y <= 0.0 and dy > DISMISS_THRESHOLD:
			_drag_moved = true  # swallow the pending release tap
			close_requested.emit()
			return
		if absf(dx) > DRAG_THRESHOLD or absf(dy) > DRAG_THRESHOLD:
			_drag_moved = true


## Release without movement: jump to the pressed row. The fold arrow flips
## collapsed at PRESS → detected here; a tap below the rows closes.
func _finish_tree_tap(release_pos: Vector2) -> void:
	if _drag_moved:
		_drag_moved = false
		return
	if _press_item == null:
		close_requested.emit()  # tap below the rows (old fall-through)
		return
	if _tree.get_item_at_position(release_pos) != _press_item:
		return  # slid off the row: not a tap
	if _press_item.collapsed != _press_item_collapsed:
		return  # the fold arrow handled this press
	chapter_selected.emit(int(_press_item.get_metadata(0)))


## Vertical drag on the TocScroll band scrolls the tree row by row
## (SCROLL_SENSITIVITY px of drag = one ROW_STEP of scroll).
func _on_toc_scroll_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_band_dragging = true
			_band_start = event.position
			_band_steps = 0
		else:
			_band_dragging = false
		return
	if _band_dragging and event is InputEventMouseMotion \
			and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
		var scrolled: float = (_band_start.y - event.position.y) * SCROLL_SENSITIVITY
		var target_steps := int(scrolled / ROW_STEP)
		while _band_steps != target_steps:
			var dir := 1 if target_steps > _band_steps else -1
			_band_steps += dir
			_step_band(dir)


## Move the band pointer one visible row and follow it with the view.
func _step_band(dir: int) -> void:
	if _band_item == null:
		return
	var next: TreeItem = (
		_band_item.get_next_visible() if dir > 0 else _band_item.get_prev_visible()
	)
	if next == null:
		return
	_band_item = next
	_tree.scroll_to_item(_band_item, false)


## Dim: tap (release, no movement) closes; pull-down ≥ threshold closes.
## The Panel margins (incl. below the search) fall through to the Dim.
func _on_dim_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_dim_pressed = true
			_dim_moved = false
			_dim_start = event.position
		elif _dim_pressed:
			_dim_pressed = false
			if not _dim_moved:
				close_requested.emit()
	elif event is InputEventMouseMotion and _dim_pressed \
			and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
		if event.position.distance_to(_dim_start) > DRAG_THRESHOLD:
			_dim_moved = true
		var dy: float = event.position.y - _dim_start.y
		if dy > DISMISS_THRESHOLD:
			_dim_pressed = false
			close_requested.emit()


func _on_search_changed(new_text: String) -> void:
	_apply_filter(new_text)


## Filter rows by title; matches keep their ancestors visible and unfold the
## path. Clearing restores the default collapse state.
func _apply_filter(query: String) -> void:
	var n := _all_items.size()
	if n == 0:
		return
	if query.is_empty():
		for i in n:
			_all_items[i].visible = true
		_apply_collapse_default()
		return
	var show: Array[bool] = []
	show.resize(n)
	for i in n:
		show[i] = _all_titles[i].findn(query) != -1
	# A match keeps its ancestors on screen (backward pass: depth ≤ prev + 1).
	for i in range(n - 1, -1, -1):
		if show[i] and _all_depths[i] > 0:
			for j in range(i - 1, -1, -1):
				if _all_depths[j] == _all_depths[i] - 1:
					show[j] = true
					break
	for i in n:
		var item := _all_items[i]
		item.visible = show[i]
		if show[i]:
			item.collapsed = false  # reveal matches inside shown parents
