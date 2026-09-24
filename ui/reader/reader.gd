extends Control
## Reading feed: one paragraph per screen, vertical swipe with slide.
## A/B panels outside the Containers (positions animated by the Tween).
## Long paragraph: text scrolls in place (TextViewport with clip); when the
## drag passes HANDOFF_MIN beyond the text edge, it moves to the next/prev
## paragraph with the classic slide. Tap: no action.

signal exit_requested
signal library_requested

const SLIDE_DURATION := 0.28
const SWIPE_THRESHOLD := 100.0   # logical px to change paragraph (short text)
const DRAG_RESISTANCE := 0.35    # resistance at the edges (0 / N-1)
const HANDOFF_MIN := 40.0        # px past the text edge to change paragraph
const WHEEL_STEP := 80.0         # px per wheel step
const TAP_MAX_MOVE := 15.0       # max movement for a gesture to count as a tap
const DOUBLE_TAP_MS := 300       # double-tap window
const MULTI_JUMP := 10           # paragraphs skipped by the two-finger gesture
const MULTI_JUMP_ENABLED := false  # two-finger swipe jump: code kept, disabled
const HOLD_MS := 450             # still press to trigger auto-scroll
const AUTO_SCROLL_SPEED := 40.0  # px/s of auto-scroll (hold)
const PINCH_THRESHOLD := 60.0    # px of finger-distance change to fire a pinch

@onready var _cover_bg: TextureRect = %CoverBg
@onready var _panel_a: Control = %TextPanelA
@onready var _panel_b: Control = %TextPanelB
@onready var _text_a: Label = %TextLabelA
@onready var _text_b: Label = %TextLabelB
@onready var _chapter_label: Label = %ChapterLabel
@onready var _counter_label: Label = %CounterLabel
@onready var _progress_bar: ProgressBar = %ProgressBar

var _book: Dictionary = {}
var _paragraphs: Array[Dictionary] = []
var _seq: int = 0

# Bookmark browsing + peek (pinch-open shows context without moving last_seq).
var _bookmark_mode := false
var _peek := false
var _bookmark_paragraphs: Array[Dictionary] = []
var _all_paragraphs: Array[Dictionary] = []
var _bookmark_return_seq := 0

# Pinch state: per-finger positions (index → pos) for distance tracking.
var _finger_pos: Dictionary = {}
var _pinch_base_dist := 0.0
var _pinch_consumed := false

var _cover_cached: ImageTexture = null
var _cover_book_id := ""

var _active_panel: Control
var _idle_panel: Control
var _active_text: Label
var _idle_text: Label

var _tween: Tween = null
var _dragging := false
var _drag_start := Vector2.ZERO
var _drag_delta := Vector2.ZERO
var _drag_start_scroll := 0.0  # text scroll at gesture start
var _over_drag := 0.0          # leftover past the text edge (for the handoff)
var _last_tap_msec := -1000000  # last single tap (double tap → library)
var _touch_count := 0           # active fingers (InputEventScreenTouch)
var _multi_gesture := false     # two-finger gesture in progress
var _multi_dx := 0.0            # accumulated dx of the multi gesture
var _feed_mode := false         # random feed: fetch at end of history, no last_seq
var _feed_last_id := -1         # id of last shown paragraph (anti-repeat)
var _finger_down := false       # finger down (for the hold)
var _hold_start_msec := -1      # when the finger landed (hold)
var _hold_armed := false        # auto-scroll running
var _hold_consumed := false     # the hold fired: release is not a tap


## Call from main.gd every time the reader is entered.
func setup(book: Dictionary, paragraphs: Array[Dictionary]) -> void:
	_book = book
	_paragraphs = paragraphs
	_feed_mode = false
	_feed_last_id = -1
	_bookmark_mode = false
	_peek = false
	_bookmark_paragraphs.clear()
	_all_paragraphs = paragraphs
	if _paragraphs.is_empty():
		push_error("reader.setup: no paragraphs for the book")
		return
	_reset_panels()
	var seq_key := Db.seq_key(str(_book.get("id", "")))
	_seq = clampi(int(Db.get_setting(seq_key)), 0, _paragraphs.size() - 1)
	_render_current()


## Feed mode: random paragraph (with its book's cover/title).
## Same setup machine: _paragraphs = growing history, _seq = position.
func setup_feed(row: Dictionary) -> void:
	_book = {
		"id": str(row.get("book_id", "")),
		"title": str(row.get("title", "")),
		"author": str(row.get("author", "")),
		"cover": row.get("cover", PackedByteArray()),
	}
	_paragraphs = [row] as Array[Dictionary]
	_feed_mode = true
	_feed_last_id = int(row.get("id", -1))
	_bookmark_mode = false
	_peek = false
	_bookmark_paragraphs.clear()
	_all_paragraphs.clear()
	_reset_panels()
	_seq = 0
	_render_current()


## Bookmark browsing (star on a library cover): only the starred paragraphs
## of one book. No last_seq writes; pinch-open peeks into the full book.
func setup_bookmarks(
	book: Dictionary, bookmarks: Array[Dictionary], all: Array[Dictionary]
) -> void:
	_book = book
	_paragraphs = bookmarks
	_bookmark_paragraphs = bookmarks
	_all_paragraphs = all
	_feed_mode = false
	_feed_last_id = -1
	_bookmark_mode = true
	_peek = false
	if _paragraphs.is_empty():
		push_error("reader.setup_bookmarks: no bookmarks")
		return
	_reset_panels()
	_seq = 0
	_render_current()


## Android back / Escape: consume only while peeking (return to the
## bookmark list); otherwise let the caller exit the reader.
func handle_back() -> bool:
	if _peek:
		_exit_peek()
		return true
	return false


func _exit_peek() -> void:
	_peek = false
	_paragraphs = _bookmark_paragraphs
	if _paragraphs.is_empty():
		library_requested.emit()
		return
	_seq = clampi(_bookmark_return_seq, 0, _paragraphs.size() - 1)
	_bookmark_mode = true
	_reset_panels()
	_render_current()


## Shared setup steps: kill tween, reset drag, panel roles, cover.
func _reset_panels() -> void:
	_kill_tween()
	_dragging = false
	_drag_delta = Vector2.ZERO
	_over_drag = 0.0
	_multi_gesture = false
	_multi_dx = 0.0
	_finger_down = false
	_hold_cancel()
	_hold_consumed = false
	_set_roles(_panel_a, _text_a, _panel_b, _text_b)
	_panel_a.position = Vector2.ZERO
	_panel_b.position = Vector2.ZERO
	_text_a.text = ""
	_text_b.text = ""
	_reset_label(_text_a)
	_reset_label(_text_b)
	_update_cover()
	# The autowrap min-height is reliable only after layout: re-sync.
	_schedule_reset(_active_text)
	_schedule_reset(_idle_text)


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		if not handle_back():
			exit_requested.emit()


func _gui_input(event: InputEvent) -> void:
	# Count touches BEFORE every guard: releases during the tween must
	# still decrement _touch_count (otherwise it goes stale).
	if event is InputEventScreenTouch:
		if event.pressed:
			_touch_count += 1
			_finger_pos[event.index] = event.position
		else:
			_touch_count = maxi(0, _touch_count - 1)
			_finger_pos.erase(event.index)

	# Release during the tween (handoff in progress): reset drag/hold state.
	if _is_animating():
		if (event is InputEventScreenTouch or (event is InputEventMouseButton \
				and event.button_index == MOUSE_BUTTON_LEFT)) and not event.pressed:
			_dragging = false
			_hold_cancel()
		return

	if event is InputEventScreenTouch:
		if event.pressed:
			if _touch_count >= 2:
				_enter_multi()
			else:
				_begin_drag(event.position)
		else:
			if _multi_gesture:
				if _touch_count < 2:
					_finish_multi()
			else:
				_finish_drag(event.position)
	elif event is InputEventScreenDrag:
		_finger_pos[event.index] = event.position
		if _multi_gesture:
			# Both fingers contribute: two parallel fingers ≈ doubled dx.
			_multi_dx += event.relative.x
			_update_pinch()
		elif _dragging:
			_update_drag(event.position)
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_begin_drag(event.position)
		else:
			_finish_drag(event.position)
	elif event is InputEventMouseMotion and _dragging:
		_update_drag(event.position)
	elif event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				_wheel(-1)
			MOUSE_BUTTON_WHEEL_DOWN:
				_wheel(1)


## Second finger lands: interrupts the single drag, starts the multi gesture.
func _enter_multi() -> void:
	if _multi_gesture:
		return
	_multi_gesture = true
	_multi_dx = 0.0
	_pinch_consumed = false
	_pinch_base_dist = _pinch_distance()
	_hold_cancel()
	if _dragging:
		_dragging = false
		_drag_delta = Vector2.ZERO
		_over_drag = 0.0
		_snap_back()


## First release under 2 fingers: evaluates the ±MULTI_JUMP skip.
func _finish_multi() -> void:
	var dx := _multi_dx
	_multi_gesture = false
	_multi_dx = 0.0
	if not MULTI_JUMP_ENABLED:
		return
	if absf(dx) >= SWIPE_THRESHOLD:
		_jump(-1 if dx < 0.0 else 1)


## Distance between the two tracked fingers; -1 if not exactly two.
func _pinch_distance() -> float:
	if _finger_pos.size() != 2:
		return -1.0
	var pts := _finger_pos.values()
	return (pts[0] as Vector2).distance_to(pts[1] as Vector2)


## Live pinch check during a two-finger drag: first threshold wins,
## the gesture is then consumed (no further pinch, multi-jump skipped).
func _update_pinch() -> void:
	if _pinch_consumed or _pinch_base_dist <= 0.0:
		return
	var dist := _pinch_distance()
	if dist < 0.0:
		return
	var delta := dist - _pinch_base_dist
	if delta <= -PINCH_THRESHOLD:
		_pinch_consumed = true
		_on_pinch_close()
	elif delta >= PINCH_THRESHOLD:
		_pinch_consumed = true
		_on_pinch_open()


## Pinch closed (fingers together): toggle a bookmark on the current
## paragraph. Not in feed mode; in bookmark mode it leaves the list.
func _on_pinch_close() -> void:
	if _feed_mode or _paragraphs.is_empty() or _book.is_empty():
		return
	var book_id := str(_book.get("id", ""))
	if book_id.is_empty():
		return
	var db_seq := int(_paragraphs[_seq].get("seq", -1))
	if db_seq < 0:
		return
	var now_on := Db.toggle_bookmark(book_id, db_seq)
	if not now_on and _bookmark_mode:
		# Removed the bookmark we were browsing: rebuild the list.
		var list := Db.get_bookmarked_paragraphs(book_id)
		if list.is_empty():
			library_requested.emit()
			return
		_bookmark_paragraphs = list
		_paragraphs = list
		_seq = clampi(_seq, 0, _paragraphs.size() - 1)
	_render_current()  # refresh ★ (no last_seq write while peek/bookmark)


## Pinch open (fingers apart) while browsing bookmarks: show the paragraph
## inside the full book WITHOUT touching the saved reading position.
func _on_pinch_open() -> void:
	if not _bookmark_mode or _paragraphs.is_empty() or _all_paragraphs.is_empty():
		return
	var want := int(_paragraphs[_seq].get("seq", -1))
	var idx := -1
	for i: int in _all_paragraphs.size():
		if int(_all_paragraphs[i].get("seq", -1)) == want:
			idx = i
			break
	if idx < 0:
		return
	_bookmark_return_seq = _seq
	_paragraphs = _all_paragraphs
	_seq = idx
	_bookmark_mode = false
	_peek = true
	_render_current()


## Jump of MULTI_JUMP paragraphs with clamp (never snaps at the edges).
func _jump(dir: int) -> void:
	if _is_animating() or _paragraphs.is_empty():
		return
	if _feed_mode:
		_feed_jump(dir * MULTI_JUMP)
		return
	var target := clampi(_seq + dir * MULTI_JUMP, 0, _paragraphs.size() - 1)
	if target == _seq:
		return
	_commit(target, 1 if dir > 0 else -1)


func _begin_drag(pos: Vector2) -> void:
	_dragging = true
	_drag_start = pos
	_drag_delta = Vector2.ZERO
	_over_drag = 0.0
	_drag_start_scroll = -_active_text.position.y
	# Hold: finger down, armed only after HOLD_MS (in _process).
	_finger_down = true
	_hold_armed = false
	_hold_consumed = false
	_hold_start_msec = Time.get_ticks_msec()


func _update_drag(pos: Vector2) -> void:
	_drag_delta = pos - _drag_start
	# Real finger movement → no hold (becomes a normal drag).
	if not _hold_armed and _drag_delta.length() > TAP_MAX_MOVE:
		_hold_start_msec = -1
	_apply_drag()


func _finish_drag(pos: Vector2) -> void:
	if not _dragging:
		_finger_down = false
		_hold_cancel()
		return
	_finger_down = false
	var consumed := _hold_consumed
	_hold_cancel()
	_dragging = false
	_drag_delta = pos - _drag_start
	var delta := _drag_delta
	_drag_delta = Vector2.ZERO
	_over_drag = 0.0

	if consumed:
		return  # a hold is not a tap

	if absf(delta.x) <= TAP_MAX_MOVE and absf(delta.y) <= TAP_MAX_MOVE:
		_handle_tap()
		return
	_last_tap_msec = -1000000  # a real gesture breaks the tap sequence

	if _active_overflow() <= 0.0:
		# Short text: the finger moved the card directly.
		if absf(delta.y) >= SWIPE_THRESHOLD:
			_go(1 if delta.y < 0.0 else -1)
		else:
			_snap_back()
	else:
		# Long text: scroll is already clamped live; the card did not move.
		# Paragraph change happens only via handoff during the drag.
		_snap_back()


func _hold_cancel() -> void:
	_hold_armed = false
	_hold_start_msec = -1


## Auto-scroll: finger still ≥ HOLD_MS on long text → continuous scrolling.
## Stops at the end of the paragraph (no continuation) or on release.
func _process(delta: float) -> void:
	if not _finger_down or _is_animating() or _multi_gesture:
		return
	if not _hold_armed:
		if _hold_start_msec < 0:
			return
		if Time.get_ticks_msec() - _hold_start_msec < HOLD_MS:
			return
		if _active_overflow() <= 0.0:
			# Short paragraph: the hold does nothing.
			_hold_start_msec = -1
			return
		# First armed frame: a hold is not a tap.
		_hold_armed = true
		_hold_consumed = true
		_last_tap_msec = -1000000
	var overflow := _active_overflow()
	if overflow <= 0.0:
		_hold_cancel()
		return
	var label := _active_text
	var scroll := -label.position.y + AUTO_SCROLL_SPEED * delta
	if scroll >= overflow:
		label.position.y = -overflow
		_hold_cancel()  # end of paragraph: stop
	else:
		label.position.y = -scroll


## Single tap = nothing; double tap within DOUBLE_TAP_MS → back to the library.
func _handle_tap() -> void:
	var now := Time.get_ticks_msec()
	if now - _last_tap_msec <= DOUBLE_TAP_MS:
		_last_tap_msec = -1000000
		library_requested.emit()
	else:
		_last_tap_msec = now


## Drag dy (cumulative from gesture start): >0 = finger toward the bottom.
## Absolute model: the target scroll derives from _drag_start_scroll, it does
## not sum previous events (otherwise it runs away). Scroll is consumed first,
## then (only for short texts) the card moves.
func _apply_drag() -> void:
	if _is_animating():
		return
	var dy := _drag_delta.y
	if is_equal_approx(dy, 0.0):
		return
	var overflow := _active_overflow()

	if overflow <= 0.0:
		_active_panel.position.y = _card_drag(dy)
		return

	var label := _active_text
	if dy < 0.0:
		# toward the bottom: scroll grows up to overflow
		var scroll_delta := minf(-dy, overflow - _drag_start_scroll)
		var residual := dy + scroll_delta  # ≤0 once past the bottom
		_over_drag = residual if residual < 0.0 else 0.0
		label.position.y = -(_drag_start_scroll + scroll_delta)
		if _over_drag <= -HANDOFF_MIN:
			_handoff(1)
	else:
		# toward the top: scroll shrinks down to 0
		var scroll_delta := maxf(-dy, -_drag_start_scroll)  # ≤0
		var residual := dy + scroll_delta  # ≥0 once past the top
		_over_drag = residual if residual > 0.0 else 0.0
		label.position.y = -(_drag_start_scroll + scroll_delta)
		if _over_drag >= HANDOFF_MIN:
			_handoff(-1)


func _card_drag(dy: float) -> float:
	if (_seq <= 0 and dy > 0.0) or (_seq >= _paragraphs.size() - 1 and dy < 0.0):
		return dy * DRAG_RESISTANCE
	return dy


## Handoff: at the end (or the start) of the text, change paragraph.
func _handoff(dir: int) -> void:
	_over_drag = 0.0
	_dragging = false
	_drag_delta = Vector2.ZERO
	_active_panel.position.y = 0.0
	_go(dir)


func _wheel(dir: int) -> void:
	if _is_animating() or _paragraphs.is_empty():
		return
	var overflow := _active_overflow()
	var label := _active_text
	var scroll := -label.position.y
	if dir > 0:
		if scroll >= overflow - 0.5:
			_go(1)
		else:
			label.position.y = maxf(label.position.y - WHEEL_STEP, -overflow)
	else:
		if scroll <= 0.5:
			_go(-1)
		else:
			label.position.y = minf(label.position.y + WHEEL_STEP, 0.0)


## dir > 0 = next paragraph, dir < 0 = previous.
func _go(dir: int) -> void:
	if _is_animating() or _paragraphs.is_empty():
		return
	if _feed_mode and dir > 0:
		# Feed: at end of history fetch a new random one and append it.
		var nxt := _fetch_feed_row()
		if nxt.is_empty():
			_snap_back()
			return
		_paragraphs.append(nxt)
	var target := _seq + dir
	if target < 0 or target >= _paragraphs.size():
		_snap_back()
		return
	_commit(target, dir)


## Next random paragraph different from the last shown (max 3 attempts).
func _fetch_feed_row() -> Dictionary:
	for i in 3:
		var row := Db.get_random_paragraph(_feed_last_id)
		if row.is_empty():
			return {}
		if int(row.get("id", -1)) != _feed_last_id:
			_feed_last_id = int(row["id"])
			return row
	return {}


## Two-finger jump in feed: amount ±10 (forward fetches, backward walks back).
func _feed_jump(amount: int) -> void:
	if _is_animating() or _paragraphs.is_empty():
		return
	if amount > 0:
		while _paragraphs.size() <= _seq + amount:
			var nxt := _fetch_feed_row()
			if nxt.is_empty():
				break
			_paragraphs.append(nxt)
		var t_fwd := mini(_seq + amount, _paragraphs.size() - 1)
		if t_fwd == _seq:
			_snap_back()
			return
		_commit(t_fwd, 1)
	else:
		var t_back := maxi(_seq + amount, 0)
		if t_back == _seq:
			_snap_back()
			return
		_commit(t_back, -1)


func _commit(target: int, dir: int) -> void:
	var h := size.y
	_idle_text.text = str(_paragraphs[target]["text"])
	_reset_label(_idle_text)  # full height + scroll at top
	_schedule_reset(_idle_text)
	_idle_panel.position.y = h if dir > 0 else -h
	var out_y := -h if dir > 0 else h

	_kill_tween()
	_tween = create_tween().bind_node(self)
	_tween.set_parallel(true)
	_tween.tween_property(_active_panel, "position:y", out_y, SLIDE_DURATION) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_property(_idle_panel, "position:y", 0.0, SLIDE_DURATION) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.finished.connect(_on_commit_finished.bind(target))


func _on_commit_finished(target: int) -> void:
	_tween = null
	_seq = target
	_peek = false  # navigating away from a peek resumes position tracking
	var swap_panel := _active_panel
	_active_panel = _idle_panel
	_idle_panel = swap_panel
	var swap_text := _active_text
	_active_text = _idle_text
	_idle_text = swap_text
	_render_current()


func _snap_back() -> void:
	if not _is_animating() and is_equal_approx(_active_panel.position.y, 0.0):
		return
	_kill_tween()
	_tween = create_tween().bind_node(self)
	_tween.tween_property(_active_panel, "position:y", 0.0, SLIDE_DURATION * 0.7) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.finished.connect(func() -> void: _tween = null)


func _render_current() -> void:
	var row: Dictionary = _paragraphs[_seq]
	_active_text.text = str(row["text"])
	_reset_label(_active_text)
	_schedule_reset(_active_text)
	if _feed_mode:
		# Feed: the paragraph's book title, counter = steps taken,
		# no progress and no last_seq persistence.
		_chapter_label.text = str(row.get("title", ""))
		_counter_label.text = "%d" % (_seq + 1)
		_progress_bar.visible = false
		_book = {
			"id": str(row.get("book_id", "")),
			"title": str(row.get("title", "")),
			"author": str(row.get("author", "")),
			"cover": row.get("cover", PackedByteArray()),
		}
		_update_cover()
		return
	var book_id := str(_book.get("id", ""))
	var chapter := str(row["chapter"]).get_file().get_basename()
	if _bookmark_mode:
		# Browsing bookmarks: ★ always on, counter = list position,
		# no progress bar and no last_seq write.
		_chapter_label.text = chapter + " ★"
		_counter_label.text = "%d / %d" % [_seq + 1, _paragraphs.size()]
		_progress_bar.visible = false
		return
	if not book_id.is_empty() and Db.is_bookmarked(book_id, int(row.get("seq", -1))):
		chapter += " ★"
	_chapter_label.text = chapter
	_counter_label.text = "%d / %d" % [_seq + 1, _paragraphs.size()]
	_progress_bar.visible = true
	_progress_bar.max_value = _paragraphs.size()
	_progress_bar.value = _seq + 1
	if not _peek:
		Db.set_setting(Db.seq_key(book_id), str(_seq))


## Label height = full content; scroll zeroed (text at top).
func _reset_label(label: Label) -> void:
	label.size.y = label.get_minimum_size().y
	label.position.y = 0.0


## Post-layout re-sync: the autowrap min-height with a width not yet
## assigned is computed wrong (doubled height) — recalculating on later
## frames fixes size.y to the real value.
func _schedule_reset(label: Label) -> void:
	_reset_label.bind(label).call_deferred()


## How much of the text exceeds the visible window (0 = it all fits).
func _active_overflow() -> float:
	var box := _active_text.get_parent() as Control
	if box == null:
		return 0.0
	return maxf(0.0, _active_text.size.y - box.size.y)


func _update_cover() -> void:
	var book_id := str(_book.get("id", ""))
	if book_id != _cover_book_id:
		_cover_book_id = book_id
		_cover_cached = BufferImage.to_texture(_book.get("cover", PackedByteArray()) as PackedByteArray)
	_cover_bg.texture = _cover_cached
	_cover_bg.visible = _cover_cached != null


func _set_roles(panel_a: Control, text_a: Label, panel_b: Control, text_b: Label) -> void:
	_active_panel = panel_a
	_active_text = text_a
	_idle_panel = panel_b
	_idle_text = text_b


func _is_animating() -> bool:
	return _tween != null and _tween.is_valid()


func _kill_tween() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = null
