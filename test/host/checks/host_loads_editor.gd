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
	print("ZTEST DONE")
