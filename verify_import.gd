extends SceneTree
## Headless check of the epub import. Usage:
## godot --headless --path . -s res://verify_import.gd

const DB_PATH := "user://library.db"
const EPUB_PATH := "res://test-epub/herman-melville_moby-dick.epub"


func _init() -> void:
	var importer := EpubImporter.new()
	var result := importer.import_epub(EPUB_PATH, DB_PATH, _noop_progress)
	print("RESULT ok=", result["ok"],
		" error=", result["error"],
		" id=", result["book_id"],
		" title=", result["title"],
		" author=", result["author"],
		" paragraphs=", result["paragraph_count"])

	var db := preload("res://common/db.gd").open_connection(DB_PATH)
	if db == null:
		push_error("verify: failed to open DB")
		quit(1)
		return
	db.query("SELECT id, title, author, paragraph_count, length(cover) AS cover_len FROM books;")
	print("BOOKS: ", db.query_result)
	db.query("SELECT count(*) AS n, min(seq) AS min_seq, max(seq) AS max_seq FROM paragraphs;")
	print("PARAGRAPHS: ", db.query_result)
	db.query("SELECT chapter, text FROM paragraphs ORDER BY seq LIMIT 3;")
	for row in db.query_result:
		print("SAMPLE [", row["chapter"], "]: ", str(row["text"]).left(140))
	db.close_db()
	quit(0)


func _noop_progress(_current: int, _total: int, _chapter: String) -> void:
	pass
