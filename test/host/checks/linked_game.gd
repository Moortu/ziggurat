extends SceneTree
# Host tests "linked game runs scripts", "unknown path fails cleanly",
# "exists answers from the table", "uid-only scene runs" and "export build
# has no manifest path": a game whose host library is the export host
# linked with test/fixtures/linked_project (two scripts, res://alpha.zig
# and res://sub/beta.zig). The project folder has no .zig file; the `.zig`
# loader answers from the linked table. ZTEST_LINKED_CASE picks the case:
#   ready    attach both scripts to nodes; their `_ready` lines print
#   unknown  load res://nope.zig, which is not in the table
#   exists   ResourceLoader.exists for both scripts and for res://nope.zig
#   uid      instance res://uid_scene.tscn, which names alpha.zig only by
#            its uid (the text path is wrong)
# Prints one "linked check: ..." line, then ZTEST DONE; the Zig test checks
# the log lines.

var nodes: Array[Node] = []
var scripts: Array[Script] = []
var frames := 0
var done := false
var mode := ""


func _initialize() -> void:
	mode = OS.get_environment("ZTEST_LINKED_CASE")
	match mode:
		"ready":
			attach("res://alpha.zig", Node2D.new())
			attach("res://sub/beta.zig", Node.new())
		"unknown":
			var s: Resource = load("res://nope.zig")
			print("linked check: nope %s" % ("is null" if s == null else "loaded"))
			finish()
		"exists":
			print("linked check: exists alpha=%s beta=%s nope=%s file=%s" % [
				ResourceLoader.exists("res://alpha.zig"),
				ResourceLoader.exists("res://sub/beta.zig"),
				ResourceLoader.exists("res://nope.zig"),
				FileAccess.file_exists("res://alpha.zig"),
			])
			finish()
		"uid":
			var packed: PackedScene = load("res://uid_scene.tscn")
			if packed == null:
				print("ZTEST FAIL uid_scene: res://uid_scene.tscn did not load")
				finish()
				return
			var n: Node = packed.instantiate()
			nodes.append(n)
			root.add_child(n)
		_:
			print("ZTEST FAIL linked_case: unknown case '%s'" % mode)
			finish()


func attach(path: String, n: Node) -> void:
	var s: Script = load(path)
	if s == null:
		print("ZTEST FAIL load_script: %s did not load" % path)
		n.free()
		finish()
		return
	n.set_script(s)
	nodes.append(n)
	scripts.append(s)
	root.add_child(n)


# `_ready` runs once the scene tree processes; the check waits two frames.
func _process(_delta: float) -> bool:
	if done:
		return true
	frames += 1
	if frames < 2:
		return false
	if mode == "ready":
		var running := nodes.size() == 2
		for i in nodes.size():
			running = running and nodes[i].get_script() == scripts[i]
		running = running and nodes[0].get("speed") == 3.0
		print("linked check: scripts %s" % ("running" if running else "absent"))
	elif mode == "uid":
		var s: Script = nodes[0].get_script()
		var path := "" if s == null else s.resource_path
		print("linked check: uid scene script %s" % path)
	finish()
	return true


func finish() -> void:
	done = true
	for n in nodes:
		n.free()
	nodes.clear()
	scripts.clear()
	print("ZTEST DONE")
	quit()
