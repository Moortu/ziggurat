extends SceneTree
# Host test "cache round trip". The Zig test runs this check twice in the
# same project, each time in a fresh Godot process.
# Run 1 (res://lists.txt absent): loads the good module, writes the
# descriptor cache and records every list and default as text.
# Run 2 (res://lists.txt present): loads nothing, reads the cache and checks
# that its lists and defaults are the same text.

const SCRIPTS := ["items/coin.zig", "player.zig", "ui/hud_label.zig"]
const CACHE := "res://.godot/ziggurat/descriptors.json"

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


# Every list and default of the loaded scripts (cached = false) or of the
# cache (cached = true), as text.
func dump(probe: Object, cached: bool) -> String:
	var out := ""
	for rel in SCRIPTS:
		var s: int = -1 if cached else probe.find_script(rel)
		var props: Array = probe.cached_property_list(rel) if cached else probe.property_list(s)
		out += "%s\nproperties %s\nmethods %s\nsignals %s\n" % [
			rel, var_to_str(props),
			var_to_str(probe.cached_method_list(rel) if cached else probe.method_list(s)),
			var_to_str(probe.cached_signal_list(rel) if cached else probe.signal_list(s))]
		out += "layout %s\n" % (probe.cached_layout_hash(rel) if cached else probe.layout_hash(s))
		for i in props.size():
			out += "default %d %s\n" % [i, probe.cached_default_text(rel, i) if cached else probe.default_text(s, i)]
	return out


func _initialize() -> void:
	var probe: Object = ClassDB.instantiate("ZigguratTestProbe")
	if probe == null:
		report("probe", false, "ZigguratTestProbe is not registered")
		print("ZTEST DONE")
		quit()
		return
	var cache_path := ProjectSettings.globalize_path(CACHE)
	if not FileAccess.file_exists("res://lists.txt"):
		write_run(probe, cache_path)
	else:
		read_run(probe, cache_path)
	print("ZTEST DONE")
	quit()


func write_run(probe: Object, cache_path: String) -> void:
	var diag: String = probe.load_module(module_path(), 1)
	report("cache_write_load", diag == "", diag)
	if diag != "":
		return
	var err: String = probe.cache_write(cache_path)
	report("cache_write", err == "" and FileAccess.file_exists(CACHE), err)
	# A second write replaces the file; no temporary file stays next to it.
	err = probe.cache_write(cache_path)
	var left := DirAccess.get_files_at("res://.godot/ziggurat")
	report("cache_write_twice_no_temporary_file", err == "" and left == PackedStringArray(["descriptors.json"]), "%s %s" % [err, left])
	var f := FileAccess.open("res://lists.txt", FileAccess.WRITE)
	f.store_string(dump(probe, false))
	f.close()
	var text := FileAccess.get_file_as_string(CACHE)
	var json = JSON.parse_string(text)
	report("cache_is_json", json is Dictionary and json["version"] == 1 and json["generation"] == 1 and json["scripts"].size() == 3, text.substr(0, 200))
	var p: Dictionary = json["scripts"][1]
	report("cache_fields", p["path"] == "player.zig" and p["class_name"] == "Player" and p["base_class"] == "CharacterBody2D" and p["flags"] == 0 \
			and p["layout_hash"] is String and p["layout_hash"].length() > 0 and p["layout_hash"].lstrip("0123456789") == "" and p["properties"][1]["default"] == 300.0 and p["properties"][11].has("default") and p["properties"][11]["default"] == null and p["properties"][8]["default"] == [1.0, 2.0] \
			and not p["properties"][0].has("default") and json["scripts"][2]["flags"] == 1, "%s %s %s" % [p["properties"][1], p["properties"][8], p["properties"][11]])


func read_run(probe: Object, cache_path: String) -> void:
	report("fresh_process_has_no_module", probe.current_generation() == 0, "generation %d" % probe.current_generation())
	var n: int = probe.cache_read(cache_path)
	report("cache_read", n == 3 and probe.cached_generation() == 1, "scripts %d, generation %d" % [n, probe.cached_generation()])
	var want := FileAccess.get_file_as_string("res://lists.txt")
	var got: String = dump(probe, true)
	report("cache_lists_and_defaults_equal_loaded", got == want, "differs; cached:\n%s\nloaded:\n%s" % [got, want])
	report("cache_unknown_script", probe.cached_property_list("nope.zig").is_empty() and probe.cached_default_text("nope.zig", 0) == "<none>", "an unknown script has data")
	report("cache_missing_file", probe.cache_read(cache_path + ".missing") == -1 and probe.cache_rejections() == 0, "a missing file is not -1 or was logged")
