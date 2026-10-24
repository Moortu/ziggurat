extends Node
# Host export tests: the exported game's main scene root. Its children
# carry the Zig scripts, whose `_ready` lines print before this one (Godot
# readies children first). It prints one line, then ZTEST DONE, and quits.


func _ready() -> void:
	print("export check: main ready")
	print("ZTEST DONE")
	get_tree().quit()
