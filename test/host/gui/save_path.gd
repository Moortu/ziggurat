@tool
extends Node
# Host test "gui: save in the script editor reaches the running game" (spec
# section 12, check 6): runs as a tool autoload in the GUI editor (under
# Xvfb) on a copy of test/host/projects/e2e. The editor's stdout and stderr
# go to the file named by the environment variable ZTEST_LOG; the game the
# editor starts inherits them, so the check reads the game's lines there.
#
# Steps, as a person would do them:
# 1. wait for the build at project open (generation 1 staged for the game);
# 2. open res://hero.zig in the script editor;
# 3. Play the main scene and wait for the game's "e2e game: checks done";
# 4. change one line in the script editor (the default of `speed`) and save
#    with ScriptEditor.save_all_scripts(), the script editor's File > Save
#    All;
# 5. within 10 s the game logs the host's `_reload_scripts` line;
# 6. the save also builds a new generation in the editor.
# Play itself saves open scripts first (EditorNode saves external data before
# a run, and the script editor's indent conversion on save marks the file
# changed), which builds another generation before the game starts; the
# check prints what Play did to the file and does not depend on it.
# Prints one ZTEST line per step, then ZTEST DONE, stops the game and quits.

const BUILD_WAIT_MS := 600000
const GAME_WAIT_MS := 120000
const RELOAD_WAIT_MS := 10000
const OPEN_WAIT_MS := 30000
const MANIFEST := "res://.godot/ziggurat/manifest"
const RELOAD_LINE := "Ziggurat: reload requested for 1 scripts (swaps arrive in a later version)."
const GAME_READY_LINE := "e2e game: checks done"

var log_path := ""


func report(name: String, ok: bool, why: String) -> void:
	if ok:
		print("ZTEST PASS %s" % name)
	else:
		print("ZTEST FAIL %s: %s" % [name, why])


func _ready() -> void:
	if not Engine.is_editor_hint():
		return
	log_path = OS.get_environment("ZTEST_LOG")
	await run()
	if EditorInterface.is_playing_scene():
		EditorInterface.stop_playing_scene()
		await wait_for(func(): return not EditorInterface.is_playing_scene(), OPEN_WAIT_MS)
	print("ZTEST DONE")
	get_tree().quit()


# The generation the manifest names, or 0.
func manifest_gen() -> int:
	var text := FileAccess.get_file_as_string(MANIFEST)
	if not text.begins_with("gen="):
		return 0
	return text.substr(4, text.find("\n") - 4).to_int()


func log_text() -> String:
	return FileAccess.get_file_as_string(log_path)


# Waits up to `ms` for `cond` to return true, checking every frame.
func wait_for(cond: Callable, ms: int) -> bool:
	var end := Time.get_ticks_msec() + ms
	while Time.get_ticks_msec() < end:
		if cond.call():
			return true
		await get_tree().process_frame
	return cond.call()


func run() -> void:
	report("gui_editor", DisplayServer.get_name() != "headless" and log_path != "" and FileAccess.file_exists(log_path),
		"display %s log '%s'" % [DisplayServer.get_name(), log_path])

	# 1. The build at open.
	var built: bool = await wait_for(func(): return FileAccess.get_file_as_string(MANIFEST) == "gen=1\npath=gen/1/libzmod.1.so\n", BUILD_WAIT_MS)
	report("gui_build_at_open", built, var_to_str(FileAccess.get_file_as_string(MANIFEST)))
	if not built:
		return

	# 2. The script in the script editor.
	var hero: Script = load("res://hero.zig")
	EditorInterface.edit_script(hero)
	var se := EditorInterface.get_script_editor()
	await wait_for(func(): return se.get_current_script() == hero and se.get_current_editor() != null, OPEN_WAIT_MS)
	var current := se.get_current_editor()
	var code: CodeEdit = null
	if current != null:
		code = current.get_base_editor() as CodeEdit
	report("gui_script_open", se.get_current_script() == hero and code != null and code.text.contains("speed: f32 = 5,"),
		"current %s editor %s" % [se.get_current_script(), code])
	if code == null:
		return

	# 3. Play, and wait until the game has run its checks.
	EditorInterface.play_main_scene()
	var running: bool = await wait_for(func(): return log_text().contains(GAME_READY_LINE), GAME_WAIT_MS)
	report("gui_game_running", running and EditorInterface.is_playing_scene(), "playing %s" % EditorInterface.is_playing_scene())
	print("gui save path: after Play, res://hero.zig has tab indentation: %s; manifest generation %d" % [FileAccess.get_file_as_string("res://hero.zig").contains("\n\t"), manifest_gen()])
	if not running:
		return
	# The game asks for nothing yet.
	report("gui_no_reload_before_save", not log_text().contains(RELOAD_LINE), "")

	# 4. Edit one line in the script editor, then save all scripts.
	var line := -1
	for i in code.get_line_count():
		if code.get_line(i).contains("speed: f32 = 5,"):
			line = i
	code.set_line(line, code.get_line(line).replace("speed: f32 = 5,", "speed: f32 = 6,"))
	report("gui_script_edited", line >= 0 and se.get_unsaved_files().size() > 0, "line %d unsaved %s" % [line, se.get_unsaved_files()])
	var before := log_text().length()
	var gen_before := manifest_gen()
	var t0 := Time.get_ticks_msec()
	se.save_all_scripts()
	report("gui_script_saved", FileAccess.get_file_as_string("res://hero.zig").contains("speed: f32 = 6,") and se.get_unsaved_files().is_empty(),
		"unsaved %s" % [se.get_unsaved_files()])

	# 5. The game's `_reload_scripts` line within 10 s of the save.
	var reloaded: bool = await wait_for(func(): return log_text().substr(before).contains(RELOAD_LINE), RELOAD_WAIT_MS)
	var ms := Time.get_ticks_msec() - t0
	print("gui save path: reload line after %d ms" % ms)
	report("gui_save_reaches_game", reloaded and ms <= RELOAD_WAIT_MS, "after %d ms" % ms)

	# 6. The save built a new generation in the editor.
	built = await wait_for(func(): return manifest_gen() > gen_before, BUILD_WAIT_MS)
	report("gui_save_builds", built, "generation %d, before the save %d" % [manifest_gen(), gen_before])
