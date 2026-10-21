@tool
extends Node
# Host test "editor reload: tool node gets new code, rejected build never
# loads, size warning once": runs as a tool autoload in the headless editor
# of test/host/projects/editor_reload, whose knob.zig is a tool script, so
# the editor loads each good build and swaps to it.
# - build at open: generation 1; a knob node gets a real instance, its
#   `value` returns 1; the test sets `level` to 5;
# - a save that makes `value` return 2: within a bounded wait the open node
#   returns 2 and keeps `level`;
# - a save whose build fails the load checks (a method that hides
#   Node.get_name): generation 3 is never loaded, generation 2 stays.
# The size warning's threshold is lowered to 1 byte first, so the first
# loaded build warns; the host test checks the warning appears once.
# Prints one ZTEST line per case, then ZTEST DONE, and quits the editor.

const WAIT_MS := 600000
const MANIFEST := "res://.godot/ziggurat/manifest"

var probe: Object


func report(name: String, ok: bool, why: String) -> void:
	if ok:
		print("ZTEST PASS %s" % name)
	else:
		print("ZTEST FAIL %s: %s" % [name, why])


func manifest_for(n: int) -> String:
	return "gen=%d\npath=gen/%d/libzmod.%d.so\n" % [n, n, n]


func wait_for(cond: Callable) -> bool:
	var end := Time.get_ticks_msec() + WAIT_MS
	while Time.get_ticks_msec() < end:
		if cond.call():
			return true
		await get_tree().process_frame
	return false


func _ready() -> void:
	if not Engine.is_editor_hint():
		return
	probe = ClassDB.instantiate("ZigguratTestProbe")
	probe.set_size_warning_bytes(1)
	await run()
	print("ZTEST DONE")
	get_tree().quit()


func run() -> void:
	var built: bool = await wait_for(func(): return probe.current_generation() >= 1)
	var knob_s: Script = load("res://knob.zig")
	var text: String = knob_s.source_code
	var knob := Node.new()
	knob.set_script(knob_s)
	add_child(knob)
	report("tool_build_loaded", built and probe.current_generation() == 1 and probe.loaded_generations() == 1 and probe.live_instances() == 1,
		"current %d loaded %d instances %d" % [probe.current_generation(), probe.loaded_generations(), probe.live_instances()])
	report("tool_node_runs_build_1", knob.call("value") == 1, str(knob.call("value")))
	knob.set("level", 5)

	# ---- the edited method reaches the open node
	knob_s.source_code = text.replace("return 1;", "return 2;")
	var err := ResourceSaver.save(knob_s, "res://knob.zig")
	var swapped: bool = await wait_for(func(): return knob.call("value") == 2)
	report("tool_node_gets_new_code", err == OK and swapped and knob.get("level") == 5 and probe.current_generation() == 2,
		"save %d value %s level %s current %d" % [err, knob.call("value"), knob.get("level"), probe.current_generation()])
	report("tool_build_manifest", FileAccess.get_file_as_string(MANIFEST) == manifest_for(2), var_to_str(FileAccess.get_file_as_string(MANIFEST)))

	# ---- a build the load checks reject is never loaded
	var outcomes: int = probe.editor_build_outcomes()
	knob_s.source_code = text.replace("return 1;", "return 2;") + "\npub fn getName(self: *const @This()) i32 {\n    _ = self;\n    return 0;\n}\n"
	err = ResourceSaver.save(knob_s, "res://knob.zig")
	var done: bool = await wait_for(func(): return probe.editor_build_outcomes() > outcomes)
	# A few frames, so a swap the outcome might have asked for would run.
	for i in 5:
		await get_tree().process_frame
	report("rejected_build_never_loads",
		err == OK and done and not probe.generation_loaded(3) and probe.loaded_generations() == 2 and probe.current_generation() == 2
		and knob.call("value") == 2 and FileAccess.get_file_as_string(MANIFEST) == manifest_for(2)
		and probe.language_validate("res://knob.zig").valid == false,
		"loaded3 %s loaded %d current %d validate %s" % [probe.generation_loaded(3), probe.loaded_generations(), probe.current_generation(), str(probe.language_validate("res://knob.zig"))])
	knob.queue_free()
