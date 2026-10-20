extends SceneTree
# Host test "cache rejects garbage". A first run (descriptor_cache.gd) wrote
# a good cache. This check makes bad copies of it, reads each, and expects
# -2 (rejected) with exactly one log line per file (the Zig test looks for the
# lines in Godot's output), the good file still reading, and a missing file
# reading as -1 without a log line.

const DIR := "res://.godot/ziggurat/"

var failed := false


func report(name: String, ok: bool, why: String) -> void:
	if ok:
		print("ZTEST PASS %s" % name)
	else:
		failed = true
		print("ZTEST FAIL %s: %s" % [name, why])


func put(name: String, text: String) -> String:
	var f := FileAccess.open(DIR + name, FileAccess.WRITE)
	f.store_string(text)
	f.close()
	return ProjectSettings.globalize_path(DIR + name)


func rejected(probe: Object, name: String, text: String) -> void:
	var path := put(name, text)
	var before: int = probe.cache_rejections()
	var r: int = probe.cache_read(path)
	report("rejects_" + name.get_basename(), r == -2 and probe.cache_rejections() == before + 1 and probe.cached_generation() == -1,
		"read %d, log lines %d, generation %d" % [r, probe.cache_rejections() - before, probe.cached_generation()])


func _initialize() -> void:
	var probe: Object = ClassDB.instantiate("ZigguratTestProbe")
	if probe == null:
		report("probe", false, "ZigguratTestProbe is not registered")
		print("ZTEST DONE")
		quit()
		return
	var good := FileAccess.get_file_as_string(DIR + "descriptors.json")
	var good_path := ProjectSettings.globalize_path(DIR + "descriptors.json")
	report("good_cache_reads", probe.cache_read(good_path) == 3 and probe.cache_rejections() == 0, "the good cache was not read")

	rejected(probe, "truncated.json", good.substr(0, good.length() / 2))
	rejected(probe, "truncated_early.json", good.substr(0, 12))
	rejected(probe, "version_2.json", good.replace("\"version\": 1", "\"version\": 2"))
	rejected(probe, "version_word.json", good.replace("\"version\": 1", "\"version\": \"one\""))
	rejected(probe, "empty.json", "")
	rejected(probe, "not_json.json", "ziggurat")
	rejected(probe, "binary.json", String.chr(0) + String.chr(255))
	rejected(probe, "wrong_type.json", good.replace("\"usage\": 4102", "\"usage\": \"x\""))
	rejected(probe, "scripts_not_array.json", "{\"version\": 1, \"generation\": 1, \"scripts\": {}}")
	rejected(probe, "bad_hash.json", good.replace("\"layout_hash\": \"", "\"layout_hash\": \"z"))
	rejected(probe, "deep.json", "{\"version\": 1, \"generation\": 1, \"x\": " + "[".repeat(200000))

	# After rejections the good file still reads; a missing one is -1.
	var n: int = probe.cache_read(good_path)
	report("good_cache_still_reads", n == 3 and probe.cached_generation() == 1, "scripts %d" % n)
	var before: int = probe.cache_rejections()
	report("missing_file_is_silent", probe.cache_read(good_path + ".none") == -1 and probe.cache_rejections() == before, "a missing file was logged or not -1")
	print("ZTEST DONE")
	quit()
