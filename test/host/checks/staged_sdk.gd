@tool
extends Node
# Host test "staged SDK builds a project", editor pass: a tool autoload in
# the headless editor of a project that has the shipped SDK in
# res://addons/ziggurat/sdk/x86_64-linux/ (the editor's own target) and an
# empty ziggurat/dev/sdk_manifest. The
# build at open must use that SDK and stage generation 1, and the editor's
# file system must not list any file of the SDK folder (it has a .gdignore).
# Prints one ZTEST line per case, then ZTEST DONE, and quits. In a game it
# does nothing.

const WAIT_MS := 600000
const MANIFEST := "res://.godot/ziggurat/manifest"
const SDK := "res://addons/ziggurat/sdk/"
const KEY_SDK := SDK + "x86_64-linux/"


func report(name: String, ok: bool, why: String) -> void:
	if ok:
		print("ZTEST PASS %s" % name)
	else:
		print("ZTEST FAIL %s: %s" % [name, why])


func _ready() -> void:
	if not Engine.is_editor_hint():
		return
	await run()
	print("ZTEST DONE")
	get_tree().quit()


func run() -> void:
	var end := Time.get_ticks_msec() + WAIT_MS
	while Time.get_ticks_msec() < end and not FileAccess.file_exists(MANIFEST):
		await get_tree().process_frame
	var manifest := FileAccess.get_file_as_string(MANIFEST)
	report("staged_sdk_built", manifest.begins_with("gen=1\n"), var_to_str(manifest))

	# Through Engine: the exported game parses this file too, and has no
	# EditorInterface class.
	var efs: Object = Engine.get_singleton("EditorInterface").get_resource_filesystem()
	while Time.get_ticks_msec() < end and efs.is_scanning():
		await get_tree().process_frame
	# The add-on folder is scanned; the SDK folder under it is not.
	report("staged_sdk_addon_scanned", efs.get_filesystem_path("res://addons/ziggurat/") != null, "res://addons/ziggurat/ is not in the editor's file system")
	report("staged_sdk_not_scanned", efs.get_filesystem_path(SDK) == null and efs.get_file_type(KEY_SDK + "ziggurat/ziggurat.zig") == "",
		"the editor's file system lists %s" % SDK)
	# The SDK files are there on disk.
	report("staged_sdk_on_disk", FileAccess.file_exists(KEY_SDK + "sdk-manifest.json"), "no %ssdk-manifest.json" % KEY_SDK)
