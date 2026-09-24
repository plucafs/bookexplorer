class_name BufferImage
extends RefCounted
## Converts image bytes (PNG/JPG/WEBP) to Image/Texture; null if invalid.


## Full-resolution texture WITH mipmaps (needed by the reader blur shader).
static func to_texture(bytes: PackedByteArray) -> ImageTexture:
	var image := to_image(bytes)
	if image == null:
		return null
	return ImageTexture.create_from_image(image)


## Full-resolution image with generated mipmaps.
static func to_image(bytes: PackedByteArray) -> Image:
	var image := _decode(bytes)
	if image == null:
		return null
	image.generate_mipmaps()
	return image


## Library thumbnail: max width (default 300), no mipmaps.
static func to_thumbnail(bytes: PackedByteArray, max_width: int = 300) -> ImageTexture:
	var image := _decode(bytes)
	if image == null:
		return null
	if image.get_width() > max_width:
		var new_height := maxi(
			int(float(image.get_height()) * float(max_width) / float(image.get_width())), 1
		)
		image.resize(max_width, new_height, Image.INTERPOLATE_LANCZOS)
	return ImageTexture.create_from_image(image)


static func _decode(bytes: PackedByteArray) -> Image:
	if bytes.is_empty():
		return null
	var image := Image.new()
	var err := ERR_FILE_UNRECOGNIZED
	if bytes.size() >= 8 and bytes[0] == 0x89 and bytes[1] == 0x50:
		err = image.load_png_from_buffer(bytes)
	elif bytes.size() >= 2 and bytes[0] == 0xFF and bytes[1] == 0xD8:
		err = image.load_jpg_from_buffer(bytes)
	elif bytes.size() >= 12 and bytes[0] == 0x52 and bytes[1] == 0x49 \
			and bytes[2] == 0x46 and bytes[3] == 0x46:
		err = image.load_webp_from_buffer(bytes)
	if err != OK:
		return null
	return image
