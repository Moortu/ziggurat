@tool
extends Node
# Host test "export: script added before export runs": an autoload in the
# editor started with --build-solutions, before the export. Play's build
# ran before the first frame; at the first frame this checks that it
# wrote the generation manifest, then prints ZTEST DONE. In a game it does
# nothing.


func _ready() -> void:
	if not Engine.is_editor_hint():
		return
	await get_tree().process_frame
	if FileAccess.file_exists("res://.godot/ziggurat/manifest"):
		print("ZTEST PASS export_editor_built")
	else:
		print("ZTEST FAIL export_editor_built: no generation manifest after Play's build")
	print("ZTEST DONE")
