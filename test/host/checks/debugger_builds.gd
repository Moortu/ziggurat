@tool
extends Node
# Host test "debugger builds: toggling during a session": runs as a tool
# autoload in the headless editor of test/host/projects/e2e with the probe
# host. The project's Zig is a wrapper that writes the arguments of every
# compiler start to the file res://argv_log.txt names. The game runs from
# the editor (Play, headless through `editor/run/main_run_args`) with
# ZTEST_GUI set, so it keeps running and writes each new
# "e2e game: hero score=..." line to the file ZTEST_GAME_LOG names.
#
# Steps:
# 1. the build at open, then the warm server, then Play;
# 2. the editor setting ziggurat/build/debugger_builds on: the Zig panel
#    shows its line, the next build (a script edit) is LLVM and
#    non-incremental, no warm server stays, and the game runs the new code
#    (it got the build through `ziggurat:reload`);
# 3. the setting off: the next edit builds in full without LLVM, a warm
#    server exists again, and the edit after that is incremental; the game
#    runs each new version.
# Prints one ZTEST line per case, then ZTEST DONE, stops the game, turns the
# setting on for the test's second pass (debugger_open.gd) and quits.

const BUILD_WAIT_MS := 600000
const GAME_WAIT_MS := 120000
const SETTING := "ziggurat/build/debugger_builds"
const PANEL_LINE := "Debugger builds: on (slower, no incremental)"

var probe: Object
var game_log := ""
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
	game_log = OS.get_environment("ZTEST_GAME_LOG")
	argv_log = FileAccess.get_file_as_string("res://argv_log.txt").strip_edges()
	await run()
	if EditorInterface.is_playing_scene():
		EditorInterface.stop_playing_scene()
		await wait_for(func(): return not EditorInterface.is_playing_scene(), 30000)
	# The second pass (debugger_open.gd) opens the project with it on.
	EditorInterface.get_editor_settings().set_setting(SETTING, true)
	print("ZTEST DONE")
	get_tree().quit()


func game_has(line: String) -> bool:
	return FileAccess.get_file_as_string(game_log).contains(line)


# The arguments of the newest compiler start.
func argv_lines() -> PackedStringArray:
	var text := FileAccess.get_file_as_string(argv_log).strip_edges()
	return PackedStringArray() if text.is_empty() else text.split("\n")


func last_argv() -> PackedStringArray:
	var lines := argv_lines()
	return lines[lines.size() - 1].split(" ")


# The first compiler start after the first `count` lines: the build that
# came next. A warm server may start right after that build, before the
# check reads the file, so the last line is not always the build's.
func argv_after(count: int) -> PackedStringArray:
	var lines := argv_lines()
	return lines[count].split(" ") if lines.size() > count else PackedStringArray()


# Rewrites the score line of res://hero.zig to add `bonus`, requests a save
# build and waits until its outcome is applied; returns the status.
func edit_and_build(bonus: int) -> Dictionary:
	var text := FileAccess.get_file_as_string("res://hero.zig")
	var lines := text.split("\n")
	for i in lines.size():
		if lines[i].contains("self.speed * 2))"):
			lines[i] = "    return bonus + @as(i32, @intFromFloat(self.speed * 2)) + %d;" % bonus
	var f := FileAccess.open("res://hero.zig", FileAccess.WRITE)
	f.store_string("\n".join(lines))
	f.close()
	var outcomes: int = probe.editor_build_outcomes()
	probe.editor_build_request("save")
	await wait_for(func(): return probe.editor_build_outcomes() > outcomes and not probe.editor_build_status().building, BUILD_WAIT_MS)
	return probe.editor_build_status()


func panel_line() -> Label:
	for d in get_tree().root.find_children("*", "EditorDock", true, false):
		var l: Label = d.find_child("Debugger", true, false)
		if l != null:
			return l
	return null


func run() -> void:
	var es := EditorInterface.get_editor_settings()

	# 1. The build at open, the warm server, then the game.
	var ok: bool = await wait_for(func(): return probe.editor_build_outcomes() >= 1 and not probe.editor_build_status().building, BUILD_WAIT_MS)
	var st: Dictionary = probe.editor_build_status()
	report("debugger_setting_registered", es.has_setting(SETTING) and es.get_setting(SETTING) == false,
		"has %s value %s" % [es.has_setting(SETTING), es.get_setting(SETTING) if es.has_setting(SETTING) else null])
	if ok and st.ok:
		ok = await wait_for(func(): return probe.editor_build_warm() == "ready", BUILD_WAIT_MS)
	else:
		ok = false
	report("debugger_session_warm", ok, "status %s warm %s" % [st, probe.editor_build_warm()])
	if not ok:
		return
	ProjectSettings.set_setting("editor/run/main_run_args", "--headless")
	EditorInterface.play_main_scene()
	ok = await wait_for(func(): return game_has("e2e game: hero score=26 speed=12.5"), GAME_WAIT_MS)
	report("debugger_game_running", ok and EditorInterface.is_playing_scene(), "playing %s" % EditorInterface.is_playing_scene())
	if not ok:
		return

	# 2. Debugger builds on.
	es.set_setting(SETTING, true)
	var line := panel_line()
	ok = await wait_for(func(): return line != null and line.visible and line.text == PANEL_LINE, 10000)
	report("debugger_panel_line", ok, "label %s" % [line.text if line != null else "missing"])
	var before: int = st.n
	st = await edit_and_build(100)
	var argv := last_argv()
	report("debugger_build_llvm", st.ok and st.n > before and st.path == "full" and argv.has("-fllvm") and not argv.has("-fincremental") and argv.has("-ODebug"),
		"status %s argv %s" % [st, argv])
	report("debugger_no_warm_server", probe.editor_build_warm() == "disabled", "warm %s" % probe.editor_build_warm())
	ok = await wait_for(func(): return game_has("e2e game: hero score=126 speed=12.5"), GAME_WAIT_MS)
	report("debugger_game_new_code", ok, "game log %s" % FileAccess.get_file_as_string(game_log))

	# 3. Off again: a full build without LLVM, a warm server, then an
	# incremental build.
	es.set_setting(SETTING, false)
	ok = await wait_for(func(): return line != null and not line.visible, 10000)
	report("debugger_panel_line_hidden", ok, "visible %s" % [line.visible if line != null else "missing"])
	before = st.n
	var starts := argv_lines().size()
	st = await edit_and_build(200)
	argv = argv_after(starts)
	report("debugger_off_full", st.ok and st.n > before and st.path == "full" and argv.has("-fno-llvm") and not argv.has("-fincremental"),
		"status %s argv %s" % [st, argv])
	ok = await wait_for(func(): return probe.editor_build_warm() == "ready", BUILD_WAIT_MS)
	report("debugger_off_warm_again", ok, "warm %s" % probe.editor_build_warm())
	ok = await wait_for(func(): return game_has("e2e game: hero score=226 speed=12.5"), GAME_WAIT_MS)
	report("debugger_off_game_new_code", ok, "game log %s" % FileAccess.get_file_as_string(game_log))
	before = st.n
	st = await edit_and_build(300)
	report("debugger_off_incremental", st.ok and st.n > before and st.path == "incremental", "status %s" % st)
	ok = await wait_for(func(): return game_has("e2e game: hero score=326 speed=12.5"), GAME_WAIT_MS)
	report("debugger_off_game_incremental_code", ok, "game log %s" % FileAccess.get_file_as_string(game_log))
