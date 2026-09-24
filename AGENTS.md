# AGENTS.md — bookexplorer

"TikTok for ebooks": reads a selected epub, splits it into paragraphs and saves them to SQLite.

## Constraints (mandatory)

- **Android only.** No desktop branch. File picker: `DisplayServer.file_dialog_show` with MIME filter `application/epub+zip` (native SAF on Godot 4.6+, no storage permission).
- **No nodes created from code.** All layout lives in hand-written `.tscn` scenes; scripts only connect signals and update properties. `Button.new()`, `add_child` of code-built Controls, `@export` dynamically-built scenes are forbidden.
- **Feature-based structure** (not `/scripts` by type): `common/` (autoload), `features/<feature>/`, `ui/<screen>/`.
- Typed GDScript (explicit return types, `:=` where obvious), `%UniqueNames` for nodes, typed signals, `push_error()` never `print()`.
- Files `snake_case`, nodes `PascalCase`, past-tense signals (`open_epub_requested`).
- Never block the main thread with I/O: epub import runs on a `Thread` with a dedicated SQLite connection; UI updates via `call_deferred`.
- Persistence only in `user://` (never `res://`).

## Architecture

```
common/db.gd                 autoload "Db" — SQLite connection (user://library.db)
common/buffer_image.gd       class_name BufferImage — PNG/JPG/WEBP bytes → ImageTexture
features/import/epub_importer.gd   class_name EpubImporter (RefCounted) — epub pipeline
ui/empty_state/               empty state: "Open epub" button
ui/importing/                 progress/error overlay
ui/confirmation/              import confirmation + "Start reading" button
ui/reader/                    TikTok reading feed (one paragraph per screen)
ui/paragraph_view/            full-paragraph view — DISCONNECTED (files kept, unused)
main.gd + main.tscn           state switch: Empty → Importing → Confirmation → Reader
```

### Database (`user://library.db`)

```sql
books(id TEXT PRIMARY KEY /*dc:identifier, fallback filename hash*/, title, author,
      cover BLOB, paragraph_count INT, imported_at INT);  -- imported_at = import OR last open
paragraphs(id INTEGER PK AUTOINCREMENT, book_id, seq INT, chapter, text);
settings(key TEXT PK, value TEXT);  -- last_book_id
bookmarks(id INTEGER PK AUTOINCREMENT, book_id, seq INT, created_at INT, UNIQUE(book_id, seq));
```

Addon: `addons/godot-sqlite` (GDExtension, class `SQLite`: `open_db`, `query`, `query_with_bindings`, `query_result`).
BLOB (cover): MANDATORY to use `query_with_bindings` with `PackedByteArray`.
Db API: `get_books()` (ORDER BY imported_at DESC, includes `bookmark_count` via correlated
subquery), `touch_book(id)` (opened → first), `get_random_paragraph(exclude_id)` (JOIN books,
for the feed), `delete_book(id)` (transaction, cascades bookmarks),
`toggle_bookmark(book_id, seq) -> bool` (add/remove, returns new state),
`is_bookmarked(book_id, seq)`, `get_bookmarked_paragraphs(book_id)` (JOIN paragraphs, ORDER BY seq).

### Import pipeline (EpubImporter)

1. Copy picker URI (`content://…`) → `user://cache/import_tmp.epub` (ZIPReader cannot open content URIs).
2. `ZIPReader` → `META-INF/container.xml` → OPF path.
3. `XMLParser` on OPF: `dc:title`/`dc:creator`/`dc:identifier` (also accepts names without the `dc:` prefix), manifest, spine in order.
4. Cover: manifest item `properties` containing `cover-image`, or `meta[name=cover]`.
5. For each spine html/xhtml item: XML parse, skip `head/script/style`, flush paragraphs on block tags (`p`,`h1-h6`,`li`,`blockquote`,`pre`,`figcaption`,…), filter empties, global `seq`.
6. Malformed XHTML → regex strip-tag fallback + `push_error`, the import continues.
7. Re-import same id → DELETE of the existing book before the insert (transaction).

### Library (`ui/library/`)

- **Bottom strip (ACTIVE)**: `%Strip` (MarginContainer anchored to the bottom) →
  `%Scroll` (horizontal ScrollContainer, scrollbar hidden, vertical disabled)
  → `%BookRow` (HBox). `_render_strip()`: empties the row and instantiates
  `library_item.tscn` for each book **in `get_books()` order** (the last opened with
  `Db.touch_book` is first, on the left), size `STRIP_ITEM_SIZE` (170×260),
  **delete X visible on all**, tap (`pressed`) → `book_selected` → Reader.
  **Star (`★`, next to the X)**: `visible = bookmark_count > 0`, emits
  `bookmarks_requested(book_id)` → main → `reader.setup_bookmarks(book, bookmarks, all)`.
  **Drag on the covers scrolls the row** (custom `gui_input` per item, absolute
  model in global coords, threshold `STRIP_DRAG_THRESHOLD`=8px; a release after
  a drag is swallowed and does not open).
  0 books → Strip hidden + `%EmptyLabel`. Scroll reset to 0 on every refresh.
- **Carousel: KEPT BUT HIDDEN** (`%Carousel.visible=false`, same for SwipeHint):
  code intact (`_compute_slots`, `_swipe_to`, node rotation, tap hit-test…),
  `refresh()` still calls `_render_carousel()` on the hidden nodes.
  Re-enable: Carousel visibility ON + Strip OFF. Hint: `visible = n>1 and _carousel.visible`.
- Header: **"Feed"** (`%FeedButton`, hidden if 0 books) + "Open epub".
  `signal feed_requested` → main → `Db.get_random_paragraph()` → `reader.setup_feed(row)`.
- Delete confirmation: native `DisplayServer.dialog_show`, fallback `%ConfirmDialog`.
- Carousel tech (active only if re-enabled): slots are **visual centers**
  (`position = slot − size/2` + `pivot_offset` at center), size per **role** in
  `_setup_node`, re-render on resize in `_notification`, swipe ≥80px → 0.28s tween
  with target position of the **destination size**.
- `Db.get_book/get_books` normalize `cover` (may be NULL → `PackedByteArray`).
- **API 4.7**: `Control` has no `to_global/to_local` → use
  `get_global_transform() * pos` / `.affine_inverse() * pos`.

### UI flow (main.gd)

- `_ready`: `Db.get_setting("last_book_id")` → valid ⇒ confirmation screen, else empty state.
- "Open epub" button → SAF picker → import `Thread` → progress overlay → confirmation → saves `last_book_id`.
- Import error → overlay shows the message + Close button → back to the initial state.
- Confirmation → **"Start reading"** → Reader: loads `Db.get_paragraphs(last_book_id)` and `setup(book, paragraphs)`.
  "Library" button → carousel. **"Feed"** button → `setup_feed(random row)`.
- `_open_reader` calls **`Db.touch_book(book_id)`** → the opened book moves to the top of `get_books()`.
- Android back (`set_quit_on_go_back(false)` + `NOTIFICATION_WM_GO_BACK_REQUEST` in main.gd):
  from Reader → source screen (`_reader_return`); from confirmation → library; anywhere else quits.
  Escape (desktop) from Reader → `exit_requested` → same path.

### TikTok Reader (`ui/reader/reader.gd`)

- Layout (`.tscn` only): black background → cover (`KEEP`, aligned top) → black overlay alpha 0.65 →
  **2 A/B text panels OUTSIDE the Containers** (`position` is animated). Per panel:
  `TextViewport` (Control with clip, box margins 32/88/-32/-96) → `Label` **anchored at the top**
  (never inside a Container: autowrap has min-width 1px), height = full content
  (`_reset_label`: `size.y = get_minimum_size().y` + `_schedule_reset` **deferred**
  post-layout: the min computed before layout is wrong and doubles the height),
  **no ellipsis**.
- **Long paragraph**: text scrolls in place (`label.position.y ∈ [−overflow, 0]`); the drag uses an
  **absolute** model (`_drag_start_scroll` captured in `_begin_drag`, never sum the cumulative delta
  to events); scroll is consumed first; passing `HANDOFF_MIN` (40px) beyond the
  text edge → `_handoff(±1)` → slide to next/prev paragraph (incoming restarts
  from scroll at top).
- **Short paragraph** (overflow=0): card follows the finger, `SWIPE_THRESHOLD` 100px → ±1.
  Wheel: scrolls unless at the edges, at the edge → ±1.
- **Tap**: single = no action; **double tap** (≤15px movement, within `DOUBLE_TAP_MS`=300)
  → `library_requested` → `main.gd` → `_set_screen(_library)` (always library). A non-tap
  gesture (swipe/drag) resets the tap sequence.
- **Hold (auto-scroll)**: finger still ≥ `HOLD_MS` (450ms) on **long text** → automatic
  scrolling at `AUTO_SCROLL_SPEED` (40px/s) in `_process`; **stops at the end of the
  paragraph** (no continuation to the next) or on release; short paragraph →
  the hold does nothing. Movement >15px during the wait cancels the hold (normal drag);
  two fingers/tween cancel it. `_hold_consumed` (set when armed) makes the
  release after a hold **not** count as a tap and not trigger the double-tap.
- **Two fingers** (`_touch_count` on `InputEventScreenTouch`, counted before the guards):
  2nd finger → `_enter_multi()` (cancels single drag + snap); `ScreenDrag` with multi →
  accumulates `relative.x` (both fingers); release under 2 fingers → `|dx| ≥ SWIPE_THRESHOLD`
  → `_jump(±1)` = **±10 paragraphs with clamp** (`clampi`, never snap at the edges).
  In feed `_jump` → `_feed_jump` (forward fetch / walk back up the history).
  **DISABLED**: `_finish_multi` returns early when `MULTI_JUMP_ENABLED=false`
  (code kept: `_jump`/`_feed_jump` intact; re-enable with one flag).
- **Pinch** (`_finger_pos: Dictionary{index→pos}` on ScreenTouch/ScreenDrag,
  exactly 2 fingers): `_enter_multi` records `_pinch_base_dist`; during multi-drag
  `_update_pinch` fires when distance changes ≥ `PINCH_THRESHOLD` (60px), sets
  `_pinch_consumed` (gesture eaten once). **Pinch closed** → `Db.toggle_bookmark`
  on the current paragraph (not in feed mode) + ` ★` feedback on the chapter label;
  in bookmark mode a removal rebuilds the list (empty → library). **Pinch open**
  → only in bookmark mode: peek into `_all_paragraphs` at that seq
  (`_peek=true`, `_bookmark_mode=false`, `_bookmark_return_seq` saved).
- **Bookmark mode** (`setup_bookmarks(book, bookmarks, all)`): `_paragraphs` =
  bookmark list, counter `i / N`, chapter label = chapter + ` ★`, progress bar hidden,
  **no `last_seq` write**; navigation clamps to the list (snap at edges).
- **Peek** (`_peek`): renders the full book at the bookmark WITHOUT writing
  `last_seq` (same guard style as feed); any `_commit` clears `_peek` and saves
  normally from then on. `handle_back()` → true while peeking: returns to the
  bookmark list (`_exit_peek`); main.gd GO_BACK and Escape call it first.
  Double tap still goes to the library.
- **Feed mode** (`setup_feed(row)`): `_paragraphs` = growing feed history,
  `_seq` = position; at end of history `_go(+1)` runs `_fetch_feed_row()`
  (`Db.get_random_paragraph(exclude last_id)`, max 3 attempts). Dedicated render:
  chapter label = **book title** of the paragraph, counter = steps taken,
  progress bar hidden, **no `last_seq` write**, cover updated from the
  row (`book_id`+`cover`). Exit: back/double tap → library (`_reader_return`).
- Bookmark entry from the star: `_reader_return = _library`, `touch_book` runs,
  `last_seq` untouched until the user navigates normally.
- Paragraph view (`ui/paragraph_view/`): **disconnected** — no reference in reader/main.
- Animation: `create_tween().bind_node(self)`, `TRANS_CUBIC + EASE_OUT`, 0.28s, A/B panels swap
  roles; input blocked during the tween (`_kill_tween`); a release during the tween
  still resets `_dragging`.
- Saved position: `Db.set_setting("last_seq:<book_id>", str(seq))` (**one key per book**)
  at every confirmed paragraph; `setup()` restarts from there, clamped. Counter = `seq + 1 / total`.
- Cover: `BufferImage.to_texture` generates **mipmaps**; `CoverBg` has a `ShaderMaterial`
  with `ui/reader/cover_blur.gdshader` (`textureLod` on `SCREEN_UV.y`: sharp at the top,
  increasing blur at the bottom — `blur_start=0.15`, `max_lod=6`, tunable in the Inspector).

## Commands

- Desktop run (dev loop; the SAF picker works there too): `godot --path . `
- Check a script without launching the editor: `godot --headless --check-only -s <file.gd>` (or open the editor and read Output)
- **End-to-end import check** (imports `test-epub/*.epub` into the DB and prints counts):
  `godot --headless --path . -s res://verify_import.gd`
- Android export: `godot --headless --export-debug "Android" build/app.apk`

## Android notes

- Portrait orientation already set in `project.godot` (`window/handheld/orientation=1`), renderer `gl_compatibility`, ETC2/ASTC enabled.
- Critical UI (button, confirmation) respects `DisplayServer.get_display_safe_area()`, touch targets ≥ 44px.
- No storage permission required (SAF). DB always in `user://` (Android forbids writing to `res://`).

## Import verification

Two ways, after a successful import:

1. Script: `godot --headless --path . -s res://verify_import.gd` (prints books/counts/3 samples)
2. Manual SQL on `~/.local/share/godot/app_userdata/bookexplorer/library.db`:

```sql
SELECT id, title, paragraph_count FROM books;
SELECT count(*) FROM paragraphs WHERE book_id = '<id>';
```

`test-epub/` contains test epubs (Moby Dick, Standard Ebooks).
