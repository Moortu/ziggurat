@tool
extends Node
# Host test "debugger builds: toggling during a session", second pass: the
# headless editor opens the same project again with the editor setting
# ziggurat/build/debugger_builds on (the first pass, debugger_builds.gd,
# left it on). The project setting ziggurat/zig_path is set, so the build
# at open starts before the editor (and its settings) exists; once the
# editor exists, one more build at open follows with debugger builds. The
# check waits until the newest build is LLVM with no incremental server.
# Prints one ZTEST line per case, then ZTEST DONE, and quits.

const BUILD_WAIT_MS := 600000
const SETTING := "ziggurat/build/debugger_builds"

var probe: Object
var argv_log := ""


func report(name: String, ok: bool, why: String) -> void:
	if ok:
		print("ZTEST PASS %s" % name)
	else:
		print("ZTEST FAIL %s: %s" % [name, why])


func wait_for(cond: Callable, ms: int) -> bool:
	var end := Time.get_ticks_msec() + ms
	while Time.get_ticks_msec() < end:
		if cond.call():
			return true
		await get_tree().process_frame
	return cond.call()


func _ready() -> void:
	if not Engine.is_editor_hint():
		return
	probe = ClassDB.instantiate("ZigguratTestProbe")
	argv_log = FileAccess.get_file_as_string("res://argv_log.txt").strip_edges()
	await run()
	EditorInterface.get_editor_settings().set_setting(SETTING, false)
	print("ZTEST DONE")
	get_tree().quit()


func last_argv() -> PackedStringArray:
	var lines := FileAccess.get_file_as_string(argv_log).strip_edges().split("\n")
	return lines[lines.size() - 1].split(" ")


func run() -> void:
	var es := EditorInterface.get_editor_settings()
	report("debugger_open_setting_on", es.get_setting(SETTING) == true, "value %s" % es.get_setting(SETTING))
	var ok: bool = await wait_for(func():
		var st: Dictionary = probe.editor_build_status()
		return st.has_last and st.ok and not st.building and probe.editor_build_warm() == "disabled" and last_argv().has("-fllvm"), BUILD_WAIT_MS)
	report("debugger_open_build_llvm", ok and not last_argv().has("-fincremental"),
		"status %s warm %s argv %s" % [probe.editor_build_status(), probe.editor_build_warm(), last_argv()])
