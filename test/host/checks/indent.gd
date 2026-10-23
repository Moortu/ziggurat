@tool
extends Node
# Host test "zig tabs indent with spaces": runs as a tool autoload in the
# headless editor of test/host/projects/highlighter (no Zig, so nothing
# builds). With the editor setting `ziggurat/editor/indent_with_spaces` on
# (the default) the editor plugin sets `indent_use_spaces` and
# `indent_size` 4 on the CodeEdit of every open `.zig` tab, also after
# Godot applied its own indentation settings to every tab again (a change
# of a `text_editor` setting; the settings dialog sends
# NOTIFICATION_EDITOR_SETTINGS_CHANGED, which the check sends itself), so a
# save through the script editor (`convert_indent_on_save`) writes spaces.
# With the setting off the tab keeps Godot's choice (tabs by default).
# Prints one ZTEST line per case, then ZTEST DONE, and quits the editor.

const WAIT_MS := 30000
const SPACES := "ziggurat/editor/indent_with_spaces"
const SIZE := "text_editor/behavior/indent/size"


func report(name: String, ok: bool, why: String) -> void:
	if ok:
		print("ZTEST PASS %s" % name)
	else:
		print("ZTEST FAIL %s: %s" % [name, why])


func frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _ready() -> void:
	if not Engine.is_editor_hint():
		return
	await run()
	print("ZTEST DONE")
	get_tree().quit()


func indent_of(code: CodeEdit) -> String:
	return "indent_use_spaces %s, indent_size %d" % [code.indent_use_spaces, code.indent_size]


# Godot applies the `text_editor` settings to every open tab again, as
# after the settings dialog changed one (EditorSettings.notify_changes).
func settings_dialog_applied() -> void:
	get_tree().root.propagate_notification(EditorSettings.NOTIFICATION_EDITOR_SETTINGS_CHANGED)


func run() -> void:
	var end := Time.get_ticks_msec() + WAIT_MS
	while EditorInterface.get_script_editor() == null and Time.get_ticks_msec() < end:
		await get_tree().process_frame
	var es := EditorInterface.get_editor_settings()
	report("indent_setting_default", es.has_setting(SPACES) and es.get_setting(SPACES) == true, "has %s, value %s" % [es.has_setting(SPACES), es.get_setting(SPACES) if es.has_setting(SPACES) else null])

	var code := await open_tab("res://mover.zig")
	if code == null:
		report("indent_spaces_on_open", false, "no script editor for mover.zig")
		return
	report("indent_spaces_on_open", code.indent_use_spaces and code.indent_size == 4, indent_of(code))

	# A `text_editor` change: Godot sets its own indentation (tabs, size 8)
	# on every tab again; the plugin sets spaces and 4 back.
	es.set_setting(SIZE, 8)
	settings_dialog_applied()
	var godot_applied := indent_of(code)
	await frames(5)
	report("indent_spaces_after_settings_change", code.indent_use_spaces and code.indent_size == 4, "%s (right after Godot applied its settings: %s)" % [indent_of(code), godot_applied])
	es.set_setting(SIZE, 4)
	settings_dialog_applied()
	await frames(5)

	# A save through the script editor converts the indentation to the
	# tab's: spaces.
	code.set_caret_line(code.get_line_count() - 1)
	code.set_caret_column(code.get_line(code.get_line_count() - 1).length())
	code.insert_text_at_caret("\npub fn added() void {\n\tconst tab_added = 1;\n\t_ = tab_added;\n}\n")
	EditorInterface.get_script_editor().save_all_scripts()
	var text := FileAccess.get_file_as_string("res://mover.zig")
	var tabbed := []
	var added := ""
	for l in text.split("\n"):
		if l.begins_with("\t"):
			tabbed.append(l)
		if l.contains("const tab_added"):
			added = l
	report("indent_save_no_leading_tab", tabbed.is_empty() and added == "    const tab_added = 1;", "lines with a leading tab %s, added line %s" % [str(tabbed), var_to_str(added)])

	# ---- setting off: Godot's choice (tabs by default), also after Godot
	# applies its settings again and in a tab opened afterwards.
	es.set_setting(SPACES, false)
	await frames(5)
	var off_now := indent_of(code)
	var off_tabs := not code.indent_use_spaces
	settings_dialog_applied()
	await frames(5)
	var other := await open_tab("res://other.zig")
	var ok := off_tabs and not code.indent_use_spaces and other != null and not other.indent_use_spaces
	report("indent_setting_off_godot_choice", ok, "mover: %s right after the change, %s after Godot applied its settings; other.zig: %s" % [off_now, indent_of(code), indent_of(other) if other != null else "no tab"])
	es.set_setting(SPACES, true)
	await frames(5)
	report("indent_setting_on_again", code.indent_use_spaces and other != null and other.indent_use_spaces, "mover: %s; other.zig: %s" % [indent_of(code), indent_of(other) if other != null else "no tab"])


# Opens `path` in the script editor; returns the tab's CodeEdit or null.
func open_tab(path: String) -> CodeEdit:
	EditorInterface.edit_script(ResourceLoader.load(path))
	for i in 5:
		await get_tree().process_frame
	var current := EditorInterface.get_script_editor().get_current_editor()
	return current.get_base_editor() if current != null else null
