extends SceneTree
# Host test "language": the ZigLanguage virtuals GDScript cannot call,
# through ZigguratTestProbe. The global class scan on the project's .zig
# files, `_validate` from cached diagnostics, the completion and lookup
# dictionaries, and the main-thread queue that `_frame` drains (checked
# over several frames). Prints one ZTEST line per case, then ZTEST DONE.

var probe: Object
var frames := 0
var runs_seen: Array[int] = []


func report(name: String, ok: bool, why: String) -> void:
	if ok:
		print("ZTEST PASS %s" % name)
	else:
		print("ZTEST FAIL %s: %s" % [name, why])


func _initialize() -> void:
	probe = ClassDB.instantiate("ZigguratTestProbe")
	check_global_classes()
	check_validate()
	check_completion()
	# 100 callbacks: _frame runs at most 64 a frame, so two frames at least.
	report("queue_pushed", probe.queue_push(100) == 100 and probe.queue_runs() == 0, "runs %d" % probe.queue_runs())


func _process(_delta: float) -> bool:
	frames += 1
	runs_seen.append(probe.queue_runs())
	if frames < 6:
		return false
	var steps_ok := true
	var last := 0
	for r in runs_seen:
		if r - last > 64:
			steps_ok = false
		last = r
	report("frame_drains_queue_bounded", last == 100 and steps_ok and runs_seen[0] < 100, "runs per frame: %s" % [runs_seen])
	print("ZTEST DONE")
	return true


func check_global_classes() -> void:
	var a: Dictionary = probe.language_global_class("res://alpha.zig")
	report("global_class_top_level", a.get("name") == "Alpha" and a.get("base_type") == "Node2D" and a.get("is_tool") == true and a.get("icon_path") == "" and a.get("is_abstract") == false, str(a))
	var b: Dictionary = probe.language_global_class("res://sub/beta.zig")
	report("global_class_subfolder", b.get("name") == "Beta" and b.get("base_type") == "Resource" and b.get("is_tool") == false, str(b))
	for path in ["res://plain.zig", "res://commented.zig", "res://nested.zig", "res://missing.zig", "user://alpha.zig", "res://../alpha.zig"]:
		var d: Dictionary = probe.language_global_class(path)
		report("global_class_none %s" % path, d.is_empty(), str(d))


func check_validate() -> void:
	var v0: Dictionary = probe.language_validate("res://bad.zig")
	report("validate_unknown_file_valid", v0.get("valid") == true, str(v0))
	probe.set_diagnostics("bad.zig", 3, 5, "expected ';', found '}'")
	var v1: Dictionary = probe.language_validate("res://bad.zig")
	var errors: Array = v1.get("errors", [])
	var e: Dictionary = errors[0] if errors.size() == 1 else {}
	report("validate_cached_error", v1.get("valid") == false and e.get("line") == 3 and e.get("column") == 5 and e.get("message") == "expected ';', found '}'" and e.get("path") == "res://bad.zig", str(v1))
	var other: Dictionary = probe.language_validate("res://good.zig")
	report("validate_other_file_unaffected", other.get("valid") == true, str(other))
	# A good build records an empty list for the file.
	probe.set_diagnostics("bad.zig", -1, 0, "")
	var v2: Dictionary = probe.language_validate("res://bad.zig")
	report("validate_after_good_build", v2.get("valid") == true and v2.get("errors", []).is_empty(), str(v2))
	# A scan problem has line 0; Godot gets line and column 1.
	probe.set_diagnostics("bad.zig", 0, 0, "scan problem")
	var v3: Dictionary = probe.language_validate("res://bad.zig")
	var e3: Dictionary = v3.get("errors", [{}])[0]
	report("validate_line_zero_clamped", v3.get("valid") == false and e3.get("line") == 1 and e3.get("column") == 1, str(v3))


func check_completion() -> void:
	var c: Dictionary = probe.language_complete_code()
	report("complete_code_empty_ok", c.get("result") == OK and c.get("options") == [] and c.get("force") == false and c.get("call_hint") == "", str(c))
	var l: Dictionary = probe.language_lookup_code()
	report("lookup_code_unavailable", l.get("result") == ERR_UNAVAILABLE and l.has("type"), str(l))
