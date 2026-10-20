# GUI editor test: a script save reaches the running game

`zig build test-gui` runs the GUI Godot editor on a virtual X display (Xvfb)
and checks that saving a Zig script in the script editor reaches a game the
editor started (spec section 12, check 6). It needs `godot` and `xvfb-run` on
`PATH` and is not part of `zig build test`.

```sh
nix shell 'github:silversquirl/zig-flake/compat#"0.17.0"' nixpkgs#godot nixpkgs#xvfb-run \
    --command zig build test-gui
```

Files:

- `save_path.gd`: the editor-side test, a tool autoload. It waits for the
  build at project open, opens `res://hero.zig` in the script editor, plays
  the main scene, changes one line in the script editor, saves with
  `ScriptEditor.save_all_scripts()` and waits up to 10 s for the game's line
  `Ziggurat: reload requested for 1 scripts (swaps arrive in a later version).`
- `run-gui.sh`: starts the editor under `xvfb-run` in its own session with a
  deadline, writes the editor's and the game's output to one log file, and
  kills whatever of the run is left at the end, also when it is interrupted.

On success the test prints nothing. To keep the timing (how long the reload
line took) set `ZTEST_GUI_RECORD=<file>`; the test writes its
`gui save path: ...` lines there.
- The test itself is `gui: save in the script editor reaches the running
  game` in `test/host/host_test.zig`. It copies `test/host/projects/e2e`,
  installs the host, points the project at the test's Zig and SDK manifest,
  and keeps Godot's settings and data folders inside the test's temporary
  folder.

## Manual desktop run (about 5 minutes)

The same steps by hand, on a real desktop. Run the commands from the
repository root inside the toolchain shell:

```sh
nix shell 'github:silversquirl/zig-flake/compat#"0.17.0"' nixpkgs#godot
```

1. Make a copy of the end-to-end project with the host and an SDK manifest
   (any empty folder works instead of `/tmp/ziggurat-e2e`):

   ```sh
   cp -r test/host/projects/e2e /tmp/ziggurat-e2e
   zig build host -p /tmp/ziggurat-e2e
   zig build sdk-manifest -Dmanifest-out=/tmp/ziggurat-e2e-sdk.json
   printf '\n[ziggurat]\n\nzig_path="%s"\ndev/sdk_manifest="/tmp/ziggurat-e2e-sdk.json"\n' "$(command -v zig)" \
       >> /tmp/ziggurat-e2e/project.godot
   mkdir -p /tmp/ziggurat-e2e/.godot
   echo 'res://addon/ziggurat_host.gdextension' > /tmp/ziggurat-e2e/.godot/extension_list.cfg
   ```

2. Open the editor: `ZTEST_GUI=1 godot --editor --path /tmp/ziggurat-e2e`
   (with `ZTEST_GUI` set, the game it starts stays open after its checks).
   Wait until the Output panel shows `ziggurat: build 1 loaded (open, ...)`
   (a first build takes up to a minute).
3. Check that **Debug > Synchronize Script Changes** is on (it is by
   default).
4. Open `hero.zig` from the FileSystem dock in the script editor.
5. Press **Run Project** (F5). The game runs `main.tscn`; the Output panel
   shows its lines: `ZTEST PASS ...` for each check (no `ZTEST FAIL`), then
   `e2e game: checks done`.
6. With the game running, change `speed: f32 = 5,` to `speed: f32 = 6,` in
   the script editor and save with **File > Save** (Ctrl+S).
7. Expected within 10 s in the Output panel, from the game:
   `Ziggurat: reload requested for 1 scripts (swaps arrive in a later version).`
   Then, from the editor: `ziggurat: build N loaded (save, ...)`.
8. Stop the game and close the editor. Delete `/tmp/ziggurat-e2e` and
   `/tmp/ziggurat-e2e-sdk.json`.

Notes:

- Run Project saves open scripts first. The script editor converts the
  indentation of a saved file to the editor's indent type (tabs by default),
  so `hero.zig` gets tabs and a build runs before the game starts. Zig accepts
  tab indentation.
- Under Xvfb the log has `Unhandled XServer error: BadWindow` lines from the
  editor embedding the game window without a window manager; they do not
  appear on a desktop and do not affect the test.
