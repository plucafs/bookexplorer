class_name TocPanel
extends Control
## Table of contents overlay: chapter list + search filter + return point
## + no-save toggle. The list drags to scroll (items are Buttons and would
## swallow the ScrollContainer events); pull-down at scroll 0 — on the list
## or below the search (Dim margins) — closes the overlay.

signal chapter_selected(seq: int)
signal close_requested
signal return_requested
signal save_toggle_requested

const ITEM_SCENE := preload("res://ui/toc/toc_item.tscn")
const CURRENT_COLOR := Color(1.0, 0.84, 0.2, 1.0)  # gold: current chapter
const DRAG_THRESHOLD := 8.0      # px before a press becomes a scroll drag
const SCROLL_SENSITIVITY := 4.0  # drag px → scroll px (>1 faster; keep in sync with library.gd)
const DISMISS_THRESHOLD := 80.0  # px of pull-down to dismiss

@onready var _dim: ColorRect = %Dim
@onready var _close_button: Button = %CloseButton
@onready var _save_button: Button = %SaveToggleButton
@onready var _scroll: ScrollContainer = %Scroll
@onready var _list: VBoxContainer = %List
@onready var _return_button: Button = %ReturnButton
@onready var _search: LineEdit = %Search
@onready var _toc_scroll: Control = %TocScroll

# List drag-to-scroll state (absolute model in global coords).
# _drag_start/_drag_scroll0 = the original press (threshold + pull-down dismiss);
# _drag_anchor/_drag_anchor0 = re-anchored at an edge so reversing the finger
# responds at once (same dead-zone fix as the library strip).
var _drag_moved := false
var _drag_start := Vector2.ZERO
var _drag_scroll0 := 0
var _drag_anchor := Vector2.ZERO
var _drag_anchor0 := 0

# TocScroll drag: vertical drags on the band under the list scroll it
# (absolute model; the node itself never moves). Same UX as LibraryScroll.
var _toc_drag_on := false
var _toc_drag_start := Vector2.ZERO  # local press position
var _toc_drag_scroll0 := 0

# Dim pull-down dismiss (tap closes on release without movement).
var _dim_pressed := false
var _dim_moved := false
var _dim_start := Vector2.ZERO


func _ready() -> void:
	_dim.gui_input.connect(_on_dim_input)
	_close_button.pressed.connect(func() -> void: close_requested.emit())
	_save_button.pressed.connect(func() -> void: save_toggle_requested.emit())
	_return_button.pressed.connect(func() -> void: return_requested.emit())
	_search.text_changed.connect(_on_search_changed)
	_toc_scroll.gui_input.connect(_on_toc_scroll_gui_input)


func open(
	entries: Array[Dictionary], current_seq: int, return_text: String, save_on: bool
) -> void:
	_drag_moved = false
	_dim_pressed = false
	_dim_moved = false
	_toc_drag_on = false
	_rebuild(entries, current_seq)
	_search.text = ""
	_scroll.scroll_vertical = 0
	_return_button.visible = not return_text.is_empty()
	_return_button.text = return_text
	set_save_state(save_on)
	visible = true


func close() -> void:
	visible = false
	_search.text = ""


func is_open() -> bool:
	return visible


func set_save_state(save_on: bool) -> void:
	_save_button.text = "Save position: ON" if save_on else "Save position: OFF"


func _rebuild(entries: Array[Dictionary], current_seq: int) -> void:
	for child in _list.get_children():
		child.free()
	for entry: Dictionary in entries:
		var seq := int(entry.get("seq", -1))
		var display := str(entry.get("title", ""))  # display-ready from Db.get_toc
		if display.is_empty():
			display = "—"
		var item := ITEM_SCENE.instantiate() as Button
		item.text = display
		item.gui_input.connect(_on_item_input.bind(item))
		item.pressed.connect(_on_item_pressed.bind(seq))
		_list.add_child(item)
		if seq == current_seq:
			item.add_theme_color_override("font_color", CURRENT_COLOR)


## Guarded selection: a release after a drag must not jump to a chapter.
func _on_item_pressed(seq: int) -> void:
	if _drag_moved:
		_drag_moved = false
		return
	chapter_selected.emit(seq)


## Drag on a list item scrolls the list; pull-down at the top dismisses.
func _on_item_input(event: InputEvent, item: Button) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_drag_moved = false
			_drag_start = item.get_global_transform() * event.position
			_drag_scroll0 = _scroll.scroll_vertical
			_drag_anchor = _drag_start
			_drag_anchor0 = _drag_scroll0
		# On release keep the flag: _on_item_pressed swallows it.
		return
	if event is InputEventMouseMotion and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
		var global_pos: Vector2 = item.get_global_transform() * event.position
		var dy := global_pos.y - _drag_start.y
		if _drag_scroll0 <= 0 and dy > DISMISS_THRESHOLD:
			_drag_moved = true  # swallow the release tap if it still lands on us
			close_requested.emit()
			return
		if absf(dy) > DRAG_THRESHOLD:
			_drag_moved = true
			var target := _drag_anchor0 - int(
				(global_pos.y - _drag_anchor.y) * SCROLL_SENSITIVITY
			)
			_scroll.scroll_vertical = target
			var actual := _scroll.scroll_vertical
			if actual != target:
				# Edge hit: re-anchor, else the whole travelled distance past
				# the edge would be a dead zone (dismiss keeps the original dy).
				_drag_anchor = global_pos
				_drag_anchor0 = actual


## Vertical drag on the TocScroll band (under the list) scrolls the list:
## finger down → dy > 0 → scroll value drops → the chapters slide down,
## following the finger. Same absolute model + edge re-anchor as LibraryScroll.
func _on_toc_scroll_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_toc_drag_on = true
			_toc_drag_start = event.position
			_toc_drag_scroll0 = _scroll.scroll_vertical
		else:
			_toc_drag_on = false
		return
	if _toc_drag_on and event is InputEventMouseMotion \
			and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
		var dy: float = event.position.y - _toc_drag_start.y
		var target := _toc_drag_scroll0 - int(dy * SCROLL_SENSITIVITY)
		_scroll.scroll_vertical = target
		var actual := _scroll.scroll_vertical
		if actual != target:
			# Edge hit: re-anchor, else the whole travelled distance past the
			# end would be a dead zone and reversing the finger feels stuck.
			_toc_drag_scroll0 = actual
			_toc_drag_start.y = event.position.y


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


func _apply_filter(query: String) -> void:
	for child in _list.get_children():
		var item := child as Button
		if item == null:
			continue
		item.visible = query.is_empty() or item.text.findn(query) != -1
