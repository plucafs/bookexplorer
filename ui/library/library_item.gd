extends Button
## Library item: cover thumbnail + title + X to delete.
## Full layout lives in library_item.tscn.

signal delete_requested

@onready var _cover_texture: TextureRect = %CoverTexture
@onready var _title_label: Label = %TitleLabel
@onready var _delete_button: Button = %DeleteButton


func _ready() -> void:
	_delete_button.pressed.connect(func() -> void: delete_requested.emit())


func setup(book: Dictionary) -> void:
	_title_label.text = str(book.get("title", ""))
	var thumb := BufferImage.to_thumbnail(book.get("cover", PackedByteArray()) as PackedByteArray, 300)
	_cover_texture.texture = thumb
	_cover_texture.visible = thumb != null
	if thumb == null:
		var author := str(book.get("author", ""))
		_title_label.text = str(book.get("title", author)) if not str(book.get("title", "")).is_empty() else author


func set_delete_enabled(enabled: bool) -> void:
	_delete_button.visible = enabled
