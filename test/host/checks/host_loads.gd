extends SceneTree
# Host test "host loads": the host registered Zig as a script language.
# Prints one ZTEST line per case, then ZTEST DONE.


func report(name: String, ok: bool, why: String) -> void:
	if ok:
		print("ZTEST PASS %s" % name)
	else:
		print("ZTEST FAIL %s: %s" % [name, why])


func _initialize() -> void:
	var classes: Array[String] = []
	var found := false
	for i in Engine.get_script_language_count():
		var lang := Engine.get_script_language(i)
		classes.append(lang.get_class())
		if lang.get_class() == "ZigLanguage":
			found = true
	report("zig_language_registered", found, "script languages: %s" % [classes])
	report("single_precision", not OS.has_feature("double"), "Godot is a double-precision build")
	print("ZTEST DONE")
	quit()
