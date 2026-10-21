@tool
extends Node
# Host test "placeholders refresh after swap": run as a tool autoload in the
# headless editor. mover.zig is not a tool script, so its node holds a
# placeholder fed from generation 1 (test/fixtures/swap_v1). After a swap to
# generation 2 (swap_v2), which adds the property `added`, the placeholder
# shows it with its default.

const SWAPPED := 3

var probe: Object


func report(name: String, ok: bool, why: String) -> void:
	if ok:
		print("ZTEST PASS %s" % name)
	else:
		print("ZTEST FAIL %s: %s" % [name, why])


func module_path(key: String) -> String:
	for line in FileAccess.get_file_as_string("res://modules.txt").split("\n", false):
		if line.begins_with(key + "="):
			return line.substr(key.length() + 1)
	return ""


func property_names(o: Object) -> Array:
	var names := []
	for p in o.get_property_list():
		names.append(p.name)
	return names


func _ready() -> void:
	if not Engine.is_editor_hint():
		return
	probe = ClassDB.instantiate("ZigguratTestProbe")
	var diag: String = probe.load_module(module_path("v1"), 1)
	var staged: String = probe.stage_module(module_path("v2"), 2)
	report("editor_load", diag == "" and staged == "", diag + staged)
	var mover_s: Script = ClassDB.instantiate("ZigScript")
	mover_s.resource_path = "res://mover.zig"
	var mover := Node.new()
	mover.set_script(mover_s)
	add_child(mover)
	var before := property_names(mover)
	report("placeholder_before_swap",
		probe.script_placeholder_count(mover_s) == 1 and probe.live_instances() == 0
		and before.has("hp") and not before.has("added"), "properties %s" % [before])

	probe.swap_request(2)
	var frames := 0
	while probe.swap_outcome() != SWAPPED and frames < 300:
		await get_tree().process_frame
		frames += 1
	var after := property_names(mover)
	report("placeholders_refresh_after_swap",
		probe.current_generation() == 2 and after.has("added") and not after.has("hp")
		and mover.get("added") == 7 and probe.script_placeholder_count(mover_s) == 1,
		"current %d, properties %s, added %s" % [probe.current_generation(), after, mover.get("added")])
	mover.queue_free()
	print("ZTEST DONE")
