extends SceneTree
# Host test "property list matches descriptors". The Zig test built the
# fixture module and listed its path in res://modules.txt (good). Loads it and
# checks the property, method and signal dictionaries of the fixture scripts,
# then every default. Prints one ZTEST line per case, then ZTEST DONE.

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


# One property dictionary against its expected fields; "" when equal.
func prop_diff(d: Dictionary, name: String, type: int, hint: int, hint_string: String, usage: int, cls := "") -> String:
	var keys: Array = d.keys()
	keys.sort()
	if keys != ["class_name", "hint", "hint_string", "name", "type", "usage"]:
		return "keys %s" % [keys]
	var want := {"name": name, "type": type, "hint": hint, "hint_string": hint_string, "usage": usage}
	for k in want:
		if d[k] != want[k]:
			return "%s of '%s' is %s, want %s" % [k, name, d[k], want[k]]
	if typeof(d["name"]) != TYPE_STRING or typeof(d["class_name"]) != TYPE_STRING_NAME:
		return "'%s' has types name %d, class_name %d" % [name, typeof(d["name"]), typeof(d["class_name"])]
	if d["class_name"] != StringName(cls):
		return "class_name of '%s' is '%s', want '%s'" % [name, d["class_name"], cls]
	return ""


func method_diff(d: Dictionary, name: String, flags: int, args: Array, ret_type: int) -> String:
	var keys: Array = d.keys()
	keys.sort()
	if keys != ["args", "default_args", "flags", "id", "name", "return"]:
		return "keys %s" % [keys]
	if d["name"] != name or d["flags"] != flags or d["id"] != 0 or d["default_args"] != []:
		return "'%s': name %s flags %s id %s default_args %s" % [name, d["name"], d["flags"], d["id"], d["default_args"]]
	var got: Array = d["args"]
	if got.size() != args.size():
		return "'%s' has %d args, want %d" % [name, got.size(), args.size()]
	for i in args.size():
		var why := prop_diff(got[i], args[i][0], args[i][1], 0, "", 6, args[i][2] if args[i].size() > 2 else "")
		if why != "":
			return "'%s' arg %d: %s" % [name, i, why]
	var why := prop_diff(d["return"], "", ret_type, 0, "", 6)
	if why != "":
		return "'%s' return: %s" % [name, why]
	return ""


func signal_diff(d: Dictionary, name: String, args: Array) -> String:
	var keys: Array = d.keys()
	keys.sort()
	if keys != ["args", "name"]:
		return "keys %s" % [keys]
	if d["name"] != name or d["args"].size() != args.size():
		return "'%s': name %s, %d args" % [name, d["name"], d["args"].size()]
	for i in args.size():
		var why := prop_diff(d["args"][i], args[i][0], args[i][1], 0, "", 6, args[i][2] if args[i].size() > 2 else "")
		if why != "":
			return "'%s' arg %d: %s" % [name, i, why]
	return ""


func _initialize() -> void:
	var probe: Object = ClassDB.instantiate("ZigguratTestProbe")
	if probe == null:
		report("probe", false, "ZigguratTestProbe is not registered")
		print("ZTEST DONE")
		quit()
		return
	var diag: String = probe.load_module(module_path(), 1)
	report("load", diag == "", diag)
	if diag == "":
		player(probe)
		others(probe)
	print("ZTEST DONE")
	quit()


func player(probe: Object) -> void:
	var s: int = probe.find_script("player.zig")
	var P := 4102
	var G := 64
	var list: Array = probe.property_list(s)
	var want := [
		["Movement/Fast motion", TYPE_NIL, 0, "", G],
		["speed", TYPE_FLOAT, 1, "0,1000,5", P],
		["", TYPE_NIL, 0, "", G],
		["health", TYPE_INT, 1, "0,100", P],
		["alive", TYPE_BOOL, 0, "", P],
		["mood", TYPE_INT, 2, "calm:0,angry:1", P],
		["layers", TYPE_INT, 0, "", P],
		["Movement/Fast motion", TYPE_NIL, 0, "", G],
		["spawn_point", TYPE_VECTOR2, 0, "", P],
		["", TYPE_NIL, 0, "", G],
		["title", TYPE_STRING, 0, "", P],
		["target", TYPE_OBJECT, 34, "Node", P, "Node"],
	]
	var why := "" if list.size() == want.size() else "%d entries, want %d" % [list.size(), want.size()]
	if why == "":
		for i in want.size():
			var w: Array = want[i]
			why = prop_diff(list[i], w[0], w[1], w[2], w[3], w[4], w[5] if w.size() > 5 else "")
			if why != "":
				why = "entry %d: %s" % [i, why]
				break
	report("property_list_player", why == "", why)

	# The same indexes the name maps use.
	var idx: bool = true
	for i in list.size():
		var is_group: bool = (list[i]["usage"] & 64) != 0
		if is_group != probe.property_is_group(s, i) or list[i]["name"] != probe.property_name(s, i):
			idx = false
	report("property_list_player_matches_descriptor_indexes", idx, "list and descriptor differ")

	var ml: Array = probe.method_list(s)
	why = "" if ml.size() == 3 else "%d methods" % ml.size()
	if why == "":
		why = method_diff(ml[0], "_physics_process", 1 | 8, [["arg0", TYPE_FLOAT]], TYPE_NIL)
	if why == "":
		why = method_diff(ml[1], "take_damage", 1, [["amount", TYPE_INT], ["critical", TYPE_BOOL]], TYPE_NIL)
	if why == "":
		why = method_diff(ml[2], "leap", 1, [["arg0", TYPE_FLOAT]], TYPE_FLOAT)
	report("method_list_player", why == "", why)

	var sl: Array = probe.signal_list(s)
	why = "" if sl.size() == 2 else "%d signals" % sl.size()
	if why == "":
		why = signal_diff(sl[0], "died", [])
	if why == "":
		why = signal_diff(sl[1], "hit", [["damage", TYPE_INT], ["source", TYPE_OBJECT, "Node"]])
	report("signal_list_player", why == "", why)

	var defaults := ["<none>", "300.0", "<none>", "100", "true", "0", "1", "<none>", "Vector2(1, 2)", "<none>", "\"\"", "null"]
	var got := []
	for i in list.size() + 2:
		got.append(probe.default_text(s, i))
	got.resize(list.size())
	report("defaults_player", got == defaults, "got %s" % [got])
	report("default_out_of_range", probe.default_text(s, list.size()) == "<none>" and probe.default_text(s, -1) == "<none>" and probe.default_text(99, 0) == "<none>", "an index past the end has a default")


func others(probe: Object) -> void:
	var c: int = probe.find_script("items/coin.zig")
	var list: Array = probe.property_list(c)
	var why := "" if list.size() == 2 else "%d entries" % list.size()
	if why == "":
		why = prop_diff(list[0], "value", TYPE_INT, 0, "", 4102)
	if why == "":
		why = prop_diff(list[1], "texture", TYPE_OBJECT, 17, "Texture2D", 4102, "Texture2D")
	report("property_list_coin", why == "", why)
	var sl: Array = probe.signal_list(c)
	why = "" if sl.size() == 1 else "%d signals" % sl.size()
	if why == "":
		why = signal_diff(sl[0], "collected", [["by", TYPE_OBJECT, "Node"], ["value", TYPE_INT]])
	report("signal_list_coin", why == "", why)
	var ml: Array = probe.method_list(c)
	report("method_list_coin_return_type", ml.size() == 1 and ml[0]["return"]["type"] == TYPE_INT and ml[0]["args"][0]["class_name"] == &"Node", str(ml))

	var h: int = probe.find_script("ui/hud_label.zig")
	var hl: Array = probe.method_list(h)
	report("method_list_hud_virtual", hl.size() == 1 and hl[0]["name"] == "_process" and hl[0]["flags"] == 9, str(hl))
	report("empty_lists", probe.signal_list(h).is_empty() and probe.property_list(99).is_empty() and probe.method_list(-1).is_empty(), "lists of a script without signals or an unknown script are not empty")
