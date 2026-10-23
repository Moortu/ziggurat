extends SceneTree
# Host tests "manifest trust", "game runs ready" and "export build has no
# manifest path": a game process (not the editor) attaches res://mover.zig
# to a node in the running scene. With the generation the manifest names
# loaded, the instance is real and `_ready` prints its line; without one
# (refused, missing, or an export build) the game keeps running and the
# node has no script. Prints which of the two happened, then ZTEST DONE;
# the Zig test checks the log lines. With ZigguratTestProbe present it also
# calls the language's `reload_scripts` hook twice, as Godot's debugger does
# after two saves; the game handles them at its next frame quietly: the
# manifest names the build it runs, so nothing is logged.

var node: Node2D
var mover_script: Script
var frames := 0
var done := false
var reloaded_at := -1


func _initialize() -> void:
	mover_script = load("res://mover.zig")
	if mover_script == null:
		print("ZTEST FAIL load_script: res://mover.zig did not load")
		finish()
		return
	node = Node2D.new()
	node.set_script(mover_script)
	root.add_child(node)


# `_ready` runs once the scene tree processes; the check waits two frames.
func _process(_delta: float) -> bool:
	if done:
		return true
	frames += 1
	if reloaded_at >= 0:
		# The game handles the request at its next frames.
		if frames < reloaded_at + 3:
			return false
		finish()
		return true
	if frames < 2:
		return false
	var running: bool = node.get_script() == mover_script and node.get("speed") == 5.0
	print("game check: scripts %s" % ("running" if running else "absent"))
	if ClassDB.class_exists("ZigguratTestProbe"):
		var probe: Object = ClassDB.instantiate("ZigguratTestProbe")
		probe.language_reload_scripts([mover_script])
		probe.language_reload_scripts([mover_script])
		reloaded_at = frames
		return false
	finish()
	return true


func finish() -> void:
	done = true
	if node != null:
		node.free()
		node = null
	mover_script = null
	print("ZTEST DONE")
	quit()
