extends SceneTree
# Host test "no plugin in a game": a game process (not the editor) from the
# same Godot binary and host library. The EDITOR level still runs in it, but
# the host adds no editor plugin there, so no `ZigEditorPlugin` exists in
# the tree. Prints one line per case, then ZTEST DONE, and quits.

var frames := 0


func _process(_delta: float) -> bool:
	frames += 1
	if frames < 5:
		return false
	var found := root.find_children("*", "ZigEditorPlugin", true, false)
	if Engine.is_editor_hint():
		print("ZTEST FAIL no_plugin_in_game: this run is the editor")
	elif found.size() != 0:
		print("ZTEST FAIL no_plugin_in_game: %d ZigEditorPlugin nodes" % found.size())
	else:
		print("ZTEST PASS no_plugin_in_game")
	print("ZTEST DONE")
	quit()
	return true
