extends SceneTree
# Host tests "load good module", "load refuses bad module" and "name maps use
# interned names". The Zig test built the modules and listed their paths in
# res://modules.txt (good, other_sdk, truncated). Prints one ZTEST line per
# case, then ZTEST DONE.

var failed := false


func report(name: String, ok: bool, why: String) -> void:
	if ok:
		print("ZTEST PASS %s" % name)
	else:
		failed = true
		print("ZTEST FAIL %s: %s" % [name, why])


func modules() -> Dictionary:
	var out := {}
	for line in FileAccess.get_file_as_string("res://modules.txt").split("\n", false):
		var eq := line.find("=")
		out[line.substr(0, eq)] = line.substr(eq + 1)
	return out


func _initialize() -> void:
	var probe: Object = ClassDB.instantiate("ZigguratTestProbe")
	if probe == null:
		report("probe", false, "ZigguratTestProbe is not registered")
		print("ZTEST DONE")
		quit()
		return
	var m := modules()
	refusals_before_load(probe, m)
	good_load(probe, m)
	refusals_after_load(probe, m)
	names(probe)
	host_api(probe)
	print("ZTEST DONE")
	quit()


func expect_refused(probe: Object, path: String, gen: int, words: Array) -> String:
	var diag: String = probe.load_module(path, gen)
	if diag == "":
		return "%s loaded as generation %d" % [path.get_file(), gen]
	for w in words:
		if not diag.contains(w):
			return "sentence lacks '%s': %s" % [w, diag]
	if diag.count(". ") > 0:
		return "not one sentence: %s" % diag
	print("refused as expected: %s" % diag)
	return ""


func refusals_before_load(probe: Object, m: Dictionary) -> void:
	var why := expect_refused(probe, m["truncated"], 2, ["libtruncated.so", "truncated"])
	report("load_refuses_bad_module_truncated", why == "", why)
	why = expect_refused(probe, m["other_sdk"], 3, ["libother_sdk.so", "layout stamp"])
	report("load_refuses_bad_module_other_sdk", why == "", why)
	why = expect_refused(probe, m["good"], 0, [m["good"].get_file(), "reserved"])
	report("load_refuses_bad_module_generation_0", why == "", why)
	var none: bool = probe.current_generation() == 0 and probe.init_calls(2) == 0 and probe.init_calls(3) == 0 and probe.init_calls(0) == 0
	report("load_refuses_bad_module_nothing_initialised", none,
		"current %d, init calls %d/%d" % [probe.current_generation(), probe.init_calls(2), probe.init_calls(3)])


func good_load(probe: Object, m: Dictionary) -> void:
	var diag: String = probe.load_module(m["good"], 1)
	report("load_good_module", diag == "", diag)
	report("load_good_module_current", probe.current_generation() == 1, "current %d" % probe.current_generation())
	report("load_good_module_init_once", probe.init_calls(1) == 1, "init calls %d" % probe.init_calls(1))
	var found: bool = probe.find_script("items/coin.zig") == 0 and probe.find_script("player.zig") == 1 and probe.find_script("ui/hud_label.zig") == 2
	report("load_good_module_scripts_by_path", found, "coin %d, player %d, hud %d" % [
		probe.find_script("items/coin.zig"), probe.find_script("player.zig"), probe.find_script("ui/hud_label.zig")])
	var missing: bool = probe.find_script("nope.zig") == -1 and probe.find_script("res://player.zig") == -1 and probe.find_script("") == -1
	report("load_good_module_unknown_paths", missing, "an unknown path was found")


func refusals_after_load(probe: Object, m: Dictionary) -> void:
	var why := expect_refused(probe, m["good"], 1, ["already loaded"])
	report("load_refuses_bad_module_same_generation", why == "", why)
	why = expect_refused(probe, m["truncated"], 4, ["libtruncated.so"])
	report("load_refuses_bad_module_keeps_current", why == "" and probe.current_generation() == 1 and probe.init_calls(1) == 1,
		"%s; current %d, init calls %d" % [why, probe.current_generation(), probe.init_calls(1)])


func names(probe: Object) -> void:
	var player: int = probe.find_script("player.zig")
	var coin: int = probe.find_script("items/coin.zig")
	# Every method and non-group property maps to its own index; groups do not map.
	var wrong := []
	for s in [coin, player, probe.find_script("ui/hud_label.zig")]:
		for i in probe.method_count(s):
			var got: int = probe.method_index(s, StringName(probe.method_name(s, i)))
			if got != i:
				wrong.append("script %d method %d -> %d" % [s, i, got])
		for i in probe.property_count(s):
			var name: String = probe.property_name(s, i)
			var got: int = probe.property_index(s, StringName(name))
			# Group entries have no value: their labels never map (the
			# fixture has no property named like a group label).
			var want: int = -1 if probe.property_is_group(s, i) else i
			if got != want:
				wrong.append("script %d property %d (%s) -> %d" % [s, i, name, got])
	report("load_good_module_names_map_to_indexes", wrong.is_empty(), str(wrong))

	# Known indexes of the fixture (property indexes count group entries).
	var known: bool = (probe.method_index(player, &"_physics_process") == 0
		and probe.method_index(player, &"take_damage") == 1
		and probe.method_index(player, &"leap") == 2
		and probe.property_index(player, &"speed") == 1
		and probe.property_index(player, &"health") == 3
		and probe.property_index(player, &"spawn_point") == 8
		and probe.property_index(player, &"target") == 11
		and probe.method_index(coin, &"collect") == 0
		and probe.property_index(coin, &"texture") == 1)
	report("load_good_module_known_indexes", known, "a fixture name maps to the wrong index")

	# Interned names: a StringName built at run time from the same text maps;
	# names the script does not define, Zig names and the empty name do not.
	var built := StringName("take" + "_dam".to_upper().to_lower() + "age")
	report("name_maps_use_interned_names", probe.method_index(player, built) == 1,
		"run-time StringName take_damage -> %d" % probe.method_index(player, built))
	var others: bool = (probe.method_index(player, &"take_damage2") == -1
		and probe.method_index(player, &"jump") == -1
		and probe.method_index(player, &"takeDamage") == -1
		and probe.method_index(player, &"clamp_health") == -1
		and probe.method_index(player, &"speed") == -1
		and probe.property_index(player, &"leap") == -1
		and probe.property_index(player, &"spawn") == -1
		and probe.property_index(player, &"_dash_timer") == -1
		and probe.method_index(player, &"") == -1
		and probe.property_index(player, &"") == -1
		and probe.method_index(coin, &"take_damage") == -1)
	report("name_maps_use_interned_names_others_do_not_map", others, "a name the script does not define mapped")


# HostApi.log and request_swap as a module calls them, from the main thread
# and from another thread. The Zig test expects the lines in Godot's output.
func host_api(probe: Object) -> void:
	probe.api_log(0, "info from main")
	probe.api_log(1, "warning from main")
	probe.api_log(2, "error from main")
	var t := Thread.new()
	t.start(func() -> void:
		for i in 50:
			probe.api_log(0, "info from thread %d" % i))
	for i in 50:
		probe.api_log(0, "info from main %d" % i)
	t.wait_to_finish()
	probe.api_request_swap()
	probe.api_request_swap()
	report("host_api_log_returns", true, "")
