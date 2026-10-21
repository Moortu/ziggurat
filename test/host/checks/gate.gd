extends SceneTree
# Host tests "depth counts nested entries", "try-lock fails while a reader
# holds", "threads during swap" and "migrating instance refuses calls".
# Loads the module built from test/fixtures/gate_project and drives the gate
# through ZigguratTestProbe. The Zig test checks the refusal log lines.

const SWAPS := 50
const WORKERS := 3
# Calls each worker must have made while the swaps ran.
const MIN_CALLS := 200

var failed := false
var probe: Object
var counter_script: Script
var holder_script: Script

# depth: written by a signal handler.
var depth_seen := -1
var nested_b: Object

# try-lock: shared between the main thread and one worker.
var inside := false
var release := false

# threads during swap.
var stop := false


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


func zig_script(path: String) -> Script:
	var s: Script = ClassDB.instantiate("ZigScript")
	s.resource_path = path
	return s


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
	counter_script = zig_script("res://counter.zig")
	holder_script = zig_script("res://holder.zig")
	var bytes_before: int = probe.live_bytes(1)
	var instances_before: int = probe.live_instances()

	check_depth()
	check_try_lock()
	check_threads()
	check_migrating()

	report("registry_matches_live", probe.registry_count() == probe.live_instances(),
		"registry %d, live %d" % [probe.registry_count(), probe.live_instances()])
	report("instances_released", probe.live_instances() == instances_before,
		"%d instances, %d before" % [probe.live_instances(), instances_before])
	report("bytes_released", probe.live_bytes(1) == bytes_before,
		"%d bytes, %d before" % [probe.live_bytes(1), bytes_before])
	finish()


# A script method that calls back into another script instance: inside the
# second one the main thread is two entries deep.
func check_depth() -> void:
	var a := make_counter()
	nested_b = make_counter()
	a.connect("ping", _a_pinged)
	nested_b.connect("ping", _b_pinged)
	var outside: int = probe.gate_depth()
	var r: int = a.call("fire")
	report("depth_counts_nested_entries", outside == 0 and depth_seen == 2 and r == 41 and probe.gate_depth() == 0,
		"outside %d, inside %d, after %d, result %d" % [outside, depth_seen, probe.gate_depth(), r])
	nested_b = null


func _a_pinged() -> void:
	nested_b.call("fire")


func _b_pinged() -> void:
	depth_seen = probe.gate_depth()


# A worker thread sits inside a slow script method (its signal handler
# waits): the swap's try-lock fails until the method returns.
func check_try_lock() -> void:
	var c := make_counter()
	c.connect("ping", _hold)
	var t := Thread.new()
	t.start(func() -> int: return c.call("fire"))
	var waited := 0
	while not inside and waited < 10000:
		OS.delay_msec(1)
		waited += 1
	var during: bool = probe.gate_try_swap()
	var depth_main: int = probe.gate_depth()
	release = true
	var r: int = t.wait_to_finish()
	var after: bool = probe.gate_try_swap()
	report("try_lock_fails_while_reader_holds", inside and not during and after and r == 41 and depth_main == 0,
		"inside %s, during %s, after %s, result %d, main depth %d" % [inside, during, after, r, depth_main])


func _hold() -> void:
	inside = true
	while not release:
		OS.delay_msec(1)


# Three threads call methods in a loop while the main thread performs test
# swaps that keep each data block (even) or move it (odd).
func check_threads() -> void:
	var objs: Array[RefCounted] = []
	var threads: Array[Thread] = []
	for i in WORKERS:
		objs.append(make_counter())
	for i in WORKERS:
		var t := Thread.new()
		t.start(_worker.bind(i, objs[i]))
		threads.append(t)
	# Let every worker get going, then swap while they run, a few
	# milliseconds apart so that each swap lands among many calls.
	OS.delay_msec(50)
	var swaps := 0
	var attempts := 0
	for k in SWAPS:
		while attempts < 200000:
			attempts += 1
			if probe.gate_test_swap(k % 2):
				swaps += 1
				break
			OS.delay_usec(20)
		OS.delay_msec(2)
	stop = true
	var results := []
	for t in threads:
		results.append(t.wait_to_finish())
	var ok := swaps == SWAPS
	for i in WORKERS:
		var calls: int = results[i][0]
		ok = ok and results[i][1] == 0 and calls >= MIN_CALLS
		# The count survived every move of the data block.
		ok = ok and objs[i].call("bump") == calls + 1
	print("ZTEST INFO threads_during_swap: swaps %d, attempts %d, [calls, errors] per thread %s" % [swaps, attempts, results])
	report("threads_during_swap", ok, "swaps %d (attempts %d), [calls, errors] per thread %s" % [swaps, attempts, results])


# Returns [calls, errors].
func _worker(i: int, obj: RefCounted) -> Array:
	var n := 0
	var errors := 0
	while not stop:
		n += 1
		if obj.call("bump") != n:
			errors += 1
		if obj.call("answer") != 42:
			errors += 1
		# Make and drop one instance on this thread (registry add and
		# remove from any thread).
		if (n + i) % 16 == 0:
			var tmp := make_counter()
			if tmp.call("answer") != 42:
				errors += 1
	return [n, errors]


# Calls into the instance being migrated are refused with one log line;
# the instance works again once the migration ends. An instance freed
# while it is migrated is released once the migration ends.
func check_migrating() -> void:
	var m := make_counter()
	var r: Array = probe.gate_migrate_probe(m, &"answer", false)
	var answer: int = m.call("answer")
	var value: int = m.get("value")
	report("migrating_instance_refuses_calls",
		# 5: INSTANCE_IS_NULL from the instance; 1: INVALID_METHOD through
		# Object::callp, which then tries the engine class.
		r.size() == 3 and r[0] == 5 and r[1] == 1 and r[2] == true and answer == 42 and value == 41,
		"probe %s, answer %d, value %d" % [r, answer, value])

	var h := Node.new()
	h.set_script(holder_script)
	var before: int = probe.live_instances()
	var r2: Array = probe.gate_migrate_probe(h, &"answer", true)
	report("migrating_instance_freed_after_migration",
		r2.size() == 3 and r2[0] == 5 and probe.live_instances() == before - 1,
		"probe %s, live %d, before %d" % [r2, probe.live_instances(), before])
