@tool
extends Node
# Host test "editor reload: no tool scripts loads nothing": runs as a tool
# autoload in the headless editor of test/host/projects/editor_reload_plain,
# which has no tool script. Each good build updates descriptors,
# placeholders, the descriptor cache and the manifest from the build's
# table snapshot; the editor loads no generation. Three builds: at open, a
# save with a new default, a save with a new property. Then:
# - res://saved.tscn, whose Walker has a snapshot-backed placeholder, is
#   opened and saved through the editor: its value and connection stay;
# - nine saves whose builds fail the load checks stage nine newer
#   generations, more than the store keeps: the build the manifest names
#   (3) is still on disk, because the editor pins it.
# The size warning's threshold is lowered to 1 byte, so the first build's
# kept descriptors trigger it; the host test checks it appears once. After
# this editor run the host test plays saved.tscn as a game from the
# manifest. Prints one ZTEST line per case, then ZTEST DONE, and quits the
# editor.

const WAIT_MS := 600000
const MANIFEST := "res://.godot/ziggurat/manifest"
const CACHE := "res://.godot/ziggurat/descriptors.json"
const SCENE := "res://saved.tscn"
const KEPT := [
	"script = ExtResource(",
	"speed = 9.0",
	"[connection signal=\"arrived\" from=\"Walker\" to=\"Tick\" method=\"start\"]",
]

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
		# The game run of saved.tscn: its Walker logs from `_ready`.
		for i in 5:
			await get_tree().process_frame
		print("ZTEST DONE")
		get_tree().quit()
		return
	probe = ClassDB.instantiate("ZigguratTestProbe")
	probe.set_size_warning_bytes(1)
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

	# ---- a scene with a snapshot-backed placeholder saves its values
	var before := FileAccess.get_file_as_string(SCENE)
	EditorInterface.open_scene_from_path(SCENE)
	var root := EditorInterface.get_edited_scene_root()
	var node: Node = root.get_node_or_null("Walker") if root != null else null
	var why := ""
	if node == null:
		why = "scene not open (root %s)" % root
	elif node.get("speed") != 9.0 or node.get("grip") != 3 or probe.live_instances() != 0:
		why = "speed %s grip %s instances %d" % [node.get("speed"), node.get("grip"), probe.live_instances()]
	report("snapshot_scene_opened", why == "", why)
	err = EditorInterface.save_scene()
	var after := FileAccess.get_file_as_string(SCENE)
	why = "" if err == OK else "save_scene returned %s; " % error_string(err)
	if after == before:
		why += "the file is unchanged; "
	for line in KEPT:
		if not after.contains(line):
			why += "lost %s; " % line
	# The default of grip (3) is not stored, as for a loaded script.
	if after.contains("grip"):
		why += "stored the default of grip; "
	report("snapshot_scene_save_keeps_values", why == "", why + "\n" + after)

	# ---- newer staged builds never sweep away the manifest's build
	for i in 9:
		var outcomes: int = probe.editor_build_outcomes()
		walker_s.source_code = text.replace("speed: f32 = 5,", "speed: f32 = 7,\ngrip: i32 = 3,") + "\npub fn getName(self: *const @This()) i32 {\n    _ = self;\n    return %d;\n}\n" % i
		err = ResourceSaver.save(walker_s, "res://walker.zig")
		done = await wait_for(func(): return probe.editor_build_outcomes() > outcomes)
		if err != OK or not done:
			break
	report("manifest_build_kept",
		done and FileAccess.get_file_as_string(MANIFEST) == manifest_for(3)
		and FileAccess.file_exists("res://.godot/ziggurat/gen/3/libzmod.3.so")
		and not FileAccess.file_exists("res://.godot/ziggurat/gen/4/libzmod.4.so") and nothing_loaded(),
		"manifest %s gen3 %s gen4 %s" % [var_to_str(FileAccess.get_file_as_string(MANIFEST)), FileAccess.file_exists("res://.godot/ziggurat/gen/3/libzmod.3.so"), FileAccess.file_exists("res://.godot/ziggurat/gen/4/libzmod.4.so")])
