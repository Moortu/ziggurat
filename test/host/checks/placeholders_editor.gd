@tool
extends Node
# Host tests "placeholder shows properties" and "tool script runs in the
# editor": run as a tool autoload in the headless editor. An earlier script
# run wrote the descriptor cache of test/fixtures/instance_project, so the
# scripts have descriptors before any module is loaded.
# - mover.zig (not a tool script) gets a placeholder instance: its exported
#   properties and defaults show through the node, no module instance is
#   made, so `_ready` never runs (the Zig test also rejects its log line).
#   Loading the module refreshes the placeholder once, however often
#   update_exports is called; a failed build turns placeholder fallback on.
# - gadget.zig (`pub const tool = true`) gets a real instance once the module
#   is loaded, and its `_ready` runs (the Zig test expects its log line once).
# Prints one ZTEST line per case, then ZTEST DONE.

var probe: Object
var list_changes := 0


func report(name: String, ok: bool, why: String) -> void:
	if ok:
		print("ZTEST PASS %s" % name)
	else:
		print("ZTEST FAIL %s: %s" % [name, why])


func zig_script(path: String) -> Script:
	var s: Script = ClassDB.instantiate("ZigScript")
	s.resource_path = path
	return s


func module_path() -> String:
	for line in FileAccess.get_file_as_string("res://modules.txt").split("\n", false):
		if line.begins_with("good="):
			return line.substr(5)
	return ""


func property_names(o: Object) -> Array:
	var names := []
	for p in o.get_property_list():
		names.append(p.name)
	return names


func on_list_changed() -> void:
	list_changes += 1


# Properties and defaults of mover.zig, as the placeholder shows them.
func shows_mover(node: Object) -> String:
	var why := ""
	var names := property_names(node)
	for n in ["Motion", "speed", "steps", "title", "ready_calls", "notifications"]:
		if not names.has(n):
			why += "no %s in %s; " % [n, names]
	if node.get("speed") != 5.0:
		why += "speed %s; " % node.get("speed")
	if node.get("title") != "":
		why += "title %s; " % node.get("title")
	if node.get("steps") != 0 or node.get("ready_calls") != 0:
		why += "steps %s ready_calls %s; " % [node.get("steps"), node.get("ready_calls")]
	return why


func _ready() -> void:
	if not Engine.is_editor_hint():
		return
	probe = ClassDB.instantiate("ZigguratTestProbe")
	var mover_s := zig_script("res://mover.zig")
	var gadget_s := zig_script("res://gadget.zig")
	report("editor_has_cached_descriptors", probe.current_generation() == 0 and probe.script_is_valid(mover_s), "no cached descriptors")

	# A non-tool script in the editor: a placeholder.
	var mover := Node2D.new()
	mover.property_list_changed.connect(on_list_changed)
	mover.set_script(mover_s)
	report("placeholder_created", mover.get_script() == mover_s and probe.script_placeholder_count(mover_s) == 1 and probe.live_instances() == 0,
		"script %s placeholders %d instances %d" % [mover.get_script(), probe.script_placeholder_count(mover_s), probe.live_instances()])
	var why := shows_mover(mover)
	report("placeholder_shows_properties_from_cache", why == "", why)

	# A stored value differs from the default; setting the default back
	# drops it again.
	mover.set("speed", 8.0)
	var set_ok: bool = mover.get("speed") == 8.0
	mover.set("speed", 5.0)
	report("placeholder_keeps_set_values", set_ok and mover.get("speed") == 5.0, "speed %s" % mover.get("speed"))

	add_child(mover)
	await get_tree().process_frame
	await get_tree().process_frame
	report("placeholder_ready_not_run", probe.live_instances() == 0 and mover.get("ready_calls") == 0, "%d instances" % probe.live_instances())

	# Loading a module is a new descriptor generation: one refresh, however
	# often Godot asks (once per property while saving a scene).
	var refreshes: int = probe.script_update_exports(mover_s, 0)
	var changes := list_changes
	var diag: String = probe.load_module(module_path(), 1)
	report("editor_load_module", diag == "", diag)
	var after: int = probe.script_update_exports(mover_s, 20)
	why = shows_mover(mover)
	report("placeholder_refreshed_once_per_generation",
		after == refreshes + 1 and list_changes == changes + 1 and why == "" and probe.script_placeholder_count(mover_s) == 1 and probe.live_instances() == 0,
		"refreshes %d -> %d, list changes %d -> %d, %s" % [refreshes, after, changes, list_changes, why])

	# A failed build turns placeholder fallback on and stops refreshes; a
	# good build turns it off again and refreshes once.
	probe.script_set_build_failed(mover_s, true)
	var failed_fallback: bool = probe.script_fallback_enabled(mover_s)
	var during: int = probe.script_update_exports(mover_s, 5)
	probe.script_set_build_failed(mover_s, false)
	var cleared: int = probe.script_update_exports(mover_s, 5)
	report("build_failed_enables_fallback",
		failed_fallback and not probe.script_fallback_enabled(mover_s) and during == after and cleared == after + 1,
		"fallback %s, refreshes %d %d %d" % [failed_fallback, after, during, cleared])

	# A tool script: a real instance, and `_ready` runs in the editor.
	var gadget := Node.new()
	gadget.set_script(gadget_s)
	report("tool_script_real_instance", gadget.get_script() == gadget_s and probe.script_placeholder_count(gadget_s) == 0 and probe.live_instances() == 1,
		"script %s placeholders %d instances %d" % [gadget.get_script(), probe.script_placeholder_count(gadget_s), probe.live_instances()])
	add_child(gadget)
	await get_tree().process_frame
	report("tool_script_ready_ran", gadget.get("ready_calls") == 1, "ready_calls %s" % gadget.get("ready_calls"))

	# Freeing the owners erases the placeholder and frees the instance.
	mover.free()
	gadget.free()
	report("placeholder_erased", probe.script_placeholder_count(mover_s) == 0 and probe.live_instances() == 0,
		"placeholders %d instances %d" % [probe.script_placeholder_count(mover_s), probe.live_instances()])
	print("ZTEST DONE")
