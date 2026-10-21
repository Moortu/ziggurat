@tool
extends Node
# Host test "editor reload: no tool scripts loads nothing": runs as a tool
# autoload in the headless editor of test/host/projects/editor_reload_plain,
# which has no tool script. Each good build updates descriptors,
# placeholders, the descriptor cache and the manifest from the build's
# table snapshot; the editor loads no generation. Three builds: at open, a
# save with a new default, a save with a new property. Prints one ZTEST line
# per case, then ZTEST DONE, and quits the editor.

const WAIT_MS := 600000
const MANIFEST := "res://.godot/ziggurat/manifest"
const CACHE := "res://.godot/ziggurat/descriptors.json"

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


func property_names(o: Object) -> Array:
	var names := []
	for p in o.get_property_list():
		names.append(p.name)
	return names


func nothing_loaded() -> bool:
	return probe.loaded_generations() == 0 and probe.current_generation() == 0


func _ready() -> void:
	if not Engine.is_editor_hint():
		return
	probe = ClassDB.instantiate("ZigguratTestProbe")
	await run()
	print("ZTEST DONE")
	get_tree().quit()


func run() -> void:
	var done: bool = await wait_for(func(): return probe.editor_build_outcomes() >= 1)
	var walker_s: Script = load("res://walker.zig")
	var text: String = walker_s.source_code
	var walker := Node.new()
	walker.set_script(walker_s)
	add_child(walker)
	report("plain_build_1", done and nothing_loaded() and FileAccess.get_file_as_string(MANIFEST) == manifest_for(1)
		and FileAccess.get_file_as_string(CACHE).contains("walker.zig") and probe.script_is_valid(walker_s)
		and walker_s.get_property_default_value("speed") == 5.0 and probe.script_placeholder_count(walker_s) == 1
		and walker.get("speed") == 5.0,
		"loaded %d current %d valid %s default %s placeholders %d" % [probe.loaded_generations(), probe.current_generation(), probe.script_is_valid(walker_s), walker_s.get_property_default_value("speed"), probe.script_placeholder_count(walker_s)])

	# ---- a new default
	walker_s.source_code = text.replace("speed: f32 = 5,", "speed: f32 = 7,")
	var err := ResourceSaver.save(walker_s, "res://walker.zig")
	done = await wait_for(func(): return probe.editor_build_outcomes() >= 2)
	report("plain_build_2", err == OK and done and nothing_loaded() and FileAccess.get_file_as_string(MANIFEST) == manifest_for(2)
		and walker_s.get_property_default_value("speed") == 7.0 and walker.get("speed") == 7.0,
		"loaded %d default %s value %s manifest %s" % [probe.loaded_generations(), walker_s.get_property_default_value("speed"), walker.get("speed"), var_to_str(FileAccess.get_file_as_string(MANIFEST))])

	# ---- a new property
	walker_s.source_code = text.replace("speed: f32 = 5,", "speed: f32 = 7,\ngrip: i32 = 3,")
	err = ResourceSaver.save(walker_s, "res://walker.zig")
	done = await wait_for(func(): return probe.editor_build_outcomes() >= 3)
	var names := property_names(walker)
	report("plain_build_3", err == OK and done and nothing_loaded() and FileAccess.get_file_as_string(MANIFEST) == manifest_for(3)
		and FileAccess.get_file_as_string(CACHE).contains("grip") and names.has("grip") and walker.get("grip") == 3
		and probe.script_placeholder_count(walker_s) == 1,
		"loaded %d properties %s grip %s" % [probe.loaded_generations(), names, walker.get("grip")])
	walker.queue_free()
