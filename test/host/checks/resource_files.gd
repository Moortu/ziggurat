extends SceneTree
# Host test "loader and saver": the `.zig` ResourceFormatLoader and
# ResourceFormatSaver, seen from GDScript. The extension list, `exists`,
# loading a good, a broken and a missing file, loads that must have no side
# effect (main thread, CACHE_MODE_IGNORE, worker threads, threaded request),
# saving (round trip, atomic replace under a reading thread, errors) and the
# `on_saved` hook, through ZigguratTestProbe. The tab-indented save is
# checked by the Zig side (it builds the result): this script only writes
# res://tab_out.zig from res://tab_in.txt. Prints one ZTEST line per case,
# then ZTEST DONE.

const GOOD := "res://good.zig"
const BROKEN := "res://broken.zig"
const BROKEN_TEXT := "const z = @import(\"ziggurat\"\npub const extends = ;\nfn {{{\n"

var probe: Object
var mutex := Mutex.new()
var stop_reader := false
var bad_reads: Array[String] = []
var reads := 0


func report(name: String, ok: bool, why: String) -> void:
	if ok:
		print("ZTEST PASS %s" % name)
	else:
		print("ZTEST FAIL %s: %s" % [name, why])


func project_files() -> PackedStringArray:
	var files := DirAccess.get_files_at("res://")
	files.sort()
	return files


func _initialize() -> void:
	probe = ClassDB.instantiate("ZigguratTestProbe")
	probe.saved_hook_install()
	check_extension()
	check_exists()
	check_load()
	check_broken()
	check_missing()
	check_side_effect_free()
	check_save()
	check_save_errors()
	check_atomic()
	check_hook()
	check_tab_save()
	print("ZTEST DONE")
	quit()


func check_extension() -> void:
	var exts := ResourceLoader.get_recognized_extensions_for_type("Script")
	report("extension_zig_recognized", "zig" in exts, str(exts))
	var exts_zig := ResourceLoader.get_recognized_extensions_for_type("ZigScript")
	report("extension_zig_recognized_for_zigscript", "zig" in exts_zig, str(exts_zig))
	var s: Script = ClassDB.instantiate("ZigScript")
	var saver_exts := ResourceSaver.get_recognized_extensions(s)
	report("saver_extension_zig", "zig" in saver_exts, str(saver_exts))
	var plain := ResourceSaver.get_recognized_extensions(Resource.new())
	report("saver_ignores_other_resources", not ("zig" in plain), str(plain))
	report("loader_ignores_other_types", not ("zig" in ResourceLoader.get_recognized_extensions_for_type("Texture2D")), "")


func check_exists() -> void:
	report("exists_true", ResourceLoader.exists(GOOD), "good.zig")
	report("exists_false", not ResourceLoader.exists("res://nope.zig"), "nope.zig")


func check_load() -> void:
	var text := FileAccess.get_file_as_string(GOOD)
	var s: Resource = ResourceLoader.load(GOOD)
	report("load_returns_zigscript", s != null and s.get_class() == "ZigScript" and s is Script, str(s))
	if s == null:
		return
	report("load_source_text", s.source_code == text and text.contains("日本語"), "length %d vs %d" % [s.source_code.length(), text.length()])
	report("load_sets_path", s.resource_path == GOOD, s.resource_path)
	var again: Resource = ResourceLoader.load(GOOD)
	report("load_reuses_cached", again == s, "")
	var fresh: Resource = ResourceLoader.load(GOOD, "", ResourceLoader.CACHE_MODE_IGNORE)
	report("load_ignore_cache_is_new_object", fresh != null and fresh != s and fresh.source_code == text, str(fresh))
	var typed: Resource = ResourceLoader.load(GOOD, "ZigScript")
	report("load_type_hint", typed == s, str(typed))


func check_broken() -> void:
	var f := FileAccess.open(BROKEN, FileAccess.WRITE)
	f.store_string(BROKEN_TEXT)
	f.close()
	var s: Resource = ResourceLoader.load(BROKEN)
	report("broken_script_loads", s != null and s.get_class() == "ZigScript" and s.source_code == BROKEN_TEXT, str(s))


func check_missing() -> void:
	var s: Resource = ResourceLoader.load("res://nope.zig")
	report("missing_file_is_null", s == null, str(s))
	var folder_as_file: Resource = ResourceLoader.load("res://nodir/nope.zig")
	report("missing_folder_is_null", folder_as_file == null, str(folder_as_file))


# A loader thread must not build, load a module, write a cache or create
# instances.
func check_side_effect_free() -> void:
	var files_before := project_files()
	var gen_before: int = probe.current_generation()
	var instances_before: int = probe.live_instances()
	var text := FileAccess.get_file_as_string(GOOD)
	var ok := true
	var why := ""

	for mode in [ResourceLoader.CACHE_MODE_IGNORE, ResourceLoader.CACHE_MODE_REUSE, ResourceLoader.CACHE_MODE_REPLACE]:
		var t := Thread.new()
		t.start(func() -> Resource: return ResourceLoader.load(GOOD, "", mode))
		var s: Resource = t.wait_to_finish()
		if s == null or s.get_class() != "ZigScript" or s.source_code != text:
			ok = false
			why += "thread load mode %d gave %s; " % [mode, s]

	# The threaded loader runs the loader on its own worker thread.
	var err := ResourceLoader.load_threaded_request(GOOD, "", false, ResourceLoader.CACHE_MODE_IGNORE)
	if err != OK:
		ok = false
		why += "load_threaded_request %s; " % error_string(err)
	var threaded: Resource = null
	for i in 2000:
		var status := ResourceLoader.load_threaded_get_status(GOOD)
		if status == ResourceLoader.THREAD_LOAD_LOADED:
			threaded = ResourceLoader.load_threaded_get(GOOD)
			break
		if status == ResourceLoader.THREAD_LOAD_FAILED or status == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
			break
		OS.delay_msec(5)
	if threaded == null or threaded.source_code != text:
		ok = false
		why += "threaded load gave %s; " % threaded

	if probe.current_generation() != gen_before or probe.live_instances() != instances_before:
		ok = false
		why += "runtime state changed (generation %d, instances %d); " % [probe.current_generation(), probe.live_instances()]
	if project_files() != files_before:
		ok = false
		why += "files changed: %s -> %s; " % [files_before, project_files()]
	if FileAccess.file_exists("res://.godot/ziggurat/descriptors.json"):
		ok = false
		why += "a descriptor cache was written; "
	var loaded: Script = ResourceLoader.load(GOOD, "", ResourceLoader.CACHE_MODE_IGNORE)
	if probe.script_is_valid(loaded) or probe.script_placeholder_count(loaded) != 0:
		ok = false
		why += "the loaded script has descriptors or placeholders; "
	if FileAccess.get_file_as_string(GOOD) != text:
		ok = false
		why += "the source file changed; "
	report("loader_is_side_effect_free", ok, why)


func check_save() -> void:
	var text := "// saved by the test\nconst x = 1;\n\tconst kept_tab = 2;\n"
	var s: Script = ClassDB.instantiate("ZigScript")
	s.source_code = text
	var err := ResourceSaver.save(s, "res://made.zig")
	report("save_ok", err == OK, error_string(err))
	report("save_writes_text", FileAccess.get_file_as_string("res://made.zig").replace("\t", "    ") == text.replace("\t", "    "), FileAccess.get_file_as_string("res://made.zig"))
	var back: Resource = ResourceLoader.load("res://made.zig", "", ResourceLoader.CACHE_MODE_IGNORE)
	report("save_then_load_roundtrip", back != null and back.source_code == FileAccess.get_file_as_string("res://made.zig"), str(back))

	# Replace an existing file with shorter text: no tail of the old file.
	s.source_code = "// short\n"
	err = ResourceSaver.save(s, "res://made.zig")
	report("save_replaces_whole_file", err == OK and FileAccess.get_file_as_string("res://made.zig") == "// short\n", FileAccess.get_file_as_string("res://made.zig"))

	# The path of a loaded script is used when none is given.
	var loaded: Script = ResourceLoader.load("res://made.zig")
	loaded.source_code = "// via resource path\n"
	err = ResourceSaver.save(loaded)
	report("save_to_own_path", err == OK and FileAccess.get_file_as_string("res://made.zig") == "// via resource path\n", error_string(err))

	# Saving leaves nothing but the files the test made.
	var expected := PackedStringArray(["broken.zig", "good.zig", "made.zig", "project.godot"])
	var files := project_files()
	var extra := []
	for f in files:
		if not (f in expected) and f != "check.gd" and f != "tab_in.txt":
			extra.append(f)
	report("save_leaves_no_temporary_file", extra.is_empty(), str(extra))


func check_save_errors() -> void:
	var s: Script = ClassDB.instantiate("ZigScript")
	s.source_code = "// x\n"
	var err := ResourceSaver.save(s, "res://nodir/x.zig")
	report("save_missing_folder_fails", err != OK and not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path("res://nodir")), error_string(err))
	err = ResourceSaver.save(Resource.new(), "res://other.zig")
	report("save_other_resource_unrecognized", err != OK and not FileAccess.file_exists("res://other.zig"), error_string(err))
	err = ResourceSaver.save(s, "res://wrong.txt")
	report("save_wrong_extension_unrecognized", err != OK and not FileAccess.file_exists("res://wrong.txt"), error_string(err))


func reader(path: String, a: String, b: String) -> void:
	while true:
		mutex.lock()
		var stop := stop_reader
		mutex.unlock()
		if stop:
			return
		var t := FileAccess.get_file_as_string(path)
		mutex.lock()
		reads += 1
		if t != a and t != b and bad_reads.size() < 5:
			bad_reads.append("length %d" % t.length())
		mutex.unlock()


# A reader thread reads the file over and over while the main thread saves
# two long texts in turn: every read is one whole text, never empty or half.
func check_atomic() -> void:
	var a := "// a\n" + "const a_line = 1;\n".repeat(20000)
	var b := "// b\n" + "const b_line_longer = 22;\n".repeat(30000)
	var s: Script = ClassDB.instantiate("ZigScript")
	s.source_code = a
	var path := "res://atomic.zig"
	var first := ResourceSaver.save(s, path)
	var t := Thread.new()
	t.start(reader.bind(path, a, b))
	var failures := 0
	for i in 60:
		s.source_code = b if i % 2 == 0 else a
		if ResourceSaver.save(s, path) != OK:
			failures += 1
	mutex.lock()
	stop_reader = true
	mutex.unlock()
	t.wait_to_finish()
	var final := FileAccess.get_file_as_string(path)
	report("save_is_atomic", first == OK and failures == 0 and bad_reads.is_empty() and reads > 0 and (final == a or final == b), "first %s failures %d reads %d bad %s" % [error_string(first), failures, reads, bad_reads])
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func check_hook() -> void:
	var paths: PackedStringArray = probe.saved_hook_paths()
	report("hook_called_with_project_relative_path", "made.zig" in paths and "atomic.zig" in paths, str(paths))
	report("hook_not_called_for_failures", not ("nodir/x.zig" in paths) and not ("other.zig" in paths), str(paths))
	var s: Script = ClassDB.instantiate("ZigScript")
	s.source_code = "// user\n"
	probe.saved_hook_clear()
	var err := ResourceSaver.save(s, "user://elsewhere.zig")
	report("hook_not_called_outside_project", err == OK and probe.saved_hook_paths().is_empty(), error_string(err))
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://elsewhere.zig"))


func check_tab_save() -> void:
	var text := FileAccess.get_file_as_string("res://tab_in.txt")
	var s: Script = ClassDB.instantiate("ZigScript")
	s.source_code = text
	var err := ResourceSaver.save(s, "res://tab_out.zig")
	report("tab_save_written", text.contains("\t") and err == OK, error_string(err))
