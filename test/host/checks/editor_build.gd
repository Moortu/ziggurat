@tool
extends Node
# Host test "editor builds at open, save triggers a build, broken build keeps
# the last good": runs as a tool autoload in the headless editor of
# test/host/projects/editor_build. The project settings point at the test's
# Zig and SDK manifest, so the host builds at project open and after every
# save of a .zig file. The check watches what each build leaves behind:
# - at open: generation 1 is loaded, the manifest names it, the descriptor
#   cache exists, and the tool script's placeholder became a real instance;
# - a save through the saver: generation 2, the manifest names it, the new
#   default shows, and a cached script whose file changed outside the editor
#   has the new text;
# - a broken save: the diagnostics reach _validate, the script falls back to
#   its placeholder data, generation 2 and the manifest stay;
# - a repaired save: generation 3, the diagnostics are gone.
# Before the first build it also checks the signal-name scan of a script
# without descriptors. Prints one ZTEST line per case, then ZTEST DONE, and
# quits the editor.

const WAIT_MS := 600000
const MANIFEST := "res://.godot/ziggurat/manifest"
const CACHE := "res://.godot/ziggurat/descriptors.json"

var probe: Object


func report(name: String, ok: bool, why: String) -> void:
	if ok:
		print("ZTEST PASS %s" % name)
	else:
		print("ZTEST FAIL %s: %s" % [name, why])


func read(path: String) -> String:
	return FileAccess.get_file_as_string(path)


func manifest_for(n: int) -> String:
	return "gen=%d\npath=gen/%d/libzmod.%d.so\n" % [n, n, n]


# Waits up to WAIT_MS for `cond` to return true.
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
	await run()
	print("ZTEST DONE")
	get_tree().quit()


func run() -> void:
	# No build yet and no cache: a script without descriptors still lists
	# the signals its text declares, so scene connections to them survive.
	var sig: Script = ClassDB.instantiate("ZigScript")
	sig.resource_path = "res://not_built.zig"
	sig.source_code = "const z = @import(\"ziggurat\");\n// pub const signals = struct { pub const commented = struct {}; };\npub const signals = struct {\n    pub const hit = struct {};\n    pub const moved = struct { x: i32, y: Inner };\n    const Inner = struct { pub const deep = 1; };\n};\nconst other = struct {\n    pub const nope = struct {};\n};\n"
	var names := []
	for s in sig.get_script_signal_list():
		names.append(s.name)
	report("signal_names_without_descriptor", names == ["hit", "moved"] and sig.has_script_signal("moved") and not sig.has_script_signal("nope"), str(names))

	# The tool script has no descriptor yet: its node gets a placeholder.
	var gadget_s: Script = load("res://gadget.zig")
	var gadget := Node.new()
	gadget.set_script(gadget_s)
	report("tool_placeholder_before_build", probe.script_placeholder_count(gadget_s) == 1 and probe.live_instances() == 0,
		"placeholders %d instances %d" % [probe.script_placeholder_count(gadget_s), probe.live_instances()])
	var ext_s: Script = load("res://ext.zig")
	var walker_s: Script = load("res://walker.zig")
	var walker_text: String = walker_s.source_code

	# ---- build at open
	var built: bool = await wait_for(func(): return probe.current_generation() >= 1)
	report("editor_builds_at_open", built and probe.current_generation() == 1 and probe.editor_build_outcomes() == 1, "generation %d outcomes %d" % [probe.current_generation(), probe.editor_build_outcomes()])
	report("manifest_written", read(MANIFEST) == manifest_for(1), var_to_str(read(MANIFEST)))
	report("staged_library_exists", FileAccess.file_exists("res://.godot/ziggurat/gen/1/libzmod.1.so"), "")
	report("descriptor_cache_written", FileAccess.file_exists(CACHE) and read(CACHE).contains("walker.zig"), "")
	report("validate_after_good_build", probe.language_validate("res://walker.zig").valid == true, str(probe.language_validate("res://walker.zig")))
	report("tool_placeholder_swapped", probe.script_placeholder_count(gadget_s) == 0 and probe.live_instances() == 1 and gadget.get_script() == gadget_s and gadget.get("ready_calls") == 0,
		"placeholders %d instances %d ready_calls %s" % [probe.script_placeholder_count(gadget_s), probe.live_instances(), gadget.get("ready_calls")])
	gadget.free()

	# ---- an edit outside the editor, picked up with the next build
	# File times have one-second steps: wait so the change is visible.
	await get_tree().create_timer(1.2).timeout
	var ext_text: String = ext_s.source_code + "\n// changed outside the editor\n"
	var f := FileAccess.open("res://ext.zig", FileAccess.WRITE)
	f.store_string(ext_text)
	f.close()

	# ---- a save through the saver builds again
	walker_s.source_code = walker_text.replace("speed: f32 = 5,", "speed: f32 = 7,")
	var err := ResourceSaver.save(walker_s, "res://walker.zig")
	built = await wait_for(func(): return probe.current_generation() >= 2)
	report("save_triggers_a_build", err == OK and built and probe.current_generation() == 2 and read(MANIFEST) == manifest_for(2),
		"save %d generation %d manifest %s" % [err, probe.current_generation(), var_to_str(read(MANIFEST))])
	report("save_new_default", walker_s.get_property_default_value("speed") == 7.0, str(walker_s.get_property_default_value("speed")))
	report("external_edit_refreshed", ext_s.source_code == ext_text, var_to_str(ext_s.source_code))

	# ---- a broken save keeps the last good build
	var outcomes: int = probe.editor_build_outcomes()
	walker_s.source_code = walker_text.replace("speed: f32 = 5,", "speed: f32 = oops,")
	err = ResourceSaver.save(walker_s, "res://walker.zig")
	var done: bool = await wait_for(func(): return probe.editor_build_outcomes() > outcomes)
	var v: Dictionary = probe.language_validate("res://walker.zig")
	var line := -1
	if v.get("errors", []).size() > 0:
		line = v.errors[0].line
	report("broken_build_keeps_last_good", done and probe.current_generation() == 2 and read(MANIFEST) == manifest_for(2),
		"generation %d manifest %s" % [probe.current_generation(), var_to_str(read(MANIFEST))])
	report("broken_build_diagnostics", v.valid == false and line == 9 and str(v.errors[0].message).contains("oops"), str(v))
	report("broken_build_other_file_valid", probe.language_validate("res://gadget.zig").valid == true, str(probe.language_validate("res://gadget.zig")))
	report("broken_build_fallback", probe.script_fallback_enabled(walker_s) and walker_s.get_property_default_value("speed") == 7.0,
		"fallback %s default %s" % [probe.script_fallback_enabled(walker_s), walker_s.get_property_default_value("speed")])

	# ---- repaired: a new generation, the diagnostics are gone
	walker_s.source_code = walker_text
	err = ResourceSaver.save(walker_s, "res://walker.zig")
	built = await wait_for(func(): return probe.current_generation() >= 3)
	report("repaired_build", built and probe.current_generation() == 3 and read(MANIFEST) == manifest_for(3) and probe.language_validate("res://walker.zig").valid == true and not probe.script_fallback_enabled(walker_s),
		"generation %d validate %s" % [probe.current_generation(), str(probe.language_validate("res://walker.zig"))])
