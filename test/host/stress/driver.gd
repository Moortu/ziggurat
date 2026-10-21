@tool
extends Node
# Host test "reload stress": runs as a tool autoload in the headless editor
# of test/host/stress/project. res://stress.cfg sets the number of edits,
# how often a build is broken on purpose and how often the nested-iteration
# case runs (20 edits in `zig build test`, 300 in `zig build test-stress`).
#
# Each edit rewrites one script and saves it through ResourceSaver (the
# `.zig` saver), which starts an editor build. The sequence is fixed (no
# randomness): mover.zig body edits, an added or removed field, a field
# renamed between `score` and `points` (its `migrate` hook copies it), and
# `level` changing type; edits to the other four scripts in turn (holder.zig
# also gains or loses a field); every `broken_every`-th edit is a build that
# does not compile (a syntax error in the file the next edit rewrites). The
# driver waits for each outcome with a bounded deadline.
#
# Meanwhile three GDScript threads call methods on their own instances
# (`bump`, `fire`, `version`) and check the answers. Every edit that builds
# calls the tool script previewer.zig, whose signal handler runs
# `EditorInterface.make_mesh_previews` (two nested `Main::iteration()`
# calls while module code is on the stack; the handler is GDScript because
# a script cannot build the Array of meshes with the SDK's v1 types). In a
# headless run each preview leaks one render instance in Godot itself;
# the host test allows exactly that report. Every `nested_every`-th edit
# makes that happen while the edit's swap waits: a thread holds the gate
# inside beacon.zig's `fire` until the build is loaded and its swap is
# deferred, then lets go, and the nested frames must defer the swap again
# (`deferred_depth`); it completes on a later frame.
#
# After every swap: moved field values, migrate results, the type-changed
# field's new default, every property default of the new build, owned
# values, every script's new code with no
# INVALID_METHOD, live bytes 0 in every older generation, one loaded
# generation per good build, the registry. At the end: threads' results,
# every instance freed, no bytes left; the runner's scans check ObjectDB,
# orphan StringNames, RIDs and resources.

const DEFERRED_DEPTH := 1
const DEFERRED_LOCK := 2
const WORKERS := 3
# Bounded wait for one edit's outcome.
const EDIT_WAIT_MS := 120000
# The first build at editor start (a cold build of the SDK).
const OPEN_WAIT_MS := 600000
const FILES := ["mover", "holder", "beacon", "previewer", "plain"]

var probe: Object
var edits := 20
var broken_every := 25
var nested_every := 10
# Seconds until the driver gives up and quits with a failure, so a stuck
# run still prints its output (the runner's deadline would lose it).
var watchdog_s := 600

var scripts := {}
var headers := {}
# The sources' state; see the *_src functions.
var st := {
	"mover": 0, "name": "score", "wide": false, "level_default": 0, "extra": false, "extra_default": 0,
	"holder": 0, "pad": false, "beacon": 0, "previewer": 0, "plain": 0,
}

var m0: RefCounted
var holder: RefCounted
var hold_beacon: RefCounted
var previewer: Node
var plain: Node
var res: Resource
var movers: Array[RefCounted] = []
var beacons: Array[RefCounted] = []
var preview_mesh: Mesh

var stop := false
var hold_inside := false
var hold_release := false
# [swap outcome, nested frames, generation unchanged, gate depth], set by
# the previews handler.
var nested_info := []

var good_builds := 1
var migrations := 0
var gens: Array[int] = []
var checks := {}
var failures := {}
var nested_cases := 0
var nested_frames := 0
var broken_builds := 0
var edit_ms: Array[int] = []


func check(name: String, ok: bool, why: String) -> void:
	checks[name] = checks.get(name, 0) + 1
	if not ok and not failures.has(name):
		failures[name] = why


func report(name: String, ok: bool, why: String) -> void:
	if ok:
		print("ZTEST PASS %s" % name)
	else:
		print("ZTEST FAIL %s: %s" % [name, why])


func report_checks(name: String) -> void:
	report(name, checks.get(name, 0) > 0 and not failures.has(name),
		"%d checks; first failure: %s" % [checks.get(name, 0), failures.get(name, "none")])


func wait_for(cond: Callable, ms: int) -> bool:
	var end := Time.get_ticks_msec() + ms
	while Time.get_ticks_msec() < end:
		if cond.call():
			return true
		await get_tree().process_frame
	return cond.call()


# ---------------------------------------------------------------- sources

func header(file: String) -> String:
	return headers[file]


func version_fn(k: int) -> String:
	return "pub fn version(self: *const @This()) i64 {\n    _ = self;\n    return %d;\n}\n" % k


func mover_src(s: Dictionary) -> String:
	var other := "points" if s.name == "score" else "score"
	var t := header("mover") + "const z = @import(\"ziggurat\");\nconst g = z.godot;\n\n"
	t += "pub const extends = g.RefCounted;\npub const tool = true;\n\n"
	t += "base: *g.RefCounted,\nbumps: i64 = 0,\n"
	t += "%s: i64 = 0,\n" % s.name
	t += "level: %s = %d,\n" % ["i64" if s.wide else "i32", s.level_default]
	if s.extra:
		t += "extra: i32 = %d,\n" % s.extra_default
	t += "note: z.String = .empty,\nmigrations: i64 = 0,\n\n"
	t += "pub fn bump(self: *@This()) i64 {\n    self.bumps += 1;\n    return self.bumps;\n}\n\n"
	t += version_fn(s.mover) + "\n"
	t += "pub fn migrate(self: *@This(), old: z.Previous(@This())) void {\n    self.migrations += 1;\n"
	t += "    if (old.get(i64, \"%s\")) |v| self.%s = v;\n}\n" % [other, s.name]
	return t


func holder_src(s: Dictionary) -> String:
	var t := header("holder") + "const z = @import(\"ziggurat\");\nconst g = z.godot;\n\n"
	t += "pub const extends = g.RefCounted;\npub const tool = true;\n\n"
	t += "base: *g.RefCounted,\n"
	if s.pad:
		t += "pad: i32 = 5,\n"
	t += "label: z.String = .empty,\ntag: z.StringName = .empty,\nres: z.Ref(g.Resource) = .{},\n\n"
	return t + version_fn(s.holder)


func beacon_src(s: Dictionary) -> String:
	var t := header("beacon") + "const z = @import(\"ziggurat\");\nconst g = z.godot;\n\n"
	t += "pub const extends = g.RefCounted;\npub const tool = true;\n\n"
	t += "pub const signals = struct {\n    pub const pulse = struct {};\n};\n\n"
	t += "base: *g.RefCounted,\nfired: i64 = 0,\n\n"
	t += "/// Counts calls on this instance, then emits `pulse`.\n"
	t += "pub fn fire(self: *@This()) i64 {\n    self.fired += 1;\n    z.emit(self, .pulse, .{});\n    return self.fired;\n}\n\n"
	return t + version_fn(s.beacon)


func previewer_src(s: Dictionary) -> String:
	var t := header("previewer") + "const z = @import(\"ziggurat\");\nconst g = z.godot;\n\n"
	t += "pub const extends = g.Node;\npub const tool = true;\n\n"
	t += "pub const signals = struct {\n    pub const wants_previews = struct {};\n};\n\n"
	t += "base: *g.Node,\npreviews: i64 = 0,\n\n"
	t += "pub fn preview(self: *@This()) i64 {\n    self.previews += 1;\n    z.emit(self, .wants_previews, .{});\n    return self.previews;\n}\n\n"
	return t + version_fn(s.previewer)


func plain_src(s: Dictionary) -> String:
	var t := header("plain") + "const z = @import(\"ziggurat\");\nconst g = z.godot;\n\n"
	t += "pub const extends = g.Node;\n\n"
	t += "base: *g.Node,\nmark: i32 = %d,\n\n" % s.plain
	return t + version_fn(s.plain)


func source(file: String, s: Dictionary) -> String:
	match file:
		"mover":
			return mover_src(s)
		"holder":
			return holder_src(s)
		"beacon":
			return beacon_src(s)
		"previewer":
			return previewer_src(s)
		_:
			return plain_src(s)


# The leading `//!` lines of a file as the project has it.
func read_header(file: String) -> String:
	var t := ""
	for line in FileAccess.get_file_as_string("res://%s.zig" % file).split("\n"):
		if not line.begins_with("//!"):
			break
		t += line + "\n"
	return t


# ---------------------------------------------------------------- run

func _ready() -> void:
	if not Engine.is_editor_hint():
		return
	probe = ClassDB.instantiate("ZigguratTestProbe")
	for line in FileAccess.get_file_as_string("res://stress.cfg").split("\n", false):
		var kv := line.split("=")
		match kv[0]:
			"edits":
				edits = int(kv[1])
			"broken_every":
				broken_every = int(kv[1])
			"nested_every":
				nested_every = int(kv[1])
			"watchdog_s":
				watchdog_s = int(kv[1])
	get_tree().create_timer(watchdog_s).timeout.connect(_watchdog)
	await run()
	print("ZTEST DONE")
	get_tree().quit()


func make(file: String) -> RefCounted:
	var o := RefCounted.new()
	o.set_script(scripts[file])
	return o


func run() -> void:
	var t0 := Time.get_ticks_msec()
	var built: bool = await wait_for(func(): return probe.current_generation() >= 1, OPEN_WAIT_MS)
	for f in FILES:
		scripts[f] = load("res://%s.zig" % f)
		headers[f] = read_header(f)
	# The generated sources at the start state are the files as committed.
	var same := true
	for f in FILES:
		same = same and source(f, st) == FileAccess.get_file_as_string("res://%s.zig" % f)
	m0 = make("mover")
	holder = make("holder")
	hold_beacon = make("beacon")
	hold_beacon.connect("pulse", _hold)
	for i in WORKERS:
		movers.append(make("mover"))
		beacons.append(make("beacon"))
	previewer = Node.new()
	previewer.set_script(scripts["previewer"])
	add_child(previewer)
	previewer.connect("wants_previews", _make_previews)
	plain = Node.new()
	plain.set_script(scripts["plain"])
	add_child(plain)
	res = Resource.new()
	holder.set("label", "stress label")
	holder.set("tag", &"stress_tag")
	holder.set("res", res)
	var box := BoxMesh.new()
	preview_mesh = box
	gens.append(probe.current_generation())
	report("stress_start", built and same and probe.current_generation() >= 1 and m0.call("version") == 0
		and probe.script_placeholder_count(scripts["plain"]) == 1 and holder.get("label") == "stress label",
		"built %s, sources match %s, gen %d, placeholders %d" % [built, same, probe.current_generation(),
			probe.script_placeholder_count(scripts["plain"])])
	print("ZTEST INFO stress: first build after %d ms" % (Time.get_ticks_msec() - t0))

	var threads: Array[Thread] = []
	for i in WORKERS:
		threads.append(Thread.new())
		threads[i].start(_worker.bind(i))
	var t1 := Time.get_ticks_msec()
	var done := 0
	for i in range(1, edits + 1):
		var ok: bool = await one_edit(i)
		if not ok:
			break
		done = i
	var run_ms := Time.get_ticks_msec() - t1
	stop = true
	var results := []
	for t in threads:
		results.append(t.wait_to_finish())
	threads.clear()

	edit_ms.sort()
	var median := edit_ms[edit_ms.size() / 2] if edit_ms.size() > 0 else -1
	var worst := edit_ms[edit_ms.size() - 1] if edit_ms.size() > 0 else -1
	print("ZTEST INFO stress: %d edits in %d ms (median %d ms, worst %d ms per edit), %d good builds, %d broken, %d nested cases, %d nested frames, threads [calls, errors] %s"
		% [done, run_ms, median, worst, good_builds, broken_builds, nested_cases, nested_frames, results])
	report("stress_edits_applied", done == edits, "%d of %d edits; first failure: %s" % [done, edits, failures])
	for name in ["saves", "moved_fields", "migrate_results", "type_change_default", "added_field_default", "owned_fields_kept",
			"new_code_no_invalid_method", "defaults_match_source", "placeholder_default", "old_generations_released", "generation_count",
			"registry_matches_live", "broken_build_keeps_last_good"]:
		report_checks(name)
	report("nested_iteration_runs_frame", nested_frames > 0 and not failures.has("nested_iteration_runs_frame"),
		"nested frames %d; %s" % [nested_frames, failures.get("nested_iteration_runs_frame", "")])
	report_checks("nested_iteration_defers_the_swap")
	var calls_ok := true
	for r in results:
		calls_ok = calls_ok and r[1] == 0 and r[0] >= done
	report("threads_no_errors", calls_ok, "[calls, errors, first error] %s" % [results])

	# Every instance freed: no bytes left in any generation.
	previewer.free()
	plain.free()
	m0 = null
	holder = null
	hold_beacon = null
	movers.clear()
	beacons.clear()
	res = null
	preview_mesh = null
	await get_tree().process_frame
	await get_tree().process_frame
	var left := 0
	for g in gens:
		left += probe.live_bytes(g)
	report("instances_released", probe.live_instances() == 0 and left == 0 and probe.registry_count() == 0,
		"%d instances, %d bytes, registry %d" % [probe.live_instances(), left, probe.registry_count()])


# One edit: returns false when its outcome did not arrive in time (the run
# stops there; the failure is reported).
func one_edit(i: int) -> bool:
	var start := Time.get_ticks_msec()
	var broken := broken_every > 0 and i % broken_every == 0
	var nested := not broken and nested_every > 0 and i % nested_every == 0
	var next := st.duplicate()
	var file := file_for(i)
	var mover_layout := false
	var type_changed := false
	match i % 6:
		2:
			next.extra = not st.extra
			next.extra_default = i
			mover_layout = true
		0, 3:
			if file == "holder":
				next.pad = not st.pad
		4:
			next.name = "points" if st.name == "score" else "score"
			mover_layout = true
		5:
			next.wide = not st.wide
			next.level_default = i
			mover_layout = true
			type_changed = true
	next[file] = i
	# Values the swap must keep (or, for `level` on a type change, reset).
	m0.set(st.name, 1000 + i)
	m0.set("level", 500 + i)
	m0.set("note", "note %d" % i)

	var outcomes: int = probe.editor_build_outcomes()
	var loaded: int = probe.loaded_generations()
	var gen: int = probe.current_generation()
	var hold_thread: Thread = null
	if nested:
		hold_inside = false
		hold_release = false
		hold_thread = Thread.new()
		hold_thread.start(func() -> int: return hold_beacon.call("fire"))
		var waited := 0
		while not hold_inside and waited < 10000:
			OS.delay_msec(1)
			waited += 1
	if broken:
		# The next edit rewrites this file, which repairs the build.
		file = file_for(i + 1)
	var s: Script = scripts[file]
	var text := source(file, next)
	if broken:
		text = source(file, st) + "\npub fn broken( {\n"
	s.source_code = text
	var err := ResourceSaver.save(s, "res://%s.zig" % file)
	check("saves", err == OK, "edit %d: save %d" % [i, err])

	if broken:
		var done: bool = await wait_for(func(): return probe.editor_build_outcomes() > outcomes, EDIT_WAIT_MS)
		for k in 3:
			await get_tree().process_frame
		broken_builds += 1
		check("broken_build_keeps_last_good", done and probe.current_generation() == gen and probe.loaded_generations() == loaded
			and m0.call("version") == st.mover and m0.get(st.name) == 1000 + i,
			"edit %d: done %s gen %d (was %d) loaded %d (was %d)" % [i, done, probe.current_generation(), gen, probe.loaded_generations(), loaded])
		edit_ms.append(Time.get_ticks_msec() - start)
		# The file goes back to the last good text with the next edit.
		return done

	if nested:
		# The build loads, and its swap waits for the thread inside `fire`.
		var waiting: bool = await wait_for(func(): return probe.loaded_generations() > loaded and probe.swap_outcome() == DEFERRED_LOCK,
			EDIT_WAIT_MS)
		hold_release = true
		hold_thread.wait_to_finish()
		# No thread holds the swap back now except module code on this
		# thread's stack: previewer.preview -> handler -> nested iterations.
		nested_info = []
		previewer.call("preview")
		var after_gen: int = probe.current_generation()
		var swapped: bool = await wait_for(func(): return probe.current_generation() > gen, EDIT_WAIT_MS)
		nested_cases += 1
		check("nested_iteration_defers_the_swap", waiting and nested_info.size() == 4 and nested_info[0] == DEFERRED_DEPTH
			and nested_info[1] >= 2 and nested_info[2] and nested_info[3] > 0 and after_gen == gen and swapped,
			"edit %d: waiting %s, [outcome, nested frames, gen unchanged, depth] %s, gen after preview %d (was %d), swapped later %s"
			% [i, waiting, nested_info, after_gen, gen, swapped])
	else:
		# Nested iterations while the build runs and the threads call.
		previewer.call("preview")

	var ok: bool = await wait_for(func(): return probe.current_generation() > gen and new_code(file, i), EDIT_WAIT_MS)
	edit_ms.append(Time.get_ticks_msec() - start)
	if not ok:
		check("moved_fields", false, "edit %d (%s): no swap within %d ms: gen %d (was %d), outcomes %d (was %d), swap outcome %d"
			% [i, file, EDIT_WAIT_MS, probe.current_generation(), gen, probe.editor_build_outcomes(), outcomes, probe.swap_outcome()])
		return false
	st = next
	good_builds += 1
	if mover_layout:
		migrations += 1
	after_swap(i, type_changed)
	return true


# The file edit `i` changes: mover.zig, except every third edit, which
# changes one of the other four in turn.
func file_for(i: int) -> String:
	if i % 3 == 0:
		return ["previewer", "beacon", "holder", "plain"][(i / 3) % 4]
	return "mover"


func new_code(file: String, k: int) -> bool:
	match file:
		"mover":
			return m0.call("version") == k
		"holder":
			return holder.call("version") == k
		"beacon":
			return hold_beacon.call("version") == k
		"previewer":
			return previewer.call("version") == k
		_:
			return plain.get("mark") == k


func after_swap(i: int, type_changed: bool) -> void:
	var gen: int = probe.current_generation()
	if not gens.has(gen):
		gens.append(gen)
	var other := "points" if st.name == "score" else "score"
	check("moved_fields", m0.get(st.name) == 1000 + i and m0.get(other) == null and m0.get("bumps") == 0,
		"edit %d: %s=%s %s=%s" % [i, st.name, m0.get(st.name), other, m0.get(other)])
	check("migrate_results", m0.get("migrations") == migrations, "edit %d: migrations %s, want %d" % [i, m0.get("migrations"), migrations])
	var want_level: int = st.level_default if type_changed else 500 + i
	check("type_change_default", m0.get("level") == want_level, "edit %d: level %s, want %d" % [i, m0.get("level"), want_level])
	var extra = m0.get("extra")
	check("added_field_default", (extra == st.extra_default) if st.extra else (extra == null),
		"edit %d: extra %s (present %s, default %d)" % [i, extra, st.extra, st.extra_default])
	# `res` here and in holder's field.
	var refs := res.get_reference_count()
	check("owned_fields_kept", m0.get("note") == "note %d" % i and holder.get("label") == "stress label"
		and holder.get("tag") == &"stress_tag" and holder.get("res") == res and refs == 2,
		"edit %d: note %s label %s tag %s res %s refs %d" % [i, m0.get("note"), holder.get("label"), holder.get("tag"),
			holder.get("res"), refs])
	var objs := [m0, holder, hold_beacon, previewer]
	var errs := []
	for o in objs:
		errs.append(probe.call_error(o, &"version"))
	check("new_code_no_invalid_method", errs == [0, 0, 0, 0] and m0.call("version") == st.mover and holder.call("version") == st.holder
		and hold_beacon.call("version") == st.beacon and previewer.call("version") == st.previewer,
		"edit %d: call errors %s versions %s/%s/%s/%s want %d/%d/%d/%d" % [i, errs, m0.call("version"), holder.call("version"),
			hold_beacon.call("version"), previewer.call("version"), st.mover, st.holder, st.beacon, st.previewer])
	# Every default of the new build (the descriptor cache reads them too).
	var si: int = probe.find_script("mover.zig")
	var defs := {}
	for k in probe.property_count(si):
		defs[probe.property_name(si, k)] = probe.default_text(si, k)
	var want_defs := {"bumps": "0", st.name: "0", "level": str(st.level_default), "note": "\"\"", "migrations": "0"}
	if st.extra:
		want_defs["extra"] = str(st.extra_default)
	check("defaults_match_source", defs == want_defs, "edit %d: defaults %s want %s" % [i, defs, want_defs])
	check("placeholder_default", plain.get("mark") == st.plain and probe.script_placeholder_count(scripts["plain"]) == 1,
		"edit %d: mark %s want %d" % [i, plain.get("mark"), st.plain])
	var held := {}
	for g in gens:
		if g != gen and probe.live_bytes(g) != 0:
			held[g] = probe.live_bytes(g)
	check("old_generations_released", held.is_empty() and probe.live_bytes(gen) > 0, "edit %d: bytes left in older generations %s" % [i, held])
	check("generation_count", probe.loaded_generations() == good_builds and gens.size() == good_builds,
		"edit %d: loaded %d, generations seen %d, good builds %d" % [i, probe.loaded_generations(), gens.size(), good_builds])
	check("registry_matches_live", probe.registry_count() == probe.live_instances(),
		"edit %d: registry %d live %d" % [i, probe.registry_count(), probe.live_instances()])


# ---------------------------------------------------------------- handlers

func _watchdog() -> void:
	print("ZTEST FAIL watchdog: the run did not finish within %d s; checks so far %s, failures %s" % [watchdog_s, checks, failures])
	print("ZTEST DONE")
	stop = true
	hold_release = true
	get_tree().quit(1)


# previewer.zig's `wants_previews`: module code is on the stack.
func _make_previews() -> void:
	var nf0: int = probe.language_nested_frames()
	var gen0: int = probe.current_generation()
	var meshes: Array[Mesh] = [preview_mesh]
	# The dummy renderer of a headless run has no image to give back, so
	# the result is empty; the two iterations run regardless.
	EditorInterface.make_mesh_previews(meshes, 16)
	var n: int = probe.language_nested_frames() - nf0
	nested_frames += n
	check("nested_iteration_runs_frame", n >= 2, "nested frames %d" % n)
	nested_info = [probe.swap_outcome(), n, probe.current_generation() == gen0, probe.gate_depth()]


# hold_beacon's `pulse`, on the holding thread.
func _hold() -> void:
	hold_inside = true
	while not hold_release:
		OS.delay_msec(1)


# Returns [calls, errors, first error].
func _worker(i: int) -> Array:
	var m: RefCounted = movers[i]
	var b: RefCounted = beacons[i]
	var n := 0
	var errors := 0
	var first := ""
	while not stop:
		n += 1
		var bumped = m.call("bump")
		var fired = b.call("fire")
		var e := [probe.call_error(m, &"version"), probe.call_error(b, &"version"), probe.call_error(holder, &"version")]
		if bumped != n or fired != n or e != [0, 0, 0]:
			errors += 1
			if first == "":
				first = "call %d: bump %s fire %s call errors %s" % [n, bumped, fired, e]
		if n % 4 == 0:
			OS.delay_usec(200)
	return [n, errors, first]
