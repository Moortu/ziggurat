# Ziggurat

Ziggurat lets a Godot 4.7 project use **Zig scripts** (`.zig` files) next to
GDScript. A Zig script is a real Godot script: you attach it to a node, its
fields show up in the Inspector, GDScript can call its methods and connect to
its signals, and saving it in the editor rebuilds it and swaps the new code
into a running game (hot reload).

It is an ordinary Godot add-on (a GDExtension) for the official Godot 4.7
editor. You do not need a custom engine build.

> **Status: proof of concept (0.1.0-poc).** This project shows that Zig
> scripting in stock Godot can work. It will probably not be developed
> further, so do not build anything important on it. Linux x86_64 is the
> tested platform. Windows x86_64 is tested under Wine only. macOS
> (universal, 11.0 or newer) is built and checked on Linux but has never
> run on a Mac. Expect rough edges. You are welcome to fork it.

## The name

The names around this project point at the gods:

- **Godot** comes from Beckett's play *Waiting for Godot*. The name is
  often read as *God* plus the French diminutive *-ot*: a little god.
- **Jenova**, the name of the C++ scripting framework
  [Projekt J.E.N.O.V.A](https://github.com/Jenova-Framework/J.E.N.O.V.A),
  is often read as *Jehovah* plus *nova*.
- A **ziggurat** is the stepped temple tower of ancient Mesopotamia, built
  to bring people closer to their gods.

So a Zig layer for Godot became a temple you build up towards Godot:
**Zig**gurat, styled Z.I.G.G.U.R.A.T after J.E.N.O.V.A.

| Platform | Editor | Exported games |
|---|---|---|
| Linux x86_64 | tested | tested (glibc 2.28 or newer) |
| Windows x86_64 | tested under Wine only; building Zig scripts in a Windows editor is untested | tested under Wine |
| macOS 11.0+ (arm64 and x86_64) | experimental, never run on a Mac | experimental, never run on a Mac |

## Requirements

- **Godot 4.7** (developed and tested with 4.7.2). Other minor versions do
  not load the add-on.
- **Zig 0.17.0** exactly. The editor can download it for you (see below).

## Install

1. Download `ziggurat-<version>.zip` from the
   [Releases](https://github.com/Moortu/ziggurat/releases) page.
2. Unpack it into your Godot project folder (the folder with
   `project.godot`). The zip already starts with `addons/`, so you get
   `addons/ziggurat/`.
3. Tell Godot to load the extension at startup. Close the editor and
   create the file `.godot/extension_list.cfg` in the project with this one
   line:

   ```
   res://addons/ziggurat/ziggurat.gdextension
   ```

   Godot also writes this file itself after it scans the project, but on
   the very first open that can need an extra restart.
4. Open the project in the Godot editor. You should see a **Zig** panel at
   the bottom and, in the Output panel, a line `ziggurat_host ... ready`.

The add-on is a per-project install, like every Godot extension: Godot 4
only loads extensions from inside the project.

### Get Zig

Use **Project > Tools > Download Zig 0.17.0**. The editor downloads the
official release once (checked with its minisign signature) into your user
folder and uses it for all projects:

- Linux: `~/.local/share/ziggurat/toolchains/`
- Windows: `%LOCALAPPDATA%\ziggurat\toolchains\`
- macOS: `~/Library/Application Support/ziggurat/toolchains/`

Or point the editor setting `ziggurat/zig_path` at your own Zig 0.17.0. The
project setting of the same name overrides it for one project. Without
either, Ziggurat uses the downloaded Zig, then `zig` on `PATH`.

## Your first Zig script

1. Create a scene with a **Node2D** root, save it as `main.tscn` and make it
   the main scene.
2. Right-click the Node2D, choose **Attach Script**, pick the language
   **Zig** and save it as `hero.zig`.
3. Replace the file with:

   ```zig
   const z = @import("ziggurat");
   const g = z.godot;

   pub const extends = g.Node2D;

   base: *g.Node2D,
   speed: f32 = 5,

   pub const meta = .{
       .speed = .{ .range = .{ 0, 100, 0.5 } },
   };

   pub const signals = struct {
       pub const hit = struct { damage: i32 };
   };

   pub fn _ready(self: *@This()) void {
       z.log(.info, "hero ready speed={d}", .{self.speed});
   }

   pub fn score(self: *@This(), bonus: i32) i32 {
       z.emit(self, .hit, .{ .damage = bonus });
       return bonus + @as(i32, @intFromFloat(self.speed * 2));
   }
   ```

4. Save. The Zig panel shows the build result and every compile error with
   its file and line. The first build of a session compiles the SDK and
   takes longer; later saves are fast.
5. Select the Node2D: **Speed** appears in the Inspector as a slider.
6. Add a child **Node** with this GDScript:

   ```gdscript
   extends Node

   func _ready() -> void:
       var hero = get_parent()
       hero.hit.connect(func(d): print("signal hit ", d))
       print("score = ", hero.score(1))

   func _process(_delta):
       if Engine.get_process_frames() % 120 == 0:
           print("score = ", get_parent().score(1))
   ```

7. Press **Play**. The Output shows `hero ready speed=5`, `signal hit 1` and
   `score = 11`.

**Hot reload:** turn on **Debug > Synchronize Script Changes**, keep the
game running, change `* 2` to `* 3` in `hero.zig` and save. Within a few
seconds the Output shows `ziggurat: swapped to build ...` and the printed
score changes, without restarting the game. The node keeps its field
values.

## Export

Exports work for Linux x86_64, Windows x86_64 and (experimental) macOS
universal. An export builds your Zig scripts into the game library with Zig
in ReleaseSafe mode, so Zig must be available. The `.zig` sources are not
shipped. Turn off **Export With Debug** for a game you ship: a debug export
keeps debug information with your computer's file paths.

## More documentation

- [`addons/ziggurat/README.md`](addons/ziggurat/README.md): the user guide
  shipped inside the add-on (debugging with lldb, export details, Windows
  and macOS notes, upgrading).
- [`docs/design/2026-10-07-ziggurat-design.md`](docs/design/2026-10-07-ziggurat-design.md):
  the design specification, including known risks.
- [`docs/testing.md`](docs/testing.md): every test step and what it needs.

## Build from source

You need Zig 0.17.0 and Godot 4.7.2 (the build reads Godot's API through
the vendored gdzig bindings and looks for `godot` on `PATH`, or takes
`-Dgodot-path=<absolute path>`).

```sh
# The release package: zig-out/ziggurat-0.1.0.zip (every platform).
zig build package

# The add-on for development, straight into a project
# (the Debug editor library for this machine):
zig build host -p /path/to/your/project
```

The package is deterministic: the same commit gives the same bytes on any
machine and from any checkout folder.

On NixOS:

```sh
nix shell 'github:silversquirl/zig-flake/compat#"0.17.0"' nixpkgs#godot \
    --command zig build package
```

## Tests

```sh
zig fmt --check src test sdk tools build.zig
zig build test-unit     # unit tests, no Godot needed
zig build test          # everything that runs on Linux (about 20 minutes)
zig build cross         # compiles for Windows, macOS and aarch64 Linux
```

`zig build test` needs Godot. The export tests also need Godot 4.7.2's
export templates (`-Dexport-templates=<folder>`), and the Windows tests
need Wine and the Windows inputs. Without them those tests skip.
[`docs/testing.md`](docs/testing.md) lists every step and option.

## Repository layout

| Path | What it holds |
|---|---|
| `src/host/` | the GDExtension: script language, script instances, editor plugin, export plugin |
| `src/build/` | the build service: workspace, compiler sessions, export builds |
| `src/platform/` | OS layer: loaders, locks, file checks (ELF, PE, Mach-O), downloads |
| `sdk/` | the `ziggurat` module that scripts import |
| `addons/ziggurat/` | the add-on files that ship as they are (README, `.gdextension`) |
| `tools/` | build helpers (archive normalising, SDK staging, Mach-O joining, Wine runner) |
| `test/` | integration, host (headless Godot), GUI, stress and package tests |
| `vendor/gdzig/` | the vendored gdzig bindings, with local patches (`vendor/gdzig/PATCHES.md`) |

## License

MIT, see [`LICENSE`](LICENSE). Third-party notices are in
[`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md).
