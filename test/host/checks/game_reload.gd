extends SceneTree
# Host test "game reload": a game process loads generation 1 from the
# manifest and runs a node with res://mover.zig (test/fixtures/swap_v1).
# The check then plays the editor's part: it writes the manifest, asks the
# game to reload as the debugger does (the probe calls the language's
# `reload_scripts` hook) and waits for the game's frames.
#   1. a manifest that names a build not staged yet: the game keeps gen 1;
#   2. a manifest that names the current build: nothing to do;
#   3. a build that fails to load (a cut file): refused, gen 1 keeps running;
#   4. a good gen 2 (test/fixtures/swap_v2): the game swaps within a few
#      frames, `version()` returns the new value, field values are kept;
#   5. a new instance runs gen 2, and a repeat request has nothing to do.
# modules.txt holds the library file name of each generation.

var probe: Object
var failed := false
var node: Node


func report(name: String, ok: bool, why: String) -> void:
	if ok:
		print("ZTEST PASS %s" % name)
	else:
		failed = true
		print("ZTEST FAIL %s: %s" % [name, why])


func lib_name(n: int) -> String:
	for line in FileAccess.get_file_as_string("res://modules.txt").split("\n", false):
		if line.begins_with("lib%d=" % n):
			return line.substr(5)
	return ""


func write_manifest(n: int) -> void:
	var f := FileAccess.open("res://.godot/ziggurat/manifest", FileAccess.WRITE)
	f.store_string("gen=%d\npath=gen/%d/%s\n" % [n, n, lib_name(n)])
	f.close()


# Asks for a reload and lets a few frames pass; returns the frames the
# generation took to become `want` (-1 when it did not within the limit).
func reload_and_wait(want: int, limit: int) -> int:
	probe.language_reload_scripts([node.get_script()])
	var frames := 0
	while probe.current_generation() != want and frames < limit:
		await process_frame
		frames += 1
	if probe.current_generation() != want:
		return -1
	return frames


func finish() -> void:
	if node != null:
		node.free()
		node = null
	print("ZTEST DONE")
	quit(1 if failed else 0)


func _initialize() -> void:
	probe = ClassDB.instantiate("ZigguratTestProbe")
	if probe == null:
		report("probe", false, "ZigguratTestProbe is not registered")
		finish()
		return
	var s: Script = load("res://mover.zig")
	node = Node.new()
	node.set_script(s)
	root.add_child(node)
	run()


func run() -> void:
	node.set("speed", 2.5)
	node.set("id", 7)
	report("game_runs_gen_1", probe.current_generation() == 1 and node.call("version") == 1,
		"gen %d version %s" % [probe.current_generation(), node.call("version")])

	# 1. Not staged yet: gen 3 has no file.
	write_manifest(3)
	var r := await reload_and_wait(3, 4)
	report("reload_before_staging", r == -1 and probe.current_generation() == 1 and node.call("version") == 1, "frames %d" % r)

	# 2. The manifest names the current build.
	write_manifest(1)
	r = await reload_and_wait(2, 4)
	report("reload_same_gen_does_nothing", r == -1 and probe.current_generation() == 1, "frames %d" % r)

	# 3. A build that does not load: refused, gen 1 keeps running.
	write_manifest(4)
	r = await reload_and_wait(4, 4)
	report("bad_build_keeps_old", r == -1 and probe.current_generation() == 1 and node.call("version") == 1 and node.get("speed") == 2.5,
		"frames %d gen %d" % [r, probe.current_generation()])

	# 4. A good gen 2 swaps; a later good manifest still works after a bad one.
	write_manifest(2)
	r = await reload_and_wait(2, 10)
	report("game_swaps_on_reload", r >= 0 and r <= 3, "frames %d" % r)
	report("method_returns_new_value", node.call("version") == 2, "version %s" % node.call("version"))
	report("field_values_kept", node.get("speed") == 2.5 and node.get("id") == 7, "speed %s id %s" % [node.get("speed"), node.get("id")])

	# 5. New instances run gen 2; a repeat request has nothing to do.
	var fresh := Node.new()
	fresh.set_script(node.get_script())
	report("new_instance_runs_gen_2", fresh.call("version") == 2, "version %s" % fresh.call("version"))
	fresh.free()
	r = await reload_and_wait(3, 4)
	report("repeat_does_nothing", r == -1 and probe.current_generation() == 2, "frames %d" % r)
	finish()
