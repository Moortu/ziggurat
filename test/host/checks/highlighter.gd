@tool
extends Node
# Host test "zig tab uses the Zig highlighter": runs as a tool autoload in
# the headless editor of test/host/projects/highlighter. The editor plugin
# gives the script editor the Zig highlighter, so a Zig tab's current
# highlighter is a `ZigHighlighter` named "Zig", each tab has its own
# (`_create`), and its regions carry the colours of the editor settings
# `text_editor/theme/highlighting/*`, with columns in code points. Prints
# one ZTEST line per case, then ZTEST DONE, and quits the editor.

const WAIT_MS := 30000
const HL := "text_editor/theme/highlighting/"


func report(name: String, ok: bool, why: String) -> void:
	if ok:
		print("ZTEST PASS %s" % name)
	else:
		print("ZTEST FAIL %s: %s" % [name, why])


func _ready() -> void:
	if not Engine.is_editor_hint():
		return
	await run()
	print("ZTEST DONE")
	get_tree().quit()


func run() -> void:
	var end := Time.get_ticks_msec() + WAIT_MS
	while EditorInterface.get_script_editor() == null and Time.get_ticks_msec() < end:
		await get_tree().process_frame
	var mover := await open_tab("res://mover.zig")
	if mover == null:
		report("highlighter_current", false, "no script editor for mover.zig")
		return
	var h: SyntaxHighlighter = mover.syntax_highlighter
	report("highlighter_current", h != null and h.get_class() == "ZigHighlighter", "highlighter %s" % (h.get_class() if h != null else "none"))
	if h == null or h.get_class() != "ZigHighlighter":
		return
	var checked := checked_highlighter()
	report("highlighter_name_zig", checked == "Zig", "checked menu item '%s'" % checked)

	var settings := EditorInterface.get_editor_settings()
	var keyword: Color = settings.get_setting(HL + "keyword_color")
	var control_flow: Color = settings.get_setting(HL + "control_flow_keyword_color")
	var number: Color = settings.get_setting(HL + "number_color")
	var string: Color = settings.get_setting(HL + "string_color")
	var doc: Color = settings.get_setting(HL + "doc_comment_color")

	var pub_line := find_line(mover, "pub const extends")
	var regions: Dictionary = h.get_line_syntax_highlighting(pub_line)
	report("highlighter_pub_keyword", pub_line >= 0 and color_at(regions, 0) == keyword, "line %d regions %s, keyword %s" % [pub_line, regions, keyword])
	var doc_line := find_line(mover, "//! Fixture")
	report("highlighter_doc_comment", color_at(h.get_line_syntax_highlighting(doc_line), 0) == doc, "doc line %d" % doc_line)

	# "ä" and the emoji are one column each (Godot's String holds code
	# points); String.find counts the same way.
	var smile_line := find_line(mover, "pub const smile")
	var text := mover.get_line(smile_line)
	regions = h.get_line_syntax_highlighting(smile_line)
	var else_col := text.find("else")
	var num_col := text.find("42")
	var str_col := text.find("\"")
	var ok: bool = regions.has(else_col) and color_at(regions, else_col) == control_flow and regions.has(num_col) and color_at(regions, num_col) == number and color_at(regions, str_col) == string
	report("highlighter_code_point_columns", ok, "line '%s' regions %s" % [text, regions])

	var other := await open_tab("res://other.zig")
	var h2: SyntaxHighlighter = other.syntax_highlighter if other != null else null
	report("highlighter_per_tab", h2 != null and h2.get_class() == "ZigHighlighter" and h2 != h, "second tab %s" % h2)


# Opens `path` in the script editor; returns the tab's CodeEdit or null.
func open_tab(path: String) -> CodeEdit:
	EditorInterface.edit_script(ResourceLoader.load(path))
	for i in 5:
		await get_tree().process_frame
	var current := EditorInterface.get_script_editor().get_current_editor()
	return current.get_base_editor() if current != null else null


func find_line(code: CodeEdit, start: String) -> int:
	for i in code.get_line_count():
		if code.get_line(i).begins_with(start):
			return i
	return -1


func color_at(regions: Dictionary, column: int) -> Variant:
	# A region runs to the next key: the colour of the last key <= column.
	var best := -1
	for k in regions.keys():
		if k <= column and k > best:
			best = k
	if best < 0:
		return null
	return regions[best].get("color")


# The checked item of the current tab's Edit > Syntax Highlighter menu
# (Godot fills it from each highlighter's `_get_name` when it opens).
func checked_highlighter() -> String:
	for popup in EditorInterface.get_script_editor().find_children("*", "PopupMenu", true, false):
		for i in popup.item_count:
			if popup.get_item_text(i) != "Syntax Highlighter":
				continue
			var sub: PopupMenu = popup.get_item_submenu_node(i)
			if sub == null:
				continue
			sub.about_to_popup.emit()
			for j in sub.item_count:
				if sub.is_item_checked(j):
					return sub.get_item_text(j)
	return ""
