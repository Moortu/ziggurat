@tool
extends Node
# Host test "change check: external edit reaches a running game without
# focus": runs as a tool autoload in the headless editor of
# test/host/projects/e2e with the probe host. The editor has no window, so
# no focus-in event ever reaches it, and the check interval setting is 0.
# The game runs from the editor (Play, headless through
# `editor/run/main_run_args`) and keeps running (ZTEST_GUI); it writes each
# new "e2e game: hero score=..." line to the file ZTEST_GAME_LOG names.
#
# Steps:
# 1. the build at open, the warm server, then Play;
# 2. res://hero.zig is rewritten by a plain file write (no build is
#    requested), and the game must print the new score within 10 s, which
#    only the check while a game runs can cause.
# Prints one ZTEST line per case, then ZTEST DONE, stops the game and quits.

const BUILD_WAIT_MS := 600000
const GAME_WAIT_MS := 120000
const CHANGE_WAIT_MS := 10000
const INTERVAL := "ziggurat/build/check_interval_seconds"

var probe: Object
var game_log := ""


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
	game_log = OS.get_environment("ZTEST_GAME_LOG")
	await run()
	if EditorInterface.is_playing_scene():
		EditorInterface.stop_playing_scene()
		await wait_for(func(): return not EditorInterface.is_playing_scene(), 30000)
	print("ZTEST DONE")
	get_tree().quit()


func game_has(line: String) -> bool:
	return FileAccess.get_file_as_string(game_log).contains(line)


func run() -> void:
	var es := EditorInterface.get_editor_settings()
	report("change_interval_zero", int(es.get_setting(INTERVAL)) == 0, "interval %s" % es.get_setting(INTERVAL))

	var ok: bool = await wait_for(func(): return probe.editor_build_outcomes() >= 1 and not probe.editor_build_status().building, BUILD_WAIT_MS)
	var st: Dictionary = probe.editor_build_status()
	if ok and st.ok:
		ok = await wait_for(func(): return probe.editor_build_warm() == "ready", BUILD_WAIT_MS)
	else:
		ok = false
	report("change_session_warm", ok, "status %s warm %s" % [st, probe.editor_build_warm()])
	if not ok:
		return
	ProjectSettings.set_setting("editor/run/main_run_args", "--headless")
	EditorInterface.play_main_scene()
	ok = await wait_for(func(): return game_has("e2e game: hero score=26 speed=12.5"), GAME_WAIT_MS)
	report("change_game_running", ok and EditorInterface.is_playing_scene(), "playing %s" % EditorInterface.is_playing_scene())
	if not ok:
		return

	# The edit: a plain file write, no build request.
	var lines := FileAccess.get_file_as_string("res://hero.zig").split("\n")
	for i in lines.size():
		if lines[i].contains("self.speed * 2))"):
			lines[i] = "    return bonus + @as(i32, @intFromFloat(self.speed * 2)) + 400;"
	var f := FileAccess.open("res://hero.zig", FileAccess.WRITE)
	f.store_string("\n".join(lines))
	f.close()
	ok = await wait_for(func(): return game_has("e2e game: hero score=426 speed=12.5"), CHANGE_WAIT_MS)
	report("change_game_new_code_without_focus", ok, "game log %s" % FileAccess.get_file_as_string(game_log))
