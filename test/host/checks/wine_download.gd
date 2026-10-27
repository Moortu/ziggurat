@tool
extends Node
# Wine end-to-end test "wine: zig download installs the real windows zip":
# runs as a tool autoload in the Windows editor under Wine with the probe
# host. res://download_cfg.txt holds the test overrides: the fixture
# server's mirror list, plain http and a toolchains folder inside the test's
# folder, but no key and no archive, so the pinned Windows archive and the
# pinned Zig key apply. The check starts the download with the Tools menu
# item, waits until it ends, prints one ZTEST line per check, then ZTEST
# DONE, and quits the editor. The test runs the installed zig.exe after.

const WAIT_MS := 600000
const MENU := "Download Zig 0.17.0"

var probe: Object


func report(name: String, ok: bool, why: String) -> void:
	if ok:
		print("ZTEST PASS %s" % name)
	else:
		print("ZTEST FAIL %s: %s" % [name, why])


func _ready() -> void:
	if not Engine.is_editor_hint():
		return
	probe = ClassDB.instantiate("ZigguratTestProbe")
	await run()
	print("ZTEST DONE")
	get_tree().quit()


func press_download() -> bool:
	for m in get_tree().root.find_children("*", "PopupMenu", true, false):
		for i in m.item_count:
			if m.get_item_text(i) == MENU:
				m.index_pressed.emit(i)
				return true
	return false


func run() -> void:
	var cfg := FileAccess.get_file_as_string("res://download_cfg.txt")
	report("wine_download_configured", probe.zig_download_configure(cfg), "the probe refused the test overrides")
	report("wine_download_menu", press_download(), "no Tools menu item '%s'" % MENU)
	var end := Time.get_ticks_msec() + WAIT_MS
	while Time.get_ticks_msec() < end:
		var s: String = probe.zig_download_state().state
		if s == "done" or s == "failed":
			break
		await get_tree().process_frame
	var st: Dictionary = probe.zig_download_state()
	report("wine_download_done", st.state == "done", str(st))
