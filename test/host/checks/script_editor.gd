@tool
extends Node
# Host test "can_instantiate rule", editor half: runs as a tool autoload in
# the headless editor. An earlier script run wrote the descriptor cache; the
# language read it at startup, so the scripts have descriptors without a
# loaded module. Checks that a non-tool Zig script cannot make instances in
# the editor while a tool script can (GDScript's rule), then loads the
# module and checks again. Prints one ZTEST line per case, then ZTEST DONE;
# the runner's --quit-after ends the editor.


func report(name: String, ok: bool, why: String) -> void:
	if ok:
		print("ZTEST PASS %s" % name)
	else:
		print("ZTEST FAIL %s: %s" % [name, why])


func zig_script(path: String) -> Script:
	var s: Script = ClassDB.instantiate("ZigScript")
	s.resource_path = path
	return s


func _ready() -> void:
	if not Engine.is_editor_hint():
		return
	var probe: Object = ClassDB.instantiate("ZigguratTestProbe")
	var player := zig_script("res://player.zig")
	var hud := zig_script("res://ui/hud_label.zig")
	var none := zig_script("res://nope.zig")
	report("editor_descriptors_from_cache", probe.current_generation() == 0 and probe.script_is_valid(player) and probe.script_is_valid(hud), "no cached descriptors in the editor")
	report("can_instantiate_editor_non_tool", not player.can_instantiate(), "a non-tool script can make instances in the editor")
	report("can_instantiate_editor_tool", hud.can_instantiate(), "a tool script cannot make instances in the editor")
	report("can_instantiate_editor_no_descriptors", not none.can_instantiate(), "a script without descriptors can make instances")
	# A non-tool script in the editor gets a placeholder instead.
	var node := CharacterBody2D.new()
	node.set_script(player)
	report("editor_placeholder_created", node.get_script() == player and probe.script_placeholder_count(player) == 1, "script %s" % node.get_script())
	node.free()
	# Loading a module in the editor leaves the module's static StringNames
	# at exit; the runner accepts them (only non-static references count).
	var diag: String = probe.load_module(module_path(), 1)
	report("editor_load_module", diag == "", diag)
	if diag == "":
		report("editor_rule_after_load", not player.can_instantiate() and hud.can_instantiate() and probe.current_generation() == 1, "rule changed after load")
	print("ZTEST DONE")


func module_path() -> String:
	for line in FileAccess.get_file_as_string("res://modules.txt").split("\n", false):
		if line.begins_with("good="):
			return line.substr(5)
	return ""
