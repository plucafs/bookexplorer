extends Control
## Library: scrollable strip at the bottom with all books (tap = open,
## the last opened stays leftmost thanks to Db.touch_book).
## The carousel is kept but hidden (visible=false): code intact,
## re-enable by toggling visibility and hiding %Strip.

signal open_epub_requested
signal book_selected(book_id: String)
signal feed_requested
signal bookmarks_requested(book_id: String)

const ITEM_SCENE := preload("res://ui/library/library_item.tscn")

const SWIPE_THRESHOLD := 80.0  # min px to change book
const TAP_MAX_MOVE := 15.0     # max movement still counted as a tap
const SLIDE_DURATION := 0.28
const SCALE_SIDE := 0.65
const ALPHA_SIDE := 0.55
const CENTER_SIZE := Vector2(260, 400)
const SIDE_SIZE := Vector2(200, 310)
const STRIP_ITEM_SIZE := Vector2(170, 260)  # item size in the bottom strip
const STRIP_DRAG_THRESHOLD := 8.0  # px before a press on an item becomes a scroll drag
const DELETE_INDEX := 0  # "Delete" button in the native dialog

@onready var _open_button: Button = %OpenButton
@onready var _feed_button: Button = %FeedButton
@onready var _empty_label: Label = %EmptyLabel
@onready var _carousel: Control = %Carousel
@onready var _book_left: Button = %BookLeft
@onready var _book_center: Button = %BookCenter
@onready var _book_right: Button = %BookRight
@onready var _swipe_hint: Label = %SwipeHint
@onready var _strip: MarginContainer = %Strip
@onready var _scroll: ScrollContainer = %Scroll
@onready var _book_row: HBoxContainer = %BookRow
@onready var _confirm_dialog: ConfirmationDialog = %ConfirmDialog

var _books: Array[Dictionary] = []
var _center_index := 0

# Slot positions (computed in _compute_slots)
var _slot_center := Vector2.ZERO
var _slot_left := Vector2.ZERO
var _slot_right := Vector2.ZERO
var _slot_far_left := Vector2.ZERO
var _slot_far_right := Vector2.ZERO

# Node refs per slot: they rotate on every swipe
var _node_left: Button
var _node_center: Button
var _node_right: Button

# Drag state
var _dragging := false
var _drag_start := Vector2.ZERO
var _drag_delta := Vector2.ZERO
var _is_animating := false

var _pending_delete_id := ""

# Strip drag-to-scroll state (the items are Buttons: they swallow the events
# the ScrollContainer would need, so we scroll it by hand).
var _strip_drag_moved := false
var _strip_drag_start := Vector2.ZERO  # global press position
var _strip_drag_scroll0 := 0


func _ready() -> void:
	_open_button.pressed.connect(func() -> void: open_epub_requested.emit())
	_feed_button.pressed.connect(func() -> void: feed_requested.emit())
	_confirm_dialog.confirmed.connect(_on_confirm_dialog_confirmed)
	_node_left = _book_left
	_node_center = _book_center
	_node_right = _book_right
	_book_left.delete_requested.connect(_on_delete_button_pressed.bind(_book_left))
	_book_center.delete_requested.connect(_on_delete_button_pressed.bind(_book_center))
	_book_right.delete_requested.connect(_on_delete_button_pressed.bind(_book_right))
	_book_left.bookmarks_requested.connect(_on_carousel_bookmarks_pressed.bind(_book_left))
	_book_center.bookmarks_requested.connect(_on_carousel_bookmarks_pressed.bind(_book_center))
	_book_right.bookmarks_requested.connect(_on_carousel_bookmarks_pressed.bind(_book_right))
	_compute_slots()
	_carousel.gui_input.connect(_on_carousel_input)


func _notification(what: int) -> void:
	# Arrives also before _ready: the @onready vars may still be null.
	if not is_node_ready():
		return
	if what == NOTIFICATION_RESIZED or what == NOTIFICATION_VISIBILITY_CHANGED:
		_compute_slots()
		# The carousel layout settles late: re-place the nodes
		# (otherwise the new slots only live in the variables).
		# During a swipe the resize is ignored: _finish_swipe re-renders.
		if not _books.is_empty() and not _is_animating:
			_render_carousel()


## Reload the library (call every time it is entered).
func refresh(books: Array[Dictionary]) -> void:
	_books = books.duplicate()
	_center_index = 0
	_node_left = _book_left
	_node_center = _book_center
	_node_right = _book_right
	_is_animating = false
	_dragging = false
	_compute_slots()
	_render_carousel()  # refresh the hidden carousel nodes (code kept)
	_render_strip()


func _compute_slots() -> void:
	var size := _carousel.size
	if size.x <= 0.0 or size.y <= 0.0:
		return
	# Slot = visual CENTERS; placement subtracts size/2 in _place/_pos_for.
	var center := size / 2.0
	_slot_center = center + Vector2(0.0, -20.0)  # slightly above center for the hint
	_slot_left = _slot_center + Vector2(-230.0, 0.0)
	_slot_right = _slot_center + Vector2(230.0, 0.0)
	_slot_far_left = _slot_center + Vector2(-600.0, 0.0)
	_slot_far_right = _slot_center + Vector2(600.0, 0.0)


## Top-left position so the visual center (of box `box`) lands on `slot`.
func _pos_for_slot(slot: Vector2, box: Vector2) -> Vector2:
	return slot - box / 2.0


## Like _pos_for_slot but with the node's current size (pivot at center:
## scale does not move the barycenter).
func _pos_for(node: Control, slot: Vector2) -> Vector2:
	node.pivot_offset = node.size / 2.0
	return _pos_for_slot(slot, node.size)


func _place(node: Control, slot: Vector2) -> void:
	node.position = _pos_for(node, slot)


func _render_carousel() -> void:
	var n := _books.size()
	_empty_label.visible = n == 0
	# The carousel hint must not show while the carousel itself is hidden.
	_swipe_hint.visible = n > 1 and _carousel.visible
	_feed_button.visible = n > 0

	if n == 0:
		_book_left.visible = false
		_book_center.visible = false
		_book_right.visible = false
		return

	# Center
	_book_center.visible = true
	_setup_node(_node_center, _center_index, true)
	_place(_node_center, _slot_center)
	_node_center.scale = Vector2.ONE
	_node_center.modulate = Color.WHITE

	# Left
	if _center_index > 0:
		_setup_node(_node_left, _center_index - 1, false)
		_place(_node_left, _slot_left)
		_node_left.scale = Vector2(SCALE_SIDE, SCALE_SIDE)
		_node_left.modulate = Color(1, 1, 1, ALPHA_SIDE)
	else:
		_book_left.visible = false
		_book_left.set_delete_enabled(false)

	# Right
	if _center_index < n - 1:
		_setup_node(_node_right, _center_index + 1, false)
		_place(_node_right, _slot_right)
		_node_right.scale = Vector2(SCALE_SIDE, SCALE_SIDE)
		_node_right.modulate = Color(1, 1, 1, ALPHA_SIDE)
	else:
		_book_right.visible = false
		_book_right.set_delete_enabled(false)


func _setup_node(node: Button, index: int, is_center: bool) -> void:
	if index < 0 or index >= _books.size():
		node.visible = false
		return
	node.visible = true
	node.setup(_books[index])
	node.set_delete_enabled(is_center)
	node.set_star_visible(int(_books[index].get("bookmark_count", 0)) > 0)
	# Size per role: nodes rotate, the role (not the node) defines the box.
	var box := CENTER_SIZE if is_center else SIDE_SIZE
	node.custom_minimum_size = box
	if node.size != box:
		node.size = box
	node.pivot_offset = node.size / 2.0


## Bottom strip: all books in a scrollable row.
## Order = get_books() → last opened (Db.touch_book) is first, on the left.
func _render_strip() -> void:
	for child in _book_row.get_children():
		child.free()
	_strip.visible = not _books.is_empty()
	_scroll.scroll_horizontal = 0  # back to the left (most recent book)
	for book: Dictionary in _books:
		var item := ITEM_SCENE.instantiate() as Button
		var book_id := str(book["id"])
		item.pressed.connect(_on_strip_item_pressed.bind(book_id))
		item.gui_input.connect(_on_strip_item_gui_input.bind(item))
		item.delete_requested.connect(_on_delete_requested.bind(book_id))
		item.bookmarks_requested.connect(_on_strip_bookmarks_requested.bind(book_id))
		_book_row.add_child(item)  # add_child first: setup uses the @onready vars
		item.custom_minimum_size = STRIP_ITEM_SIZE
		item.setup(book)
		item.set_delete_enabled(true)  # X visible on every book in the row
		item.set_star_visible(int(book.get("bookmark_count", 0)) > 0)


func _on_strip_item_pressed(book_id: String) -> void:
	# A release after a drag must not open the book (BaseButton emits
	# pressed right after our gui_input handler on the release event).
	if _strip_drag_moved:
		_strip_drag_moved = false
		return
	book_selected.emit(book_id)


func _on_strip_bookmarks_requested(book_id: String) -> void:
	bookmarks_requested.emit(book_id)


func _on_carousel_bookmarks_pressed(node: Button) -> void:
	var idx := _index_of_node(node)
	if idx >= 0:
		bookmarks_requested.emit(str(_books[idx]["id"]))


## Drag on a strip item scrolls the row horizontally.
## Positions are converted to GLOBAL space: the item origin moves while we
## scroll, so local deltas would be eaten by the feedback (absolute model).
func _on_strip_item_gui_input(event: InputEvent, item: Button) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_strip_drag_moved = false
			_strip_drag_start = item.get_global_transform() * event.position
			_strip_drag_scroll0 = _scroll.scroll_horizontal
		# On release keep the flag: _on_strip_item_pressed swallows it.
		return
	if event is InputEventMouseMotion and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
		var global_pos: Vector2 = item.get_global_transform() * event.position
		var dx := global_pos.x - _strip_drag_start.x
		if absf(dx) > STRIP_DRAG_THRESHOLD:
			_strip_drag_moved = true
			_scroll.scroll_horizontal = _strip_drag_scroll0 - int(dx)


## Carousel input: horizontal drag + tap.
func _on_carousel_input(event: InputEvent) -> void:
	if _is_animating:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_dragging = true
			_drag_start = event.position
			_drag_delta = Vector2.ZERO
		elif _dragging:
			_dragging = false
			_drag_delta = event.position - _drag_start
			_handle_release()
	elif event is InputEventMouseMotion and _dragging:
		_drag_delta = event.position - _drag_start


func _handle_release() -> void:
	var dx := _drag_delta.x
	var dy := _drag_delta.y

	# Horizontal swipe
	if absf(dx) >= SWIPE_THRESHOLD and absf(dx) > absf(dy):
		# finger left (dx<0) → next; finger right (dx>0) → previous
		_swipe_to(1 if dx < 0.0 else -1)
		return

	# Tap (little movement)
	if absf(dx) <= TAP_MAX_MOVE and absf(dy) <= TAP_MAX_MOVE:
		_handle_tap(_drag_start)
		return

	# Vertical swipe or too short: snap back to position
	_snap_back()


func _handle_tap(pos: Vector2) -> void:
	# Control (4.7) has no to_global: transform with Transform2D.
	var global_pos: Vector2 = _carousel.get_global_transform() * pos
	# Hit-test: which book was touched?
	if _book_center.visible and _node_center.get_global_rect().has_point(global_pos):
		if _center_index >= 0 and _center_index < _books.size():
			book_selected.emit(str(_books[_center_index]["id"]))
		return
	if _book_left.visible and _node_left.get_global_rect().has_point(global_pos):
		_swipe_to(-1)
		return
	if _book_right.visible and _node_right.get_global_rect().has_point(global_pos):
		_swipe_to(1)
		return


## Swipe of ±1 position with a scrolling animation.
func _swipe_to(delta: int) -> void:
	var new_index := _center_index + delta
	if new_index < 0 or new_index >= _books.size():
		_snap_back()
		return

	_is_animating = true

	# Exiting node: refresh with the new book (index beyond) and move it off
	var exiting: Button
	var entering_slot: Vector2
	var far_slot: Vector2
	if delta > 0:  # toward next: left exits left, right enters from right
		exiting = _node_left
		entering_slot = _slot_right
		far_slot = _slot_far_right
	else:  # toward prev: right exits right, left enters from left
		exiting = _node_right
		entering_slot = _slot_left
		far_slot = _slot_far_left

	var entering_index := new_index + delta  # the book beyond the new center
	_setup_node(exiting, entering_index, false)
	_place(exiting, far_slot)
	exiting.scale = Vector2(SCALE_SIDE, SCALE_SIDE)
	exiting.modulate = Color(1, 1, 1, ALPHA_SIDE)

	# Destination slot for each current node
	var dest_center: Vector2
	var dest_side: Vector2  # where the node that is neither exiting nor center goes
	if delta > 0:
		dest_center = _slot_left       # center → left
		dest_side = _slot_center        # right → center
	else:
		dest_center = _slot_right       # center → right
		dest_side = _slot_center        # left → center

	var other := _node_right if delta > 0 else _node_left

	var tween := create_tween().bind_node(self).set_parallel(true)
	# Target with the DESTINATION ROLE size (the size snaps at final render).
	tween.tween_property(_node_center, "position",
			_pos_for_slot(dest_center, SIDE_SIZE), SLIDE_DURATION) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(_node_center, "scale", Vector2(SCALE_SIDE, SCALE_SIDE), SLIDE_DURATION) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(_node_center, "modulate", Color(1, 1, 1, ALPHA_SIDE), SLIDE_DURATION)

	tween.tween_property(other, "position",
			_pos_for_slot(dest_side, CENTER_SIZE), SLIDE_DURATION) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(other, "scale", Vector2.ONE, SLIDE_DURATION) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(other, "modulate", Color.WHITE, SLIDE_DURATION)

	tween.tween_property(exiting, "position",
			_pos_for_slot(entering_slot, SIDE_SIZE), SLIDE_DURATION) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	# exiting stays at side scale/alpha (it is the new side)

	tween.chain().tween_callback(_finish_swipe.bind(delta))


func _finish_swipe(delta: int) -> void:
	_center_index += delta

	# Rotate the refs: a node in one role moves to the new one
	var old_left := _node_left
	var old_center := _node_center
	var old_right := _node_right
	if delta > 0:
		# left exits → becomes right; center → left; right → center
		_node_left = old_center
		_node_center = old_right
		_node_right = old_left
	else:
		# right exits → becomes left; center → right; left → center
		_node_right = old_center
		_node_center = old_left
		_node_left = old_right

	_is_animating = false
	_render_carousel()


func _snap_back() -> void:
	# Back to base positions without changing index
	if _is_animating:
		return
	_render_carousel()


# --- Delete ---

func _on_delete_button_pressed(node: Button) -> void:
	var idx := _index_of_node(node)
	if idx >= 0:
		_on_delete_requested(str(_books[idx]["id"]))


func _index_of_node(node: Button) -> int:
	if node == _node_center:
		return _center_index
	if node == _node_left:
		return _center_index - 1
	if node == _node_right:
		return _center_index + 1
	return -1


func _on_delete_requested(book_id: String) -> void:
	_pending_delete_id = book_id
	var title := _title_of(book_id)
	var message := "Delete \"%s\" and all of its paragraphs?" % title
	if DisplayServer.has_feature(DisplayServer.FEATURE_NATIVE_DIALOG):
		var err := DisplayServer.dialog_show(
			"Delete book",
			message,
			PackedStringArray(["Delete", "Cancel"]),
			_on_native_dialog_result
		)
		if err == OK:
			return
		push_warning("library: native dialog unavailable (%d), falling back" % err)
	# Fallback (desktop/headless): in-scene dialog
	_confirm_dialog.dialog_text = message
	_confirm_dialog.popup_centered()


func _on_native_dialog_result(index: int) -> void:
	if index == DELETE_INDEX:
		_delete_pending()
	else:
		_pending_delete_id = ""


func _on_confirm_dialog_confirmed() -> void:
	_delete_pending()


func _delete_pending() -> void:
	if _pending_delete_id.is_empty():
		return
	var book_id := _pending_delete_id
	_pending_delete_id = ""
	if not Db.delete_book(book_id):
		push_error("library: deletion failed for '%s'" % book_id)
		return
	refresh(Db.get_books())


func _title_of(book_id: String) -> String:
	for book: Dictionary in _books:
		if str(book.get("id", "")) == book_id:
			return str(book.get("title", book_id))
	return book_id
