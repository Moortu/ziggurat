extends SceneTree
# Host tests "script reports descriptors", "script without descriptors",
# "update_exports is idempotent" and the game half of "can_instantiate rule".
# The Zig test runs this check twice in the same project, each time in a
# fresh Godot process. The fixture's player.zig text is res://player_source.txt.
# Run 1 (res://script_lists.txt absent): checks ZigScripts without any
# descriptors, loads the good module, checks every answer of a ZigScript
# against the module's descriptors, writes the descriptor cache and records
# the lists as text.
# Run 2 (res://script_lists.txt present): loads nothing at first, so the
# scripts answer from the descriptor cache the language read at startup;
# then checks that update_exports refreshes once per descriptor generation.

const CACHE := "res://.godot/ziggurat/descriptors.json"
const LISTS := "res://script_lists.txt"

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


# A new ZigScript with resource path `path` ("" for none).
func zig_script(path: String) -> Script:
	var s: Script = ClassDB.instantiate("ZigScript")
	if path != "":
		s.resource_path = path
	return s


# The script's lists as text, for comparing two processes.
func dump(s: Script) -> String:
	return "properties %s\nmethods %s\nsignals %s\n" % [
		var_to_str(s.get_script_property_list()),
		var_to_str(s.get_script_method_list()),
		var_to_str(s.get_script_signal_list())]


func _initialize() -> void:
	var probe: Object = ClassDB.instantiate("ZigguratTestProbe")
	if probe == null:
		report("probe", false, "ZigguratTestProbe is not registered")
		print("ZTEST DONE")
		quit()
		return
	if not FileAccess.file_exists(LISTS):
		first_run(probe)
	else:
		second_run(probe)
	print("ZTEST DONE")
	quit()


# Every answer of a script that has no descriptors; "" when all are empty.
func empty_answers(probe: Object, s: Script) -> String:
	var why := ""
	if probe.script_is_valid(s):
		why += "valid; "
	if not probe.script_fallback_enabled(s):
		why += "placeholder fallback off; "
	if s.can_instantiate():
		why += "can instantiate; "
	if not s.get_script_property_list().is_empty() or not s.get_script_method_list().is_empty() or not s.get_script_signal_list().is_empty():
		why += "lists not empty; "
	if s.get_instance_base_type() != &"" or s.get_global_name() != &"" or s.is_tool():
		why += "base %s, global %s, tool %s; " % [s.get_instance_base_type(), s.get_global_name(), s.is_tool()]
	if s.has_script_method(&"take_damage") or s.has_script_signal(&"hit") or probe.script_has_default(s, &"speed"):
		why += "has a member; "
	if s.get_property_default_value(&"speed") != null or not probe.script_method_info(s, &"leap").is_empty():
		why += "has a default or method info; "
	if not probe.script_members(s).is_empty() or probe.script_member_line(s, &"speed") != -1:
		why += "has members; "
	if not s.get_script_constant_map().is_empty() or s.get_rpc_config() != {}:
		why += "constants or rpc config; "
	return why


func first_run(probe: Object) -> void:
	# No module and no cache: nothing describes any script.
	var none := zig_script("res://player.zig")
	var no_path := zig_script("")
	var why := empty_answers(probe, none)
	if why == "":
		why = empty_answers(probe, no_path)
	report("script_without_descriptors", why == "", why)
	none = null
	no_path = null

	var diag: String = probe.load_module(module_path(), 1)
	report("load", diag == "", diag)
	if diag != "":
		return

	var unknown := zig_script("res://nope.zig")
	why = empty_answers(probe, unknown)
	report("script_without_descriptors_unknown_path", why == "", why)
	unknown = null

	var player := zig_script("res://player.zig")
	var hud := zig_script("res://ui/hud_label.zig")
	var i: int = probe.find_script("player.zig")
	why = ""
	# Godot passes the lists through PropertyInfo and MethodInfo, which
	# keeps the content but not the key order: compare with ==.
	if player.get_script_property_list() != probe.property_list(i):
		why += "property list differs: %s; " % [player.get_script_property_list()]
	if player.get_script_method_list() != probe.method_list(i):
		why += "method list differs: %s vs %s; " % [player.get_script_method_list(), probe.method_list(i)]
	# Signals pass through MethodInfo, which adds method keys (flags, id,
	# return, default_args): compare names and arguments.
	var sl: Array = player.get_script_signal_list()
	var want_sl: Array = probe.signal_list(i)
	if sl.size() != want_sl.size():
		why += "%d signals; " % sl.size()
	else:
		for n in sl.size():
			if sl[n]["name"] != want_sl[n]["name"] or sl[n]["args"] != want_sl[n]["args"]:
				why += "signal %d differs: %s; " % [n, sl[n]]
	if player.get_script_property_list().size() != 12 or player.get_script_method_list().size() != 3 or player.get_script_signal_list().size() != 2:
		why += "list sizes; "
	report("script_reports_descriptors_lists", why == "", why)

	why = ""
	if not probe.script_is_valid(player) or probe.script_fallback_enabled(player):
		why += "valid %s, fallback %s; " % [probe.script_is_valid(player), probe.script_fallback_enabled(player)]
	if player.get_instance_base_type() != &"CharacterBody2D" or player.get_global_name() != &"Player":
		why += "base %s, global %s; " % [player.get_instance_base_type(), player.get_global_name()]
	if player.is_tool() or not hud.is_tool() or hud.get_global_name() != &"HudLabel":
		why += "tool flags or hud name; "
	if not player.has_script_method(&"take_damage") or not player.has_script_method(&"_physics_process") or player.has_script_method(&"takeDamage") or player.has_script_method(&"nope"):
		why += "has_method; "
	if not player.has_script_signal(&"hit") or not player.has_script_signal(&"died") or player.has_script_signal(&"nope"):
		why += "has_script_signal; "
	var info: Dictionary = probe.script_method_info(player, &"leap")
	if info.get("name") != "leap" or info.get("return", {}).get("type") != TYPE_FLOAT or not probe.script_method_info(player, &"nope").is_empty():
		why += "method info %s; " % [info]
	report("script_reports_descriptors_queries", why == "", why)

	why = ""
	if player.get_property_default_value(&"speed") != 300.0 or player.get_property_default_value(&"spawn_point") != Vector2(1, 2) or player.get_property_default_value(&"alive") != true:
		why += "defaults %s %s; " % [player.get_property_default_value(&"speed"), player.get_property_default_value(&"spawn_point")]
	if not probe.script_has_default(player, &"speed") or not probe.script_has_default(player, &"target") or probe.script_has_default(player, &"Movement/Fast motion") or probe.script_has_default(player, &"nope"):
		why += "has_property_default_value; "
	var members: Array = probe.script_members(player)
	if members != [&"speed", &"health", &"alive", &"mood", &"layers", &"spawn_point", &"title", &"target"]:
		why += "members %s; " % [members]
	if not player.get_script_constant_map().is_empty() or player.get_rpc_config() != {}:
		why += "constants %s, rpc %s; " % [player.get_script_constant_map(), player.get_rpc_config()]
	report("script_reports_descriptors_defaults_members", why == "", why)

	# Member lines: the first top-level line declaring the member.
	var text := FileAccess.get_file_as_string("res://player_source.txt")
	player.source_code = text
	var lines := text.split("\n")
	var want := {}
	for n in lines.size():
		for key in [["speed", "speed: "], ["take_damage", "pub fn takeDamage("], ["_physics_process", "pub fn _physicsProcess("], ["signals", "pub const signals"]]:
			if not want.has(key[0]) and lines[n].begins_with(key[1]):
				want[key[0]] = n + 1
	why = "" if want.size() == 4 else "fixture lines not found: %s" % [want]
	for key in want:
		var got: int = probe.script_member_line(player, StringName(key))
		if got != want[key]:
			why += "%s at %d, want %d; " % [key, got, want[key]]
	# `hit` is declared inside `signals`, not at the top level; `leap` is a
	# meta name with no declaration of its own.
	for key in [&"hit", &"leap", &"nope", &""]:
		if probe.script_member_line(player, key) != -1:
			why += "%s has a line; " % key
	report("script_reports_descriptors_member_lines", why == "", why)
	report("script_source_code", player.source_code == text and player.has_source_code(), "source code not kept")

	# The game half of the can_instantiate rule: not in the editor, every
	# valid script can make instances.
	report("can_instantiate_game", player.can_instantiate() and hud.can_instantiate(), "player %s, hud %s" % [player.can_instantiate(), hud.can_instantiate()])

	# Instances are refused with one line naming the script; the node keeps
	# no script.
	var node := Node.new()
	node.set_script(player)
	report("instance_create_refused", node.get_script() == null, "node has a script")
	node.free()

	report("reload_returns_ok", player.reload() == OK and player.reload(true) == OK, "reload failed")

	var err: String = probe.cache_write(ProjectSettings.globalize_path(CACHE))
	report("script_cache_write", err == "", err)
	var f := FileAccess.open(LISTS, FileAccess.WRITE)
	f.store_string(dump(player) + dump(hud))
	f.close()
	player = null
	hud = null


func second_run(probe: Object) -> void:
	report("second_run_has_no_module", probe.current_generation() == 0, "generation %d" % probe.current_generation())
	var player := zig_script("res://player.zig")
	var hud := zig_script("res://ui/hud_label.zig")
	var want := FileAccess.get_file_as_string(LISTS)
	var got := dump(player) + dump(hud)
	report("script_reports_descriptors_from_cache", got == want, "differs; cached:\n%s\nloaded:\n%s" % [got, want])
	var why := ""
	if not probe.script_is_valid(player) or probe.script_fallback_enabled(player):
		why += "valid or fallback; "
	if player.get_instance_base_type() != &"CharacterBody2D" or player.get_global_name() != &"Player" or player.is_tool() or not hud.is_tool():
		why += "base, name or tool flags; "
	if player.get_property_default_value(&"speed") != 300.0 or not player.has_script_method(&"take_damage") or not player.has_script_signal(&"hit"):
		why += "default, method or signal; "
	if probe.script_members(player).size() != 8 or probe.script_method_info(player, &"leap").get("name") != "leap":
		why += "members or method info; "
	report("script_reports_descriptors_from_cache_queries", why == "", why)

	# Godot calls update_exports once per property during a scene save:
	# only a new descriptor generation refreshes.
	var none := zig_script("res://nope.zig")
	var a: int = probe.script_update_exports(player, 50)
	var b: int = probe.script_update_exports(none, 50)
	var diag: String = probe.load_module(module_path(), 1)
	report("load", diag == "", diag)
	var c: int = probe.script_update_exports(player, 50)
	report("update_exports_is_idempotent", a == 1 and b == 0 and c == 2, "refreshes: cache %d, no descriptors %d, after load %d" % [a, b, c])
	report("script_reports_loaded_after_cache", player.get_script_property_list() == probe.property_list(probe.find_script("player.zig")), "property list differs after load")
	player = null
	hud = null
	none = null
