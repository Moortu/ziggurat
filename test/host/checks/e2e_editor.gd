@tool
extends Node
# Host test "e2e headless", editor pass: runs as a tool autoload in the
# headless editor of test/host/projects/e2e. The project settings point at
# the test's Zig and SDK manifest, so the editor builds every script at
# project open and stages the result for the game (manifest and library in
# .godot/ziggurat). The check waits for that, then opens the main scene in
# the editor: the tool script has a real instance there, the other scripts
# have placeholders that show the scene's stored values. Prints one ZTEST
# line per case, then ZTEST DONE, and quits. In the game this autoload does
# nothing (the game pass checks from res://listener.gd).

const WAIT_MS := 600000
const MANIFEST := "res://.godot/ziggurat/manifest"


func report(name: String, ok: bool, why: String) -> void:
	if ok:
		print("ZTEST PASS %s" % name)
	else:
		print("ZTEST FAIL %s: %s" % [name, why])


func _ready() -> void:
	if not Engine.is_editor_hint():
		return
	await run()
	print("ZTEST DONE")
	get_tree().quit()


func run() -> void:
	var end := Time.get_ticks_msec() + WAIT_MS
	while Time.get_ticks_msec() < end and not FileAccess.file_exists(MANIFEST):
		await get_tree().process_frame
	# The manifest is written last, after the library is staged.
	var manifest := FileAccess.get_file_as_string(MANIFEST)
	report("editor_built_and_staged", manifest == "gen=1\npath=gen/1/libzmod.1.so\n" and FileAccess.file_exists("res://.godot/ziggurat/gen/1/libzmod.1.so"),
		var_to_str(manifest))

	var scene: PackedScene = load("res://main.tscn")
	var root := scene.instantiate()
	var beacon := root.get_node("Beacon")
	var hero := root.get_node("Hero")
	# A tool script runs in the editor: its method answers.
	report("editor_tool_instance", beacon.call("pulse") == 4, "pulse %s" % beacon.call("pulse"))
	# A script without `tool` has a placeholder with the scene's values.
	report("editor_placeholder_values", hero.get("speed") == 12.5 and hero.get("spawn") == Vector2(3, 4),
		"speed %s spawn %s" % [hero.get("speed"), hero.get("spawn")])
	root.free()
