extends Control
## Empty state: centered "Open epub" button.

signal open_epub_requested

@onready var _open_button: Button = %OpenButton


func _ready() -> void:
	_open_button.pressed.connect(_on_open_pressed)


func _on_open_pressed() -> void:
	open_epub_requested.emit()
