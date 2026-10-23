@tool
extends Node
# Host tests "play ...": runs as a tool autoload in an editor started with
# `--build-solutions`, which calls the editor plugins' `_build` (what Play
# calls before the game starts) once, after this autoload's `_ready` and
# before the first `process_frame` signal, and
# exits with status 1 when it returns false. The project is
# test/host/projects/editor_panel with the probe host; res://play_case.txt
# names the case:
# - `builds_first`: an edit is saved in `_ready`, so its build request
#   still waits in the main-thread queue when `_build` runs; `_build` must return true with that
#   build applied (the manifest names it, the new default shows).
# - `failed`: every build fails; `_build` returns false and shows the Zig
#   panel.
# - `timeout_good`: the build is held at the gate, a good build exists from
#   an earlier run, `play_wait_seconds` is 1: `_build` returns true with the
#   toast.
# - `timeout_none`: as `timeout_good` without a good build: false, and the
#   panel shows.
# - `no_service`: no SDK manifest setting: true at once.
# - `off`: `build_on_play` is false (the build is held): true, nothing
#   requested.
# Each case prints ZTEST lines; a case that returns false prints them when
# the editor exits (no frame follows), then ZTEST DONE.

const MANIFEST := "res://.godot/ziggurat/manifest"
const STILL_RUNNING := "Zig build still running; the game starts with build %d and reloads when the build finishes"

var probe: Object
var case_name := ""
var frame := 0
var dock: Node = null
var hidden_before := false
var shown := false
var finished := false


func report(name: String, ok: bool, why: String) -> void:
	if ok:
		print("ZTEST PASS %s" % name)
	else:
		print("ZTEST FAIL %s: %s" % [name, why])


func zig_dock() -> Node:
	for d in get_tree().root.find_children("*", "EditorDock", true, false):
		if d.title == "Zig":
			return d
	return null


func manifest_gen() -> int:
	var text := FileAccess.get_file_as_string(MANIFEST)
	if not text.begins_with("gen="):
		return -1
	return text.get_slice("\n", 0).trim_prefix("gen=").to_int()


func _ready() -> void:
	if not Engine.is_editor_hint():
		return
	probe = ClassDB.instantiate("ZigguratTestProbe")
	case_name = FileAccess.get_file_as_string("res://play_case.txt").strip_edges()
	var play: Dictionary = probe.editor_plugin_play()
	report("play_not_before_first_frame", play.calls == 0, str(play))
	# The Zig dock starts closed, so showing it is seen.
	dock = zig_dock()
	if dock != null:
		dock.close()
		hidden_before = not dock.is_visible_in_tree()
		dock.visibility_changed.connect(_on_dock_visibility)
	match case_name:
		"builds_first":
			report("play_settings_default",
				ProjectSettings.get_setting("ziggurat/build/build_on_play") == true and ProjectSettings.get_setting("ziggurat/build/play_wait_seconds") == 60,
				"build_on_play %s, play_wait_seconds %s" % [ProjectSettings.get_setting("ziggurat/build/build_on_play"), ProjectSettings.get_setting("ziggurat/build/play_wait_seconds")])
			# The first build of a fresh build cache can take minutes.
			ProjectSettings.set_setting("ziggurat/build/play_wait_seconds", 600)
			# The build request of an edit saved now still waits in the
			# main-thread queue when `_build` runs, as after Play's autosave.
			var script: Script = load("res://broken.zig")
			script.source_code = script.source_code.replace("start_speed: f32 = 5;", "start_speed: f32 = 7;")
			report("play_edit_saved", ResourceSaver.save(script, "res://broken.zig") == OK, "save failed")
		"timeout_good", "timeout_none":
			ProjectSettings.set_setting("ziggurat/build/play_wait_seconds", 1)
		"off":
			ProjectSettings.set_setting("ziggurat/build/build_on_play", false)
	get_tree().process_frame.connect(_on_frame)


func _on_frame() -> void:
	frame += 1
	var play: Dictionary = probe.editor_plugin_play()
	if finished:
		return
	if play.calls == 0:
		if frame >= 30:
			finished = true
			report("play_called", false, "_build was not called in %d frames" % frame)
			print("ZTEST DONE")
			get_tree().quit()
		return
	# The first frame after `_build` returned true.
	finished = true
	var st: Dictionary = probe.editor_build_status()
	report("play_called_once", play.calls == 1, str(play))
	match case_name:
		"builds_first":
			var s: Script = load("res://broken.zig")
			report("play_builds_first",
				play.result and play.requested == 1 and not st.building and st.ok and st.trigger == "play" and manifest_gen() == st.n and s.get_property_default_value("speed") == 7.0,
				"play %s, status %s, manifest %d, speed default %s" % [str(play), str(st), manifest_gen(), s.get_property_default_value("speed")])
		"timeout_good":
			var want := STILL_RUNNING % manifest_gen()
			var toasts: Array = probe.editor_panel_toasts()
			report("play_timeout_with_good_build",
				play.result and play.requested == 1 and st.building and manifest_gen() >= 1 and toasts.has("warning: " + want),
				"play %s, status %s, manifest %d, toasts %s" % [str(play), str(st), manifest_gen(), str(toasts)])
		"no_service":
			report("play_without_service", play.result and play.requested == 0 and not st.building and not st.has_last, "play %s, status %s" % [str(play), str(st)])
		"off":
			report("play_off", play.result and play.requested == 0 and st.building and not st.has_last, "play %s, status %s" % [str(play), str(st)])
		_:
			report("play_returned_false", false, "case %s: _build returned true (%s, status %s)" % [case_name, str(play), str(st)])
	print("ZTEST DONE")
	get_tree().quit()


func _on_dock_visibility() -> void:
	if dock.is_visible_in_tree() and probe.editor_plugin_play().calls >= 1:
		shown = true


# A case where `_build` returns false ends without another frame.
func _exit_tree() -> void:
	if not Engine.is_editor_hint() or finished:
		return
	finished = true
	match case_name:
		"failed", "timeout_none":
			report("play_cancel_shows_panel", hidden_before and shown, "dock %s, hidden before %s, shown %s" % [dock, hidden_before, shown])
		_:
			report("play_finished", false, "case %s: the editor exited before a frame followed _build" % case_name)
	print("ZTEST DONE")
