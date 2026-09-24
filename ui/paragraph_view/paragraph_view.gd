extends Control
## Full-paragraph view: scrollable text, swipe right (or Esc/back) to close.
## Swipe detection in _input: only the dominant horizontal axis is consumed,
## the vertical one passes to the ScrollContainer.

signal closed

const SLIDE_DURATION := 0.28
const SWIPE_RIGHT_THRESHOLD := 120.0

@onready var _scroll: ScrollContainer = %Scroll
@onready var _text_label: Label = %FullTextLabel
@onready var _chapter_label: Label = %ChapterLabel
@onready var _counter_label: Label = %CounterLabel
@onready var _back_button: Button = %BackButton

var _tween: Tween = null
var _closing := false
var _dragging := false
var _drag_start := Vector2.ZERO


func _ready() -> void:
	_back_button.pressed.connect(close)


## Opens the view with the full paragraph text.
func open(text: String, chapter: String, counter: String) -> void:
	_text_label.text = text
	_chapter_label.text = chapter
	_counter_label.text = counter
	_dragging = false
	_closing = false
	_kill_tween()
	visible = true
	_scroll.scroll_vertical = 0
	position.x = size.x
	_tween = create_tween().bind_node(self)
	_tween.tween_property(self, "position:x", 0.0, SLIDE_DURATION) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.finished.connect(func() -> void: _tween = null)


## Closes with a rightward slide and emits `closed`.
func close() -> void:
	if not visible or _closing:
		return
	_closing = true
	_dragging = false
	_kill_tween()
	_tween = create_tween().bind_node(self)
	_tween.tween_property(self, "position:x", size.x, SLIDE_DURATION) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.finished.connect(_on_closed)


## Instant close (reset when the reader reopens).
func reset() -> void:
	_kill_tween()
	_closing = false
	_dragging = false
	visible = false
	position = Vector2.ZERO


func is_open() -> bool:
	return visible


func _input(event: InputEvent) -> void:
	if not visible or _closing:
		return
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		close()
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_dragging = true
			_drag_start = event.position
		elif _dragging:
			_dragging = false
			_try_close(event.position)
		return
	if event is InputEventScreenTouch:
		if event.pressed:
			_dragging = true
			_drag_start = event.position
		elif _dragging:
			_dragging = false
			_try_close(event.position)


func _try_close(end_pos: Vector2) -> void:
	var delta := end_pos - _drag_start
	if delta.x > SWIPE_RIGHT_THRESHOLD and absf(delta.x) > absf(delta.y):
		get_viewport().set_input_as_handled()
		close()


func _on_closed() -> void:
	_tween = null
	_closing = false
	visible = false
	position = Vector2.ZERO
	closed.emit()


func _kill_tween() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = null
