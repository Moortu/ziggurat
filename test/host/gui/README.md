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
  the main scene, changes two lines (the default of `speed` and the body of
  `score`), saves with `ScriptEditor.save_all_scripts()` and waits for the
  new build. The editor sends the game the debugger message
  `ziggurat:reload` right after it writes the manifest; the test checks that
  the game logs `ziggurat: generation <n> loaded` within 10 s of the save,
  then waits up to 10 s for the game's line `e2e game: hero score=126
  speed=12.5` (the running game's new code, the field value kept; before:
  `score=26`).
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
   echo 'res://addons/ziggurat/ziggurat.gdextension' > /tmp/ziggurat-e2e/.godot/extension_list.cfg
   ```

2. Open the editor: `ZTEST_GUI=1 godot --editor --path /tmp/ziggurat-e2e`
   (with `ZTEST_GUI` set, the game it starts stays open after its checks).
   Wait until the Output panel shows `ziggurat: build 1 loaded (open, ...)`
   (a first build takes up to a minute).
3. Check that **Debug > Synchronize Script Changes** is on (it is by
   default).
4. Open `hero.zig` from the FileSystem dock in the script editor.
5. Press **Run Project** (F5). The editor builds first (Build on Play; the
   Zig panel at the bottom, tab `Zig`, shows the build). The game runs `main.tscn`; the Output panel
   shows its lines: `ZTEST PASS ...` for each check (no `ZTEST FAIL`), then
   `e2e game: checks done`.
6. With the game running (its Output shows `e2e game: hero score=26
   speed=12.5`), change `speed: f32 = 5,` to `speed: f32 = 6,` and add
   ` + 100` before the `;` in the `return` of `score`, then save with
   **File > Save** (Ctrl+S).
7. When the editor logs `ziggurat: build M loaded (save, ...)`, it tells the
   game. Expected within a few seconds from the game: `ziggurat: generation
   M loaded`, `ziggurat: swapped to build M ...` and `e2e game: hero
   score=126 speed=12.5`.
8. Stop the game and close the editor. Delete `/tmp/ziggurat-e2e` and
   `/tmp/ziggurat-e2e-sdk.json`.

Notes:

- Run Project saves open scripts first, and the script editor converts the
  indentation of a saved file to its tab's indent type. Ziggurat sets `.zig`
  tabs to spaces (editor setting `ziggurat/editor/indent_with_spaces`, on by
  default), so `hero.zig` keeps spaces; with the setting off Godot's own type
  applies (tabs by default), which Zig also accepts.
- Under Xvfb the log has `Unhandled XServer error: BadWindow` lines from the
  editor embedding the game window without a window manager; they do not
  appear on a desktop and do not affect the test.

## Optional manual check: Zig panel and download (about 10 minutes, needs the internet)

The headless host tests cover the panel and the download against a local
fixture server. This run checks them once on a real desktop with the real
mirrors. It downloads about 57 MB and needs about 900 MB of free memory for a
few seconds.

1. Run the commands of step 1 above, but replace the `printf` line with this
   one, so only the SDK manifest is set and no Zig path:

   ```sh
   printf '\n[ziggurat]\n\ndev/sdk_manifest="/tmp/ziggurat-e2e-sdk.json"\n' \
       >> /tmp/ziggurat-e2e/project.godot
   ```

2. Open the editor with an empty user data folder and no Zig on `PATH`, so
   Ziggurat finds no Zig:

   ```sh
   env XDG_DATA_HOME=/tmp/ziggurat-dl-data PATH="$(dirname "$(command -v godot)")" \
       godot --editor --path /tmp/ziggurat-e2e
   ```

   Expected: the Zig panel (bottom dock, tab `Zig`) says the build failed
   because no usable Zig 0.17.0 was found, and an error toast offers
   **Project > Tools > Download Zig 0.17.0**.
3. Choose **Project > Tools > Download Zig 0.17.0**. The panel's download
   row shows the mirror and the bytes received, then `Checking and unpacking
   Zig (needs about 800 MB of memory)`, then `Zig 0.17.0 installed`. A build
   follows; the status line shows `Build <n> ok (manual, ...)`.
4. In `hero.zig`, break a line (for example remove a `;`) and save. Expected:
   a warning toast `Zig build failed: ...; build <n> stays in use`, and the
   panel lists the error with a `res://hero.zig:<line>:<column>` link. Click
   the link: the script editor opens `hero.zig` at that line. Undo the change
   and save; the panel shows a good build again.
5. Close the editor. Delete `/tmp/ziggurat-e2e`, `/tmp/ziggurat-e2e-sdk.json`
   and `/tmp/ziggurat-dl-data` (the downloaded Zig, several hundred MB).
