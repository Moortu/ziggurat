@tool
extends Node
# Host test "editor plugin is present": runs as a tool autoload in the
# headless editor of test/host/projects/empty with the probe host. The host
# registers `ZigEditorPlugin` at the EDITOR level and hands it to the editor
# (`editor_add_plugin`), so exactly one child of EditorNode has that class.
# A Callable that the host builds in Zig (object and method name) reaches a
# method bound on the plugin when a signal fires. The plugin registers the
# editor setting `ziggurat/zig_path` with a file picker. Prints one ZTEST
# line per case, then ZTEST DONE, and quits the editor.

const WAIT_MS := 30000

signal ping

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


func _ready() -> void:
	if not Engine.is_editor_hint():
		return
	probe = ClassDB.instantiate("ZigguratTestProbe")
	await run()
	print("ZTEST DONE")
	get_tree().quit()


func editor_node() -> Node:
	for child in get_tree().root.get_children():
		if child.get_class() == "EditorNode":
			return child
	return null


func plugins() -> Array[Node]:
	var found: Array[Node] = []
	var editor := editor_node()
	if editor == null:
		return found
	for child in editor.get_children():
		if child.get_class() == "ZigEditorPlugin":
			found.append(child)
	return found


func run() -> void:
	# The editor adds extension plugins while it builds itself, before the
	# first frame; wait a little in case it defers one.
	await wait_for(func(): return plugins().size() > 0)
	var list := plugins()
	report("editor_plugin_present", list.size() == 1, "ZigEditorPlugin children of EditorNode: %d (EditorNode found: %s)" % [list.size(), editor_node() != null])
	if list.size() != 1:
		return
	var plugin: Node = list[0]
	report("editor_plugin_is_editor_plugin", plugin is EditorPlugin and plugin.is_inside_tree(), "class %s, in tree %s" % [plugin.get_class(), plugin.is_inside_tree()])

	# The host connects `ping` to the plugin's bound test method through a
	# Callable it made in Zig; one emit runs the method once.
	if not probe.has_method("editor_plugin_connect"):
		report("editor_plugin_callable", false, "the probe has no method editor_plugin_connect")
		return
	var before: int = probe.editor_plugin_pings()
	var connected: bool = probe.editor_plugin_connect(plugin, self, &"ping")
	ping.emit()
	var after: int = probe.editor_plugin_pings()
	report("editor_plugin_callable", connected and after == before + 1, "connected %s, pings %d -> %d" % [connected, before, after])

	var settings := EditorInterface.get_editor_settings()
	var hint := -1
	for p in settings.get_property_list():
		if p.name == "ziggurat/zig_path":
			hint = p.hint
	report("editor_setting_zig_path", settings.has_setting("ziggurat/zig_path") and hint == PROPERTY_HINT_GLOBAL_FILE, "has %s, hint %d" % [settings.has_setting("ziggurat/zig_path"), hint])
