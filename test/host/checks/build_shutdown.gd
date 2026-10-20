@tool
extends Node
# Host test "shutdown during build": runs as a tool autoload in the headless
# editor of test/host/projects/editor_build. The project's Zig is a wrapper
# script that waits while the gate file `block` exists, so the build at
# open cannot finish. The check waits until that build runs a compiler and
# quits the editor. The Zig test checks that the host stopped the build
# service (no thread left), that no build was loaded, that no compiler
# process outlives the editor and that the runner finds no leak.

const WAIT_MS := 30000

var probe: Object


func _ready() -> void:
	if not Engine.is_editor_hint():
		return
	probe = ClassDB.instantiate("ZigguratTestProbe")
	var end := Time.get_ticks_msec() + WAIT_MS
	while not probe.editor_build_busy() and Time.get_ticks_msec() < end:
		await get_tree().process_frame
	if probe.editor_build_busy() and probe.editor_build_outcomes() == 0:
		print("ZTEST PASS build_running_at_quit")
	else:
		print("ZTEST FAIL build_running_at_quit: busy %s outcomes %d" % [probe.editor_build_busy(), probe.editor_build_outcomes()])
	print("ZTEST DONE")
	get_tree().quit()
