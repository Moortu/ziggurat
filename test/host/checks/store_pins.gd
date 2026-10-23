@tool
extends Node
# Host test "staged builds stay pinned until the editor loads them; a
# dropped outcome releases its pin": runs as a tool autoload in the headless
# editor of test/host/projects/editor_reload, whose knob.zig is a tool
# script, so the editor loads each good build.
# - build at open: generation 1, loaded;
# - the store keeps one generation (max_count 1), and the main thread is
#   held while three more builds stage and sweep: their outcomes wait in
#   the main-thread queue, and each sweep would delete every unpinned
#   generation but the newest. Generations 2 to 4 stay on disk, because each
#   is pinned from staging, and all three load once the frames run;
# - the queue is held (not drained) while one more build stages; then the
#   editor quits with its outcome queued. The host logs at exit how many
#   generation locks anything still holds; the host test expects 0.
# Prints one ZTEST line per case, then ZTEST DONE, and quits the editor.

const WAIT_MS := 600000
const GEN := "res://.godot/ziggurat/gen/%d"

var probe: Object


func report(name: String, ok: bool, why: String) -> void:
	if ok:
		print("ZTEST PASS %s" % name)
	else:
		print("ZTEST FAIL %s: %s" % [name, why])


func wait_for(cond: Callable) -> bool:
	var end := Time.get_ticks_msec() + WAIT_MS
	while Time.get_ticks_msec() < end:
		if cond.call():
			return true
		await get_tree().process_frame
	return false


func gen_exists(n: int) -> bool:
	return DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(GEN % n))


func _ready() -> void:
	if not Engine.is_editor_hint():
		return
	probe = ClassDB.instantiate("ZigguratTestProbe")
	await run()
	print("ZTEST DONE")
	get_tree().quit()


func run() -> void:
	var built: bool = await wait_for(func(): return probe.editor_build_outcomes() >= 1)
	report("pins_build_1", built and probe.generation_loaded(1),
		"outcomes %d loaded %s" % [probe.editor_build_outcomes(), probe.generation_loaded(1)])

	# ---- three builds stage and sweep while the main thread is held
	var caps: bool = probe.editor_build_set_store_caps(1, 1 << 30)
	var idle := true
	for i in 3:
		probe.editor_build_request("manual")
		idle = probe.editor_build_wait_idle(WAIT_MS) and idle
	var kept := gen_exists(2) and gen_exists(3) and gen_exists(4)
	report("pins_staged_kept", caps and idle and kept and probe.editor_build_outcomes() == 1,
		"caps %s idle %s gens %s %s %s outcomes %d" % [caps, idle, gen_exists(2), gen_exists(3), gen_exists(4), probe.editor_build_outcomes()])
	var applied: bool = await wait_for(func(): return probe.editor_build_outcomes() >= 4)
	report("pins_staged_builds_load", applied and probe.generation_loaded(2) and probe.generation_loaded(3) and probe.generation_loaded(4),
		"outcomes %d loaded %s %s %s" % [probe.editor_build_outcomes(), probe.generation_loaded(2), probe.generation_loaded(3), probe.generation_loaded(4)])

	# ---- quit with an outcome in the queue
	probe.editor_build_hold_queue(true)
	probe.editor_build_request("manual")
	idle = probe.editor_build_wait_idle(WAIT_MS)
	for i in 3:
		await get_tree().process_frame
	report("pins_outcome_queued_at_quit", idle and gen_exists(5) and probe.queue_pending() >= 1 and probe.editor_build_outcomes() == 4,
		"idle %s gen5 %s pending %d outcomes %d" % [idle, gen_exists(5), probe.queue_pending(), probe.editor_build_outcomes()])
