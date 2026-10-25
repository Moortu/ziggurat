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

The `sdk/` folder holds the Zig sources your scripts build against. It has
a `.gdignore` file, so Godot does not import it and exports leave it out.

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

## Export

- Exports work for Linux x86_64 only in this version. An export for another
  platform finishes without Zig scripts, and the export log shows the error
  "Ziggurat exports Linux x86_64 only in this version".
- A Linux export builds the game library from your Zig scripts with Zig
  (ReleaseSafe), so Zig must be available as above. The `.zig` sources are
  not put into the exported game. The game runs on Linux with glibc 2.28 or
  newer.
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
