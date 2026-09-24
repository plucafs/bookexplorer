extends Control
## Confirmation screen: cover, title, author, paragraph count.

signal open_epub_requested
signal read_requested
signal library_requested

@onready var _cover_texture: TextureRect = %CoverTexture
@onready var _title_label: Label = %TitleLabel
@onready var _author_label: Label = %AuthorLabel
@onready var _count_label: Label = %CountLabel
@onready var _read_button: Button = %ReadButton
@onready var _library_button: Button = %LibraryButton
@onready var _open_button: Button = %OpenButton


func _ready() -> void:
	_read_button.pressed.connect(func() -> void: read_requested.emit())
	_library_button.pressed.connect(func() -> void: library_requested.emit())
	_open_button.pressed.connect(func() -> void: open_epub_requested.emit())


func show_book(book: Dictionary) -> void:
	_title_label.text = str(book.get("title", ""))
	var author := str(book.get("author", ""))
	_author_label.text = author
	_author_label.visible = not author.is_empty()
	_count_label.text = "%d paragraphs" % int(book.get("paragraph_count", 0))
	_set_cover(book.get("cover", PackedByteArray()) as PackedByteArray)
	visible = true


func _set_cover(cover_bytes: PackedByteArray) -> void:
	_cover_texture.texture = BufferImage.to_texture(cover_bytes)
	_cover_texture.visible = _cover_texture.texture != null
	if _cover_texture.texture == null and not cover_bytes.is_empty():
		push_error("confirmation: cover not decodable")
