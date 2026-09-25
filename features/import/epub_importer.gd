class_name EpubImporter
extends RefCounted
## Imports an epub: ZIPReader + XMLParser → paragraphs + cover + real TOC
## (EPUB3 nav / EPUB2 NCX → toc_entries) into SQLite.
## To be used on a Thread: import_epub() opens its own SQLite connection.
## UI updates only via progress_cb.call_deferred() (thread-safe).

const DB_SCRIPT := preload("res://common/db.gd")
const TMP_PATH := "user://cache/import_tmp.epub"

const BLOCK_TAGS: Dictionary = {
	&"p": true, &"h1": true, &"h2": true, &"h3": true, &"h4": true,
	&"h5": true, &"h6": true, &"li": true, &"blockquote": true, &"pre": true,
	&"figcaption": true, &"dt": true, &"dd": true, &"caption": true,
	&"td": true, &"th": true,
}

const SKIP_TAGS: Dictionary = { &"head": true, &"script": true, &"style": true }

var _buf: String = ""
var _paras: Array[String] = []
var _skip_depth: int = 0

static var _meaningful_re: RegEx = null


## True if the text contains at least one letter or digit.
## Discards empty strings, whitespace (incl. nbsp), zero-width and punctuation-only.
static func is_meaningful(text: String) -> bool:
	var clean := text.replace(" ", " ").replace("​", "").replace("﻿", "")
	clean = clean.strip_edges()
	if clean.is_empty():
		return false
	if _meaningful_re == null:
		var re := RegEx.new()
		re.compile("[\\p{L}\\p{N}]")
		_meaningful_re = re
	return _meaningful_re.search(clean) != null


## Imports the epub from source_path into the database db_path.
## progress_cb (optional): Callable(current: int, total: int, chapter: String).
func import_epub(source_path: String, db_path: String, progress_cb: Callable = Callable()) -> Dictionary:
	var result := {
		"ok": false, "error": "", "book_id": "",
		"title": "", "author": "", "paragraph_count": 0,
	}

	var copy_err := _copy_to_cache(source_path)
	if copy_err != OK:
		result["error"] = "Failed to read file (error %d)" % copy_err
		return result

	var zip := ZIPReader.new()
	var zip_err := zip.open(TMP_PATH)
	if zip_err != OK:
		result["error"] = "Not a valid epub (ZIPReader error %d)" % zip_err
		return result

	var opf_path := _find_opf_path(zip)
	if opf_path.is_empty():
		zip.close()
		result["error"] = "container.xml or OPF not found"
		return result

	var opf_bytes := zip.read_file(opf_path)
	if opf_bytes.is_empty():
		zip.close()
		result["error"] = "OPF empty or unreadable"
		return result

	var meta := _parse_opf(opf_bytes, opf_path)
	var book_id: String = str(meta["id"])
	if book_id.is_empty():
		book_id = source_path.get_file().md5_text()

	var paragraphs := _collect_paragraphs(zip, str(opf_path), meta, progress_cb)
	var toc_rows := _collect_toc(zip, meta, paragraphs)

	var cover: PackedByteArray = PackedByteArray()
	var cover_href: String = str(meta["cover_href"])
	if not cover_href.is_empty() and zip.get_files().has(cover_href):
		cover = zip.read_file(cover_href)
	zip.close()

	var db := DB_SCRIPT.open_connection(db_path)
	if db == null:
		_cleanup_tmp()
		result["error"] = "Failed to open database"
		return result

	var title := str(meta["title"])
	if title.is_empty():
		title = source_path.get_file().get_basename().replace("_", " ").replace("-", " ")

	var ok := _persist(db, book_id, title, str(meta["author"]), cover, paragraphs, toc_rows)
	db.close_db()
	_cleanup_tmp()

	if not ok:
		result["error"] = "Failed to write to database"
		return result

	result["ok"] = true
	result["book_id"] = book_id
	result["title"] = title
	result["author"] = str(meta["author"])
	result["paragraph_count"] = paragraphs.size()
	return result


func _copy_to_cache(source_path: String) -> Error:
	DirAccess.make_dir_recursive_absolute("user://cache")
	var input := FileAccess.open(source_path, FileAccess.READ)
	if input == null:
		return FileAccess.get_open_error()
	var output := FileAccess.open(TMP_PATH, FileAccess.WRITE)
	if output == null:
		var err := FileAccess.get_open_error()
		input.close()
		return err
	while not input.eof_reached():
		output.store_buffer(input.get_buffer(65536))
	input.close()
	output.close()
	return OK


func _find_opf_path(zip: ZIPReader) -> String:
	if not zip.get_files().has("META-INF/container.xml"):
		return ""
	var parser := XMLParser.new()
	if parser.open_buffer(zip.read_file("META-INF/container.xml")) != OK:
		return ""
	while parser.read() == OK:
		if parser.get_node_type() != XMLParser.NODE_ELEMENT:
			continue
		if _local(parser.get_node_name()) != "rootfile":
			continue
		var full_path := _attr(parser, "full-path")
		if not full_path.is_empty():
			return full_path
	return ""


## Returns {title, author, id, manifest, spine, cover_href, nav_href, ncx_href}.
func _parse_opf(opf_bytes: PackedByteArray, opf_path: String) -> Dictionary:
	var manifest := {}
	var spine: Array[String] = []
	var title := ""
	var author := ""
	var book_id := ""
	var cover_id := ""
	var meta_cover_id := ""
	var nav_id := ""
	var spine_toc_id := ""
	var section := ""  # metadata | manifest | spine
	var base_dir := opf_path.get_base_dir()

	var parser := XMLParser.new()
	if parser.open_buffer(opf_bytes) != OK:
		push_error("EpubImporter: OPF not parseable")
		return {}

	while parser.read() == OK:
		match parser.get_node_type():
			XMLParser.NODE_ELEMENT:
				var name := _local(parser.get_node_name())
				if name == "metadata" or name == "manifest" or name == "spine":
					section = "" if parser.is_empty() else name
					if name == "spine":
						spine_toc_id = _attr(parser, "toc")  # EPUB2 NCX id
					continue
				if section == "metadata" and name == "meta":
					if _attr(parser, "name") == "cover":
						meta_cover_id = _attr(parser, "content")
					continue
				if section == "metadata" and (name == "title" or name == "creator" or name == "identifier"):
					var text := ""
					if parser.is_empty():
						text = parser.get_node_data().strip_edges()
					else:
						while parser.read() == OK:
							if parser.get_node_type() == XMLParser.NODE_ELEMENT_END:
								break
							if parser.get_node_type() == XMLParser.NODE_TEXT \
									or parser.get_node_type() == XMLParser.NODE_CDATA:
								text += parser.get_node_data()
						text = text.strip_edges()
					if not text.is_empty():
						if name == "title" and title.is_empty():
							title = text
						elif name == "creator" and author.is_empty():
							author = text
						elif name == "identifier" and book_id.is_empty():
							book_id = text
					continue
				if section == "manifest" and name == "item":
					var id := _attr(parser, "id")
					if not id.is_empty():
						manifest[id] = {
							"href": _attr(parser, "href"),
							"media_type": _attr(parser, "media-type"),
						}
						var props := _attr(parser, "properties")
						if props.find("cover-image") != -1:
							cover_id = id
						if props.find("nav") != -1:
							nav_id = id  # EPUB3 nav document
					continue
				if section == "spine" and name == "itemref":
					var idref := _attr(parser, "idref")
					var linear := _attr(parser, "linear")
					if not idref.is_empty() and linear != "no":
						spine.append(idref)
					continue
			XMLParser.NODE_ELEMENT_END:
				var end_name := _local(parser.get_node_name())
				if end_name == "metadata" or end_name == "manifest" or end_name == "spine":
					section = ""

	var chosen := cover_id if not cover_id.is_empty() else meta_cover_id
	var cover_href := ""
	if chosen != "" and manifest.has(chosen):
		cover_href = _resolve_href(base_dir, str(manifest[chosen]["href"]))
	var nav_href := ""
	if nav_id != "" and manifest.has(nav_id):
		nav_href = _resolve_href(base_dir, str(manifest[nav_id]["href"]))
	var ncx_href := ""
	if spine_toc_id != "" and manifest.has(spine_toc_id):
		ncx_href = _resolve_href(base_dir, str(manifest[spine_toc_id]["href"]))

	return {
		"title": title, "author": author, "id": book_id,
		"manifest": manifest, "spine": spine, "cover_href": cover_href,
		"nav_href": nav_href, "ncx_href": ncx_href,
	}


## Returns an Array of {chapter: String, text: String}.
func _collect_paragraphs(
	zip: ZIPReader, opf_path: String, meta: Dictionary, progress_cb: Callable
) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var manifest: Dictionary = meta["manifest"]
	var spine: Array[String] = meta["spine"]
	var base_dir := opf_path.get_base_dir()
	var total := spine.size()

	for i in total:
		var item_id: String = spine[i]
		if not manifest.has(item_id):
			push_error("EpubImporter: spine id '%s' missing from manifest" % item_id)
			continue
		var entry: Dictionary = manifest[item_id]
		var href := _resolve_href(base_dir, str(entry["href"]))
		if progress_cb.is_valid():
			progress_cb.call_deferred(i + 1, total, href)

		var media_type := str(entry["media_type"])
		var ext := href.get_extension().to_lower()
		if not (media_type.contains("html") or ext in ["xhtml", "html", "htm"]):
			continue
		if not zip.get_files().has(href):
			push_error("EpubImporter: spine file missing from zip: %s" % href)
			continue
		for p in _extract_paragraphs(zip.read_file(href)):
			out.append({ "chapter": href, "text": p })

	return out


## Real TOC entries mapped to first-paragraph seqs: [{seq, title}, ...].
## Source: EPUB3 nav → EPUB2 NCX → none (empty: caller keeps fallback).
func _collect_toc(
	zip: ZIPReader, meta: Dictionary, paragraphs: Array[Dictionary]
) -> Array[Dictionary]:
	var raw: Array[Dictionary] = []
	var nav_href := str(meta.get("nav_href", ""))
	var ncx_href := str(meta.get("ncx_href", ""))
	if not nav_href.is_empty() and zip.get_files().has(nav_href):
		raw = _parse_nav(zip.read_file(nav_href), nav_href.get_base_dir())
	if raw.is_empty() and not ncx_href.is_empty() and zip.get_files().has(ncx_href):
		raw = _parse_ncx(zip.read_file(ncx_href), ncx_href.get_base_dir())
	if raw.is_empty():
		return []
	# chapter href → first paragraph seq (same resolution as _collect_paragraphs)
	var chapter_seq := {}
	for i in paragraphs.size():
		var ch := str(paragraphs[i]["chapter"])
		if not chapter_seq.has(ch):
			chapter_seq[ch] = i
	var out: Array[Dictionary] = []
	var seen := {}
	for entry: Dictionary in raw:
		var href := str(entry.get("href", ""))
		var title := str(entry.get("title", "")).strip_edges()
		if title.is_empty():
			title = href.get_file().get_basename()
		if not chapter_seq.has(href):
			continue  # points at a file with no paragraphs
		var seq := int(chapter_seq[href])
		if seen.has(seq):
			continue  # multiple navPoints into one file → first wins
		seen[seq] = true
		out.append({ "seq": seq, "title": title })
	return out


## EPUB3 nav: entries of the <nav epub:type="toc">, else the first <nav>.
## hrefs resolved relative to the nav file dir (base_dir), fragments stripped.
func _parse_nav(bytes: PackedByteArray, base_dir: String) -> Array[Dictionary]:
	var navs: Array[Array] = []
	var toc_nav := -1
	var current_nav := -1
	var pending := {}
	var parser := XMLParser.new()
	if parser.open_buffer(bytes) != OK:
		push_error("EpubImporter: nav not parseable")
		return []
	while parser.read() == OK:
		match parser.get_node_type():
			XMLParser.NODE_ELEMENT:
				var name := _local(parser.get_node_name())
				if name == "nav":
					navs.append([])
					current_nav = navs.size() - 1
					if _attr(parser, "epub:type").to_lower().find("toc") != -1:
						toc_nav = current_nav
				elif name == "a" and current_nav >= 0 and pending.is_empty():
					var href := _attr(parser, "href")
					if not href.is_empty():
						pending = { "href": href, "title": "" }
			XMLParser.NODE_TEXT, XMLParser.NODE_CDATA:
				if not pending.is_empty():
					pending["title"] = str(pending["title"]) + parser.get_node_data()
			XMLParser.NODE_ELEMENT_END:
				var end_name := _local(parser.get_node_name())
				if end_name == "a" and not pending.is_empty() and current_nav >= 0:
					navs[current_nav].append({
						"title": str(pending["title"]).strip_edges(),
						"href": _resolve_href(base_dir, str(pending["href"])),
					})
					pending = {}
				elif end_name == "nav":
					current_nav = -1
	var chosen := toc_nav
	if chosen < 0 and not navs.is_empty():
		chosen = 0
	if chosen < 0:
		return []
	var out: Array[Dictionary] = []
	for entry in navs[chosen]:
		out.append(entry)
	return out


## EPUB2 NCX: navPoints in start order (a parent before its children).
## content src relative to the NCX file dir (base_dir), fragments stripped.
func _parse_ncx(bytes: PackedByteArray, base_dir: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var stack: Array[int] = []  # indices into out of the open navPoints
	var parser := XMLParser.new()
	if parser.open_buffer(bytes) != OK:
		push_error("EpubImporter: NCX not parseable")
		return []
	while parser.read() == OK:
		match parser.get_node_type():
			XMLParser.NODE_ELEMENT:
				var name := _local(parser.get_node_name())
				if name == "navpoint":
					out.append({ "title": "", "href": "" })
					stack.append(out.size() - 1)
					if parser.is_empty():
						stack.pop_back()
				elif name == "text" and not stack.is_empty():
					var text := ""
					if parser.is_empty():
						text = parser.get_node_data()
					else:
						while parser.read() == OK:
							if parser.get_node_type() == XMLParser.NODE_ELEMENT_END:
								break
							if parser.get_node_type() == XMLParser.NODE_TEXT \
									or parser.get_node_type() == XMLParser.NODE_CDATA:
								text += parser.get_node_data()
					var idx: int = stack.back()
					out[idx]["title"] = str(out[idx]["title"]) + text.strip_edges()
				elif name == "content" and not stack.is_empty():
					var src := _attr(parser, "src")
					if not src.is_empty():
						out[stack.back()]["href"] = _resolve_href(base_dir, src)
			XMLParser.NODE_ELEMENT_END:
				if _local(parser.get_node_name()) == "navpoint" and not stack.is_empty():
					stack.pop_back()
	var clean: Array[Dictionary] = []
	for entry: Dictionary in out:
		if not str(entry.get("href", "")).is_empty():
			clean.append(entry)
	return clean


func _extract_paragraphs(bytes: PackedByteArray) -> Array[String]:
	_buf = ""
	_paras = []
	_skip_depth = 0

	var parser := XMLParser.new()
	if parser.open_buffer(bytes) != OK:
		push_error("EpubImporter: XHTML not parseable, regex fallback")
		return _extract_paragraphs_fallback(bytes)

	while true:
		var err := parser.read()
		if err == ERR_FILE_EOF:
			break
		if err != OK:
			push_error("EpubImporter: parse aborted (error %d), regex fallback" % err)
			return _extract_paragraphs_fallback(bytes)

		match parser.get_node_type():
			XMLParser.NODE_ELEMENT:
				var name := _local(parser.get_node_name())
				if SKIP_TAGS.has(name):
					if not parser.is_empty():
						_skip_depth += 1
				elif _skip_depth == 0:
					if name == "br":
						_buf += "\n"
					elif BLOCK_TAGS.has(name):
						_flush_buffer()
			XMLParser.NODE_ELEMENT_END:
				var name := _local(parser.get_node_name())
				if SKIP_TAGS.has(name):
					_skip_depth = maxi(0, _skip_depth - 1)
				elif _skip_depth == 0 and BLOCK_TAGS.has(name):
					_flush_buffer()
			XMLParser.NODE_TEXT, XMLParser.NODE_CDATA:
				if _skip_depth == 0:
					_buf += parser.get_node_data()

	_flush_buffer()
	return _paras


func _extract_paragraphs_fallback(bytes: PackedByteArray) -> Array[String]:
	var text := bytes.get_string_from_utf8()
	var patterns: Array[Dictionary] = [
		{"p": "(?is)<(script|style|head)\\b[^>]*>.*?</\\1>", "r": ""},
		{"p": "(?is)<br\\s*/?>", "r": "\n"},
		{"p": "(?is)</(p|h[1-6]|li|blockquote|pre|figcaption|dt|dd|caption|tr|div)>", "r": "\n\n"},
		{"p": "(?is)<[^>]+>", "r": ""},
	]
	for item in patterns:
		var re := RegEx.new()
		if re.compile(str(item["p"])) == OK:
			text = re.sub(text, str(item["r"]), true)
	for entity: String in ["&nbsp;", "&amp;", "&lt;", "&gt;", "&quot;", "&#39;", "&#8217;", "&#8220;", "&#8221;"]:
		text = text.replace(entity, _entity_replacement(entity))

	var word_re := RegEx.new()
	word_re.compile("[\\p{L}\\p{N}]")
	var out: Array[String] = []
	for chunk in text.split("\n\n"):
		var clean := chunk.strip_edges()
		if not clean.is_empty() and word_re.search(clean) != null:
			out.append(clean)
	return out


func _flush_buffer() -> void:
	var clean := _buf.strip_edges()
	_buf = ""
	if is_meaningful(clean):
		_paras.append(clean)


func _local(node_name: String) -> String:
	var idx := node_name.rfind(":")
	return node_name.substr(idx + 1).to_lower() if idx != -1 else node_name.to_lower()


## XMLParser exposes attributes by index: search by name (case-insensitive).
func _attr(parser: XMLParser, attr_name: String) -> String:
	for i in parser.get_attribute_count():
		if parser.get_attribute_name(i).to_lower() == attr_name.to_lower():
			return parser.get_attribute_value(i)
	return ""


func _resolve_href(base_dir: String, href: String) -> String:
	var no_fragment := href.split("#")[0]
	var decoded := no_fragment.uri_decode()
	if decoded.begins_with("/"):
		decoded = decoded.trim_prefix("/")
	var full := base_dir.path_join(decoded) if not base_dir.is_empty() else decoded
	var stack: Array[String] = []
	for part in full.split("/"):
		if part.is_empty() or part == ".":
			continue
		if part == "..":
			if not stack.is_empty():
				stack.pop_back()
			continue
		stack.append(part)
	return "/".join(stack)


func _persist(
	db: SQLite, book_id: String, title: String, author: String,
	cover: PackedByteArray, paragraphs: Array[Dictionary], toc_rows: Array[Dictionary]
) -> bool:
	if not db.query("BEGIN;"):
		push_error("EpubImporter BEGIN: %s" % db.error_message)
		return false

	var ok := true
	ok = ok and db.query_with_bindings("DELETE FROM paragraphs WHERE book_id = ?;", [book_id])
	ok = ok and db.query_with_bindings("DELETE FROM toc_entries WHERE book_id = ?;", [book_id])
	ok = ok and db.query_with_bindings("DELETE FROM books WHERE id = ?;", [book_id])
	ok = ok and db.query_with_bindings(
		"""INSERT INTO books (id, title, author, cover, paragraph_count, imported_at)
		VALUES (?, ?, ?, ?, ?, ?);""",
		[book_id, title, author, cover, paragraphs.size(), int(Time.get_unix_time_from_system())]
	)
	for i in paragraphs.size():
		if not ok:
			break
		var row: Dictionary = paragraphs[i]
		ok = db.query_with_bindings(
			"INSERT INTO paragraphs (book_id, seq, chapter, text) VALUES (?, ?, ?, ?);",
			[book_id, i, str(row["chapter"]), str(row["text"])]
		)
	for i in toc_rows.size():
		if not ok:
			break
		var entry: Dictionary = toc_rows[i]
		ok = db.query_with_bindings(
			"INSERT INTO toc_entries (book_id, seq, title) VALUES (?, ?, ?);",
			[book_id, int(entry["seq"]), str(entry["title"])]
		)

	if not ok:
		push_error("EpubImporter INSERT: %s" % db.error_message)
		db.query("ROLLBACK;")
		return false
	if not db.query("COMMIT;"):
		push_error("EpubImporter COMMIT: %s" % db.error_message)
		db.query("ROLLBACK;")
		return false
	return true


func _cleanup_tmp() -> void:
	var dir := DirAccess.open("user://cache")
	if dir != null:
		dir.remove(TMP_PATH.get_file())


func _entity_replacement(entity: String) -> String:
	match entity:
		"&nbsp;": return " "
		"&amp;": return "&"
		"&lt;": return "<"
		"&gt;": return ">"
		"&quot;": return "\""
		"&#39;": return "'"
		"&#8217;": return "’"
		"&#8220;": return "“"
		"&#8221;": return "”"
	return entity
