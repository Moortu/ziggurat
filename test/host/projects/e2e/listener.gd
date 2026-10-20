extends Node
# End-to-end check (host test "e2e headless", game pass, and the GUI test's
# game): runs in the game started on res://main.tscn, after the Zig scripts'
# `_ready` (siblings are ready before this node). It checks what a user of
# Zig scripts sees from GDScript:
# - `_ready` ran and the exported values are the scene's stored values;
# - `get_property_list` shows them with their types and hints;
# - a signal emitted with `z.emit` reaches connections made from GDScript
#   (`connect`, the `Signal` property `target.hit`) and from the scene file,
#   with the right arguments;
# - a method call returns its value;
# - a handler may read the emitting instance during the emit (a call into
#   the same instance while its method runs);
# - object metadata on a node with a Zig script still works.
# Prints one ZTEST line per case. Headless, it then prints ZTEST DONE and
# quits. With the environment variable ZTEST_GUI set (the GUI test), the game
# keeps running so the editor can save a script while it runs.

var hits := []
var signal_hits := []
var scene_hits := []
var seen_strikes := []
var target: Node


func report(name: String, ok: bool, why: String) -> void:
	if ok:
		print("ZTEST PASS %s" % name)
	else:
		print("ZTEST FAIL %s: %s" % [name, why])


func _on_hit(damage) -> void:
	hits.append(damage)
	# Back into the instance whose `strike` is running.
	seen_strikes.append(target.get("strikes"))


func _on_signal_hit(damage) -> void:
	signal_hits.append(damage)


func _on_scene_hit(damage) -> void:
	scene_hits.append(damage)


func find_prop(node: Object, name: String) -> Dictionary:
	for p in node.get_property_list():
		if p.name == name:
			return p
	return {}


func prop_ok(node: Object, name: String, type: int, hint: int, hint_string: String) -> bool:
	var p := find_prop(node, name)
	return not p.is_empty() and p.type == type and p.hint == hint and p.hint_string == hint_string and (p.usage & PROPERTY_USAGE_SCRIPT_VARIABLE) != 0


func _ready() -> void:
	var hero = get_node("../Hero")
	var beacon = get_node("../Beacon")
	target = get_node("../Target")

	report("game_scripts_attached", hero.get_script() is Script and hero.get_script().resource_path == "res://hero.zig" and target.get_script() != null,
		"hero script %s" % hero.get_script())

	# _ready ran once on each Zig node.
	report("ready_ran", hero.get("ready_calls") == 1, "ready_calls %s" % hero.get("ready_calls"))

	# The scene's stored values, not the defaults.
	report("exported_values_from_scene",
		hero.get("speed") == 12.5 and hero.get("title") == "stored title" and hero.get("layers") == 5 and hero.get("spawn") == Vector2(3, 4) and beacon.get("pulses") == 3,
		"speed %s title %s layers %s spawn %s pulses %s" % [hero.get("speed"), hero.get("title"), hero.get("layers"), hero.get("spawn"), beacon.get("pulses")])

	# The property list with types and hints.
	report("property_list_hints",
		prop_ok(hero, "speed", TYPE_FLOAT, PROPERTY_HINT_RANGE, "0,100,0.5")
		and prop_ok(hero, "title", TYPE_STRING, PROPERTY_HINT_NONE, "")
		and prop_ok(hero, "layers", TYPE_INT, PROPERTY_HINT_FLAGS, "ground:1,water:2,air:4")
		and prop_ok(hero, "spawn", TYPE_VECTOR2, PROPERTY_HINT_NONE, ""),
		"speed %s title %s layers %s spawn %s" % [find_prop(hero, "speed"), find_prop(hero, "title"), find_prop(hero, "layers"), find_prop(hero, "spawn")])

	# Signals: the script declares them, GDScript connects, z.emit delivers.
	var sig_names := []
	for s in target.get_signal_list():
		if s.name in ["hit", "idle"]:
			sig_names.append(s.name)
	report("signal_declared", target.has_signal("hit") and sig_names == ["hit", "idle"], str(sig_names))
	var err: int = target.connect("hit", _on_hit)
	var sig: Variant = target.get("hit")
	var sig_err := -1
	if sig is Signal:
		sig_err = sig.connect(_on_signal_hit)
	var strikes = target.strike(5)
	report("emit_reaches_connect", err == OK and hits == [5] and strikes == 1, "connect %s hits %s strikes %s" % [error_string(err), hits, strikes])
	report("emit_reaches_signal_property", sig is Signal and sig_err == OK and signal_hits == [5], "property %s connect %s hits %s" % [sig, sig_err, signal_hits])
	report("emit_reaches_scene_connection", scene_hits == [5], "hits %s" % [scene_hits])
	report("handler_reads_emitter", seen_strikes == [1], "strikes seen %s" % [seen_strikes])
	# A signal nothing connects to: emitting it is not an error.
	target.rest()

	# Method calls return their values.
	report("method_call_returns", hero.score(1) == 26 and beacon.pulse() == 4, "score %s" % hero.score(1))
	var m: Variant = hero.get("score")
	report("method_callable_property", m is Callable and m.call(2) == 27, "property %s" % [m])

	# Metadata is the object's, not the script's: `set` passes it on.
	hero.set_meta("tag", 7)
	hero.set("metadata/other", 8)
	report("metadata_not_swallowed", hero.get_meta("tag") == 7 and hero.get_meta("other") == 8 and hero.get("metadata/tag") == 7,
		"tag %s other %s" % [hero.get_meta("tag", null), hero.get_meta("other", null)])

	print("e2e game: checks done")
	if OS.get_environment("ZTEST_GUI") != "":
		return
	print("ZTEST DONE")
	get_tree().quit()
