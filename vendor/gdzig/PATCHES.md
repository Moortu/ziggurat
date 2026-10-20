# Patches to the vendored gdzig

This folder is a copy of the gdzig package pinned by Stage 2
(`git+https://github.com/gdzig/gdzig#c8e0768c9eb768827163f0ac893a5038bda799cb`,
package hash `godot-0.0.0-dev-q0GYjsfPwgCDsHpBgBeKR6ph6EbtJLqaMCY7waAmKGty`),
with the two changes below and this file. Everything else is unchanged, but
the example project's `.godot` cache files are left out of the repository
by gdzig's own `example/.gitignore`. gdzig's license is in `LICENSE`.

Both changes raise a comptime branch quota. gdzig builds the virtual method
table of a user class at compile time: `virtualMethodNames` lists the class's
`_`-prefixed functions, and `VTable.findMethod` looks each name up and builds
its wrapper. The work grows with the number of virtuals the class implements.
`ZigLanguage` (`src/host/language.zig`) implements all 60 virtuals of
`ScriptLanguageExtension` in Godot 4.7.2, which the stock quotas do not allow.

## Measurement

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

## Updating gdzig

Copy the new package over this folder, apply both patches again (or drop
them if upstream raised the quotas or made the lookup cheaper), and repeat
the measurement with `zig build host`.
