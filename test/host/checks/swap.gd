extends SceneTree
# Host tests of the swap engine: "rollback on allocation failure", "same
# layout keeps data", "changed layout moves fields", "migrate hook runs",
# "instance freed before swap gets one deinit", instances freed and made
# during a swap, and a script missing from the new build.
# Generation 1 is test/fixtures/swap_v1, generation 2 test/fixtures/swap_v2
# (staged, not published). Swaps are requested through ZigguratTestProbe
# and run at the language's `_frame`. The Zig test checks the log lines
# (deinit once per instance, dropped fields, the missing script).

# Outcomes of `swap_outcome` (swap.Outcome).
const NONE := 0
const SWAPPED := 3
const REJECTED := 4

var failed := false
var probe: Object
var keeper_s: Script
var mover_s: Script
var migrator_s: Script
var oldonly_s: Script

# Made by the hook that runs during the swap.
var made_during: Node
var victim_after: Node
var victim_before: Node
var hook_ran := false


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


func zig_script(path: String) -> Script:
	var s: Script = ClassDB.instantiate("ZigScript")
	s.resource_path = path
	return s


func make_mover(id: int) -> Node:
	var n := Node.new()
	n.set_script(mover_s)
	n.set("id", id)
	# Not moved by a swap: the old deinit logs it.
	n.set("hp", id)
	return n


func make_ref(s: Script) -> RefCounted:
	var o := RefCounted.new()
	o.set_script(s)
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
	var diag: String = probe.load_module(module_path("v1"), 1)
	report("load", diag == "", diag)
	var staged: String = probe.stage_module(module_path("v2"), 2)
	report("stage", staged == "", staged)
	if diag != "" or staged != "":
		finish()
		return
	keeper_s = zig_script("res://keeper.zig")
	mover_s = zig_script("res://mover.zig")
	migrator_s = zig_script("res://migrator.zig")
	oldonly_s = zig_script("res://oldonly.zig")
	run()


# Waits until the swap outcome is `want` (or a few hundred frames passed).
func wait_outcome(want: int) -> int:
	var frames := 0
	while probe.swap_outcome() != want and frames < 300:
		await process_frame
		frames += 1
	return probe.swap_outcome()


func run() -> void:
	# Made first, so it is the first changed-layout instance migrated: the
	# hook below frees it after its migration.
	var bytes_empty: int = probe.live_bytes(1)
	victim_after = make_mover(5)
	var before_oldonly: int = probe.live_bytes(1)
	var oldonly := make_ref(oldonly_s)
	var oldonly_bytes: int = probe.live_bytes(1) - before_oldonly
	var keeper := make_ref(keeper_s)
	keeper.set("value", 11)
	var m1 := make_mover(1)
	var m2 := make_mover(2)
	var res := Resource.new()
	m1.set("speed", 2.5)
	m1.set("title", "hello")
	m1.set("item", res)
	m1.set("count", 4)
	var mig := Node.new()
	mig.set_script(migrator_s)
	mig.set("hp", 55)
	# Freed before any swap: its deinit runs once, on generation 1.
	var gone := make_mover(9)
	gone.free()
	# Made last, so the hook frees it before the swap reaches it.
	victim_before = make_mover(6)

	var keeper_data: int = probe.instance_data(keeper)
	var m1_data: int = probe.instance_data(m1)
	var bytes1: int = probe.live_bytes(1)
	var bytes2: int = probe.live_bytes(2)

	# The swap allocates one block per changed-layout instance (4 movers and
	# the migrator); the third allocation fails.
	probe.fail_allocation(3)
	probe.swap_request(2)
	var outcome: int = await wait_outcome(REJECTED)
	probe.fail_allocation(0)
	var gens_ok := true
	for o in [keeper, m1, m2, mig, oldonly, victim_after, victim_before]:
		gens_ok = gens_ok and probe.instance_generation(o) == 1
	report("rollback_on_allocation_failure",
		outcome == REJECTED and probe.current_generation() == 1 and gens_ok
		and probe.live_bytes(1) == bytes1 and probe.live_bytes(2) == bytes2
		and probe.instance_data(keeper) == keeper_data and probe.instance_data(m1) == m1_data
		and m1.get("speed") == 2.5 and m1.get("title") == "hello" and keeper.call("version") == 1,
		"outcome %d, current %d, generations %s, bytes %d/%d (before %d/%d), data %s %s, speed %s" % [
			outcome, probe.current_generation(), gens_ok, probe.live_bytes(1), probe.live_bytes(2),
			bytes1, bytes2, probe.instance_data(keeper) == keeper_data, probe.instance_data(m1) == m1_data, m1.get("speed")])

	# The hook runs on the swapping thread after the first changed-layout
	# instance moved: it frees that one, frees one not reached yet, and
	# makes a new one.
	probe.swap_hook(_during_swap)
	var swaps: int = probe.swaps_done()
	probe.swap_request(2)
	outcome = await wait_outcome(SWAPPED)
	report("swapped", outcome == SWAPPED and probe.swaps_done() == swaps + 1 and probe.current_generation() == 2 and hook_ran,
		"outcome %d, swaps %d -> %d, current %d, hook %s" % [outcome, swaps, probe.swaps_done(), probe.current_generation(), hook_ran])

	report("same_layout_keeps_data",
		probe.instance_data(keeper) == keeper_data and probe.instance_generation(keeper) == 2
		and keeper.get("value") == 11 and keeper.call("version") == 2,
		"data kept %s, generation %d, value %s, version %s" % [probe.instance_data(keeper) == keeper_data,
			probe.instance_generation(keeper), keeper.get("value"), keeper.call("version")])

	var names := []
	for p in m1.get_property_list():
		names.append(p.name)
	report("changed_layout_moves_fields",
		probe.instance_generation(m1) == 2 and probe.instance_data(m1) != m1_data
		and m1.get("speed") == 2.5 and m1.get("title") == "hello" and m1.get("item") == res
		and m1.get("id") == 1 and m2.get("id") == 2
		# Type changed: reset to version 2's default. New: its default.
		and m1.get("count") == 3 and m1.get("added") == 7
		# Removed.
		and m1.get("hp") == null and not names.has("hp") and names.has("added")
		# `init` did not run again.
		and m1.get("inits") == 1 and m1.call("version") == 2,
		"generation %d, speed %s, title %s, item %s, id %s, count %s, added %s, hp %s, inits %s, version %s" % [
			probe.instance_generation(m1), m1.get("speed"), m1.get("title"), m1.get("item") == res, m1.get("id"),
			m1.get("count"), m1.get("added"), m1.get("hp"), m1.get("inits"), m1.call("version")])

	report("migrate_hook_runs", mig.get("migrated") == true and mig.get("health") == 55,
		"migrated %s, health %s" % [mig.get("migrated"), mig.get("health")])

	report("instance_made_during_swap_on_new_generation",
		made_during != null and probe.instance_generation(made_during) == 2 and made_during.get("inits") == 1,
		"generation %d, inits %s" % [probe.instance_generation(made_during) if made_during else -1,
			made_during.get("inits") if made_during else null])

	report("script_missing_keeps_old_code",
		probe.instance_generation(oldonly) == 1 and oldonly.call("answer") == 10,
		"generation %d, answer %s" % [probe.instance_generation(oldonly), oldonly.call("answer")])

	# Generation 1 holds only the instance of the script it alone has.
	report("old_generation_bytes_released", probe.live_bytes(1) == bytes_empty + oldonly_bytes,
		"%d bytes, want %d" % [probe.live_bytes(1), bytes_empty + oldonly_bytes])
	report("registry_matches_live", probe.registry_count() == probe.live_instances(),
		"registry %d, live %d" % [probe.registry_count(), probe.live_instances()])

	# Nothing left to do: a request for the current generation.
	probe.swap_request(2)
	outcome = await wait_outcome(NONE)
	report("request_for_current_does_nothing", outcome == NONE and probe.swaps_done() == swaps + 1,
		"outcome %d, swaps %d" % [outcome, probe.swaps_done()])

	m1.set("item", null)
	for n in [m1, m2, mig, made_during]:
		n.free()
	keeper = null
	oldonly = null
	report("instances_released", probe.live_instances() == 0 and probe.live_bytes(2) == bytes2,
		"%d instances, %d bytes in generation 2 (before %d)" % [probe.live_instances(), probe.live_bytes(2), bytes2])
	finish()


func _during_swap() -> void:
	hook_ran = true
	victim_after.free()
	victim_before.free()
	made_during = make_mover(7)
