@tool
extends Node
# Host test "focus-in builds an external edit": runs as a tool autoload in
# the headless editor of test/host/projects/editor_panel with the probe
# host and the test's Zig. A `.zig` file written outside Godot (FileAccess,
# not the saver) is built when the editor plugin gets
# NOTIFICATION_APPLICATION_FOCUS_IN, with trigger `watcher`; a second
# focus-in without a change builds nothing. With the editor setting
# `ziggurat/build/check_interval_seconds` at 1 an external edit starts a
# build within 3 s without a focus-in. Prints one ZTEST line per case,
# then ZTEST DONE, and quits the editor.

const WAIT_MS := 300000
const INTERVAL := "ziggurat/build/check_interval_seconds"

var probe: Object


func report(name: String, ok: bool, why: String) -> void:
	if ok:
		print("ZTEST PASS %s" % name)
	else:
		print("ZTEST FAIL %s: %s" % [name, why])


func wait_ms(cond: Callable, ms: int) -> bool:
	var end := Time.get_ticks_msec() + ms
	while Time.get_ticks_msec() < end:
		if cond.call():
			return true
		await get_tree().process_frame
	return false


func frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _ready() -> void:
	if not Engine.is_editor_hint():
		return
	probe = ClassDB.instantiate("ZigguratTestProbe")
	await run()
	print("ZTEST DONE")
	get_tree().quit()


# Waits until one more outcome than `outcomes` is applied and no build
# runs.
func settle(outcomes: int) -> Dictionary:
	await wait_ms(func(): return probe.editor_build_outcomes() > outcomes and not probe.editor_build_status().building, WAIT_MS)
	await frames(5)
	return probe.editor_build_status()


func plugin() -> Node:
	for child in get_tree().root.get_children():
		if child.get_class() == "EditorNode":
			for c in child.get_children():
				if c.get_class() == "ZigEditorPlugin":
					return c
	return null


func write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func run() -> void:
	for m in ["editor_build_status", "editor_build_outcomes", "editor_build_checks"]:
		if not probe.has_method(m):
			report("external_probe_methods", false, "the probe has no method %s" % m)
			return
	var p := plugin()
	if p == null:
		report("external_plugin", false, "no ZigEditorPlugin")
		return
	var es := EditorInterface.get_editor_settings()
	report("check_interval_default", es.has_setting(INTERVAL) and es.get_setting(INTERVAL) == 0, "has %s, value %s" % [es.has_setting(INTERVAL), es.get_setting(INTERVAL) if es.has_setting(INTERVAL) else null])

	# The build at open.
	var st: Dictionary = await settle(0)
	if not st.get("ok", false):
		report("external_open_build", false, str(st))
		return

	# ---- an edit from outside, then focus-in: one `watcher` outcome
	var outcomes: int = probe.editor_build_outcomes()
	write("res://extra.zig", "pub fn extra() i32 {\n    return 1;\n}\n")
	p.notification(NOTIFICATION_APPLICATION_FOCUS_IN)
	st = await settle(outcomes)
	await frames(30)
	var got: int = probe.editor_build_outcomes() - outcomes
	report("focus_in_builds_external_edit", got == 1 and st.trigger == "watcher" and st.ok, "%d outcomes, %s" % [got, str(st)])

	# ---- focus-in again without a change: the check runs, nothing builds
	outcomes = probe.editor_build_outcomes()
	var checks: Dictionary = probe.editor_build_checks()
	p.notification(NOTIFICATION_APPLICATION_FOCUS_IN)
	var checked := await wait_ms(func(): return probe.editor_build_checks().checks > checks.checks, 30000)
	await frames(30)
	var after: Dictionary = probe.editor_build_checks()
	st = probe.editor_build_status()
	report("focus_in_unchanged_no_build", checked and probe.editor_build_outcomes() == outcomes and after.skipped == checks.skipped + 1 and not st.building,
		"checked %s, outcomes %d -> %d, checks %s -> %s, building %s" % [checked, outcomes, probe.editor_build_outcomes(), str(checks), str(after), st.building])

	# ---- the interval check: an edit builds within 3 s without a focus-in
	es.set_setting(INTERVAL, 1)
	await frames(5)
	outcomes = probe.editor_build_outcomes()
	checks = probe.editor_build_checks()
	var t0 := Time.get_ticks_msec()
	write("res://extra.zig", "pub fn extra() i32 {\n    return 2;\n}\n")
	var started := await wait_ms(func():
		var c: Dictionary = probe.editor_build_checks()
		return c.checks - c.skipped > checks.checks - checks.skipped, 3000)
	var started_ms := Time.get_ticks_msec() - t0
	st = await settle(outcomes)
	report("interval_check_builds", started and st.trigger == "watcher" and st.ok, "started %s after %d ms, %s" % [started, started_ms, str(st)])
	es.set_setting(INTERVAL, 0)
	await frames(5)
