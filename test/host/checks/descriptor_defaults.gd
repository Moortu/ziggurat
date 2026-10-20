extends SceneTree
# Host test "defaults round trip as typed JSON": every v1 default type goes
# through the cache's typed JSON and back and comes out equal, with the type
# the property declares. No module is needed.

var failed := false


func report(name: String, ok: bool, why: String) -> void:
	if ok:
		print("ZTEST PASS %s" % name)
	else:
		failed = true
		print("ZTEST FAIL %s: %s" % [name, why])


func _initialize() -> void:
	var probe: Object = ClassDB.instantiate("ZigguratTestProbe")
	if probe == null:
		report("probe", false, "ZigguratTestProbe is not registered")
		print("ZTEST DONE")
		quit()
		return
	var cases := [
		["bool_true", TYPE_BOOL, true],
		["bool_false", TYPE_BOOL, false],
		["int", TYPE_INT, -5],
		["int_large", TYPE_INT, 4611686018427387904],
		["int_min", TYPE_INT, -9223372036854775808],
		["float", TYPE_FLOAT, 300.5],
		["float_tiny", TYPE_FLOAT, 1.0e-300],
		["float_whole", TYPE_FLOAT, 300.0],
		["string", TYPE_STRING, "héllo \"quoted\" ; Object(Node)\n\ttab"],
		["string_empty", TYPE_STRING, ""],
		["string_name", TYPE_STRING_NAME, &"some_name"],
		["node_path", TYPE_NODE_PATH, ^"Parent/Child:prop"],
		["vector2", TYPE_VECTOR2, Vector2(1.5, -2.25)],
		["vector2i", TYPE_VECTOR2I, Vector2i(3, -4)],
		["rect2", TYPE_RECT2, Rect2(1, 2, 3.5, 4)],
		["rect2i", TYPE_RECT2I, Rect2i(1, -2, 3, 4)],
		["vector3", TYPE_VECTOR3, Vector3(1, 2.5, -3)],
		["vector3i", TYPE_VECTOR3I, Vector3i(1, -2, 3)],
		["transform2d", TYPE_TRANSFORM2D, Transform2D(Vector2(1, 2), Vector2(3, 4), Vector2(5, 6))],
		["vector4", TYPE_VECTOR4, Vector4(1, 2, 3, 4.5)],
		["vector4i", TYPE_VECTOR4I, Vector4i(1, 2, -3, 4)],
		["plane", TYPE_PLANE, Plane(1, 2, 3, 4)],
		["quaternion", TYPE_QUATERNION, Quaternion(0.1, 0.2, 0.3, 0.4)],
		["aabb", TYPE_AABB, AABB(Vector3(1, 2, 3), Vector3(4, 5, 6))],
		["basis", TYPE_BASIS, Basis(Vector3(1, 2, 3), Vector3(4, 5, 6), Vector3(7, 8, 9))],
		["transform3d", TYPE_TRANSFORM3D, Transform3D(Basis(Vector3(1, 2, 3), Vector3(4, 5, 6), Vector3(7, 8, 9)), Vector3(10, 11, 12))],
		["projection", TYPE_PROJECTION, Projection(Vector4(1, 2, 3, 4), Vector4(5, 6, 7, 8), Vector4(9, 10, 11, 12), Vector4(13, 14, 15, 16))],
		["color", TYPE_COLOR, Color(0.1, 0.2, 0.3, 0.4)],
	]
	for c in cases:
		var out: Array = probe.roundtrip_default(c[1], [c[2]])
		var back: Variant = out[0] if out.size() == 1 else null
		report("roundtrip_" + c[0], out.size() == 1 and typeof(back) == c[1] and back == c[2],
			"restored %s, want %s" % [out, c[2]])

	# Floats that JSON numbers cannot hold travel as text.
	for special in [["nan", NAN, "\"nan\""], ["inf", INF, "\"inf\""], ["minus_inf", -INF, "\"-inf\""]]:
		var out: Array = probe.roundtrip_default(TYPE_FLOAT, [special[1]])
		var same: bool = out.size() == 1 and typeof(out[0]) == TYPE_FLOAT and (is_nan(out[0]) if special[0] == "nan" else out[0] == special[1])
		report("roundtrip_float_" + special[0], same and probe.stored_default(TYPE_FLOAT, [special[1]]) == special[2], "got %s, stored %s" % [out, probe.stored_default(TYPE_FLOAT, [special[1]])])

	# Object handles are stored as null and come back as a null object.
	report("roundtrip_object_null", probe.stored_default(TYPE_OBJECT, [null]) == "null" and probe.roundtrip_default(TYPE_OBJECT, [null]) == [null], "stored %s" % probe.stored_default(TYPE_OBJECT, [null]))
	var node := Node.new()
	report("object_is_never_stored_as_data", probe.stored_default(TYPE_OBJECT, [node]) == "null", probe.stored_default(TYPE_OBJECT, [node]))
	node.free()

	# A value of another type than the declared one has no stored form.
	var mismatches := [[TYPE_INT, "x"], [TYPE_BOOL, 1], [TYPE_STRING, 5], [TYPE_VECTOR2, Vector3(1, 2, 3)], [TYPE_INT, 1.5], [TYPE_FLOAT, 3], [TYPE_STRING, &"sn"], [TYPE_ARRAY, []], [TYPE_NIL, 1]]
	var bad := []
	for m in mismatches:
		if probe.stored_default(m[0], [m[1]]) != "":
			bad.append(m)
	report("mismatched_type_has_no_stored_form", bad.is_empty(), str(bad))
	# A non-finite vector component has no stored form either.
	report("non_finite_component_has_no_stored_form", probe.stored_default(TYPE_VECTOR2, [Vector2(NAN, 1)]) == "" and probe.stored_default(TYPE_COLOR, [Color(INF, 0, 0, 1)]) == "", "stored")
	print("ZTEST DONE")
	quit()
