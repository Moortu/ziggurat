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


# The cache text with the default of property `name` of player.zig replaced
# by the raw JSON `raw`. Text surgery: re-serialising through JSON.stringify
# would turn the integers into floats, which the cache refuses.
func with_default(good: String, name: String, raw: String) -> String:
	var from := good.find("\"name\": \"%s\"" % name)
	var re := RegEx.create_from_string("\"default\": (\\[[^\\]]*\\]|[^\\n]+)")
	var m := re.search(good, from)
	return good.substr(0, m.get_start(1)) + raw + good.substr(m.get_end(1))


func prop_index(name: String) -> int:
	return ["", "speed", "", "health", "alive", "mood", "layers", "", "spawn_point", "", "title", "target"].find(name)


func dropped(probe: Object, name: String, prop: String, raw: String) -> void:
	var objects := Performance.get_monitor(Performance.OBJECT_COUNT)
	var path := put(name, with_default(FileAccess.get_file_as_string(DIR + "descriptors.json"), prop, raw))
	var drops: int = probe.cache_drops()
	var rejects: int = probe.cache_rejections()
	var n: int = probe.cache_read(path)
	report("drops_" + name.get_basename(), n == 3 and probe.cache_drops() == drops + 1 and probe.cache_rejections() == rejects
		and probe.cached_default_text("player.zig", prop_index(prop)) == "<none>"
		and probe.cached_default_text("player.zig", 10) != "<none>"
		and Performance.get_monitor(Performance.OBJECT_COUNT) == objects,
		"read %d, drop lines %d, default %s, objects %d -> %d" % [n, probe.cache_drops() - drops, probe.cached_default_text("player.zig", prop_index(prop)), objects, Performance.get_monitor(Performance.OBJECT_COUNT)])


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

	rejected(probe, "numeric_string_usage.json", good.replace("\"usage\": 4102", "\"usage\": \"4102\""))
	rejected(probe, "numeric_string_version.json", good.replace("\"version\": 1", "\"version\": \"1\""))
	rejected(probe, "deep_default.json", with_default(good, "speed", "[".repeat(200000)))
	rejected(probe, "deep_default_closed.json", with_default(good, "speed", "[".repeat(200000) + "]".repeat(200000)))

	# A default that does not fit its property is dropped (one log line per
	# file), the rest of the file stays, and nothing is constructed.
	var attack := JSON.stringify("Object ;c\n(Node, \"name\": \"pwn\")")
	dropped(probe, "drop_comment_attack.json", "speed", attack)
	dropped(probe, "drop_object_text.json", "speed", "\"Object(Node)\"")
	dropped(probe, "drop_numeric_string.json", "health", "\"5\"")
	dropped(probe, "drop_float_for_int.json", "health", "5.5")
	dropped(probe, "drop_short_vector.json", "spawn_point", "[1, 2, 3]")
	dropped(probe, "drop_int_for_bool.json", "alive", "1")
	dropped(probe, "drop_array_for_object.json", "target", "[1, 2]")
	# Text for a String property is only text.
	var text := "Object ;c\n(Node)"
	var before_objects := Performance.get_monitor(Performance.OBJECT_COUNT)
	var path := put("string_default.json", with_default(good, "title", JSON.stringify(text)))
	var drops_before: int = probe.cache_drops()
	var read_n: int = probe.cache_read(path)
	report("string_default_is_plain_text", read_n == 3 and probe.cache_drops() == drops_before and probe.cached_default_text("player.zig", 10) == var_to_str(text)
		and Performance.get_monitor(Performance.OBJECT_COUNT) == before_objects, "read %d, text %s" % [read_n, probe.cached_default_text("player.zig", 10)])

	# After rejections the good file still reads; a missing one is -1.
	var n: int = probe.cache_read(good_path)
	report("good_cache_still_reads", n == 3 and probe.cached_generation() == 1, "scripts %d" % n)
	var before: int = probe.cache_rejections()
	report("missing_file_is_silent", probe.cache_read(good_path + ".none") == -1 and probe.cache_rejections() == before, "a missing file was logged or not -1")
	print("ZTEST DONE")
	quit()
