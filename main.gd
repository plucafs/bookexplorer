extends Control
## Orchestrator: empty state → SAF picker → import thread → confirmation → reader.
## No nodes created from code: every screen lives in main.tscn.

const EPUB_MIME := "application/epub+zip"
const DbScript := preload("res://common/db.gd")

@onready var _empty_state: Control = %EmptyState
@onready var _importing_overlay: Control = %ImportingOverlay
@onready var _confirmation: Control = %ConfirmationScreen
@onready var _library: Control = %Library
@onready var _reader: Control = %Reader

var _thread: Thread = null
var _reader_return: Control = null


func _ready() -> void:
	_empty_state.open_epub_requested.connect(_open_picker)
	_library.open_epub_requested.connect(_open_picker)
	_library.book_selected.connect(_on_book_selected)
	_library.feed_requested.connect(_on_feed_requested)
	_confirmation.open_epub_requested.connect(_open_picker)
	_confirmation.read_requested.connect(_on_read_requested)
	_confirmation.library_requested.connect(_on_library_requested)
	_importing_overlay.close_requested.connect(_on_import_close_requested)
	_reader.exit_requested.connect(_on_reader_exit)
	_reader.library_requested.connect(_on_reader_library_requested)
	get_viewport().size_changed.connect(_on_viewport_resized)
	get_tree().set_quit_on_go_back(false)
	_apply_safe_area()
	_show_initial_state()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		# Android back: from the reader return to the source screen,
		# from confirmation to the library; anywhere else, quit.
		if _reader.visible:
			_on_reader_exit()
		elif _confirmation.visible and not Db.get_books().is_empty():
			_on_library_requested()
		else:
			get_tree().quit()


func _show_initial_state() -> void:
	if not Db.get_books().is_empty():
		_set_screen(_library)
		return
	_set_screen(_empty_state)


func _set_screen(screen: Control) -> void:
	_empty_state.visible = screen == _empty_state
	_importing_overlay.visible = screen == _importing_overlay
	_confirmation.visible = screen == _confirmation
	_library.visible = screen == _library
	_reader.visible = screen == _reader
	if screen == _library:
		_library.refresh(Db.get_books())


func _on_book_selected(book_id: String) -> void:
	_open_reader(book_id, _library)


## "Feed" button: random paragraph from all books.
func _on_feed_requested() -> void:
	var row := Db.get_random_paragraph()
	if row.is_empty():
		push_error("main: feed has no paragraphs (empty library?)")
		return
	_reader_return = _library
	_reader.setup_feed(row)
	_set_screen(_reader)


func _on_library_requested() -> void:
	_set_screen(_library)


func _on_read_requested() -> void:
	_open_reader(Db.get_setting("last_book_id"), _confirmation)


func _open_reader(book_id: String, return_to: Control) -> void:
	if book_id.is_empty():
		push_error("main: missing book_id, cannot open the reader")
		return
	var book := Db.get_book(book_id)
	if book.is_empty():
		push_error("main: book '%s' not found" % book_id)
		return
	var paragraphs := Db.get_paragraphs(book_id)
	if paragraphs.is_empty():
		push_error("main: no paragraphs for '%s'" % book_id)
		return
	Db.touch_book(book_id)  # opened book → top of the library list
	_reader_return = return_to
	_reader.setup(book, paragraphs)
	_set_screen(_reader)


func _on_reader_exit() -> void:
	_set_screen(_reader_return if _reader_return != null else _confirmation)


## Double tap in the reader → always the library.
func _on_reader_library_requested() -> void:
	_set_screen(_library)


func _open_picker() -> void:
	var current_dir := OS.get_system_dir(OS.SYSTEM_DIR_DOWNLOADS)
	var err := DisplayServer.file_dialog_show(
		"Open epub",
		current_dir,
		"",
		false,
		DisplayServer.FILE_DIALOG_MODE_OPEN_FILE,
		PackedStringArray([EPUB_MIME]),
		_on_file_selected
	)
	if err != OK:
		push_error("main: failed to open picker (error %d)" % err)


func _on_file_selected(status: bool, paths: PackedStringArray, _filter_index: int) -> void:
	if not status or paths.is_empty():
		return
	_start_import(paths[0])


func _start_import(source: String) -> void:
	if _thread != null:
		return
	_importing_overlay.show_importing()
	_set_screen(_importing_overlay)
	_thread = Thread.new()
	_thread.start(_import_thread.bind(source))


func _import_thread(source: String) -> void:
	var importer := EpubImporter.new()
	var result := importer.import_epub(source, DbScript.DB_PATH, _on_import_progress)
	_on_import_finished.bind(result).call_deferred()


func _on_import_progress(current: int, total: int, chapter: String) -> void:
	_importing_overlay.set_progress(current, total, chapter)


func _on_import_finished(result: Dictionary) -> void:
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null
	if not bool(result.get("ok", false)):
		push_error("main: import failed — %s" % str(result.get("error", "")))
		_importing_overlay.show_error(str(result.get("error", "Unknown error")))
		return
	Db.set_setting("last_book_id", str(result["book_id"]))
	var book := Db.get_book(str(result["book_id"]))
	_confirmation.show_book(book)
	_set_screen(_confirmation)


func _on_import_close_requested() -> void:
	_show_initial_state()


## Root offset to the safe area (notch/cutout), mapped into the viewport.
func _apply_safe_area() -> void:
	var safe := DisplayServer.get_display_safe_area()
	var screen := DisplayServer.screen_get_size()
	var viewport := get_viewport().get_visible_rect().size
	if screen.x <= 0 or screen.y <= 0:
		return
	if safe.size.x <= 0 or safe == Rect2i(Vector2i.ZERO, screen):
		offset_left = 0.0
		offset_top = 0.0
		offset_right = 0.0
		offset_bottom = 0.0
		return
	var scale_x := viewport.x / float(screen.x)
	var scale_y := viewport.y / float(screen.y)
	offset_left = safe.position.x * scale_x
	offset_top = safe.position.y * scale_y
	offset_right = (safe.position.x + safe.size.x) * scale_x - viewport.x
	offset_bottom = (safe.position.y + safe.size.y) * scale_y - viewport.y


func _on_viewport_resized() -> void:
	_apply_safe_area()
