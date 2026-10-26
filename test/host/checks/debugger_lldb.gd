@tool
extends Node
# Host test "lldb stops in a script", editor pass: runs as a tool autoload
# in the headless editor of test/host/projects/e2e with the probe host. It
# turns the editor setting ziggurat/build/debugger_builds on and requests a
# build, so the generation the manifest names is a debugger build (LLVM,
# non-incremental, Debug) for the game that the test then runs under lldb.
# Prints one ZTEST line per case, then ZTEST DONE, and quits. In the game
# this autoload does nothing.

const BUILD_WAIT_MS := 600000
const SETTING := "ziggurat/build/debugger_builds"

var probe: Object


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
	await wait_for(func(): return probe.editor_build_outcomes() >= 1 and not probe.editor_build_status().building, BUILD_WAIT_MS)
	EditorInterface.get_editor_settings().set_setting(SETTING, true)
	var outcomes: int = probe.editor_build_outcomes()
	probe.editor_build_request("manual")
	await wait_for(func(): return probe.editor_build_outcomes() > outcomes and not probe.editor_build_status().building, BUILD_WAIT_MS)
	var st: Dictionary = probe.editor_build_status()
	report("lldb_debugger_build", st.ok and st.trigger == "manual" and st.path == "full" and probe.editor_build_warm() == "disabled",
		"status %s warm %s" % [st, probe.editor_build_warm()])
	print("ZTEST DONE")
	get_tree().quit()
