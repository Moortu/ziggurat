# Ziggurat

Ziggurat lets a Godot 4.7 project use Zig scripts (`.zig` files) next to
GDScript. Licence: MIT (`LICENSE`); third-party notices are in
`THIRD_PARTY_LICENSES.md`.

This version works in the Godot 4.7 editor on Linux x86_64, and exports
games for Linux x86_64 only.

## Install

1. Put this `addons/ziggurat/` folder into your project, either from the
   Asset Store or by unpacking the release zip into the project folder (the
   zip already starts with `addons/`).
2. Restart the editor. Godot loads the extension at startup; there is no
   plugin to turn on.

The `sdk/` folder holds the Zig sources your scripts build against, one
folder per platform (`sdk/x86_64-linux/`, `sdk/x86_64-windows/`): the
editor uses its own platform's folder, and an export uses the folder of
the platform it exports to. `sdk/` has a `.gdignore` file, so Godot does
not import it and exports leave it out. The export inputs of each platform
are in `bin/<platform>/`.

One zip holds the add-on for every platform: `ziggurat-0.1.0.zip` is
about 30 MiB (about 310 MiB unpacked), most of it the two SDK copies.

## Download Zig

Ziggurat needs Zig 0.17.0 exactly. The add-on does not include Zig.

- Easiest: Project > Tools > Download Zig 0.17.0. The editor downloads the
  official release once into your user folder
  (`~/.local/share/ziggurat/toolchains/`) and uses it for all projects.
- Or set the editor setting `ziggurat/zig_path` to a Zig 0.17.0
  executable. The project setting of the same name overrides it for one
  project. Without either, Ziggurat uses the downloaded Zig, then `zig` on
  `PATH`.

Ziggurat builds the project's Zig scripts when you save a script, when you
press Play, and with Project > Tools > Build Zig Scripts. The Zig panel at
the bottom of the editor shows the result and every error.

## Debugging with lldb

Normal editor builds are fast, but their debug information is not good
enough for a debugger: the first build of a session has lines and a stack
but no variables, and the later fast (incremental) builds have broken
debug information.

- Turn on the editor setting `ziggurat/build/debugger_builds` (Editor
  Settings > Ziggurat > Build). While it is on, every build uses LLVM and
  Debug mode without incremental compilation, so lldb can read it. Builds
  are slower, and the Zig panel shows "Debugger builds: on (slower, no
  incremental)". The change applies at the next build. A running game gets
  each new build as usual. Turn it off to get fast builds back.
- Many Linux distributions set `/proc/sys/kernel/yama/ptrace_scope` to 1.
  Then lldb cannot attach to a game that the editor started, unless lldb
  runs as root. Start the game under a debugger instead:
  1. In Debug > Customize Run Instances, set Main Run Args to
     `lldb-server gdbserver 127.0.0.1:1234 %command%`. Godot then starts
     the game through `lldb-server`, which is the game's parent, so
     `ptrace_scope` 1 allows it.
  2. Press Play, then connect from a terminal:
     `lldb -o "gdb-remote 1234"`.
  This route is not tested yet.
  Or run the game under lldb from a terminal, without the editor:
  `lldb -- godot --path <project folder>`. The add-on's tests check this
  way. The game then runs the last build and does not get new builds
  from the editor.
- Set breakpoints by file and line, for example `b player.zig:12`. That is
  more reliable than function names, because Zig names functions by their
  module path.
- `--export-debug` (or Export With Debug) builds the game library with its
  debug information. For Linux the export log says "Ziggurat: debug export
  keeps debug information, with this computer's file paths, and is not
  reproducible. Turn off Export With Debug for a release." For Windows the
  compiler writes the debug information to a separate `.pdb` file in the
  build cache, which the export does not ship; the DLL keeps only that
  file's name, and the log says so. A release export has no debug
  information.
- The editor setting `ziggurat/build/backend` chooses the compiler backend
  for normal builds: `auto` (the default), `llvm`, `self_hosted` or
  `self_hosted_incremental`. `debugger_builds` wins over it.

## Export

- Exports work for Linux x86_64 only in this version. An export for another
  platform finishes without Zig scripts, and the export log shows the error
  "Ziggurat exports Linux x86_64 only in this version".
- A Linux export builds the game library from your Zig scripts with Zig
  (ReleaseSafe), so Zig must be available as above. The `.zig` sources are
  not put into the exported game. The game runs on Linux with glibc 2.28 or
  newer.
- Godot's export dialog has "Export With Debug" on by default. A debug
  export keeps debug information in the game library. That information
  holds absolute paths from your computer (your project, SDK and cache
  folders, so your user name too), and the library is not reproducible.
  Turn "Export With Debug" off for a game you ship.
- Zig scripts are only exported with a full export (Export Project). A
  PCK/ZIP or patch export does not contain them: the export log shows an
  error, and a game that runs such a pack with the game library of an
  earlier export runs that export's Zig code.
- If the export fails (for example, a script does not compile), Godot can
  leave an incomplete game in the output folder. Do not ship it; fix the
  error and export again.
- In `ziggurat.gdextension`, the `template_debug` and `template_release`
  keys point into `res://.godot/ziggurat/export/`. This is by design: that
  file does not exist until the export builds it. Do not change these keys.
