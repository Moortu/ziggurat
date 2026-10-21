extends SceneTree
# Host test "snapshot defaults equal the module's for every vector type".
# Loads the vectors module, writes the descriptor cache from the loaded
# generation and from a snapshot of its table, and compares the two files.
# The fixture's values are all distinct, so a swapped component fails.

var failed := false


func report(name: String, ok: bool, why: String) -> void:
	if ok:
		print("ZTEST PASS %s" % name)
	else:
		failed = true
		print("ZTEST FAIL %s: %s" % [name, why])


func module_path() -> String:
	for line in FileAccess.get_file_as_string("res://modules.txt").split("\n", false):
		if line.begins_with("good="):
			return line.substr(5)
	return ""


func _initialize() -> void:
	var probe: Object = ClassDB.instantiate("ZigguratTestProbe")
	if probe == null:
		report("probe", false, "ZigguratTestProbe is not registered")
		print("ZTEST DONE")
		quit()
		return
	var diag: String = probe.load_module(module_path(), 1)
	report("vectors_load", diag == "", diag)
	if diag != "":
		print("ZTEST DONE")
		quit()
		return
	var live_path := ProjectSettings.globalize_path("res://.godot/ziggurat/live.json")
	var snap_path := ProjectSettings.globalize_path("res://.godot/ziggurat/snapshot.json")
	var e1: String = probe.cache_write(live_path)
	var e2: String = probe.cache_write_snapshot(snap_path)
	var live := FileAccess.get_file_as_string("res://.godot/ziggurat/live.json")
	var snap := FileAccess.get_file_as_string("res://.godot/ziggurat/snapshot.json")
	report("vectors_files_written", e1 == "" and e2 == "" and live != "", "%s %s" % [e1, e2])
	report("vectors_snapshot_equals_live", snap == live, "snapshot:\n%s\nlive:\n%s" % [snap, live])
	var json = JSON.parse_string(snap)
	var props: Array = json["scripts"][0]["properties"]
	var missing := []
	for p in props:
		if not p.has("default") or p["default"] == null:
			missing.append(p["name"])
	# 16 vector-like properties, every one with a stored default.
	report("vectors_all_have_defaults", props.size() == 16 and missing.is_empty(), "%d properties, no default: %s" % [props.size(), missing])
	var by_name := {}
	for p in props:
		by_name[p["name"]] = p["default"]
	report("vectors_component_order", by_name["t3"] == [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0] \
			and by_name["proj"] == [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0, 16.0] \
			and by_name["t2"] == [1.0, 2.0, 3.0, 4.0, 5.0, 6.0] and by_name["aabb"] == [1.0, 2.0, 3.0, 4.0, 5.0, 6.0] \
			and by_name["plane"] == [1.0, 2.0, 3.0, 4.0] and by_name["col"] == [0.25, 0.5, 0.75, 0.125], "wrong order: %s" % [by_name])
	DirAccess.remove_absolute(live_path)
	DirAccess.remove_absolute(snap_path)
	print("ZTEST DONE")
	quit()
