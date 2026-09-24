extends Button
## Library item: cover thumbnail + title + X to delete + star for bookmarks.
## Full layout lives in library_item.tscn.

signal delete_requested
signal bookmarks_requested

@onready var _cover_texture: TextureRect = %CoverTexture
@onready var _title_label: Label = %TitleLabel
@onready var _delete_button: Button = %DeleteButton
@onready var _star_bg: ColorRect = %StarBg
@onready var _star_button: Button = %StarButton


func _ready() -> void:
	_delete_button.pressed.connect(func() -> void: delete_requested.emit())
	_star_button.pressed.connect(func() -> void: bookmarks_requested.emit())


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


## Star is shown only when the book has bookmarks (bookmark_count > 0).
func set_star_visible(visible: bool) -> void:
	_star_button.visible = visible
	_star_bg.visible = visible
