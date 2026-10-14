# Z.I.G.G.U.R.A.T: design (revision 4)

Status: draft, revised after three independent reviews and the Stage 0 spikes (section 16). Date: 2026-10-07; revision 4: 2026-10-13. The project is named Ziggurat, styled **Z.I.G.G.U.R.A.T** in titles and branding (after Projekt J.E.N.O.V.A). Dots are display only: every identifier, file name, package name and Godot class name is plain lowercase `ziggurat`.

Pins: Zig 0.17.0, Godot 4.7.2 (single precision only), gdzig commit `c8e0768` (2026-10-05). All are enforced at load time (section 3).

How to read claims: **verified** means someone ran it or read the cited source; **speculation** is labeled as such.

## 1. Goal and non-goals

**Goal.** Do for Zig what Projekt J.E.N.O.V.A does for C++: write `.zig` scripts inside a Godot project, attach them to nodes like GDScript, have the editor compile them, and hot-reload them without restarting. gdzig provides the Godot bindings. This project writes no bindings; it is the integration layer on top of gdzig.

**Non-goals for v1.**
- No new bindings and no gdzig fork. Fixes go upstream.
- No Windows or macOS support yet. Linux x64 comes first, but every decision keeps both in mind (section 4).
- No networking inside the extension. v1 uses a configured Zig path or the one on `PATH`. A toolchain downloader is stage 7 work and needs a signature check against a pinned public key.
- No script-to-script inheritance (the descriptor format reserves room for it).
- No safe unloading of old module generations (section 6).
- No Godot version other than 4.7.2, and no double-precision builds.
- No native threads or `WorkerThreadPool` tasks started from user code (section 6).

## 2. What the research and reviews established

Full reports are in `../research/` (private workspace, next to this repository). Facts that drive the design:

**J.E.N.O.V.A** (`jenova-runtime.md`). A full script backend, not a GDExtension wrapper: `ScriptLanguageExtension` plus `ScriptExtension` plus `script_instance_create3`. All scripts compile into one library. Its "interpreter" exists only because C++ cannot generate call wrappers, so signatures are recovered after linking (linker MAP files on Windows, `gdb` on Linux) and called through a runtime FFI. Problems we do not copy:
- one shared memory slot per property, swapped in and out around every call (not reentrant, not thread-safe);
- reload unloads the old module before loading the new one, with no rollback; on Linux old modules are never unloaded and are loaded with `RTLD_GLOBAL`;
- the build busy-waits on the main thread, and compile errors never reach the script editor;
- `_validate` and all debugger hooks are stubs; scripts work only on Node owners; no placeholders, no inheritance;
- most user-reported problems come from networking and package-manager code linked into the extension;
- its module runs its own godot-cpp with the host's library token and casts objects across the two godot-cpp copies. Our design avoids that because gdzig engine classes are opaque (an engine object is just its Godot pointer; no per-object wrapper data).

**Godot 4.7.2 script contract** (`godot-script-contract.md`, plus review). Key points:
- `Object::get_script()` returns `script_instance->get_script()`, so the instance must hold a strong reference to its Script. A null `_instance_create` result silently drops the script.
- Nearly every virtual is "required", but nothing checks that at load time. A missing one logs once and returns zero. Some zero returns do damage: a null `_make_template` crashes the Create Script dialog, and the default `_auto_indent_code` replaces user code with an empty string.
- `script_instance_create3` keeps the info table pointer without copying it, so the table must be static.
- A null `refcount_decremented_func` leaks every RefCounted object that carries the script.
- `callp` receives an uninitialized call-error struct. Always set it. `INVALID_METHOD` is the only code that falls through to engine methods.
- In the editor, non-tool scripts get placeholder instances. Scene values survive saving only if `_has_property_default_value` is true for them. While a script is broken or has no descriptors, `_is_placeholder_fallback_enabled` must be true, otherwise saving the scene drops every script value and signal connection.
- The engine enables processing only if `has_method` reports `_process` and friends, and only at READY.
- **`_frame` is not a safe point.** `Main::iteration()` runs nested inside functions a script can call (for example `EditorInterface.make_mesh_previews` calls it twice, `editor_interface.cpp:218-219`), and every nested iteration calls `language->frame()` (`main.cpp:5107`). Re-checked: verified.
- Recovery mode loads no GDExtensions (`gdextension_manager.cpp:115-117`, re-checked), so a panic that kills the editor can leave the project unopenable with our language.
- `_get_global_class_name` runs on the file-scan thread and can only parse text cheaply. Duplicate global class names overwrite each other silently.
- GDExtension `reloadable = true` does not update script-instance tables that live in the unloaded library. A language extension must ship `reloadable = false`; user code reloads as a separate library (the way C# does).
- On save, the editor tells the running game to reload scripts immediately (`script_editor_plugin.cpp:768`). The game is a separate process.
- 4.7 falls back to a plain-text highlighter unless an `EditorSyntaxHighlighter` is registered for the language (#121288 open; not verified in source).
- `EditorPlugin._build()` runs before Play.

**Zig 0.17.0** (`zig-integration.md`, plus review; x86_64 Linux unless stated):
- `std.DynLib` has no Windows implementation. On Linux without libc it uses Zig's `ElfDynLib`, which does no relocations, TLS or init and segfaulted on first thread-local access. We write our own loader. Modules link libc.
- gdzig builds and passes its in-Godot test suite (133/133) with the self-hosted backend. Incremental rebuild after a function-body change took 14 to 26 ms; LLVM took 3.6 s.
- **Incremental warm-up is expensive** (review, 300 synthetic scripts with 30 fields and 30 methods each): non-incremental cold build 5.4 s; first incremental update 86 s; the same again after a compiler-server restart 80 s (no state survives); later body edit 20 to 26 ms; later field-default edit about 265 ms. Small gdzig-only projects warm up in 14 to 20 s. Stage 0 measured with a different generator and found shorter warm-ups but slower body edits at 300 and 1000 scripts (section 12).
- Incremental builds have broken debug info (gdb and lldb). Non-incremental builds work with lldb.
- Windows self-hosted DLLs crashed under Wine (not tested on real Windows). macOS incremental linking panics.
- Compile errors come back as a binary `ErrorBundle` over `--listen`, decodable with `std.zig.ErrorBundle`. **Errors raised inside SDK code point at the SDK's file** (for example `ziggurat.zig:92`) with "called at comptime here" notes, not at the user's line.
- **A module can import only files below its root file's folder** (`error: import of file outside module path`, re-checked). A root file in the cache folder cannot import project files. Also, a file may belong to only one module, so one module per script fails when scripts share helpers.
- The compiler's output file is rewritten in place by incremental builds and left as partial garbage after failed builds. Never load it directly.
- Each module file is about 15 MB (24.6 MB incremental), plus 256 KiB of thread-local storage per thread that touches it. 100 reloads take about 2.5 GB on disk.
- `@typeInfo` is struct-of-arrays (`field_names`, `field_types`, `field_attrs` with `defaultValue()`, `decl_names`). `decl_names` lists only `pub` declarations. Parameter names are unavailable. Unused function bodies are never analyzed, so compile-time checks do not cover them.
- A panic in user code aborts the process; recovery is impossible. gdzig ignores a user's `pub const panic`.
- `std.fs.getAppDataDir` was removed. Per-OS directory logic is ours.
- Export: iOS and web cannot practically load a separately compiled module; link everything into one library per platform.

**gdzig behavior across two copies** (review, verified by source and experiments):
- Godot does not call into a user copy because of the host's library token. Opaque classes need no instance bindings, and `Object.destroy`'s binding is freed in the same call.
- All Variant, String, StringName, Array and Dictionary values live on the engine heap (`engine_allocator` has no state), so any copy can free them. Memory from a copy's own Zig allocator or pools must be freed by the same copy.
- `StringName.fromComptimeLatin1` returns a cached static name that must never be `deinit`ed. Doing so double-frees; Godot then prints "Unreferenced static string" while holding the StringName table lock, calls our `_debug_get_current_stack_info`, which creates a StringName, and **deadlocks**. This was the hang and the "ObjectDB leaked" warning in the spike, found with gdb. gdzig has the same bug (`Callable.mixin.zig:24-25`).
- gdzig Variant helpers are unsafe at the boundary: `Variant(Resource).as(*Node)` returns a non-null pointer; `as(*Node)` on a freed node returns a dangling pointer; scalar `f32`, `i32`, `u64` do not compile; enum conversion from an out-of-range int panics; `Variant.init` on a fresh RefCounted leaks it (init refcount 1 plus one added by the Variant).
- Lazy caches (method-bind pointers, static names) are written without atomics and race under threads.
- `classdbGetMethodBind` returns null when no method matches (custom engine builds), and ptrcall dereferences it.

**Spike** (`../research/spike/`, Godot 4.7.2 headless): a gdzig host registered "Zig" as a script language; Godot created instances through our `ScriptExtension` and `script_instance_create3` and delivered `READY`; a separately built library used gdzig in bindings-only mode with the host's entry point and renamed real nodes; two copies loaded at once. gdzig needs `@setEvalBranchQuota(100_000)` in `virtualMethodNames` for classes with many virtuals (the spike used a patched copy). On a project's first editor start Godot itself segfaults during extension doc generation (a deferred call runs after `EditorHelp::cleanup_doc()`); this is godotengine/godot#111645 and #111048, fix PR #123658 open. Workaround: pre-create `.godot/extension_list.cfg`.

**Stage 0 spikes** (`../research/stage0/`, one `RESULT.md` per spike; Zig 0.17.0, Godot 4.7.2, x86_64 Linux). Verified:
- **Root location** (`s1-root/RESULT.md`). A hidden generated root `<project>/.ziggurat_root.zig` builds a multi-folder project, also with spaces, non-ASCII letters, `"` and `\` in paths. Godot's file scan skips dot-files, so the root is not in the filesystem cache and gets no `.uid`. The scan honors `.gdignore` but does not skip `addons/`. A read-only project builds from a mirror copy in the cache folder, with error paths mapped back (section 5).
- **Warm-up** (`s2-warmup/RESULT.md`). Numbers in section 12. **An `@export` inside a generic function goes stale under incremental compilation:** after a field change in a script, the `ziggurat_describe` exported from the generic SDK function still pointed at the old table and code, and the update reported 0 errors. A non-incremental build of the same sources passes, and so do exports declared in the generated root (tested at 50 scripts; section 5). Incremental outputs are sparse files about 2.7 times the size of a non-incremental build (677 MB apparent size at 1000 scripts).
- **Generation swap and migration** (`s3-swap/RESULT.md`). Two gdzig copies; fields moved by name and type, dropped fields logged, the `migrate` hook, the old `deinit`; a same-layout swap keeps the data pointer; a swap requested inside a script call waits for `_frame`; instance data and the user heap end at 0 bytes; 20 runs out of 20. The strong-reference fix holds: `get_script()` is non-null after `set_script` and after a swap. **A half-truncated `.so` passed `dlopen` and ran** (the cut removed only debug sections and the section headers), so the loader checks ELF completeness before loading, with checked arithmetic: an unchecked sum on a corrupt header crashed the Debug host.
- **RefCounted objects made from Zig** (host check). An object made with `ScriptExtension.init()` already holds one counted reference and `refcount_init` is spent, so Godot's `Variant(Object *)` constructor adds a second one. The creator drops its creation reference after building the Variant; otherwise the script leaks at exit.
- **Game-process reload** (`s4-game/RESULT.md`), with a fake editor that speaks the real remote debugger protocol. `reload_scripts` arrives as `_reload_scripts(scripts, soft_reload=true)` at the end of the game's frame; `reload_scripts` with an empty path list never reaches the language. The manifest flow swaps, keeps the generation when the build is not staged yet, and rejects bad manifests (section 6). `_reload_scripts` and `_add_global_constant` are required virtuals in 4.7.2. **Debugger packets must be written from one buffer:** `StreamPeer.put_var` writes the length and the payload in two writes, and the game drops the connection.
- **Stripped-source export** (`s5-export/RESULT.md`). Section 10.
- **GUI editor** (`s7-gui/RESULT.md`, automated, on a virtual X display). The host loads, Create Script offers Zig, a tool script swaps live in the edited scene, and a scene saved after the swap keeps the swapped values. A null `_make_template` crashed the editor (signal 11 in `ScriptCreateDialog::ok_pressed`). Without a pre-created `extension_list.cfg` the GUI first start does not crash, but Create Script lists Zig only after a restart. Saving a scene saves every open script, and the editor rewrites `.zig` files with tab indentation (`convert_indent_on_save`). Non-tool Zig scripts ran inside the editor, both during `--import` and in the GUI editor, because the spike host has no placeholder instances. gdzig's comptime branch quota blocks five more `ZigLanguage` virtuals (section 7).

**Not run in Stage 0:** Windows (deferred to stage 7) and macOS; double-precision builds; thread races (the spike gate used a single-threaded lock); nested `Main::iteration()` during a swap; a release (not Debug) export build; the six manual checks of the GUI editor on a real desktop (`s7-gui/MANUAL.md`).

## 3. Architecture

Five layers; each depends only on layers below it.

```
L5  Editor plugin      menus, build panel, diagnostics, highlighter, templates
L4  Script backend     ScriptLanguage, Script, ScriptInstance, placeholders, loader/saver
L3  Module runtime     loads built modules as generations, gate, reload, state migration
L2  Build service      drives zig, decodes errors, caches, backend policy
L1  Platform services  PathService, DynamicLoader, process spawn, GenerationStore
L0  gdzig              bindings
```

L1 and L2 have no Godot dependency. L4 passes in everything Godot-specific (for example the project root); `globalize_path` is called in L4, never in L1.

**Two binaries.**
- **Host** (`ziggurat_host`): built with gdzig, `reloadable = false`, stable. Contains L1 to L5. It owns its GDExtension entry point (gdzig's does not keep `get_proc_address`) and passes it to user modules. `compatibility_minimum` and `compatibility_maximum` are both 4.7.
- **User module**: rebuilt constantly. Contains the user's scripts, a generated root, and the `ziggurat` SDK. Uses gdzig in bindings-only mode (sets `gdzig.raw` from the host's entry data; registers no classes).

**The only contract between them** is one C-ABI table, returned by `ziggurat_describe`:
- It starts with a magic number, an ABI version and a size field.
- It carries a **layout stamp computed at compile time** from the `@sizeOf` and `@offsetOf` of every boundary struct, the sha256 of the vendored `extension_api.json` and `gdextension_interface.h`, the Zig version, target, float precision and SDK version. A gdzig commit hash cannot be read from a path dependency, so it is not used.
- The host refuses any module whose stamp differs, and refuses to start unless Godot reports exactly 4.7.2 and no `double` feature.
- Then the script descriptors (section 8) and the generated wrapper pointers: create, destroy, call by name, get and set property, notification. The host copies descriptor strings at load instead of borrowing them.

**Boundary rules.**
- Engine objects cross as raw object pointers or ObjectIDs, never as copies of wrapper types. Only the host registers ClassDB classes.
- **The SDK is a curated surface, not a re-export of gdzig.** It exposes engine classes, builtin value types, and our own checked helpers, and withholds `Registry`, `ClassDb.register*`, Callable constructors from raw function pointers, and gdzig's `Variant` helpers. A script can create only Callables of the form (object, method name), which always resolve to the current generation.
- The SDK owns a **checked conversion layer** (below). User code and wrappers never call gdzig's Variant conversions directly.
- L4 talks to gdzig through its own thin wrapper layer, so gdzig API changes stay contained.

**Checked conversion layer (SDK).**
- Follows Godot's strict conversion rules (int and float, String and StringName, nil to null object). Integer narrowing is range-checked; engine enums are treated as non-exhaustive; every failure returns Godot's call-error code and never panics.
- Objects are resolved only through ObjectID (`objectGetInstanceFromId`), then `objectCastTo` with the class tag; a failed cast is `CALL_ERROR_INVALID_ARGUMENT`.
- `Ref(T)` is an owning RefCounted handle with Godot's first-reference semantics. Variant arguments are borrowed for the length of the call; storing one requires taking a reference.
- Comptime names are a separate type without `deinit` (never free static StringNames).
- Lazy caches are warmed on the main thread at module init.

**Ownership rules.** Engine-heap values may be freed by any copy. Zig-heap memory is freed only by the generation that allocated it. Instance memory comes from a host-provided allocator, so generation N+1 never frees memory that generation N's allocator allocated.

## 4. L1: platform services

Every path, library load and process spawn goes through these. No other code builds a path string or calls `dlopen`.

```zig
pub const OsPath = struct { bytes: []const u8 }; // WTF-8; built only through join()
pub const PathService = struct {
    pub fn init(roots: ProjectRoots) PathService;           // roots injected by L4
    pub fn dir(self: PathService, kind: DirKind, a: Allocator) !OsPath; // cache, config, temp, toolchain
    pub fn join(a: Allocator, base: OsPath, parts: []const []const u8) !OsPath;
    pub fn libName(t: std.Target, stem: []const u8, gen: u32) []const u8; // unique per generation
    pub fn importLiteral(a: Allocator, rel: OsPath) ![]const u8;          // forward slashes, escaped
};
pub const Loader = switch (builtin.os.tag) {
    .linux, .macos => @import("posix.zig"),
    .windows => @import("win.zig"),
    else => @compileError("unsupported OS"),
}; // each: open(OsPath) LoadError!Library; lookup(Library, comptime T, [:0]const u8) ?T;
   //       close(Library) void; describeError(buf) []const u8
pub const GenerationStore = struct { stage(built, extras) !Generation; pin(gen) Lock; sweep() void };
```

- **Per-OS directories.** Linux uses XDG; Windows `%LOCALAPPDATA%`; macOS `~/Library/Caches`.
- **Linux loader.** `dlopen` with `RTLD_NOW | RTLD_LOCAL`. **Windows loader.** `LoadLibraryExW` with explicit search flags and long-path (`\\?\`) handling, and a rename-then-delete policy for locked files. **macOS loader.** `dlopen`. Windows and macOS are compile-time stubs that fail with a clear message until implemented.
- **Hidden Linux assumptions to avoid.** `lib*.so` names (use `libName`), copying a loaded file, backslashes and quotes in generated `@import` strings, case-insensitive file systems (the build checks that script paths do not differ only by case), spaces and unicode in paths, read-only project folders, two editors sharing one cache folder (a lock file per cache entry).
- **GenerationStore** stages each build into its own folder, takes a lock file per generation, sweeps stale generations at editor start, and keeps those a running game still uses. A cap on count and total size applies (generations are about 15 to 25 MB each; incremental outputs are sparse files about 2.7 times the non-incremental size, so staging copies keep the holes).
- **Zig locator.** v1: a configured path, else `PATH`; the version is checked at startup. No downloads in v1.

## 5. L2: build service

- **Where the generated root lives.** A Zig module can import only files below its root file's folder, so the root cannot sit in the cache or in a subfolder. The build writes one hidden generated root file, `<project>/.ziggurat_root.zig`, that imports every script with one top-level `const` per script. Godot's file scan skips dot-files, so the root is not in the filesystem cache and gets no `.uid` (verified, Stage 0 spike s1-root). A cache-side build file imports it as module `project`. The script folders default to `res://`; the generator itself skips folders with `.gdignore` and `addons/`, because Godot's scan does not skip `addons/`. All builds run from one cache folder: Zig rebuilds its build runner for each new build folder.
- **Read-only projects.** When a probe write at the project root fails, the build writes the root and a mirror copy of the `.zig` files into `<cache>/mirror-<project id>/` and builds there. Error paths are mapped back by replacing the mirror prefix; Zig reports them relative to the build folder, so the mapping handles relative and absolute paths. The mirror is re-synced on every build. A symlink farm also works on Linux, but it needs symlink rights on Windows.
- **The generated root owns the C exports.** `ziggurat_init` and `ziggurat_describe` are non-generic functions declared in the generated root, which refers to each script's compile-time descriptor table; the SDK provides non-generic init code and emits no exports. An export from a generic SDK function instantiated per script type went stale under incremental compilation after a field change, with 0 errors (Stage 0 spike s2-warmup; section 13). As a second check, after each incremental update the build service compares the output's tables with the sources (for example each script's layout hash), because a swap that silently keeps old code is worse than a failed build. In a static export build there are no module exports at all.
- **Which files are scripts.** A file with a top-level `pub const extends`. Other `.zig` files compile as helpers inside the same module. Helpers that fail to compile standalone, `test` blocks, and same basenames in different folders were tested and are fine.
- **One module for all scripts**, as verified: a file cannot be in two modules, type identity would split, and each module carries its own 10 to 15 MB of std and gdzig. Body edits stayed at 20 to 26 ms with 300 scripts (earlier research; Stage 0 measured 39 ms median, 131 ms first edit, section 12). To avoid replacing every script on each swap, the descriptor carries a **layout hash per script**; if it is unchanged, only function pointers swap and the instance data stays.
- **One declaration per script.** The root describes each script in its own top-level `const`. Describing 300 scripts in one comptime block exceeded the branch limit.
- **Optional extras.** `ziggurat.zon` lists extra package dependencies, merged into the generated build. Users do not own `build.zig` in v1.
- **Driving the compiler.** The compiler server (`--listen`) returns an `ErrorBundle`. Errors from SDK code carry the script's path in their message; the host maps them to a line with a text scan, so the script editor shows a line for these too. `_validate` only reads cached diagnostics; it never compiles. A `--listen` session refuses `-femit-bin`, so the service finds the output through the `emit_digest` message and copies it out after each clean update.
- **Triggers.** Save, Play (`EditorPlugin._build`), a manual button, an optional file watcher, and a **build at project open**. Builds run off the main thread, one at a time; triggers during a build merge into one follow-up build.
- **Backend policy** (table keyed by target, overridable in settings):

| Platform | Default | Reload latency | Status |
|---|---|---|---|
| x86_64 Linux, session start | LLVM or self-hosted non-incremental | seconds | measured (5.4 s for 300 scripts; 6.4 s in Stage 0) |
| x86_64 Linux, after warm-up | self-hosted + incremental | 20 to 94 ms body edit (median), first edit up to 275 ms | measured (section 12); warm-up 3 s to 86 s by project size and shape |
| x86_64 Linux debug build | LLVM, non-incremental | about 3.6 s | incremental debug info is broken |
| Windows | LLVM | seconds | self-hosted crashed under Wine; real Windows unchecked |
| macOS | LLVM | seconds | incremental panics |

Every editor session starts with a non-incremental build and warms the incremental compiler server in the background; the incremental path is an optimization on a correct slow path, never a requirement.
- **Script naming rules.** Zig `camelCase` maps to Godot `snake_case`; the mapping copies Godot 4.7.2's own `String::to_snake_case` (`_separate_compound_words`, `core/string/ustring.cpp`) exactly: a break goes before an uppercase letter that follows a lowercase letter, before the last capital of an uppercase run when a lowercase letter follows (`HTTPUrl` gives `http_url`), and at letter/digit boundaries (`vec2` gives `vec_2`). A capital run stays one word, so `getHealthHUD` gives `get_health_hud`. The mapping loses information, so two names that map to the same Godot name are a compile error. Because the digit rule differs from Godot's hand-written names (`vector2`), a script can set the Godot name explicitly with a name override in its metadata. A leading `_` means "private" for fields but "Godot virtual" for functions.
- **Panic handling.** The generated root installs a panic handler that logs to Godot and then aborts. Recovery is impossible by nature; the design makes it visible, not survivable. Editor builds use Debug or ReleaseSafe, because ReleaseFast silently returns garbage on out-of-bounds access. In the editor, a panic only occurs through tool scripts; non-tool scripts run in the separate game process.
- **Debugging.** A separate non-incremental "debug build" for attaching lldb.

## 6. L3: module runtime and reload

A **generation** is one successfully built, validated module, staged in its own folder by `GenerationStore`.

**The gate.** Every entry from Godot into module code (callp, notification, get and set, create, free, refcount callbacks, Callable calls) goes through a reader-writer gate with a main-thread depth counter. A swap runs only when the depth is 0 and the write lock is acquired with a **try-lock**, so the main thread never blocks on a thread that is itself waiting on the main thread; if the try-lock fails, the swap retries next frame. `reload()`, `_reload_scripts` and `_reload_tool_script` only queue work; they never swap, because Godot's nested `Main::iteration()` can call `_frame` while a script's own frame is on the stack.

**Reload sequence** (swap steps run from `_frame` under the gate):
1. Build produces a new module and descriptors (off the main thread).
2. Check that the staged copy is a complete ELF file (section headers and `PT_LOAD` segments inside the file, every offset sum done with checked arithmetic), then load the new generation next to the old one (`RTLD_LOCAL`, unique path). `dlopen` accepts a library whose tail is cut. The check is size consistency, not integrity; a content hash written by the build would close that gap.
3. Validate magic, ABI version, layout stamp and the descriptor table. On any failure, unload the new generation, keep the old one, and report the error. Nothing has changed yet. A swap request targets the latest generation that loaded and validated, never a rejected one.
4. Migrate state, per instance, as a **move**: copy every field whose **name and exact type identity** match from old to new (never re-run init, because a copied pointer set in `_ready` must stay valid); call the new generation's optional `migrate` hook; reset each moved field in the old instance to its default (from the defaults image in the table; `base` is not reset); then call the old generation's `deinit`, which releases only what was not moved, such as engine references held in old state. Without the reset, owned memory moved to the new generation is freed by the old `deinit`. Removed fields or changed types are dropped with a warning. When a script's layout hash is unchanged, the instance data stays in place and neither `migrate` nor `deinit` runs. Verified in Stage 0 spike s3-swap.
5. Swap each instance to the new generation, update script descriptors and refresh every placeholder.

**Accounting.** Live bytes per generation count only the instance data the host allocated for that generation. The user heap behind `z.allocator` is shared by all generations. A same-layout swap moves the data block's tag to the new generation.

**Open for stage 4: calls back into an instance during migration.** `deinit` and `migrate` run under the swap write lock today, so a call from that code back into an instance deadlocks on the gate. Either the swapping thread may re-enter, or `deinit` and `migrate` run outside the write lock with the instances marked as swapping.

**While code is broken** the last good generation keeps running, placeholders stay on with fallback enabled, and the last good descriptors feed the Inspector.

**Where descriptors live.** In the project (under `.godot/`), not in the per-user cache, so a restarted editor or a fresh machine still has them after the first build. When a script has no descriptors, `_is_valid` is false and `_is_placeholder_fallback_enabled` is true, so scene values and signal connections survive saving. A build runs at project open.

**Unload policy.** Old generations are not unloaded in v1; old code can still be reached through Callables and similar. This is safe to rely on because: only (object, method) Callables are allowed, and they resolve to the current generation; native threads and `WorkerThreadPool` tasks from user code are forbidden in v1; and old instance memory is released by `deinit` at migration. Memory cost is about 15 to 25 MB per reload on disk and in the address space, plus 256 KiB of thread-local storage per thread that touched the module. The host counts generations and warns or evicts at a limit. Exported games never reload. Safe unloading is stage 7.

**Instances** hold a strong reference to their Script, an owner pointer (any Godot object), and a pointer to module-owned instance data tagged with its generation.

**The running game.** Non-tool scripts run in a separate game process.
- On save the editor tells the game to reload scripts immediately, and the build may not be done. The editor therefore writes an **atomic generation manifest** at `.godot/ziggurat/manifest`: exactly the two lines `gen=<n>` and `path=gen/<n>/<library>`, written to a temporary file, synced with `fsync`, then renamed. The game's `_reload_scripts` and `_reload_all_scripts` only read the manifest and queue; the swap runs at `_frame`. A reload that arrives before the build is staged keeps the current generation and is logged, not an error; the editor sends another reload after staging. `reload_scripts` with an empty path list never reaches the language, so the editor always lists at least one script.
- **Trust.** Debugger messages (`reload_scripts`, `reload_all_scripts`) carry no trusted path; loading a library from a path you are sent is arbitrary code execution. The game reads only the on-disk manifest and loads only files inside `realpath(.godot/ziggurat)`: limits on file size and line length, no NUL bytes, a decimal generation number in range, a relative path with a fixed character set, no `.` or `..` components, no absolute paths, no symlinks that leave the folder, a regular file, a manifest that is itself a regular file and not a symlink, and a re-check right before loading. All of these are implemented in Stage 0 spike s4-game. Tested there: a `..` component, an absolute path, a symlinked file and a symlinked folder that leave the folder, NUL bytes, a file over the size limit, a line over the length limit, a generation number that does not fit or is out of range, an extra line and an empty file. Not tested: the character set, `.` and empty components, the regular-file check, a symlinked manifest, and the re-check before loading. **Required for stage 4:** the path must start with `gen/<gen>/`, and a path already loaded under another generation is refused. The spike reader does not tie the path to the generation, so `gen=3` with `path=gen/2/...` passes every check and runs `ziggurat_init` again on a live module as generation 3. This protects against a manifest that points elsewhere, not against a hostile writer inside the folder. The re-check narrows the window between check and load but does not close it; loading through an open file descriptor would.
- The manifest path exists only in debug builds and editor-launched games. Export builds compile it out with a compile-time option (no symbol and no manifest path string remain, verified in s4-game).
- In an editor-launched game the manifest swap worked when `reload_scripts` arrived (Stage 0 spike s7-gui). After one save path, `EditorInterface.save_scene()`, no `reload_scripts` reached the game, for no known cause (section 14). Until that is understood, the editor plugin also sends `reload_scripts` itself through `EditorDebuggerSession.send_message`.

## 7. L4: script backend

Implements the full contract, with no stubs for required virtuals:
- **`ScriptLanguageExtension`:** name, type, extension (`zig`), recognized extensions, templates (never null: a null `_make_template` crashed the Create Script dialog in Stage 0; `make_template` rejects a quoted script path as parent class), `_validate` from cached diagnostics, `_handles_global_class_type`, `_get_global_class_name` (see below), `_reload_scripts` (re-read from disk, filter to own scripts), `_add_global_constant`, `_add_named_global_constant` and `_remove_named_global_constant`, `_reload_all_scripts` and `_reload_tool_script` (queue only; note `_reload_all_scripts` also fires when any other extension reloads), `_frame` (swap point under the gate), `_thread_enter` and `_thread_exit`, `_auto_indent_code` (returns input unchanged), `_get_documentation` (returns an empty array), `_supports_builtin_mode` (false), `_can_inherit_from_file`, `_validate_path`, `_complete_code`, `_lookup_code`, `_profiling_*`, `_debug_get_stack_level_*`, `_get_public_*`, and a **thread-safe, lock-free `_debug_get_current_stack_info`** that creates no StringNames (see deadlock in section 2) and is exercised once at init.
  Verified in Stage 0: `_reload_scripts` and `_add_global_constant` are required in 4.7.2 (without them the game logs an ERROR per reload and per autoload), and the editor also requires `_add_named_global_constant` once a project has an autoload. gdzig's comptime branch quota currently blocks adding five virtuals (`_add_named_global_constant`, `_remove_named_global_constant`, `_complete_code`, `_lookup_code`, `_auto_indent_code`); this needs a gdzig change (sections 13 and 14).
- **`ScriptExtension`:** `_can_instantiate` copies GDScript's rule (valid, and tool or scripting enabled, and not recovery mode); Stage 0 confirmed the gap this closes: with an always-true `_can_instantiate` and no placeholder instances, non-tool Zig scripts ran inside the editor, both during `--import` and in the GUI editor; `_instance_create`, `_placeholder_instance_create` and `_placeholder_erased`; `_update_exports` is **idempotent**: it does nothing unless the descriptor generation changed (Godot calls it once per property during scene save); `_has_property_default_value`; `_is_placeholder_fallback_enabled`; `reload` (queue; the return value is defined, and running an EditorScript requires a blocking build or a clear error); tool flag, per script (the spike kept one per generation); base type; `_is_valid`, `_has_script_signal`, `_get_script_signal_list`, `_get_members`, `_get_constants`, `_get_member_line`, `_get_rpc_config` and `_get_method_info` from the descriptors. RPC config is cached per object and never refreshed, so RPCs added by a reload are ignored; document this.
- **Global classes.** Register a global class only when the script has an explicit `pub const class_name`. A cheap text scan returns it on the scan thread, with `base_type` and `is_tool` in the returned dictionary. File names are not used as class names, because duplicates overwrite silently.
- **`ScriptInstance`** (static info table; every callback provided): set, get, property list; `call` (always sets `r_error`; unknown method returns `INVALID_METHOD`); `has_method` from the descriptor; notification (forward and reversed order); refcount callbacks (decrement returns true); `get_property_state` returns **every STORAGE property** (PackedScene and the Inspector dock depend on it); property revert; owner, script, language, to_string, free. Callbacks handle `language == null`, because host class objects can be destroyed after the host's CORE deinitialize.
- **Resource loader and saver** for `.zig`. The loader has no side effects (the editor loads a second Script object for the same path with `CACHE_MODE_IGNORE`; loaders can run on worker threads), returns the Script even if it fails to compile, and in exports resolves the script path without the source file: it answers each registered `res://...zig` path from the linked registry, fails cleanly for unknown paths, and implements `_exists` from the same registry. The saver is required, because Create Script and every script save go through `ResourceSaver`; a Script keeps the file text for the script editor apart from the code that runs. On scene save the editor saves every open script and rewrites indentation with tabs (`convert_indent_on_save`, verified in Stage 0), so the build accepts tab-indented files or the plugin changes that setting for Zig.
- **Shutdown.** The `ZigLanguage` object is destroyed in the SCENE-level exit (this removes the "1 ObjectDB instance was leaked" warning). Host deinit does not free pools, allocators or the registry; gdzig's stock cleanup in `entrypoint.zig` would be unsafe here.
- **A checklist** built from the Godot report's pitfall list and this section is part of the stage 3 definition of done.

## 8. Script shape and descriptors

A script is one `.zig` file, and the file is the struct. Example:

```zig
const z = @import("ziggurat");
const g = z.godot; // curated gdzig surface

pub const extends = g.CharacterBody2D;
pub const class_name = "Player";   // optional; required for a global class

base: *g.CharacterBody2D,   // reserved: filled in by the host, never exported
speed: f32 = 300,           // exported; every non-base field must have a default
health: i32 = 100,          // exported
_dash_timer: f32 = 0,       // leading underscore: private, not exported

pub const meta = .{ .speed = .{ .range = .{ 0, 1000 }, .group = "Movement" } };

pub const signals = struct {
    pub const died = struct {};
    pub const hit = struct { damage: i32 };
};

pub fn init(self: *@This()) void { ... }                 // optional
pub fn deinit(self: *@This()) void { ... }               // optional; releases owned memory
pub fn migrate(self: *@This(), old: z.Previous(@This())) void { ... } // optional
pub fn _physicsProcess(self: *@This(), delta: f64) void { ... }
pub fn takeDamage(self: *@This(), amount: i32) void {
    self.health -= amount;
    z.emit(self, .hit, .{ .damage = amount });
}
```

Rules:
- Fields are exported unless their name starts with `_`. The type must convert to a Variant through the checked layer; otherwise the build fails with an error naming the field. Every non-`base` field needs a default (a field with no default, or `= undefined`, is a compile error, because Zig otherwise fails with an unhelpful message or silently gives no default). All fields come first in the file (Zig rejects declarations between fields).
- Extra options live in `pub const meta`, checked against real field names at compile time. Wrapper types like `Export(f32, ...)` were rejected because they change the field type.
- `pub fn` is callable from Godot; non-`pub` is private. Engine callbacks are plain `pub fn`s found by name. Parameter names are unavailable, so exposed methods show as `arg0, arg1` unless `meta` names them.
- Signals are a nested struct; fields give argument names and types. Emitting is checked at compile time for analyzed code. The SDK makes the exported functions analyzed; bodies of unused private functions are not analyzed by Zig, so this check does not cover them.
- `get_<name>` and `set_<name>` as `pub fn` override direct field access.
- Instance memory is allocated by the host through `z.allocator(self)`. Owned memory in private fields must be freed in `deinit`.
- `base` can be any Godot object. Tool scripts: `pub const tool = true;`. `extends` takes an engine class in v1; the class name comes from an explicit `class_name` declaration, because `@typeName` of the type is a long path.

**Descriptors.** `ziggurat_describe` returns the table of section 3. Per script: path, class name, base class, tool flag, layout hash, a defaults image (every field at its default, used to reset moved fields and to fill new ones at migration); per property: name, Variant type, hint, hint string, usage, default (from field defaults, evaluated at compile time); per method: name, argument types, return type, flags; per signal: name, argument names and types; plus the generated wrapper pointers. The call wrapper checks each Variant argument through the checked conversion layer and returns Godot's call-error code on mismatch instead of panicking. The host saves a plain-text copy of every good table under `.godot/`.

## 9. L5: editor plugin

Build button and Build-on-Play (`_build`), a build panel with diagnostics, errors in the script editor through `_validate`, a registered `EditorSyntaxHighlighter` (otherwise 4.7 shows plain text), script templates, settings (Zig path, backend override, script folders), and per-generation status. Registered at EDITOR initialization level.

## 10. Export

The export plugin builds one library per target platform with every script linked statically and registered at startup (no dynamic module loading, no `dlopen`), and uses a deterministic release build, not the editor's last build. Scenes reference `res://x.zig`, but sources are left out of the package: an `EditorExportPlugin` skips every `.zig` file, and the host's loader answers the path from the linked registry. Godot 4.7.2 release builds hand `res://x.zig` to the loader without checking that the file exists (the existence check is editor-only), so no stub file is needed (verified, Stage 0 spike s5-export; a stub file per script, as C# does, stays the fallback if a later Godot checks first). The plugin is required: a default export ships `.zig` sources verbatim. Open gaps: the spike built Debug, not the deterministic release build; scenes saved by the editor reference scripts by uid, which was not tested with stripped sources; release templates reject `--main-pack`, so tests run the `<exe>.pck` next to the binary. Linux first; the target glibc version is pinned. Web and iOS require static linking, which this design already uses. Android needs the NDK for libc builds.

## 11. Testing

- L1 and L2: plain `zig build test`, with Windows and macOS cross-compile of L1 and L2 in CI from stage 1.
- SDK, conversions and descriptors: in-Godot tests through gdzig's harness.
- L3 to L5: headless Godot 4.7.2 scenes. The harness pre-creates `.godot/extension_list.cfg` to avoid the first-start crash.
- Reload stress test: hundreds of reloads with property changes, removed properties, failing builds, a multi-threaded caller, and a script that triggers nested `Main::iteration()`; check for crashes, deadlocks and ObjectDB leaks.
- Fuzz tests for the `ErrorBundle` decoder and for host-side validation of descriptor tables from untrusted modules.
- Regression tests for each verified bug: static StringName double-free deadlock, Variant type confusion, enum out of range, RefCounted leak, scene save with no descriptors.
- Each stage has a written definition of done. Nothing is called done without a run that shows it.

## 12. Stages

**Stage 0: spikes before committing to the plan**, each with pass or fail criteria. Results are in `../research/stage0/RESULTS.md` and section 2.
1. **Root location:** the hidden generated root at the project root builds a multi-folder project; Godot's file scan ignores it; a read-only project has a defined fallback. **Pass:** `<project>/.ziggurat_root.zig`, mirror fallback (section 5).
2. **Warm-up at 50, 300 and 1000 scripts:** the session-start non-incremental build plus background warm-up, and the swap with the warm server. Measured (Debug, self-hosted backend, x86_64 Linux, with other load on the machine, one sample per size):

   | Scripts | Session-start build (`build-lib`) | Full `zig build`, fresh cache | Warm-up | Body edit: first after warm-up / median of 5 | Field-default edit | Compiler peak memory |
   |---|---|---|---|---|---|---|
   | 50 | 2.7 s | 23.2 s | 3.3 s | 34 / 20 ms | 90 ms | 1.10 GB |
   | 300 | 6.4 s | 26.9 s | 11.8 s | 131 / 39 ms | 103 ms | 1.35 GB |
   | 1000 | 18.1 s | 37.5 s | 36.2 s | 275 / 94 ms | 227 ms | 2.02 GB |

   The session-start build assumes cached gdzig bindings; the full build adds the build runner, binding generation and translate-c. The bounds used were 3 s, 10 s and 30 s for the session-start build, 100, 100 and 200 ms for a body edit, and 1, 1 and 2 s for a field-default edit (50, 300 and 1000 scripts). They are provisional and not yet confirmed by the user. Against them the session-start build, the field-default edit and the median body edit pass at every size; the first body edit after warm-up fails at 300 and 1000 scripts. Which body-edit number counts is open (section 15). **The swap with the warm server failed** at every size while the exports came from a generic SDK function, and passed with exports declared in the generated root (tested at 50 scripts; section 5).
3. **Generation swap and migration:** two real gdzig copies, instance state migrated by name and type, `deinit` of the old generation, no leaks, no crash; plus the strong-reference instance fix (`get_script()` non-null after `set_script`). **Pass**, 20 runs out of 20 (section 6). Nested `Main::iteration()` during a swap was not exercised; the stage 4 stress test covers it.
4. **Game-process reload:** the manifest flow works with an editor-launched game. **Pass (game side)** with a fake editor speaking the real debugger protocol; with the real editor (spike 7) the swap works when `reload_scripts` arrives (section 6).
5. **Stripped-source export:** a scene with a script loads in an exported game. **Pass**, no stub file needed (section 10).
6. **Real Windows machine:** an LLVM DLL, `LoadLibraryExW`, rename and delete of old generations, MAX_PATH. **Not run:** deferred to stage 7.
7. **GUI editor:** the spike and the swap run in the real editor (all spike runs were headless). **Automated pass** on a virtual X display; six manual checks on a real desktop are pending.

Then: 1. L1 and L2 (platform and build services). 2. SDK, conversions and descriptors. 3. Script backend, first end-to-end: attach a script, see properties in the Inspector, run `_ready`. 4. Reload: gate, generations, migration, rollback. 5. Editor plugin. 6. Export. 7. Hardening: debug build and lldb setup, Windows and macOS bring-up (including Stage 0 spike 6), verify incremental on real hardware, toolchain downloader with signature check, script inheritance, safe unloading.

## 13. Upstream work and pins

- **gdzig:** the `@setEvalBranchQuota` fix; the `Callable.fromClosure` `deinit` bug; unsafe Variant helpers (`as(*Node)` type confusion and dangling pointers, `Variant.ptr`/`constPtr` returning the address of a parameter, `Variant.call` not compiling, enum panics); a null check on `classdbGetMethodBind`; atomic lazy caches; whether a supported "bindings only" mode is wanted (we set `gdzig.raw` from outside today, which works but is undocumented); the comptime branch quota in `VTable.findMethod` (100000), which blocks five `ZigLanguage` virtuals (section 7): a higher quota or a cheaper lookup.
- **Zig:** a candidate report: under `-fincremental`, an `@export` inside a generic function stays bound to the old instantiation after the instantiating type changes, and the update reports 0 errors (section 5). It has not been reduced to a minimal case or reported upstream.
- **Godot:** nothing to fix ourselves. First-start crash: #111645, #111048, PR #123658.
- Pin gdzig commit, Godot 4.7.2 and Zig 0.17.0, enforced through the layout stamp. Open Godot issues #121567, #120978 and #117946 indicate script API changes in 4.8, so a 4.8 port is separate work.

## 14. Risks

1. gdzig API churn (README warns of rapid change). Mitigated by the wrapper layer, the curated SDK and the commit pin.
2. Script-language traps in Godot. Mitigated by the checklist in section 7.
3. Incremental compilation is young and expensive to warm up. It is only the fast path.
4. Windows and macOS are unverified (Stage 0 did not run either; Windows is deferred to stage 7); the design avoids Linux assumptions, but that is a claim until real hardware runs it.
5. Memory and disk grow with each reload in long sessions (no unloading in v1). Incremental outputs are sparse files about 2.7 times the non-incremental size, multiplied by kept generations. The compiler server grew from 1.4 to 2.0 GB at 1000 scripts over nine updates after warm-up; growth over a long session was not measured.
6. A user-code panic in a tool script kills the editor and can leave the project in recovery mode. This cannot be recovered; it is reported clearly.
7. State migration ran in Stage 0 spike 3 on the main thread only, without nested `Main::iteration()` or callbacks into instances during `deinit` and `migrate` (section 6, open for stage 4).
8. Incremental compilation can keep old code with 0 errors: a generic `@export` went stale after a field change. Mitigated by root-owned exports and a table check after each update (section 5).
9. gdzig's comptime branch quota blocks five `ZigLanguage` virtuals. Until it is fixed upstream, the editor logs an ERROR at start for projects with an autoload, and typing in the script editor can log completion errors.
10. Live reload into an editor-launched game is not fully understood: after `EditorInterface.save_scene()` no `reload_scripts` reached the game, for no known cause, and the script editor's own File > Save path is untested until the manual checks run. Mitigated by the plugin sending `reload_scripts` itself.
11. GUI editor coverage is automated only, on a virtual X display; the six manual checks on a real desktop are pending.
12. A damaged module file can load if its size is consistent: the ELF check before loading is not an integrity check (section 6), and it skips the section-table bound when `e_shnum` is 0 (extended section numbering; Zig output does not use it).
13. Safe unloading (stage 7) has two known traps: each script's defaults image points into the module's read-only data, so a module must not be unloaded while a table or a moved field still refers to it; and instances freed after the host's shutdown at SCENE exit leak their data.

## 15. Decisions and open questions

Decided by the user (2026-10-07; the name override confirmed 2026-10-13):
- **Name:** Ziggurat, styled Z.I.G.G.U.R.A.T.
- **License:** MIT, same as Jenova-Runtime (verified through the GitHub API).
- **v1 Variant types:** start simple on a base that is tested: builtin value types, engine object pointers and enums. Typed arrays and dictionaries come after the checked conversion layer has tests.
- **Acronym rule:** copy Godot's algorithm (section 8), with an explicit name override. The override was confirmed with the spec approval on 2026-10-13.

Settled by Stage 0:
- **Hidden root:** `<project>/.ziggurat_root.zig`; read-only projects build from a mirror copy in the cache folder (section 5).

Open:

- **Warm-up bounds.** The bounds in section 12 are provisional and need the user's confirmation, together with which body-edit number counts: the first edit after warm-up or the median of several.
- **Callbacks during migration** under the swap write lock (section 6, stage 4).
- **Six manual GUI editor checks** (Stage 0 spike 7) on a real desktop, including the script editor's File > Save path into a running game.

## 16. Review log

Three independent reviews (Godot contract; host and module boundary with gdzig; Zig, OS-agnostic and coherence) found the following; each is reflected above.

| Finding | Severity | Where fixed |
|---|---|---|
| `_frame` is not a safe swap point (nested `Main::iteration`) | blocker | 6 (gate), 7 |
| Scene data lost when descriptors are missing (cache outside project) | blocker | 6 (descriptors in project, fallback) |
| Resetting private fields crashes the editor and can lock the project into recovery mode | blocker | 6 (migration by name and type), 8 (hooks) |
| Spike hang: double-freed static StringName deadlocks via `_debug_get_current_stack_info` | blocker | 2, 3, 7, 11 |
| gdzig Variant conversions are unsafe (type confusion, dangling, scalar compile errors, enum panics) | blocker | 3 (checked conversion layer) |
| Generated root cannot live in the cache folder | blocker | 5 (hidden root at project root), 12 spike 1 |
| Incremental warm-up costs 14 to 86 s and recurs each session | blocker | 2, 5 (session starts non-incremental) |
| Running game races the build; load-from-path is arbitrary code execution | major | 6 (manifest, compiled out of exports) |
| Ownership across the table (engine heap vs Zig heap, RefCounted leaks) | major | 3 |
| Version stamp insufficient | major | 3 (compile-time layout stamp) |
| Code pointers outliving a reload (Callables, worker tasks) | major | 3 (curated SDK), 6 |
| Instance lifecycle (`init`, `deinit`, `migrate`, allocator, defaults) | major | 8 |
| Generation size and disk growth | major | 4, 6 |
| SDK errors point at the SDK, not the user's line | major | 5 |
| Missing required virtuals, `can_instantiate`, global class names, `_update_exports` | major | 7 |
| L1 depends on Godot; networking in the extension | major | 3, 1, 4 |
| Export with stripped sources | major | 10, 12 spike 5 |
| Shutdown order and ObjectDB leak | major | 7 |
| Name mapping, field order, lazy analysis | minor | 5, 8 |

**Questions the reviews did not settle:** thread races, double precision, Windows and macOS, and everything inside the GUI editor. Stage 0 covered the GUI editor (automated); thread races, double precision, Windows and macOS remain open (sections 2 and 14).

**Revision 4 (2026-10-13): Stage 0 results.** Sections 2, 5, 6, 7, 8, 10, 12, 13, 14 and 15 take in the spike results: hidden root location and read-only fallback, root-owned C exports, migration as a move, the ELF check before loading, the manifest trust rules, required virtuals, stripped-source export, measured warm-up numbers and new risks.
