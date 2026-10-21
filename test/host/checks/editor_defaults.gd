@tool
extends Node
# Host test "editor reload: defaults after a layout change": runs as a tool
# autoload in the headless editor of test/host/projects/editor_defaults.
# Build 1 (at open) loads shift.zig; a save changes `level` from i32 to
# i64, so `note` and the fields after it move. The editor builds that save
# incrementally, writes the descriptor cache (which reads every default)
# and swaps; every property's default and a new instance's values must be
# those of the new source. Found by the reload stress test.

const WAIT_MS := 600000

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


func defaults(si: int) -> Dictionary:
	var d := {}
	for i in probe.property_count(si):
		d[probe.property_name(si, i)] = probe.default_text(si, i)
	return d


func _ready() -> void:
	if not Engine.is_editor_hint():
		return
	probe = ClassDB.instantiate("ZigguratTestProbe")
	await run()
	print("ZTEST DONE")
	get_tree().quit()


func run() -> void:
	var built: bool = await wait_for(func(): return probe.current_generation() >= 1)
	var s: Script = load("res://shift.zig")
	var o := RefCounted.new()
	o.set_script(s)
	var si: int = probe.find_script("shift.zig")
	var want1 := {"bumps": "0", "points": "0", "level": "0", "extra": "2", "note": "\"\"", "migrations": "0"}
	report("defaults_build_1", built and defaults(si) == want1, "built %s, defaults %s" % [built, defaults(si)])

	s.source_code = s.source_code.replace("level: i32 = 0,", "level: i64 = 5,").replace("return 1;", "return 2;")
	var err := ResourceSaver.save(s, "res://shift.zig")
	var swapped: bool = await wait_for(func(): return probe.current_generation() == 2 and o.call("version") == 2)
	si = probe.find_script("shift.zig")
	var want2 := {"bumps": "0", "points": "0", "level": "5", "extra": "2", "note": "\"\"", "migrations": "0"}
	report("defaults_after_layout_change", err == OK and swapped and defaults(si) == want2,
		"save %d swapped %s defaults %s" % [err, swapped, defaults(si)])
	var fresh := RefCounted.new()
	fresh.set_script(s)
	report("new_instance_after_layout_change", fresh.get("level") == 5 and fresh.get("extra") == 2 and fresh.get("note") == "",
		"level %s extra %s note %s" % [fresh.get("level"), fresh.get("extra"), fresh.get("note")])
