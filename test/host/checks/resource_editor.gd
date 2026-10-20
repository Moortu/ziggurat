@tool
extends Node
# Host test "loader and saver in the editor": runs as a tool autoload in the
# headless editor of test/host/projects/language. Checks what only the real
# editor does: the file scan (on its own thread) picks up `.zig` files and
# their global classes through the loader and the language, the file system
# reports the resource type of a `.zig` file, and a save from the script
# editor (which rewrites indentation with tabs, `convert_indent_on_save`)
# reaches the saver. TABS_KEPT is the finding of host test "tabs compile or
# are converted": the Zig 0.17 build accepts tab indentation, so the saver
# writes the editor's tabs unchanged (the Zig test fails if that changes).

const TABS_KEPT := true

var probe: Object


func report(name: String, ok: bool, why: String) -> void:
	if ok:
		print("ZTEST PASS %s" % name)
	else:
		print("ZTEST FAIL %s: %s" % [name, why])


func global_class(name: String) -> Dictionary:
	for entry in ProjectSettings.get_global_class_list():
		if entry.get("class") == name:
			return entry
	return {}


func _ready() -> void:
	if not Engine.is_editor_hint():
		return
	probe = ClassDB.instantiate("ZigguratTestProbe")
	probe.saved_hook_install()
	var efs := EditorInterface.get_resource_filesystem()
	# The first scan runs on a thread; wait for it and for the class list.
	for i in 900:
		if not efs.is_scanning() and not global_class("Alpha").is_empty() and not global_class("Beta").is_empty():
			break
		await get_tree().process_frame
	var alpha := global_class("Alpha")
	report("scan_global_class_top_level", alpha.get("language") == "Zig" and alpha.get("path") == "res://alpha.zig" and alpha.get("base") == "Node2D" and alpha.get("is_tool") == true, str(alpha))
	var beta := global_class("Beta")
	report("scan_global_class_subfolder", beta.get("language") == "Zig" and beta.get("path") == "res://sub/beta.zig" and beta.get("base") == "Resource", str(beta))
	report("scan_no_class_without_class_name", global_class("plain").is_empty() and global_class("Plain").is_empty(), str(ProjectSettings.get_global_class_list()))
	report("filesystem_file_type", efs.get_file_type("res://alpha.zig") == "ZigScript" and efs.get_file_type("res://plain.zig") == "ZigScript", "%s %s" % [efs.get_file_type("res://alpha.zig"), efs.get_file_type("res://plain.zig")])
	report("global_class_resolves_to_script", ResourceLoader.load("res://alpha.zig") is Script, "")
	await save_from_editor()
	print("ZTEST DONE")


# Opens res://plain.zig in the script editor, adds a space-indented line and
# saves all scripts. The editor converts the indentation to tabs first.
func save_from_editor() -> void:
	var script: Script = ResourceLoader.load("res://plain.zig")
	EditorInterface.edit_script(script)
	for i in 5:
		await get_tree().process_frame
	var editor := EditorInterface.get_script_editor()
	var current := editor.get_current_editor()
	var code: CodeEdit = current.get_base_editor() if current != null else null
	if code == null:
		report("editor_save_written", false, "no script editor for plain.zig")
		return
	code.set_caret_line(code.get_line_count() - 1)
	code.set_caret_column(code.get_line(code.get_line_count() - 1).length())
	code.insert_text_at_caret("\npub fn added() void {\n    const editor_added = 1;\n    _ = editor_added;\n}\n")
	probe.saved_hook_clear()
	editor.save_all_scripts()
	var text := FileAccess.get_file_as_string("res://plain.zig")
	var line := ""
	for l in text.split("\n"):
		if l.contains("const editor_added"):
			line = l
	report("editor_save_written", line != "", text)
	var want := "\tconst editor_added = 1;" if TABS_KEPT else "    const editor_added = 1;"
	report("editor_save_indentation", line == want, "line %s, wanted %s" % [var_to_str(line), var_to_str(want)])
	report("editor_save_hook", "plain.zig" in probe.saved_hook_paths(), str(probe.saved_hook_paths()))
	var reloaded: Script = ResourceLoader.load("res://plain.zig", "", ResourceLoader.CACHE_MODE_IGNORE)
	report("editor_save_loads_back", reloaded != null and reloaded.source_code == text, "")
