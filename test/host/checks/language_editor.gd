@tool
extends Node
# Host test "language in the editor": runs as a tool autoload in the
# headless editor. Being an autoload, it makes the editor call
# `_add_named_global_constant`. Then it drives the editor's own Create
# Script dialog with Zig selected, so Godot calls `_get_built_in_templates`
# and `_make_template`: with templates on, with templates off, and with a
# quoted script path as parent class. The script is made built-in, so the
# dialog hands it back through `script_created` without saving a file.
# Prints one ZTEST line per case, then ZTEST DONE; the runner's
# --quit-after ends the editor.

var made: Script = null
var count := 0


func report(name: String, ok: bool, why: String) -> void:
	if ok:
		print("ZTEST PASS %s" % name)
	else:
		print("ZTEST FAIL %s: %s" % [name, why])


func _ready() -> void:
	if not Engine.is_editor_hint():
		return
	var probe: Object = ClassDB.instantiate("ZigguratTestProbe")
	report("autoload_named_global_constant", probe.has_global_constant("check"), "the language did not record the autoload 'check'")

	var dialogs := get_tree().root.find_children("*", "ScriptCreateDialog", true, false)
	if dialogs.is_empty():
		report("create_script_dialog_found", false, "no ScriptCreateDialog")
		print("ZTEST DONE")
		return
	var dialog: Node = dialogs[0]
	dialog.script_created.connect(func(s: Script) -> void: made = s)

	var s := await create(dialog, "Node2D", true)
	report("template_offered", template_items(dialog).has("Object: Default"), "template menu: %s" % [template_items(dialog)])
	report("make_template_default", s != null and s.get_class() == "ZigScript" and s.source_code.contains("pub const extends = z.godot.Node2D;") and s.source_code.contains("base: *z.godot.Node2D,") and s.source_code.contains("pub fn _ready(self: *@This()) void"), source_of(s))

	s = await create(dialog, "Node", false)
	report("make_template_templates_off", s != null and s.source_code.contains("pub const extends = z.godot.Node;"), source_of(s))

	s = await create(dialog, "Resource", true)
	report("make_template_non_node_init", s != null and s.source_code.contains("pub const extends = z.godot.Resource;") and s.source_code.contains("pub fn init(self: *@This()) void") and not s.source_code.contains("_ready"), source_of(s))

	s = await create(dialog, "\"res://nope.gd\"", true)
	report("make_template_refuses_script_parent", s != null and s.source_code.begins_with("// Zig scripts extend engine classes only") and not s.source_code.contains("pub const extends"), source_of(s))
	print("ZTEST DONE")


# Fills the dialog for a new built-in Zig script with parent class `parent`
# and presses Create; returns the script the dialog made, or null.
func create(dialog: Node, parent: String, templates: bool) -> Script:
	made = null
	count += 1
	var langs := language_menu(dialog)
	var zig := -1
	for i in langs.item_count:
		if langs.get_item_text(i) == "Zig":
			zig = i
	if zig < 0:
		return null
	langs.select(zig)
	langs.item_selected.emit(zig)
	dialog.config(parent, "res://made_%d.zig" % count, true, false)
	var use_templates := checkbox(dialog, "Use Template")
	use_templates.button_pressed = templates
	use_templates.pressed.emit()
	# The dialog updates its template menu while visible, deferred.
	dialog.popup_centered()
	await get_tree().process_frame
	await get_tree().process_frame
	var built_in := checkbox(dialog, "Built-in Script:")
	built_in.button_pressed = true
	built_in.pressed.emit()
	dialog.get_ok_button().pressed.emit()
	if dialog.visible:
		dialog.hide()
	return made


func language_menu(dialog: Node) -> OptionButton:
	for menu in dialog.find_children("*", "OptionButton", true, false):
		for i in menu.item_count:
			if menu.get_item_text(i) == "GDScript":
				return menu
	return null


func template_items(dialog: Node) -> Array[String]:
	var items: Array[String] = []
	for menu in dialog.find_children("*", "OptionButton", true, false):
		if menu == language_menu(dialog):
			continue
		for i in menu.item_count:
			items.append(menu.get_item_text(i))
	return items


func checkbox(dialog: Node, accessibility: String) -> CheckBox:
	for c in dialog.find_children("*", "CheckBox", true, false):
		if c.accessibility_name == accessibility:
			return c
	return null


func source_of(s: Script) -> String:
	return "null" if s == null else s.source_code
