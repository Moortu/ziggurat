extends SceneTree
# Host test "shutdown race closed" (Stage 3 parked race). A worker thread
# is inside a script method (its signal handler sleeps, then calls into
# another instance by name) when the main thread runs the runtime's
# shutdown, which frees the name maps. Shutdown must wait until the worker
# left the gate and must not deadlock the worker's nested entry. The worker
# then drops the last reference to its own instance, which is freed on that
# thread after the name maps are gone.

const HOLD_MS := 300

var failed := false
var probe: Object
var counter_script: Script
var holder: RefCounted
var inside := false
var nested := -1


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


func make_counter() -> RefCounted:
	var o := RefCounted.new()
	o.set_script(counter_script)
	return o


func finish() -> void:
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
	counter_script = ClassDB.instantiate("ZigScript")
	counter_script.resource_path = "res://counter.zig"
	holder = make_counter()
	var live_before: int = probe.live_instances()

	var t := Thread.new()
	t.start(_work)
	var waited := 0
	while not inside and waited < 10000:
		OS.delay_msec(1)
		waited += 1
	var t0 := Time.get_ticks_msec()
	probe.runtime_shutdown()
	var elapsed := Time.get_ticks_msec() - t0
	var r: Array = t.wait_to_finish()
	print("ZTEST INFO shutdown waited %d ms for the worker" % elapsed)
	report("shutdown_race_closed",
		inside and elapsed >= HOLD_MS - 50 and r == [41, 42] and probe.live_instances() == live_before,
		"inside %s, shutdown took %d ms, worker %s, live %d (before %d)" % [inside, elapsed, r, probe.live_instances(), live_before])
	# A leaked instance still answers by name after shutdown.
	report("call_after_shutdown", holder.call("answer") == 42, "answer %s" % holder.call("answer"))
	holder = null
	finish()


# Returns [fire result, nested answer]; `leak` is freed here, on this thread.
func _work() -> Array:
	var leak := make_counter()
	leak.connect("ping", _slow)
	var r: int = leak.call("fire")
	leak = null
	return [r, nested]


func _slow() -> void:
	inside = true
	OS.delay_msec(HOLD_MS)
	# A nested entry while shutdown waits for the gate.
	nested = holder.call("answer")
