@tool
extends Node
# Host tests "download ...": runs as a tool autoload in the headless editor
# with the probe host. The test's fixture HTTP server stands in for the Zig
# mirrors and ziglang.org; res://download_cfg.txt holds the test overrides
# (handed to the probe's `zig_download_configure`) and res://download_case.txt
# names the case. The per-user folders are inside the test's folder and
# `PATH` has no Zig. The check starts the download with the Tools menu item
# `Download Zig 0.17.0` the way the editor does, follows the download's
# state and the Zig panel, prints one ZTEST line per check, then ZTEST DONE,
# and quits the editor. The test reads the server's request log and the
# toolchains folder afterwards.

const WAIT_MS := 120000
const MENU := "Download Zig 0.17.0"

var probe: Object
var toolchains: String


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


func zig_dock() -> Node:
	for d in get_tree().root.find_children("*", "EditorDock", true, false):
		if d.title == "Zig":
			return d
	return null


func menu_with(text: String) -> PopupMenu:
	for m in get_tree().root.find_children("*", "PopupMenu", true, false):
		for i in m.item_count:
			if m.get_item_text(i) == text:
				return m
	return null


func press_download() -> bool:
	var menu := menu_with(MENU)
	if menu == null:
		return false
	for i in menu.item_count:
		if menu.get_item_text(i) == MENU:
			menu.index_pressed.emit(i)
	return true


func state() -> Dictionary:
	return probe.zig_download_state()


func finished() -> bool:
	var s: String = state().state
	return s == "done" or s == "failed"


# Names in the toolchains folder that a download or an install leaves only
# while it runs.
func temp_names() -> Array:
	var left := []
	var d := DirAccess.open(toolchains)
	if d == null:
		return left
	d.include_hidden = true
	for n in d.get_files() + d.get_directories():
		if n.begins_with(".download-") or (n.begins_with(".zig-") and n.contains(".tmp-")):
			left.append(n)
	return left


func run() -> void:
	for m in ["zig_download_configure", "zig_download_state", "zig_download_cancel", "zig_download_requests", "editor_build_status", "editor_panel_toasts"]:
		if not probe.has_method(m):
			report("download_probe_methods", false, "the probe has no method %s" % m)
			return
	toolchains = OS.get_environment("XDG_DATA_HOME").path_join("ziggurat/toolchains")
	var cfg := FileAccess.get_file_as_string("res://download_cfg.txt")
	report("download_configured", probe.zig_download_configure(cfg), "the probe refused the test overrides")
	var case_name := FileAccess.get_file_as_string("res://download_case.txt").strip_edges()
	var dock := zig_dock()
	if dock == null:
		report("download_dock", false, "no Zig dock")
		return
	var row: Control = dock.find_child("Download", true, false)
	var text: Label = dock.find_child("DownloadText", true, false)
	var cancel: Button = dock.find_child("DownloadCancel", true, false)
	if row == null or text == null or cancel == null:
		report("download_panel_children", false, "row %s, text %s, cancel %s" % [row, text, cancel])
		return
	report("download_idle_at_start", state().state == "idle" and not row.visible, "%s, row visible %s" % [str(state()), row.visible])
	match case_name:
		"installs":
			await installs(row, text)
		"fails":
			await fails(row, text)
		"cancel":
			await cancelled(row, text, cancel)
		"second":
			await second_click(cancel)
		_:
			report("download_case", false, "unknown case '%s'" % case_name)


func installs(row: Control, text: Label) -> void:
	var outcomes: int = probe.editor_build_outcomes()
	report("download_menu", press_download(), "no Tools menu item '%s'" % MENU)
	var seen_checking := false
	var end := Time.get_ticks_msec() + WAIT_MS
	while Time.get_ticks_msec() < end and not finished():
		if state().state == "checking" and text.text == "Checking and unpacking Zig (needs about 800 MB of memory)":
			seen_checking = true
		await get_tree().process_frame
	var st := state()
	report("download_done", st.state == "done", str(st))
	report("download_installed", FileAccess.file_exists(toolchains.path_join("zig-0.17.0/zig")), "no %s" % toolchains.path_join("zig-0.17.0/zig"))
	# The check runs on a worker thread; the panel showed its line meanwhile
	# (the fixture is tiny, so the state may pass in one frame).
	print("download checking line seen: %s" % seen_checking)
	await frames(5)
	report("download_panel_installed", row.visible and text.text == "Zig 0.17.0 installed", "row visible %s, text '%s'" % [row.visible, text.text])
	# The plugin asks for a build; the locator finds the downloaded Zig.
	await wait_for(func(): return probe.editor_build_outcomes() > outcomes and probe.editor_build_status().get("trigger", "") == "manual" and not probe.editor_build_status().building)
	var b: Dictionary = probe.editor_build_status()
	report("download_build_follows", b.get("trigger", "") == "manual" and b.get("zig_problem", "") == "none", str(b))
	report("download_no_temp", temp_names().is_empty(), str(temp_names()))


func fails(row: Control, text: Label) -> void:
	report("download_menu", press_download(), "no Tools menu item '%s'" % MENU)
	await wait_for(finished)
	var st := state()
	report("download_failed", st.state == "failed" and st.reason != "", str(st))
	await frames(5)
	var errors := 0
	for e in probe.editor_panel_toasts():
		if e.begins_with("error: ") and e.contains("Zig 0.17.0") and e.contains("download"):
			errors += 1
	report("download_failed_toast", errors == 1, str(probe.editor_panel_toasts()))
	report("download_panel_failed", row.visible and text.text.begins_with("Zig download failed: "), "row visible %s, text '%s'" % [row.visible, text.text])
	report("download_nothing_installed", not DirAccess.dir_exists_absolute(toolchains.path_join("zig-0.17.0")), "zig-0.17.0 exists")
	report("download_no_temp", temp_names().is_empty(), str(temp_names()))


# Waits until the archive download of the slow mirror has bytes.
func downloading() -> bool:
	var st := state()
	return st.state == "downloading" and st.bytes > 0


func cancelled(row: Control, text: Label, cancel: Button) -> void:
	report("download_menu", press_download(), "no Tools menu item '%s'" % MENU)
	await wait_for(downloading)
	var st := state()
	report("download_progress", st.state == "downloading" and st.total > 0 and row.visible and cancel.visible and text.text.begins_with("Downloading Zig 0.17.0"),
		"%s, row visible %s, cancel visible %s, text '%s'" % [str(st), row.visible, cancel.visible, text.text])
	var partial := temp_names()
	cancel.pressed.emit()
	await frames(5)
	st = state()
	report("download_cancelled", st.state == "idle" and not cancel.visible, "%s, cancel visible %s" % [str(st), cancel.visible])
	report("download_partial_gone", partial.size() == 1 and temp_names().is_empty(), "before %s, after %s" % [str(partial), str(temp_names())])
	report("download_nothing_installed", not DirAccess.dir_exists_absolute(toolchains.path_join("zig-0.17.0")), "zig-0.17.0 exists")


func second_click(cancel: Button) -> void:
	report("download_menu", press_download(), "no Tools menu item '%s'" % MENU)
	await wait_for(downloading)
	var before := state()
	var requests: int = probe.zig_download_requests()
	press_download()
	await frames(30)
	var after := state()
	report("download_second_click_ignored", before.state == "downloading" and after.state == "downloading" and after.mirror == before.mirror and probe.zig_download_requests() == requests,
		"before %s, after %s, requests %d then %d" % [str(before), str(after), requests, probe.zig_download_requests()])
	cancel.pressed.emit()
	await frames(5)
	report("download_no_temp", temp_names().is_empty(), str(temp_names()))
