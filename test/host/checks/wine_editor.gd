@tool
extends Node
# Wine end-to-end test "wine editor builds and runs a script", while the
# Windows Zig cannot compile under Wine (test/wine_gaps.zig): the editor
# runs with --build-solutions, whose build fails, so the editor stops
# before its first frame. This autoload only marks the run as finished;
# the test reads the build lines of the output.


func _ready() -> void:
	if Engine.is_editor_hint():
		print("ZTEST DONE")
