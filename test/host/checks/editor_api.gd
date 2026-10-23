@tool
extends Node
# Host test "public build API": runs as a tool autoload in the headless
# editor of test/host/projects/editor_build with the probe host. The
# project's Zig is the wrapper script of `addZigWrapper` (res://gate.txt
# names its gate folder: a `block` file holds every build). res://zigs.txt
# holds three lines: the wrapper, a fake Zig that reports another version,
# and a path where no file exists. `PATH` has no Zig and the per-user
# folders are inside the test's folder, so the settings decide which Zig is
# found. A relative Zig path is a failed outcome. The check drives `editor_build.requestBuild` and reads
# `editor_build.status` and `diagnosticsCopy` through the probe. Settings
# are read again at each request. Prints one ZTEST line per case, then
# ZTEST DONE, and quits the editor.

const WAIT_MS := 300000
const SETTING := "ziggurat/zig_path"

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


# Requests a build with `trigger` and waits until its outcome is applied;
# returns the status after it.
func build(trigger: String) -> Dictionary:
	var outcomes: int = probe.editor_build_outcomes()
	probe.editor_build_request(trigger)
	await wait_for(func(): return probe.editor_build_outcomes() > outcomes and not probe.editor_build_status().building)
	return probe.editor_build_status()


func run() -> void:
	for m in ["editor_build_status", "editor_build_request", "editor_build_diagnostics"]:
		if not probe.has_method(m):
			report("api_probe_methods", false, "the probe has no method %s" % m)
			return
	var gate := FileAccess.get_file_as_string("res://gate.txt").strip_edges()
	var zigs := FileAccess.get_file_as_string("res://zigs.txt").strip_edges().split("\n")
	var wrapper := zigs[0]
	var old_zig := zigs[1]
	var missing := zigs[2]

	await wait_for(func(): return probe.editor_build_outcomes() >= 1 and not probe.editor_build_status().building)
	var st: Dictionary = probe.editor_build_status()
	report("api_open_status", st.has_last and st.trigger == "open" and st.ok and st.n >= 1 and st.zig_problem == "none" and st.path == "full", str(st))
	var first_n: int = st.n

	# A manual build held at the gate: `building` until it ends, and the
	# last outcome is still the one from open.
	var block := FileAccess.open(gate + "/block", FileAccess.WRITE)
	block.store_string("block")
	block.close()
	var outcomes: int = probe.editor_build_outcomes()
	report("api_request_known_trigger", probe.editor_build_request("manual"), "manual refused")
	await frames(30)
	st = probe.editor_build_status()
	report("api_building", st.building and st.has_last and st.trigger == "open" and probe.editor_build_outcomes() == outcomes, str(st))
	DirAccess.remove_absolute(gate + "/block")
	await wait_for(func(): return probe.editor_build_outcomes() > outcomes and not probe.editor_build_status().building)
	await frames(30)
	st = probe.editor_build_status()
	report("api_manual_outcome", probe.editor_build_outcomes() == outcomes + 1 and not st.building and st.trigger == "manual" and st.ok and st.n > first_n and st.zig_problem == "none" and st.error_count == 0,
		"outcomes %d -> %d, %s" % [outcomes, probe.editor_build_outcomes(), str(st)])

	# Settings are read again at each request.
	ProjectSettings.set_setting(SETTING, missing)
	st = await build("manual")
	report("api_zig_missing", not st.ok and st.trigger == "manual" and st.zig_problem == "missing" and st.n == -1 and str(st.message).begins_with("Ziggurat needs Zig 0.17.0, but no zig was found"), str(st))

	ProjectSettings.set_setting(SETTING, old_zig)
	st = await build("manual")
	report("api_zig_wrong_version", not st.ok and st.zig_problem == "wrong_version" and str(st.message).contains("is Zig 0.16.0"), str(st))

	# The editor setting is used while the project setting is empty, and
	# the project setting wins when both are set.
	var settings := EditorInterface.get_editor_settings()
	ProjectSettings.set_setting(SETTING, "")
	settings.set_setting(SETTING, wrapper)
	st = await build("manual")
	report("api_editor_setting_used", st.ok and st.zig_problem == "none", str(st))
	settings.set_setting(SETTING, old_zig)
	ProjectSettings.set_setting(SETTING, wrapper)
	st = await build("manual")
	report("api_project_setting_wins", st.ok and st.zig_problem == "none", str(st))
	settings.set_setting(SETTING, "")

	# A relative path builds nothing, but it is a failed outcome that names
	# the setting, so the status shows it.
	ProjectSettings.set_setting(SETTING, "relative/zig")
	st = await build("manual")
	report("api_relative_path", not st.ok and st.trigger == "manual" and st.zig_problem == "missing" and st.n == -1 and str(st.message).contains("project setting ziggurat/zig_path (relative/zig)") and str(st.message).contains("not an absolute path"), str(st))
	# A relative editor setting does not matter while the project setting
	# is set.
	ProjectSettings.set_setting(SETTING, wrapper)
	settings.set_setting(SETTING, "relative/zig")
	var before: int = probe.editor_build_outcomes()
	st = await build("manual")
	report("api_relative_editor_ignored", probe.editor_build_outcomes() > before and st.ok and st.zig_problem == "none", str(st))
	settings.set_setting(SETTING, "")

	# A compile error: counted, and listed per file by `diagnosticsCopy`.
	var walker_s: Script = load("res://walker.zig")
	var text: String = walker_s.source_code
	var broken := text.replace("speed: f32 = 5,", "speed: f32 = oops,")
	var f := FileAccess.open("res://walker.zig", FileAccess.WRITE)
	f.store_string(broken)
	f.close()
	st = await build("manual")
	var diags: Array = probe.editor_build_diagnostics()
	var walker_lines: Array = []
	for d in diags:
		if d.rel == "walker.zig":
			walker_lines.append(d.line)
	report("api_diagnostics", not st.ok and st.error_count >= 1 and st.zig_problem == "none" and walker_lines.has(9), "%s, diagnostics %s" % [str(st), str(diags)])

	f = FileAccess.open("res://walker.zig", FileAccess.WRITE)
	f.store_string(text)
	f.close()
	st = await build("manual")
	diags = probe.editor_build_diagnostics()
	var walker_diags := 0
	for d in diags:
		if d.rel == "walker.zig":
			walker_diags += 1
	report("api_diagnostics_cleared", st.ok and st.error_count == 0 and walker_diags == 0, "%s, diagnostics %s" % [str(st), str(diags)])
	report("api_unknown_trigger", not probe.editor_build_request("nonsense"), "accepted")
