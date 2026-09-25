extends Node
## Autoload "Db" — main SQLite connection (user://library.db).
## Bulk writes (import) use a dedicated connection on the Thread:
## see EpubImporter / open_connection().

const DB_PATH := "user://library.db"

const SCHEMA_SQL := """
CREATE TABLE IF NOT EXISTS books (
	id TEXT PRIMARY KEY,
	title TEXT NOT NULL DEFAULT '',
	author TEXT NOT NULL DEFAULT '',
	cover BLOB,
	paragraph_count INTEGER NOT NULL DEFAULT 0,
	imported_at INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS paragraphs (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	book_id TEXT NOT NULL,
	seq INTEGER NOT NULL,
	chapter TEXT NOT NULL DEFAULT '',
	text TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_paragraphs_book_seq ON paragraphs (book_id, seq);
CREATE TABLE IF NOT EXISTS settings (
	key TEXT PRIMARY KEY,
	value TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS bookmarks (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	book_id TEXT NOT NULL,
	seq INTEGER NOT NULL,
	created_at INTEGER NOT NULL DEFAULT 0,
	UNIQUE (book_id, seq)
);
CREATE TABLE IF NOT EXISTS toc_entries (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	book_id TEXT NOT NULL,
	seq INTEGER NOT NULL,
	title TEXT NOT NULL
);
"""

var _db: SQLite


func _ready() -> void:
	var db := open_connection()
	if db == null:
		return
	_db = db


func _exit_tree() -> void:
	if _db != null:
		_db.close_db()
		_db = null


## Opens an independent connection and ensures its schema.
## Static: usable also from the import thread.
static func open_connection(path: String = DB_PATH) -> SQLite:
	var db := SQLite.new()
	db.verbosity_level = 0  # QUIET: no log per insert
	db.path = path
	if not db.open_db():
		push_error("Db: failed to open %s — %s" % [path, db.error_message])
		return null
	if not db.query(SCHEMA_SQL):
		push_error("Db: schema failed — %s" % db.error_message)
		db.close_db()
		return null
	return db


func get_setting(key: String) -> String:
	if _db == null:
		return ""
	if not _db.query_with_bindings("""SELECT "value" FROM settings WHERE "key" = ?;""", [key]):
		push_error("Db.get_setting: %s" % _db.error_message)
		return ""
	var rows: Array = _db.query_result
	if rows.is_empty():
		return ""
	return str(rows[0].get("value", ""))


func set_setting(key: String, value: String) -> void:
	if _db == null:
		push_error("Db.set_setting: no connection")
		return
	var ok := _db.query_with_bindings(
		"""INSERT INTO settings ("key", "value") VALUES (?, ?)
		ON CONFLICT("key") DO UPDATE SET "value" = excluded."value";""",
		[key, value]
	)
	if not ok:
		push_error("Db.set_setting: %s" % _db.error_message)


func get_book(book_id: String) -> Dictionary:
	if _db == null:
		return {}
	if not _db.query_with_bindings(
		"SELECT id, title, author, cover, paragraph_count, imported_at FROM books WHERE id = ?;",
		[book_id]
	):
		push_error("Db.get_book: %s" % _db.error_message)
		return {}
	var rows: Array = _db.query_result
	if rows.is_empty():
		return {}
	return _normalize_book(rows[0] as Dictionary)


## All paragraphs of a book in reading order: [{seq, chapter, text}, ...]
func get_paragraphs(book_id: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if _db == null:
		return out
	if not _db.query_with_bindings(
		"SELECT seq, chapter, text FROM paragraphs WHERE book_id = ? ORDER BY seq ASC;",
		[book_id]
	):
		push_error("Db.get_paragraphs: %s" % _db.error_message)
		return out
	for row: Dictionary in _db.query_result:
		out.append({
			"seq": int(row.get("seq", 0)),
			"chapter": str(row.get("chapter", "")),
			"text": str(row.get("text", "")),
		})
	return out


## All imported books, most recent first (import or last opened).
func get_books() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if _db == null:
		return out
	if not _db.query(
		"""SELECT id, title, author, cover, paragraph_count, imported_at,
		(SELECT count(*) FROM bookmarks WHERE bookmarks.book_id = books.id) AS bookmark_count
		FROM books ORDER BY imported_at DESC;"""
	):
		push_error("Db.get_books: %s" % _db.error_message)
		return out
	for row: Dictionary in _db.query_result:
		out.append(_normalize_book(row))
	return out


## Cover BLOB can come back NULL: always normalize to a typed Dictionary.
func _normalize_book(row: Dictionary) -> Dictionary:
	var cover: PackedByteArray = PackedByteArray()
	if row.get("cover") is PackedByteArray:
		cover = row["cover"]
	return {
		"id": str(row.get("id", "")),
		"title": str(row.get("title", "")),
		"author": str(row.get("author", "")),
		"cover": cover,
		"paragraph_count": int(row.get("paragraph_count", 0)),
		"imported_at": int(row.get("imported_at", 0)),
		"bookmark_count": int(row.get("bookmark_count", 0)),
	}


## A random paragraph from ANY book (feed mode), with the book data
## (title/author/cover) for the cover and header. exclude_id = id of the
## paragraph to avoid (-1 = none); max 3 attempts.
func get_random_paragraph(exclude_id: int = -1) -> Dictionary:
	if _db == null:
		return {}
	for attempt in 3:
		var ok := _db.query_with_bindings(
			"""SELECT p.id, p.book_id, p.seq, p.chapter, p.text,
			b.title, b.author, b.cover
			FROM paragraphs p JOIN books b ON b.id = p.book_id
			WHERE p.id != ? ORDER BY RANDOM() LIMIT 1;""",
			[exclude_id]
		)
		if not ok:
			push_error("Db.get_random_paragraph: %s" % _db.error_message)
			return {}
		var rows: Array = _db.query_result
		if rows.is_empty():
			return {}  # no rows (empty DB or only the excluded one)
		var row := rows[0] as Dictionary
		var cover: PackedByteArray = PackedByteArray()
		if row.get("cover") is PackedByteArray:
			cover = row["cover"]
		return {
			"id": int(row.get("id", -1)),
			"book_id": str(row.get("book_id", "")),
			"seq": int(row.get("seq", 0)),
			"chapter": str(row.get("chapter", "")),
			"text": str(row.get("text", "")),
			"title": str(row.get("title", "")),
			"author": str(row.get("author", "")),
			"cover": cover,
		}
	return {}


## Reading-position key for a book (one key per book).
func seq_key(book_id: String) -> String:
	return "last_seq:" + book_id


## True if the paragraph (seq within the book) is bookmarked.
func is_bookmarked(book_id: String, seq: int) -> bool:
	if _db == null:
		return false
	if not _db.query_with_bindings(
		"SELECT 1 FROM bookmarks WHERE book_id = ? AND seq = ? LIMIT 1;",
		[book_id, seq]
	):
		push_error("Db.is_bookmarked: %s" % _db.error_message)
		return false
	return not (_db.query_result as Array).is_empty()


## Adds the bookmark if missing, removes it if present.
## Returns true if the paragraph is bookmarked now.
func toggle_bookmark(book_id: String, seq: int) -> bool:
	if _db == null:
		push_error("Db.toggle_bookmark: no connection")
		return false
	if is_bookmarked(book_id, seq):
		if not _db.query_with_bindings(
			"DELETE FROM bookmarks WHERE book_id = ? AND seq = ?;", [book_id, seq]
		):
			push_error("Db.toggle_bookmark: %s" % _db.error_message)
			return false
		return false
	if not _db.query_with_bindings(
		"INSERT INTO bookmarks (book_id, seq, created_at) VALUES (?, ?, ?);",
		[book_id, seq, int(Time.get_unix_time_from_system())]
	):
		push_error("Db.toggle_bookmark: %s" % _db.error_message)
		return false
	return true


## Bookmarked paragraphs of one book in reading order
## (same shape as get_paragraphs: [{seq, chapter, text}, ...]).
func get_bookmarked_paragraphs(book_id: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if _db == null:
		return out
	if not _db.query_with_bindings(
		"""SELECT p.seq, p.chapter, p.text FROM paragraphs p
		JOIN bookmarks b ON b.book_id = p.book_id AND b.seq = p.seq
		WHERE p.book_id = ? ORDER BY p.seq ASC;""",
		[book_id]
	):
		push_error("Db.get_bookmarked_paragraphs: %s" % _db.error_message)
		return out
	for row: Dictionary in _db.query_result:
		out.append({
			"seq": int(row.get("seq", 0)),
			"chapter": str(row.get("chapter", "")),
			"text": str(row.get("text", "")),
		})
	return out


## Table of contents: [{title, seq}] in reading order.
## Titles come from the epub nav/NCX (toc_entries, imported); books imported
## before that (or with no nav/NCX) fall back to chapter href basenames.
func get_toc(book_id: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if _db == null:
		return out
	if not _db.query_with_bindings(
		"SELECT seq, title FROM toc_entries WHERE book_id = ? ORDER BY seq ASC, id ASC;",
		[book_id]
	):
		push_error("Db.get_toc: %s" % _db.error_message)
		return out
	if not (_db.query_result as Array).is_empty():
		for row: Dictionary in _db.query_result:
			out.append({
				"title": str(row.get("title", "")),
				"seq": int(row.get("seq", 0)),
			})
		return out
	# Fallback: one entry per distinct chapter href, display-ready titles.
	if not _db.query_with_bindings(
		"""SELECT chapter, MIN(seq) AS seq FROM paragraphs
		WHERE book_id = ? GROUP BY chapter ORDER BY MIN(seq) ASC;""",
		[book_id]
	):
		push_error("Db.get_toc: %s" % _db.error_message)
		return out
	for row: Dictionary in _db.query_result:
		var title := str(row.get("chapter", "")).get_file().get_basename()
		out.append({
			"title": title if not title.is_empty() else "—",
			"seq": int(row.get("seq", 0)),
		})
	return out


## Marks the book as just opened: moves it to the top of the list
## (get_books orders by imported_at DESC — also used as "last opened").
func touch_book(book_id: String) -> bool:
	if _db == null:
		push_error("Db.touch_book: no connection")
		return false
	var ok := _db.query_with_bindings(
		"UPDATE books SET imported_at = ? WHERE id = ?;",
		[int(Time.get_unix_time_from_system()), book_id]
	)
	if not ok:
		push_error("Db.touch_book: %s" % _db.error_message)
	return ok


## Deletes the book and all its content
## (paragraphs, bookmarks, toc entries, position).
func delete_book(book_id: String) -> bool:
	if _db == null:
		push_error("Db.delete_book: no connection")
		return false
	if not _db.query("BEGIN;"):
		push_error("Db.delete_book BEGIN: %s" % _db.error_message)
		return false
	var ok := true
	ok = ok and _db.query_with_bindings("DELETE FROM paragraphs WHERE book_id = ?;", [book_id])
	ok = ok and _db.query_with_bindings("DELETE FROM bookmarks WHERE book_id = ?;", [book_id])
	ok = ok and _db.query_with_bindings("DELETE FROM toc_entries WHERE book_id = ?;", [book_id])
	ok = ok and _db.query_with_bindings("DELETE FROM books WHERE id = ?;", [book_id])
	ok = ok and _db.query_with_bindings(
		"""DELETE FROM settings WHERE "key" = ?;""", [seq_key(book_id)]
	)
	if ok and get_setting("last_book_id") == book_id:
		ok = _db.query_with_bindings(
			"""DELETE FROM settings WHERE "key" = ?;""", ["last_book_id"]
		)
	if not ok:
		push_error("Db.delete_book: %s" % _db.error_message)
		_db.query("ROLLBACK;")
		return false
	if not _db.query("COMMIT;"):
		push_error("Db.delete_book COMMIT: %s" % _db.error_message)
		_db.query("ROLLBACK;")
		return false
	return true
