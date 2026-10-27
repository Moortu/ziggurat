# Ziggurat

Ziggurat lets a Godot 4.7 project use Zig scripts (`.zig` files) next to
GDScript. Licence: MIT (`LICENSE`); third-party notices are in
`THIRD_PARTY_LICENSES.md`.

This version works in the Godot 4.7 editor on Linux x86_64 and Windows
x86_64, and exports games for Linux x86_64 and Windows x86_64. macOS
(Apple silicon and Intel, macOS 11.0 or newer) is experimental: see
"macOS" below.

Windows support is tested under Wine 11.19 only, never on a real Windows
machine. Under Wine, the Windows build of Zig 0.17.0 cannot compile
anything (a Wine limit), so a Windows editor that builds Zig scripts, or
exports a project with Zig scripts, is not tested at all. Tested under
Wine: a Windows game exported from the Linux editor runs; the Windows
editor loads the add-on, finds Zig and downloads it; the Windows editor
exports a Linux game from a project without Zig scripts.

## Install

1. Put this `addons/ziggurat/` folder into your project, either from the
   Asset Store or by unpacking the release zip into the project folder (the
   zip already starts with `addons/`).
2. Restart the editor. Godot loads the extension at startup; there is no
   plugin to turn on.

Upgrading from an older version: close the editor and delete the old
`addons/ziggurat/` folder first, then unpack the new one. Unpacking over an
older version leaves its old `sdk/` files (about 150 MiB) and two old
files in `bin/` behind. If you set the project setting
`ziggurat/dev/sdk_manifest` to the old `sdk/sdk-manifest.json`, clear it:
it keeps the old SDK in use.

On Windows, the Godot editor loads a copy of the add-on's library,
`addons/ziggurat/bin/~ziggurat_host.dll` (a hidden file), and leaves it
there while it runs. It is safe to delete when the editor is closed. Do not
commit or ship it; add this line to your project's `.gitignore`:

```
addons/ziggurat/bin/~*.dll
```

The `sdk/` folder holds the Zig sources your scripts build against, one
folder per platform (`sdk/x86_64-linux/`, `sdk/x86_64-windows/`,
`sdk/aarch64-macos/`, `sdk/x86_64-macos/`): the editor uses its own
platform's folder, and an export uses the folder of the platform it
exports to (a macOS export uses both macOS folders). `sdk/` has a
`.gdignore` file, so Godot does not import it and exports leave it out.
The export inputs of each platform are in `bin/<platform>/`, and the
macOS game library of a project without Zig scripts is in
`bin/universal-macos/`.

One zip holds the add-on for every platform: `ziggurat-0.1.0.zip` is
about 60 MiB (about 630 MiB unpacked), most of it the four SDK copies.

## macOS (experimental)

macOS is experimental: it is built on Linux and has not been tested on a
Mac. Nothing of it has run on a Mac yet: not the editor library, not the
Zig download, not an exported game. The checks so far only read the
files (their format, architectures, exports and signatures). When the
editor starts on macOS, its Output log says once: "Ziggurat on macOS is
experimental and has not been tested on a Mac."

- You need macOS 11.0 (Big Sur) or newer. The libraries are universal:
  one file holds the Apple silicon (arm64) and the Intel (x86_64) code.
- The libraries are not notarized. The arm64 code carries an ad-hoc
  signature (no developer identity), and the x86_64 code is not signed.
  Whether macOS accepts these two is not tested. A zip that you download
  with a browser is marked as "quarantined", and macOS may then refuse
  to load the add-on's library. Remove the mark from the add-on folder
  before you open the project (not tested on a Mac). In a terminal, in
  your project folder:

  ```
  xattr -dr com.apple.quarantine addons/ziggurat
  ```

- Project > Tools > Download Zig 0.17.0 is offered on macOS (Apple
  silicon and Intel). It downloads the official release into
  `~/Library/Application Support/ziggurat/toolchains/`. The download
  checks the file's size, SHA-256 and signature. This was tested on Linux
  with the real macOS files, up to the point where the downloaded `zig`
  would run; that `zig` was never started on a Mac. The folder name has
  a space; a test on Linux installs, finds and runs Zig from a folder
  with a space.
- Export with a **universal** preset (the macOS preset option Binary
  Format > Architecture set to `universal`, Godot's default). Godot's
  official export templates hold only universal programs, so a preset
  set to `arm64` or `x86_64` alone fails in Godot itself. Ziggurat
  always builds a universal game library; the game has it in
  `<game>.app/Contents/Frameworks/libziggurat_game.dylib`.
- Ziggurat checks a macOS export to a `.zip` or an `.app`. It does not
  check a `.dmg` or `.pkg` export (only a macOS editor can write those):
  make sure that the app inside holds
  `Contents/Frameworks/libziggurat_game.dylib`.
- When the export preset signs the app (Code Signing), Godot signs the
  game library again. On a Linux or Windows editor, use "Built-in
  (ad-hoc only)", Godot's default there; Godot then also turns on the
  "Disable Library Validation" entitlement. Godot 4.7.2 does not support
  `rcodesign` for an app that holds a GDExtension library: the export
  log shows the error "'rcodesign' doesn't support signing applications
  with embedded dynamic libraries." A signature with a developer
  identity needs Xcode `codesign`, which only a macOS editor offers (not
  tested). How macOS treats the app with the hardened runtime and
  library validation is not tested.
- A script's own `export fn` (a C symbol) makes the macOS export fail. On
  Linux and Windows the export hides such symbols, but Zig 0.17 cannot
  hide them in a macOS library, so the export check refuses the library
  ("The export library's ... slice exports ...; it may export only
  _ziggurat_host_init."). Use `fn` or `pub fn` without `export` in
  scripts.
- Each editor build gets its own library name inside the file (its
  "install name", `@rpath/libzmod-<n>.dylib`), so that macOS loads every
  new build instead of an older one it already loaded. All builds of one
  `self_hosted_incremental` compiler share one name. Hot reload on a Mac
  is not tested.
- The project setting `ziggurat/dev/sdk_manifest` (for working on
  Ziggurat itself) replaces the SDK of the Mac's own arch only. A macOS
  export then builds the other arch with the shipped SDK, so the two
  halves of the universal game library can differ.

## Download Zig

Ziggurat needs Zig 0.17.0 exactly. The add-on does not include Zig.

- Easiest: Project > Tools > Download Zig 0.17.0 (Linux x86_64, Windows
  x86_64, and macOS, untested). The editor downloads the official release
  once into your user folder (Linux: `~/.local/share/ziggurat/toolchains/`;
  Windows: `%LOCALAPPDATA%\ziggurat\toolchains\`; macOS:
  `~/Library/Application Support/ziggurat/toolchains/`) and uses it for
  all projects.
- Or set the editor setting `ziggurat/zig_path` to a Zig 0.17.0
  executable (`zig.exe` on Windows). The project setting of the same name
  overrides it for one project. Without either, Ziggurat uses the
  downloaded Zig, then `zig` on `PATH`.

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
  file's name, and the log says so. For macOS the debug information also
  stays in the build cache; the library keeps only the paths of those
  files, so it is not reproducible, and the log says so. A release export
  has no debug information.
- The editor setting `ziggurat/build/backend` chooses the compiler backend
  for normal builds: `auto` (the default), `llvm`, `self_hosted` or
  `self_hosted_incremental`. `debugger_builds` wins over it.

## Export

- Exports work for Linux x86_64 and Windows x86_64 in this version, from
  either editor, and for macOS (experimental, see "macOS" above; macOS
  exports were tested from the Linux editor only). An
  export for another platform finishes without Zig scripts, and the
  export log shows the error "Ziggurat exports Linux x86_64, Windows
  x86_64 and macOS (universal) in this version".
- An export builds the game library from your Zig scripts with Zig
  (ReleaseSafe), so Zig must be available as above. The `.zig` sources are
  not put into the exported game. A Linux game runs on Linux with glibc
  2.28 or newer. A Windows game ships `ziggurat_game.dll` next to the
  `.exe`; the DLL is not code-signed.
- A Linux game exported from the Windows editor has no executable bit
  (Windows has none). On Linux, run `chmod +x` on the game file before you
  start it.
- On Windows, the export cannot delete the game library of an earlier
  export (`.godot/ziggurat/export/x86_64-windows/ziggurat_game.dll`) while
  another program has it loaded or open. It then renames it aside
  (`ziggurat_game.dll.old-<16 hex digits>`), and the next export deletes
  it. If it cannot be renamed either, the export fails and asks you to
  close the programs that use it.
- Godot's export dialog has "Export With Debug" on by default. A debug
  export keeps debug information in the game library. For Linux that
  information holds absolute paths from your computer (your project, SDK
  and cache folders, so your user name too), and the library is not
  reproducible. For Windows the debug information stays in a `.pdb` file in
  the build cache and is not shipped. Turn "Export With Debug" off for a
  game you ship.
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
