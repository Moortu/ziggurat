@tool
extends Node
# Host test "load checks": runs as a tool autoload in the headless editor of
# test/host/projects/load_checks. After the build at open, the host's load
# checks report a property and a method whose Godot names
# already exist in Node (named.zig) and a Node field in a Resource script
# (holder.zig), as diagnostics without a line; clean.zig has none. Prints
# one ZTEST line per case, then ZTEST DONE, and quits the editor. The
# findings fail the build: its generation is not used.

const WAIT_MS := 600000

var probe: Object


func report(name: String, ok: bool, why: String) -> void:
	if ok:
		print("ZTEST PASS %s" % name)
	else:
		print("ZTEST FAIL %s: %s" % [name, why])


func messages(path: String) -> Array:
	var out := []
	for e in probe.language_validate(path).get("errors", []):
		out.append(e.message)
	return out


func _ready() -> void:
	if not Engine.is_editor_hint():
		return
	probe = ClassDB.instantiate("ZigguratTestProbe")
	var end := Time.get_ticks_msec() + WAIT_MS
	while probe.editor_build_outcomes() < 1 and Time.get_ticks_msec() < end:
		await get_tree().process_frame
	report("load_checks_build_done", probe.editor_build_outcomes() == 1, "outcomes %d" % probe.editor_build_outcomes())

	var named := messages("res://named.zig")
	report("load_check_property_hides",
		named.has("Property 'name' of res://named.zig hides Node.name; rename it or give it a name override in meta."), str(named))
	report("load_check_method_hides",
		named.has("Method 'get_name' of res://named.zig hides Node.get_name; rename it or give it a name override in meta."), str(named))
	var holder := messages("res://holder.zig")
	report("load_check_node_field",
		holder == ["res://holder.zig extends Resource, which is not a Node, so field 'target' cannot hold a Node."], str(holder))
	report("load_check_clean", probe.language_validate("res://clean.zig").valid == true, str(probe.language_validate("res://clean.zig")))
	# Findings fail the build: the generation is not used, nothing is
	# written for the game, and the flagged script stays in fallback.
	report("load_check_generation_not_used",
		probe.current_generation() == 0 and not FileAccess.file_exists("res://.godot/ziggurat/manifest") and not FileAccess.file_exists("res://.godot/ziggurat/descriptors.json"),
		"generation %d" % probe.current_generation())
	var named_s: Script = load("res://named.zig")
	report("load_check_marks_build_failed", probe.script_fallback_enabled(named_s), "")
	print("ZTEST DONE")
	get_tree().quit()
