extends SceneTree
# Host tests "ready runs", "properties through the object", "call falls
# through", "strong reference" and "wrong owner type". Loads the module built
# from test/fixtures/instance_project, attaches its scripts to nodes in the
# running scene and checks what Godot sees through the owner objects. The
# Zig test checks the log lines (the `_ready` line, the refusal line).
# Scenes are built in code, with scripts made from the module (no file).

const FRAMES := 3

var failed := false
var probe: Object
var mover  # untyped: the script members are not Node2D members
var idle
var frames := 0
var done := false
var bytes_before := 0


func report(name: String, ok: bool, why: String) -> void:
	if ok:
		print("ZTEST PASS %s" % name)
	else:
		failed = true
		print("ZTEST FAIL %s: %s" % [name, why])


func module_path() -> String:
	for line in FileAccess.get_file_as_string("res://modules.txt").split("\n", false):
		if line.begins_with("good="):
			return line.substr(5)
	return ""


# A new ZigScript with resource path `path`.
func zig_script(path: String) -> Script:
	var s: Script = ClassDB.instantiate("ZigScript")
	s.resource_path = path
	return s


func finish() -> void:
	done = true
	print("ZTEST DONE")
	quit()


func _initialize() -> void:
	probe = ClassDB.instantiate("ZigguratTestProbe")
	if probe == null:
		report("probe", false, "ZigguratTestProbe is not registered")
		finish()
		return
	var diag: String = probe.load_module(module_path(), 1)
	report("load", diag == "", diag)
	if diag != "":
		finish()
		return
	bytes_before = probe.live_bytes(1)

	# strong reference: the instance keeps its script alive after every
	# other reference is dropped.
	var s := zig_script("res://mover.zig")
	mover = Node2D.new()
	mover.name = "Mover"
	mover.set_script(s)
	report("attach", mover.get_script() == s, "script %s" % [mover.get_script()])
	s = null
	var kept: Script = mover.get_script()
	report("strong_reference", kept != null and kept.resource_path == "res://mover.zig", "script %s" % [kept])
	kept = null
	report("instance_count", probe.live_instances() == 1, "%d instances" % probe.live_instances())

	# The nodes get READY once the main loop runs; the checks start on the
	# first frame.
	root.add_child(mover)
	idle = Node.new()
	idle.set_script(zig_script("res://idle.zig"))
	root.add_child(idle)


func first_frame() -> void:
	# ready runs: _ready was called through the instance when the tree
	# became ready (the Zig test checks its log line).
	report("ready_runs", mover.get("ready_calls") == 1, "ready_calls %s" % [mover.get("ready_calls")])
	report("notifications_forwarded", mover.get("notifications") > 0, "notifications %s" % [mover.get("notifications")])
	report("attach_idle", idle.get_script() != null and idle.call("ping", 2) == 2, "idle not attached")

	check_properties()
	check_calls()
	check_owner()
	check_refcounted_owner()


func check_properties() -> void:
	var why := ""
	if mover.get("speed") != 5.0:
		why += "speed %s; " % [mover.get("speed")]
	mover.set("speed", 7.5)
	if mover.get("speed") != 7.5:
		why += "speed after set %s; " % [mover.get("speed")]
	mover.speed = 6.0
	if mover.speed != 6.0:
		why += "speed as member %s; " % [mover.speed]
	# A value that does not convert leaves the field alone.
	mover.set("speed", "fast")
	if mover.get("speed") != 6.0:
		why += "speed after bad set %s; " % [mover.get("speed")]
	mover.set("title", "Bob")
	if mover.get("title") != "Bob":
		why += "title %s; " % [mover.get("title")]
	if mover.get("nope") != null:
		why += "unknown property has a value; "
	# Engine properties still work.
	mover.position = Vector2(3, 4)
	if mover.get("position") != Vector2(3, 4):
		why += "position %s; " % [mover.get("position")]
	report("properties_get_set", why == "", why)

	why = ""
	var by_name := {}
	var order: Array[String] = []
	for p in mover.get_property_list():
		by_name[p.name] = p
		order.append(p.name)
	for name in ["speed", "title", "steps", "ready_calls", "notifications", "Motion", "position"]:
		if not by_name.has(name):
			why += "%s missing; " % name
	if why == "":
		if by_name["speed"].type != TYPE_FLOAT or by_name["speed"].usage & PROPERTY_USAGE_STORAGE == 0:
			why += "speed entry %s; " % [by_name["speed"]]
		if by_name["title"].type != TYPE_STRING:
			why += "title entry %s; " % [by_name["title"]]
		if by_name["Motion"].usage & PROPERTY_USAGE_GROUP == 0:
			why += "group entry %s; " % [by_name["Motion"]]
		# The group comes before its members, as in the descriptor.
		if order.find("Motion") > order.find("speed"):
			why += "group after its member; "
	report("property_list_through_object", why == "", why)

	why = ""
	if not mover.property_can_revert(&"speed") or mover.property_get_revert(&"speed") != 5.0:
		why += "speed revert %s %s; " % [mover.property_can_revert(&"speed"), mover.property_get_revert(&"speed")]
	if mover.property_can_revert(&"nope"):
		why += "unknown property can revert; "
	report("property_revert", why == "", why)

	var state: Dictionary = probe.property_state(mover)
	report("property_state", state.get("speed") == 6.0 and state.get("title") == "Bob" and state.has("steps") and not state.has("Motion"), "state %s" % [state])

	report("to_string", str(mover) == "Bob", "str %s" % str(mover))
	mover.set("title", "")


func check_calls() -> void:
	var why := ""
	if mover.get_name() != &"Mover":
		why += "get_name %s; " % mover.get_name()
	if mover.call("scaled", 3) != 18:
		why += "scaled %s; " % [mover.call("scaled", 3)]
	if mover.call(&"get_name") != &"Mover":
		why += "call get_name; "
	if not mover.has_method(&"scaled") or mover.has_method(&"nope"):
		why += "has_method; "
	if mover.get_method_argument_count(&"scaled") != 1:
		why += "argument count %d; " % mover.get_method_argument_count(&"scaled")
	var names := []
	for m in mover.get_method_list():
		names.append(m.name)
	if not names.has("scaled") or not names.has("_ready") or not names.has("get_name"):
		why += "method list; "
	report("call_falls_through", why == "", why)

	# Godot's own error codes: an unknown name is INVALID_METHOD (1), a
	# known one with too few arguments TOO_FEW_ARGUMENTS (4).
	var unknown: int = probe.call_error(mover, &"nope")
	var too_few: int = probe.call_error(mover, &"scaled")
	report("call_errors", unknown == 1 and too_few == 4, "nope %d, scaled() %d" % [unknown, too_few])


func check_owner() -> void:
	# wrong owner type: mover.zig extends Node2D, a plain Node is refused.
	var n := Node.new()
	n.set_script(mover.get_script())
	report("wrong_owner_refused", n.get_script() == null, "node has script %s" % [n.get_script()])
	n.free()
	# A derived class is accepted: Sprite2D is a Node2D.
	var count_before: int = probe.live_instances()
	var sprite := Sprite2D.new()
	sprite.set_script(mover.get_script())
	report("derived_owner_accepted", sprite.get_script() != null and sprite.get("speed") == 5.0, "sprite script %s" % [sprite.get_script()])
	sprite.free()
	report("instance_freed", probe.live_instances() == count_before, "%d instances, %d before" % [probe.live_instances(), count_before])


# A RefCounted owner dies with its last reference: refcount_decremented
# lets it, the instance is freed and the script's deinit runs once (the Zig
# test counts its log line).
func check_refcounted_owner() -> void:
	var before: int = probe.live_instances()
	var rc := RefCounted.new()
	rc.set_script(zig_script("res://keeper.zig"))
	report("refcounted_owner_attached", rc.get_script() != null and probe.live_instances() == before + 1 and rc.get("uses") == 7,
		"script %s, %d instances (before %d)" % [rc.get_script(), probe.live_instances(), before])
	rc = null
	report("refcounted_owner_released", probe.live_instances() == before, "%d instances (before %d)" % [probe.live_instances(), before])


func _process(_delta: float) -> bool:
	if done:
		return true
	frames += 1
	if frames == 1:
		first_frame()
	if frames < FRAMES:
		return false
	# _process runs only for the script that defines it.
	report("process_only_when_defined", mover.is_processing() and not idle.is_processing() and mover.get("steps") > 0,
		"mover %s (steps %s), idle %s" % [mover.is_processing(), mover.get("steps"), idle.is_processing()])
	mover.free()
	idle.free()
	report("instances_released", probe.live_instances() == 0 and probe.live_bytes(1) == bytes_before,
		"%d instances, %d bytes (before %d)" % [probe.live_instances(), probe.live_bytes(1), bytes_before])
	finish()
	return true
