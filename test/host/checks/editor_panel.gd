@tool
extends Node
# Host test "zig panel": runs as a tool autoload in the headless editor of
# test/host/projects/editor_panel with the probe host. The project's Zig is
# the wrapper script of `addZigWrapper`; res://zigs.txt holds the wrapper
# and a path where no file exists. `PATH` has no Zig and the per-user
# folders are inside the test's folder. The check reads the bottom dock
# `Zig` (status line, diagnostics with links), calls the Tools menu item
# `Build Zig Scripts` the way the editor does, and counts the editor's
# toasts. Prints one ZTEST line per case, then ZTEST DONE, and quits the
# editor.

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


# Waits until one more outcome than `outcomes` is applied and no build
# runs, then a few frames so the plugin's `_process` updates the panel.
func settle(outcomes: int) -> Dictionary:
	await wait_for(func(): return probe.editor_build_outcomes() > outcomes and not probe.editor_build_status().building)
	await frames(10)
	return probe.editor_build_status()


# Requests a build with `trigger` and waits for its outcome.
func build(trigger: String) -> Dictionary:
	var outcomes: int = probe.editor_build_outcomes()
	probe.editor_build_request(trigger)
	return await settle(outcomes)


func zig_dock() -> Node:
	for d in get_tree().root.find_children("*", "EditorDock", true, false):
		if d.title == "Zig":
			return d
	return null


# The editor's Tools menu: the PopupMenu that has an item `text`.
func menu_with(text: String) -> PopupMenu:
	for m in get_tree().root.find_children("*", "PopupMenu", true, false):
		for i in m.item_count:
			if m.get_item_text(i) == text:
				return m
	return null


# Toast labels in the editor's toaster whose text passes `pred`.
func toasts(pred: Callable) -> Array:
	var found := []
	for l in EditorInterface.get_editor_toaster().find_children("*", "Label", true, false):
		if pred.call(l.text):
			found.append(l.text)
	return found


func run() -> void:
	for m in ["editor_build_status", "editor_build_request", "editor_panel_toasts"]:
		if not probe.has_method(m):
			report("panel_probe_methods", false, "the probe has no method %s" % m)
			return
	var zigs := FileAccess.get_file_as_string("res://zigs.txt").strip_edges().split("\n")
	var missing := zigs[1]

	# ---- the build at open shows in the dock
	var st: Dictionary = await settle(0)
	var dock := zig_dock()
	report("panel_dock", dock != null and dock.get_class() == "ZigPanel" and dock.default_slot == EditorDock.DOCK_SLOT_BOTTOM,
		"dock %s" % (str(dock) if dock == null else "%s slot %d" % [dock.get_class(), dock.default_slot]))
	if dock == null:
		return
	var status: Label = dock.find_child("Status", true, false)
	var diags: RichTextLabel = dock.find_child("Diagnostics", true, false)
	var button: Button = dock.find_child("BuildButton", true, false)
	if status == null or diags == null or button == null:
		report("panel_children", false, "status %s, diagnostics %s, button %s" % [status, diags, button])
		return
	report("panel_shows_build", st.ok and status.text.begins_with("Build 1 ok (open, full, ") and status.text.ends_with(" ms)"), "status '%s', %s" % [status.text, str(st)])

	# ---- the Tools menu item builds with trigger `manual`
	var menu := menu_with("Build Zig Scripts")
	report("panel_download_menu_item", menu_with("Download Zig 0.17.0") != null, "no Tools menu item 'Download Zig 0.17.0'")
	if menu == null:
		report("panel_build_menu_item", false, "no Tools menu item 'Build Zig Scripts'")
		return
	var outcomes: int = probe.editor_build_outcomes()
	for i in menu.item_count:
		if menu.get_item_text(i) == "Build Zig Scripts":
			menu.index_pressed.emit(i)
	st = await settle(outcomes)
	report("panel_build_menu_item", st.ok and st.trigger == "manual" and st.n == 2 and status.text.begins_with("Build 2 ok (manual, "), "status '%s', %s" % [status.text, str(st)])

	# ---- the Build button builds with trigger `manual` too
	outcomes = probe.editor_build_outcomes()
	button.pressed.emit()
	st = await settle(outcomes)
	report("panel_build_button", st.ok and st.trigger == "manual" and st.n == 3, str(st))

	# ---- a broken save: the status line, a link per error, the link opens
	# the script at the error
	var script: Script = load("res://broken.zig")
	var good_text: String = script.source_code
	script.source_code = good_text.replace("start_speed: f32 = 5;", "start_speed: f32 = oops;")
	outcomes = probe.editor_build_outcomes()
	var err := ResourceSaver.save(script, "res://broken.zig")
	st = await settle(outcomes)
	var text := diags.get_parsed_text()
	report("panel_failed_status", err == OK and not st.ok and st.trigger == "save" and status.text.begins_with("Build failed: 1 errors, 0 warnings (") and status.text.ends_with(" ms); build 3 stays in use"),
		"save %d, status '%s', %s" % [err, status.text, str(st)])
	var re := RegEx.create_from_string("res://broken\\.zig:3:\\d+")
	var found := re.search(text)
	report("panel_lists_errors", found != null, "diagnostics text '%s'" % text)
	if found != null:
		diags.meta_clicked.emit(found.get_string())
		await frames(5)
		var se := EditorInterface.get_script_editor()
		var current := se.get_current_editor()
		var code: CodeEdit = current.get_base_editor() if current != null else null
		var res: Script = se.get_current_script()
		report("panel_link_opens_script", res != null and res.resource_path == "res://broken.zig" and code != null and code.get_caret_line() == 2,
			"resource %s, caret line %s" % [res.resource_path if res != null else "none", str(code.get_caret_line()) if code != null else "none"])

	# ---- toasts: a failure after a good build is one warning toast; the
	# same failure again reuses it
	var failed := func(t: String) -> bool: return t.begins_with("Zig build failed")
	var first: Array = toasts(failed)
	st = await build("manual")
	var again: Array = toasts(failed)
	var log: Array = probe.editor_panel_toasts()
	var warnings := 0
	for e in log:
		if e.begins_with("warning: Zig build failed"):
			warnings += 1
	report("panel_failure_toast", first.size() == 1 and again.size() == 1 and warnings == 2 and not st.ok,
		"toasts %s then %s, pushed %s" % [str(first), str(again), str(log)])

	# ---- a missing Zig: one error toast with the download hint, reused
	ProjectSettings.set_setting(SETTING, missing)
	st = await build("manual")
	var hint := func(t: String) -> bool: return t.contains("Download Zig 0.17.0")
	var missing_first: Array = toasts(hint)
	st = await build("manual")
	var missing_again: Array = toasts(hint)
	log = probe.editor_panel_toasts()
	var errors := 0
	for e in log:
		if e.begins_with("error: ") and e.contains("Download Zig 0.17.0"):
			errors += 1
	report("panel_missing_zig_toast", st.zig_problem == "missing" and missing_first.size() == 1 and missing_again.size() == 1 and errors == 2,
		"toasts %s then %s, pushed %s, %s" % [str(missing_first), str(missing_again), str(log), str(st)])
	ProjectSettings.set_setting(SETTING, zigs[0])

	# ---- repaired: the panel shows the new build and no errors
	script.source_code = good_text
	outcomes = probe.editor_build_outcomes()
	ResourceSaver.save(script, "res://broken.zig")
	st = await settle(outcomes)
	report("panel_repaired", st.ok and status.text.begins_with("Build 4 ok (save, ") and not diags.get_parsed_text().contains("res://broken.zig:"),
		"status '%s', diagnostics '%s'" % [status.text, diags.get_parsed_text()])
