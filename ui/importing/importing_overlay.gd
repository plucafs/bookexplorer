extends Control
## Import overlay: progress, or error with a Close button.

signal close_requested

@onready var _progress_label: Label = %ProgressLabel
@onready var _chapter_label: Label = %ChapterLabel
@onready var _close_button: Button = %CloseButton


func _ready() -> void:
	_close_button.pressed.connect(func() -> void: close_requested.emit())


func show_importing() -> void:
	_progress_label.text = "Processing…"
	_chapter_label.text = ""
	_close_button.visible = false
	visible = true


func set_progress(current: int, total: int, chapter: String) -> void:
	_progress_label.text = "%d/%d" % [current, total]
	_chapter_label.text = chapter.get_file()


func show_error(message: String) -> void:
	_progress_label.text = "Import failed"
	_chapter_label.text = message
	_close_button.visible = true
