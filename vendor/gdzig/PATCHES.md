# Patches to the vendored gdzig

This folder is a copy of the gdzig package pinned by Stage 2
(`git+https://github.com/gdzig/gdzig#c8e0768c9eb768827163f0ac893a5038bda799cb`,
package hash `godot-0.0.0-dev-q0GYjsfPwgCDsHpBgBeKR6ph6EbtJLqaMCY7waAmKGty`),
with the three changes below and this file. Everything else is unchanged, but
gdzig's own `example/.gitignore` keeps two ignored items of its example
project out of the repository: `example/project/.godot/imported/` and
`example/project/.godot/global_script_class_cache.cfg`
(`example/project/.godot/extension_list.cfg` is committed). gdzig's license
is in `LICENSE`.

Patch 3 adds a build option that withholds the Object helpers (see its
section). Patches 1 and 2 each raise a comptime branch quota. gdzig builds
the virtual method table of a user class at compile time:
`virtualMethodNames` lists the class's `_`-prefixed functions, and
`VTable.findMethod` looks each name up and builds its wrapper. The work
grows with the number of virtuals the class implements.
`ZigLanguage` (`src/host/language.zig`) implements all 60 virtuals of
`ScriptLanguageExtension` in Godot 4.7.2, which the stock quotas do not allow.

## Measurement (patches 1 and 2)

Zig 0.17.0, `zig build host` (the host library, Debug, x86_64-linux), with
`ZigLanguage` implementing every `ScriptLanguageExtension` virtual. Each
quota was bisected with the other one set to 10 000 000, and the pair of
minimums was then checked together.

| Patch | Function | Stock quota | Smallest that compiles | Chosen |
|---|---|---|---|---|
| 1 | `virtualMethodNames` in `src/extension/class.zig` | none (Zig default 1000) | 1825 | 10 000 |
| 2 | `VTable.findMethod` in `src/class/vtable.zig` | 100 000 | 186 392 | 1 000 000 |

- 1825 with 186 392 compiles; 1824 with 186 392 fails, and 1825 with
  186 391 fails.
- The chosen values are about five times the minimum, so a second class of
  the same size (the script class, `ScriptExtension`) and small gdzig changes
  fit. A quota is only a ceiling: compile time is the same for every value
  that compiles.

## Patch 1: `virtualMethodNames`

```diff
--- a/src/extension/class.zig
+++ b/src/extension/class.zig
@@ -435,6 +435,9 @@
 }
 
 fn virtualMethodNames(comptime T: type) []const []const u8 {
+    // Ziggurat patch 1 (vendor/gdzig/PATCHES.md): a class with every
+    // ScriptLanguageExtension virtual needs 1825.
+    @setEvalBranchQuota(10_000);
     const callbacks = [_][]const u8{
         "_destroyPropertyList",
         "_get",
```

The compile error without it (patch 2 applied):

```
gdzig/extension/class.zig:471:28: error: evaluation exceeded 1000 backwards branches
            if (std.mem.eql(u8, decl, cb)) break true;
                ~~~~~~~~~~~^~~~~~~~~~~~~~
gdzig/extension/class.zig:471:28: note: use @setEvalBranchQuota() to raise the branch limit from 1000
gdzig/extension/class.zig:512:68: note: called at comptime here
            Result = Result.extend(ancestors[i], virtualMethodNames(ancestors[i]));
                                                 ~~~~~~~~~~~~~~~~~~^~~~~~~~~~~~~~
gdzig/extension/class.zig:283:56: note: called at comptime here
            const UserVTable = comptime UserClassVTable(T);
                                        ~~~~~~~~~~~~~~~^~~
```

With a quota of 1824 the error is at `gdzig/class/vtable.zig:111:87`
(`combineNames`, called from `extend` in the same evaluation):
`evaluation exceeded 1824 backwards branches`.

## Patch 2: `VTable.findMethod`

```diff
--- a/src/class/vtable.zig
+++ b/src/class/vtable.zig
@@ -31,7 +31,9 @@
         }
 
         fn findMethod(comptime method_name: []const u8) c.GDExtensionClassCallVirtual {
-            @setEvalBranchQuota(100_000);
+            // Ziggurat patch 2 (vendor/gdzig/PATCHES.md): a class with every
+            // ScriptLanguageExtension virtual needs 186392.
+            @setEvalBranchQuota(1_000_000);
             inline for (class.selfAndAncestorsOf(T)) |Owner| {
                 if (@hasDecl(Owner, method_name)) {
                     const method = @field(Owner, method_name);
```

The compile error without it (patch 1 applied):

```
casez/casez.zig:511:54: error: evaluation exceeded 100000 backwards branches
    for (input, 0..) |c, i| result[i] = ascii.toLower(c);
                                        ~~~~~~~~~~~~~^~~
casez/casez.zig:511:54: note: use @setEvalBranchQuota() to raise the branch limit from 100000
casez/casez.zig:394:50: note: called at comptime here
        const result: [1][]const u8 = .{lowercase(segment)};
                                        ~~~~~~~~~^~~~~~~~~
casez/casez.zig:356:48: note: called at comptime here
            const split = splitUppercaseSegment(config, segment);
                          ~~~~~~~~~~~~~~~~~~~~~^~~~~~~~~~~~~~~~~
casez/casez.zig:192:60: note: called at comptime here
    return outputLen(config, expandWords(config, parseWords(config, input)));
                                                 ~~~~~~~~~~^~~~~~~~~~~~~~~
casez/casez.zig:4:102: note: called at comptime here
pub fn comptimeConvert(comptime config: Config, comptime input: []const u8) *const [comptimeOutputLen(config, input):0]u8 {
                                                                                    ~~~~~~~~~~~~~~~~~^~~~~~~~~~~~~~~
gdzig/class/vtable.zig:17:56: note: generic function instantiated here
                    kvs[idx] = .{ casez.comptimeConvert(godot_case.virtual_method, method_name), wrapper };
                                  ~~~~~~~~~~~~~~~~~~~~~^~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
```

The error is reported in the comptime evaluation that builds the table
(`VTable.map`), whose quota `findMethod` raises. With a quota of 186 391
the error is at `std/static_string_map.zig:222:13` instead.

## Patch 3: build option `object_helpers`

gdzig's Object mixin gives every engine class six helpers: `setInstance`,
`asInstance`, `connect`, `disconnect`, `emit` and `emitAlloc`. Ziggurat's
SDK re-exports the engine classes to scripts as plain aliases
(`tools/godot_surface.zig`), so scripts would inherit them. Scripts must
not use them: the instance binding belongs to the host, `connect` and
`disconnect` take a gdzig Callable, and `emit`/`emitAlloc` convert through
gdzig's Variant helpers instead of the SDK's checked `z.emit`.

The patch adds the build option `object_helpers: bool` (default `true`, so
the default build matches upstream) and passes it to the `gdzig` module in
its `build_options`. The six helpers become private functions with the
suffix `Helper`, and the public names are constants that select either the
helper or a compile error. The constants are analyzed only when used, so a
build with `false` compiles as long as nothing names a helper.

Ziggurat's `build.zig` asks for `.object_helpers = false` for the SDK's
gdzig only (`addSdk`); the host's gdzig keeps the default and calls
`setInstance`/`asInstance` itself. The two different option sets make two
gdzig dependency instances in one build.

```diff
--- a/build.zig
+++ b/build.zig
@@ -10,6 +10,8 @@
     const regenerate_interface = b.option(bool, "regenerate-interface", "Regenerate the vendored GDExtension interface header (requires Python)") orelse false;
+    // Ziggurat patch 3 (vendor/gdzig/PATCHES.md).
+    const object_helpers = b.option(bool, "object_helpers", "Provide the Object helpers setInstance, asInstance, connect, disconnect, emit and emitAlloc on every class [default: true]") orelse true;
@@ -145,6 +147,7 @@
     gdzig_options.addOption([]const u8, "precision", precision);
+    gdzig_options.addOption(bool, "object_helpers", object_helpers);
--- a/src/class/Object.mixin.zig
+++ b/src/class/Object.mixin.zig
@@ -88,8 +88,23 @@
+// Ziggurat patch 3 (vendor/gdzig/PATCHES.md): with the build option
+// `object_helpers = false` these six helpers are compile errors.
+pub const setInstance = if (object_helpers) setInstanceHelper else @compileError(withheld("setInstance"));
+pub const asInstance = if (object_helpers) asInstanceHelper else @compileError(withheld("asInstance"));
+pub const connect = if (object_helpers) connectHelper else @compileError(withheld("connect"));
+pub const disconnect = if (object_helpers) disconnectHelper else @compileError(withheld("disconnect"));
+pub const emit = if (object_helpers) emitHelper else @compileError(withheld("emit"));
+pub const emitAlloc = if (object_helpers) emitAllocHelper else @compileError(withheld("emitAlloc"));
+
+const object_helpers = @import("build_options").object_helpers;
+
+fn withheld(comptime name: []const u8) []const u8 {
+    return "ziggurat: " ++ name ++ " is not available in scripts; use z.emit or z.godot.Callable";
+}
+
 /// Bind an instance of an extension class to this engine class.
-pub fn setInstance(self: *Self, comptime T: type, instance_: *T) void {
+fn setInstanceHelper(self: *Self, comptime T: type, instance_: *T) void {
-pub fn asInstance(self: *Self, comptime T: type) ?*T {
+fn asInstanceHelper(self: *Self, comptime T: type) ?*T {
-pub fn connect(self: *Self, comptime S: type, callable: Callable) ConnectError!void {
+fn connectHelper(self: *Self, comptime S: type, callable: Callable) ConnectError!void {
-pub fn disconnect(self: *Self, comptime S: type, callable: Callable) void {
+fn disconnectHelper(self: *Self, comptime S: type, callable: Callable) void {
-pub fn emit(self: *Self, comptime SignalType: type, signal: AssertNonAllocating(SignalType)) EmitError!void {
+fn emitHelper(self: *Self, comptime SignalType: type, signal: AssertNonAllocating(SignalType)) EmitError!void {
-pub fn emitAlloc(self: *Self, comptime SignalType: type, signal: SignalType) EmitError!void {
+fn emitAllocHelper(self: *Self, comptime SignalType: type, signal: SignalType) EmitError!void {
```

bindgen copies the mixin text into every generated class file, so the
constants, `object_helpers` and `withheld` exist in each class. With
`false`, a script line `self.base.connect(signals.hit, undefined)` fails
with one error, reported at the constant in the generated class file (for
`Node`, `gdzig/class/Node.zig`), not at the script line:

```
error: ziggurat: connect is not available in scripts; use z.emit or z.godot.Callable
```

gdzig itself calls `asInstance` in two places (`src/builtin/variant.zig`,
`src/extension/method.zig`), on pointers to gdzig extension (struct)
classes only. A build with `false` reaches them only for such classes,
which Ziggurat scripts do not define.

Tests: `integration: scripts cannot call object helpers` in
`test/sdk_e2e.zig` (one script per helper, exact message), and a comptime
block in `src/host/test_probe.zig` that names all six helpers on the
host's gdzig.

## Updating gdzig

Copy the new package over this folder, apply the three patches again (drop
patches 1 and 2 if upstream raised the quotas or made the lookup cheaper),
repeat the measurement with `zig build host`, and run `zig build test`
(it covers patch 3).
