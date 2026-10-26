@tool
extends Node
# Host test "zig path: unusable path is logged once by the change check":
# runs as a tool autoload in the headless editor of
# test/host/projects/editor_panel with the probe host and the test's Zig.
# With a relative project setting `ziggurat/zig_path`, three focus-in
# checks build nothing and log the unusable path once (the host test counts
# the line); with the setting usable again, a focus-in check runs. Prints
# one ZTEST line per case, then ZTEST DONE, and quits the editor.

const WAIT_MS := 300000
const SETTING := "ziggurat/zig_path"

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


func plugin() -> Node:
	for child in get_tree().root.get_children():
		if child.get_class() == "EditorNode":
			for c in child.get_children():
				if c.get_class() == "ZigEditorPlugin":
					return c
	return null


func run() -> void:
	for m in ["editor_build_status", "editor_build_outcomes", "editor_build_checks"]:
		if not probe.has_method(m):
			report("zig_path_probe_methods", false, "the probe has no method %s" % m)
			return
	var p := plugin()
	if p == null:
		report("zig_path_plugin", false, "no ZigEditorPlugin")
		return

	# The build at open.
	await wait_ms(func(): return probe.editor_build_outcomes() > 0 and not probe.editor_build_status().building, WAIT_MS)
	await frames(5)
	var st: Dictionary = probe.editor_build_status()
	if not st.get("ok", false):
		report("zig_path_open_build", false, str(st))
		return

	# ---- a relative path: three focus-in checks, no check and no outcome
	var good: String = ProjectSettings.get_setting(SETTING)
	ProjectSettings.set_setting(SETTING, "relative/zig")
	var outcomes: int = probe.editor_build_outcomes()
	var checks: Dictionary = probe.editor_build_checks()
	for i in 3:
		p.notification(NOTIFICATION_APPLICATION_FOCUS_IN)
		await frames(30)
	var after: Dictionary = probe.editor_build_checks()
	report("zig_path_unusable_not_checked", probe.editor_build_outcomes() == outcomes and after.checks == checks.checks,
		"outcomes %d -> %d, checks %s -> %s" % [outcomes, probe.editor_build_outcomes(), str(checks), str(after)])

	# ---- usable again: a focus-in check runs
	ProjectSettings.set_setting(SETTING, good)
	checks = probe.editor_build_checks()
	p.notification(NOTIFICATION_APPLICATION_FOCUS_IN)
	var checked := await wait_ms(func(): return probe.editor_build_checks().checks > checks.checks, 30000)
	report("zig_path_usable_checked", checked, "checks %s -> %s" % [str(checks), str(probe.editor_build_checks())])
	await frames(5)
