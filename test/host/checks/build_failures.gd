@tool
extends Node
# Host test "a failure without file errors keeps the diagnostics": runs as a
# tool autoload in the headless editor of test/host/projects/editor_build.
# The project's Zig is a wrapper script that exits with an error while the
# gate file `fail` exists (res://gate.txt names the gate folder). A broken
# script fails a build with errors in its file; then a build fails without
# any file error (the compiler dies). The second failure must keep the
# first one's diagnostics and failed state. Prints one ZTEST line per case,
# then ZTEST DONE, and quits the editor.

const WAIT_MS := 120000

var probe: Object


func report(name: String, ok: bool, why: String) -> void:
	if ok:
		print("ZTEST PASS %s" % name)
	else:
		print("ZTEST FAIL %s: %s" % [name, why])


func wait_for(cond: Callable) -> bool:
	var end := Time.get_ticks_msec() + WAIT_MS
	while Time.get_ticks_msec() < end:
		if cond.call():
			return true
		await get_tree().process_frame
	return false


func _ready() -> void:
	if not Engine.is_editor_hint():
		return
	probe = ClassDB.instantiate("ZigguratTestProbe")
	await run()
	print("ZTEST DONE")
	get_tree().quit()


func run() -> void:
	var gate := FileAccess.get_file_as_string("res://gate.txt").strip_edges()
	var built: bool = await wait_for(func(): return probe.current_generation() >= 1)
	report("failures_first_build", built, "generation %d" % probe.current_generation())

	var walker_s: Script = load("res://walker.zig")
	var text: String = walker_s.source_code
	var outcomes: int = probe.editor_build_outcomes()
	walker_s.source_code = text.replace("speed: f32 = 5,", "speed: f32 = oops,")
	ResourceSaver.save(walker_s, "res://walker.zig")
	await wait_for(func(): return probe.editor_build_outcomes() > outcomes)
	report("failures_compile_error", probe.language_validate("res://walker.zig").valid == false and probe.script_fallback_enabled(walker_s), str(probe.language_validate("res://walker.zig")))

	# The next build fails before the compiler says anything about files.
	var f := FileAccess.open(gate + "/fail", FileAccess.WRITE)
	f.store_string("fail")
	f.close()
	outcomes = probe.editor_build_outcomes()
	var gadget_s: Script = load("res://gadget.zig")
	ResourceSaver.save(gadget_s, "res://gadget.zig")
	await wait_for(func(): return probe.editor_build_outcomes() > outcomes)
	DirAccess.remove_absolute(gate + "/fail")
	var v: Dictionary = probe.language_validate("res://walker.zig")
	report("failure_without_file_errors_keeps_diagnostics",
		probe.editor_build_outcomes() == outcomes + 1 and v.valid == false and probe.script_fallback_enabled(walker_s) and probe.current_generation() == 1,
		"outcomes %d validate %s generation %d" % [probe.editor_build_outcomes(), str(v), probe.current_generation()])
