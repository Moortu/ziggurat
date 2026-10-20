@tool
extends Node
# Host test "shutdown during build": runs as a tool autoload in the headless
# editor of test/host/projects/editor_build and quits the editor while a
# build runs: the build at open when it still runs, otherwise a build that
# a save starts. The Zig test checks that the host stopped the build service
# (no thread left), that no compiler process outlives the editor and that
# the runner finds no leak.

const WAIT_MS := 600000

var probe: Object


func _ready() -> void:
	if not Engine.is_editor_hint():
		return
	probe = ClassDB.instantiate("ZigguratTestProbe")
	if not probe.editor_build_busy():
		# The build at open is done already: start another one.
		var walker: Script = load("res://walker.zig")
		walker.source_code = walker.source_code.replace("speed: f32 = 5,", "speed: f32 = 6,")
		ResourceSaver.save(walker, "res://walker.zig")
		var end := Time.get_ticks_msec() + WAIT_MS
		while not probe.editor_build_busy() and Time.get_ticks_msec() < end:
			await get_tree().process_frame
	if probe.editor_build_busy():
		print("ZTEST PASS build_running_at_quit")
	else:
		print("ZTEST FAIL build_running_at_quit: no build running")
	print("ZTEST DONE")
	get_tree().quit()
