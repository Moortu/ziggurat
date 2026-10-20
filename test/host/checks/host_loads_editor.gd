@tool
extends Node
# Host test "host loads in editor": runs as a tool autoload in the headless
# editor. Prints one ZTEST line per case, then ZTEST DONE; the runner's
# --quit-after ends the editor.


func report(name: String, ok: bool, why: String) -> void:
	if ok:
		print("ZTEST PASS %s" % name)
	else:
		print("ZTEST FAIL %s: %s" % [name, why])


func _ready() -> void:
	if not Engine.is_editor_hint():
		return
	var classes: Array[String] = []
	var found := false
	for i in Engine.get_script_language_count():
		var lang := Engine.get_script_language(i)
		classes.append(lang.get_class())
		if lang.get_class() == "ZigLanguage":
			found = true
	report("zig_language_registered_in_editor", found, "script languages: %s" % [classes])
	# GDScript cannot call a language's get_name(); the Create Script dialog
	# lists every language by the name the engine read from it.
	var names := script_dialog_languages()
	report("zig_language_name", names.has("Zig"), "Create Script dialog languages: %s" % [names])
	print("ZTEST DONE")


# The item texts of the language menus of every ScriptCreateDialog.
func script_dialog_languages() -> Array[String]:
	var names: Array[String] = []
	for dialog in get_tree().root.find_children("*", "ScriptCreateDialog", true, false):
		for menu in dialog.find_children("*", "OptionButton", true, false):
			for i in menu.item_count:
				names.append(menu.get_item_text(i))
	return names
