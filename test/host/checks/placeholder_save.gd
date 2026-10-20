@tool
extends Node
# Host test "scene save keeps values without descriptors": runs as a tool
# autoload in the headless editor of a project with no descriptor cache and
# no loaded module, so res://mover.zig has no descriptors. Opens
# res://saved.tscn (a copy of test/host/checks/placeholder_scene.tscn),
# saves it through the editor and checks that every stored value and signal
# connection is still in the file.
# The resource loader for `.zig` files arrives in a later task. Until then
# this check puts a ZigScript for res://mover.zig into Godot's resource
# cache (setting resource_path does that), and the scene loader reuses it
# for the scene's ext_resource.

const SCENE := "res://saved.tscn"
const KEPT := [
	"script = ExtResource(",
	"speed = 9.0",
	"title = \"hello\"",
	"steps = 3",
	"retired = 42",
	"[connection signal=\"timeout\" from=\"Tick\" to=\"Mover\" method=\"on_tick\"]",
	"[connection signal=\"visibility_changed\" from=\"Mover\" to=\"Tick\" method=\"set_wait_time\" binds= [0.5]]",
]

var probe: Object
var mover_s: Script


func report(name: String, ok: bool, why: String) -> void:
	if ok:
		print("ZTEST PASS %s" % name)
	else:
		print("ZTEST FAIL %s: %s" % [name, why])


func _ready() -> void:
	if not Engine.is_editor_hint():
		return
	probe = ClassDB.instantiate("ZigguratTestProbe")
	mover_s = ClassDB.instantiate("ZigScript")
	mover_s.resource_path = "res://mover.zig"
	report("no_descriptors", probe.current_generation() == 0 and not probe.script_is_valid(mover_s) and probe.script_fallback_enabled(mover_s),
		"generation %d valid %s" % [probe.current_generation(), probe.script_is_valid(mover_s)])
	# Let the editor finish starting up before opening a scene.
	for i in 5:
		await get_tree().process_frame
	var before := FileAccess.get_file_as_string(SCENE)

	EditorInterface.open_scene_from_path(SCENE)
	var root := EditorInterface.get_edited_scene_root()
	var mover: Node = root.get_node_or_null("Mover") if root != null else null
	var why := ""
	if mover == null:
		why = "scene not open (root %s)" % root
	else:
		if mover.get_script() != mover_s:
			why += "script %s; " % mover.get_script()
		if probe.script_placeholder_count(mover_s) != 1 or probe.live_instances() != 0:
			why += "placeholders %d instances %d; " % [probe.script_placeholder_count(mover_s), probe.live_instances()]
		if mover.get("speed") != 9.0 or mover.get("title") != "hello" or mover.get("steps") != 3 or mover.get("retired") != 42:
			why += "values %s %s %s %s; " % [mover.get("speed"), mover.get("title"), mover.get("steps"), mover.get("retired")]
	report("scene_opened_with_placeholder", why == "", why)

	var err := EditorInterface.save_scene()
	var after := FileAccess.get_file_as_string(SCENE)
	why = "" if err == OK else "save_scene returned %s; " % error_string(err)
	for line in KEPT:
		if not before.contains(line):
			why += "fixture lacks %s; " % line
		if not after.contains(line):
			why += "lost %s; " % line
	report("scene_save_keeps_values_without_descriptors", why == "", why + "\n" + after)
	print("ZTEST DONE")
