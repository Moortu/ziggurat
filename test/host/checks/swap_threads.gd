extends SceneTree
# Host test "threads across two generations": three threads call methods on
# ticker.zig instances (and make and drop instances) while 20 real swaps
# alternate between generation 1 (test/fixtures/swap_v1) and generation 2
# (swap_v2), whose layouts differ. The swaps run at the language's `_frame`
# whenever no thread is inside the gate.

const SWAPS := 20
const WORKERS := 3
# Calls each worker must have made while the swaps ran.
const MIN_CALLS := 200
const SWAPPED := 3

var failed := false
var probe: Object
var ticker_s: Script
var stop := false
# True while the main thread performs the swaps.
var in_window := false


func report(name: String, ok: bool, why: String) -> void:
	if ok:
		print("ZTEST PASS %s" % name)
	else:
		failed = true
		print("ZTEST FAIL %s: %s" % [name, why])


func module_path(key: String) -> String:
	for line in FileAccess.get_file_as_string("res://modules.txt").split("\n", false):
		if line.begins_with(key + "="):
			return line.substr(key.length() + 1)
	return ""


func make_ticker() -> RefCounted:
	var o := RefCounted.new()
	o.set_script(ticker_s)
	return o


func finish() -> void:
	print("ZTEST DONE")
	quit()


func _initialize() -> void:
	probe = ClassDB.instantiate("ZigguratTestProbe")
	var diag: String = probe.load_module(module_path("v1"), 1)
	var staged: String = probe.stage_module(module_path("v2"), 2)
	report("load", diag == "" and staged == "", diag + staged)
	if diag != "" or staged != "":
		finish()
		return
	ticker_s = ClassDB.instantiate("ZigScript")
	ticker_s.resource_path = "res://ticker.zig"
	run()


func run() -> void:
	var bytes1: int = probe.live_bytes(1)
	var bytes2: int = probe.live_bytes(2)
	await swap_during_calls()
	# The objects, the threads and their bound callables were locals of
	# swap_during_calls; the resumed function's state lets go of the last
	# of them a frame later.
	await process_frame
	report("bytes_released", probe.live_instances() == 0 and probe.live_bytes(1) == bytes1 and probe.live_bytes(2) == bytes2,
		"%d instances, %d/%d bytes in generations 1/2 (before %d/%d)" % [probe.live_instances(),
			probe.live_bytes(1), probe.live_bytes(2), bytes1, bytes2])
	finish()


func swap_during_calls() -> void:
	var objs: Array[RefCounted] = []
	var threads: Array[Thread] = []
	for i in WORKERS:
		objs.append(make_ticker())
	# No local holds a thread or an object beyond the two arrays, which are
	# cleared at the end so the instances are freed before the check.
	for i in WORKERS:
		threads.append(Thread.new())
		threads[i].start(_worker.bind(i, objs[i]))
	# Three more call `_debug_get_current_stack_info` the whole time.
	var stack_threads: Array[Thread] = []
	for i in WORKERS:
		stack_threads.append(Thread.new())
		stack_threads[i].start(_stack_worker)
	OS.delay_msec(50)
	in_window = true
	var swaps := 0
	var frames := 0
	for k in SWAPS:
		var want := 2 if k % 2 == 0 else 1
		var before: int = probe.swaps_done()
		probe.swap_request(want)
		while probe.swaps_done() == before and frames < 100000:
			await process_frame
			frames += 1
		if probe.swaps_done() == before + 1 and probe.current_generation() == want:
			swaps += 1
	in_window = false
	stop = true
	var results := []
	for i in WORKERS:
		results.append(threads[i].wait_to_finish())
	var stack_calls := 0
	var stack_bad := 0
	for t in stack_threads:
		var r: Array = t.wait_to_finish()
		stack_calls += r[0]
		stack_bad += r[1]
	stack_threads.clear()
	report("stack_info_from_threads", swaps == SWAPS and stack_calls >= 1000 and stack_bad == 0,
		"swaps %d, calls %d, bad %d" % [swaps, stack_calls, stack_bad])
	var ok := swaps == SWAPS
	for i in WORKERS:
		var calls: int = results[i][0]
		ok = ok and results[i][1] == 0 and results[i][2] >= MIN_CALLS
		# The count survived every move between the layouts.
		ok = ok and objs[i].call("bump") == calls + 1
		# The last swap went to generation 1.
		ok = ok and probe.instance_generation(objs[i]) == 1 and objs[i].call("version") == 1
	print("ZTEST INFO threads_across_two_generations: swaps %d, frames %d, [calls, errors, calls during swaps] per thread %s" % [swaps, frames, results])
	report("threads_across_two_generations", ok,
		"swaps %d (frames %d), [calls, errors, calls during swaps] per thread %s" % [swaps, frames, results])
	report("registry_matches_live", probe.registry_count() == probe.live_instances(),
		"registry %d, live %d" % [probe.registry_count(), probe.live_instances()])
	threads.clear()
	objs.clear()


# Returns [calls, calls that returned a non-empty stack]. The stack info is
# empty: Ziggurat has no frames to report.
func _stack_worker() -> Array:
	var n := 0
	var bad := 0
	while not stop:
		n += 1
		if probe.language_stack_info() != 0:
			bad += 1
	return [n, bad]


# Returns [calls, errors, calls made while the swaps ran].
func _worker(i: int, obj: RefCounted) -> Array:
	var n := 0
	var errors := 0
	var during := 0
	while not stop:
		n += 1
		var before := in_window
		if obj.call("bump") != n:
			errors += 1
		var v: int = obj.call("version")
		if v != 1 and v != 2:
			errors += 1
		if before and in_window:
			during += 1
		# Make and drop one instance on this thread: it lands on whichever
		# generation is current and is migrated or freed with the others.
		if (n + i) % 16 == 0:
			# The instance is on the current generation: made on it, or
			# migrated with the others. A swap between the reads can make
			# them disagree, so a few tries; an instance left behind on an
			# old generation disagrees every time the other one is current.
			var tmp := make_ticker()
			var on_current := false
			for attempt in 3:
				var cur_before: int = probe.current_generation()
				var gen: int = probe.instance_generation(tmp)
				if gen == cur_before and gen == probe.current_generation():
					on_current = true
					break
			if not on_current:
				errors += 1
			if tmp.call("bump") != 1:
				errors += 1
	return [n, errors, during]
