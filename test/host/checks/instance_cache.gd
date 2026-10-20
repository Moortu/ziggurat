extends SceneTree
# Host test "placeholder shows properties", game half: loads the module built
# from test/fixtures/instance_project and writes its descriptor cache, so the
# editor run that follows has descriptors before it loads any module.

const CACHE := "res://.godot/ziggurat/descriptors.json"


func module_path() -> String:
	for line in FileAccess.get_file_as_string("res://modules.txt").split("\n", false):
		if line.begins_with("good="):
			return line.substr(5)
	return ""


func _initialize() -> void:
	var probe: Object = ClassDB.instantiate("ZigguratTestProbe")
	var diag: String = probe.load_module(module_path(), 1)
	if diag == "":
		diag = probe.cache_write(ProjectSettings.globalize_path(CACHE))
	if diag == "":
		print("ZTEST PASS instance_cache_written")
	else:
		print("ZTEST FAIL instance_cache_written: %s" % diag)
	print("ZTEST DONE")
	quit()
