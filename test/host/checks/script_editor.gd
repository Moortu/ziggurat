@tool
extends Node
# Host test "can_instantiate rule", editor half: runs as a tool autoload in
# the headless editor. An earlier script run wrote the descriptor cache; the
# language read it at startup, so the scripts have descriptors without a
# loaded module. Checks that a non-tool Zig script cannot make instances in
# the editor while a tool script can (GDScript's rule). Prints one ZTEST
# line per case, then ZTEST DONE; the runner's --quit-after ends the editor.


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
	# A non-tool script in the editor asks for a placeholder instead.
	var node := Node.new()
	node.set_script(player)
	report("editor_placeholder_refused", node.get_script() == null, "node has a script")
	node.free()
	print("ZTEST DONE")
