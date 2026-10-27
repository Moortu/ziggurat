# Testing

Zig 0.17.0 and Godot 4.7.2. Steps that run Godot find `godot` on `PATH`, or
take `-Dgodot-path=<absolute path>`.

| Command | What it runs | Needs |
|---|---|---|
| `zig fmt --check src test sdk tools build.zig` | formatting | Zig |
| `zig build test` | unit tests, integration tests, `test-godot`, `test-host`, `test-package` and `test-macos`; pass `-Dexport-templates=<folder>` to run the export tests too (below), the `-Dwindows-*` options to add `test-windows` and `test-wine-e2e` (below), and the macOS inputs `-Dmacos-zig-tarball` and `-Dbaseline-zip` (below) to run the two tests that skip without them | Zig, Godot |
| `zig build test-unit` | unit tests only (no compiler child, no Godot). On Linux x86_64 and aarch64 it also builds `sdk/names_test.zig` (the SDK's lazy caches) with ThreadSanitizer and runs it with `TSAN_OPTIONS=halt_on_error=1`, which the build sets: a reported data race fails the step. | Zig |
| `zig build test-godot` | the SDK tests inside a headless Godot | Godot |
| `zig build test-host` | the host tests in a headless Godot, including the editor plugin (Zig panel, Build on Play, reload message, highlighter, indentation, external edits), the Zig download and the export (`-Dhost-test-filter=<text>` runs only matching tests, for example `download` or `export:`). The export tests export a project with `--export-release` and run the exported game; the test `install from the zip` unzips the release package (`zig build package`) into a fresh project whose path holds a space, builds, plays, exports and runs it. They need Godot 4.7.2's export templates, `-Dexport-templates=<folder with linux_release.x86_64>`, and skip without it (one notice line after the run). | Godot (export templates for the export tests) |
| `zig build test-gui` | the GUI editor test under Xvfb: a script saved in the script editor reaches the running game through the editor's `ziggurat:reload` message (`test/host/gui/README.md`, also the manual desktop runs). Not part of `test`. | Godot, `xvfb-run` |
| `zig build test-stress` | the reload stress test with 300 edits in a headless editor (`test/host/stress/driver.gd`): saves with swaps, three threads calling scripts, nested `Main::iteration()` from a script call, broken builds, leak scans. `test` and `test-host` run it with 20 edits. Not part of `test`; never cached; prints its run time. | Godot |
| `zig build test-package` | the release package tests: layout and names, no executables, no repository or cache paths, licence notices, glibc at most 2.28, every `.gdextension` library present (and the export inputs of every platform), the macOS files (universal editor and empty game libraries, per-arch BSD archives and thin empty game libraries, minimum macOS 11.0), two packager runs giving identical bytes, and two nested `zig build package` runs with different cache folders under `/tmp` giving identical bytes (this one adds about 2 minutes). With `-Dbaseline-zip=<the Stage 7b ziggurat-0.1.0.zip>` it also checks that every 7b file is unchanged except the two Linux and Windows editor libraries, `ziggurat.gdextension` and `README.md`, and that every new file is a macOS file; without the option that test skips. Part of `test`. | Zig |
| `zig build test-windows` | the `test-unit` set built for `x86_64-windows-gnu` and run under Wine (`tools/wine_run.zig`); tests that need a real Windows skip, and `test/wine_gaps.zig` lists the known Wine gaps. An explicit step: it fails with a clear message when `wine` is not on `PATH`. | Zig, Wine |
| `zig build test-wine-e2e` | the Windows end-to-end tests under Wine (`test/host/wine_e2e.zig`): a Windows export from the Linux editor run under Wine, the Windows editor's Linux export, the real Windows Zig download from a local server, and the old-library rule. Two tests (the Windows editor building and exporting Zig scripts) stop where `zig.exe` starts and skip on the known Wine gap (the Windows Zig compiles nothing under Wine 11.19); any other failure fails. Each test skips when the `-Dwindows-*` option or `-Dexport-templates` it needs is missing. | Zig, Godot, Wine, Windows inputs |
| `zig build test-macos` | checks the universal macOS editor library `bin/libziggurat_host.dylib` with Ziggurat's own Mach-O reader: x86_64 and arm64 slices, minimum macOS 11.0, exports, the arm64 linker signature. `rcodesign` is an optional cross-check of the signature, used when it is on `PATH` (`nixpkgs#rcodesign`); the Mach-O reader's own tests in the unit set use `llvm-objdump` and `llvm-lipo` the same way (`nixpkgs#llvm`). Nothing runs on a Mac. Part of `test`. | Zig |
| `zig build cross` | compiles the test binaries and, per cross target, the host library, the export archive and the empty game library for Windows, macOS and aarch64 Linux, plus the universal macOS editor and empty game libraries (not run) | Zig |

Build steps that are not tests:

| Command | What it writes |
|---|---|
| `zig build package` | the release package `zig-out/ziggurat-0.1.0.zip` (root `addons/ziggurat/`; the release download and the Asset Store upload are this file). It holds every target (`x86_64-linux`, `x86_64-windows`, `aarch64-macos`, `x86_64-macos`): the editor libraries in `bin/` (the macOS one universal), the export host archive and empty game library of each target in `bin/<target key>/`, the universal macOS empty game library in `bin/universal-macos/`, and each target's SDK in `sdk/<target key>/`. Deterministic: the same commit gives the same bytes from any checkout and any cache folder (`tools/ar_normalize.zig` gives the export archives' members, GNU, COFF and BSD, base names). |
| `zig build host -p <project>` | the add-on into `<project>/addons/ziggurat/` for development: the Debug editor library for `-Dtarget` (`libziggurat_host.so` or `ziggurat_host.dll`), and the Linux and Windows `bin/<target key>/` export inputs, `sdk/<target key>/` SDKs and `ziggurat.gdextension` (not the macOS files; take them from the package to export for macOS). A project set up before Stage 6 also has an old `addon/` folder, which makes Godot load a second host: delete it. |
| `zig build host-archive` | the export host archives `zig-out/lib/x86_64-linux/libziggurat_host_export.a` and `zig-out/lib/x86_64-windows/ziggurat_host_export.lib` |
| `zig build sdk-stage -Dsdk-out=<absolute folder>` | the shipped SDK (sources, `.gdignore`, `sdk-manifest.json` with relative roots) into an empty or missing folder |

On NixOS:

```sh
nix shell 'github:silversquirl/zig-flake/compat#"0.17.0"' nixpkgs#godot nixpkgs#xvfb-run \
    --command zig build test
```

With the export tests, from nixpkgs' copy of the official templates
(`nix build nixpkgs#godot.export-templates-bin`; any folder that holds
Godot 4.7.2's `linux_release.x86_64` works, for example
`~/.local/share/godot/export_templates/4.7.2.stable`). Without the option
the export tests skip and the run prints one notice line:

```sh
zig build test -Dexport-templates=<out>/share/godot/export_templates/4.7.2.stable
```

The Windows steps take their Windows programs from three options and
never download them:

- `-Dwindows-godot=<folder>`: a folder with Godot 4.7.2's
  `Godot_v4.7.2-stable_win64_console.exe` and `Godot_v4.7.2-stable_win64.exe`;
- `-Dwindows-zig=<folder>`: the unpacked `zig-x86_64-windows-0.17.0`;
- `-Dwindows-zig-zip=<file>`: the original `zig-x86_64-windows-0.17.0.zip`,
  with its `.minisig` next to it.

`zig build test` runs the Wine steps only when one of these options is
given, as `-Dexport-templates` adds the export tests. Wine runs with
`WINEDEBUG=-all` in its own prefix under `.zig-cache/ziggurat-wine/`
(never `~/.wine`), made once and reused. Windows support is tested under
Wine only, not on a real Windows machine.

```sh
zig build test -Dexport-templates=<templates> -Dwindows-godot=<folder> \
    -Dwindows-zig=<folder> -Dwindows-zig-zip=<file>
```

Two Stage 7c (macOS) tests take their inputs from options too, and skip
without them:

- `-Dmacos-zig-tarball=<file>`: the original
  `zig-aarch64-macos-0.17.0.tar.xz` or `zig-x86_64-macos-0.17.0.tar.xz`,
  with its `.minisig` next to it. The host test `download: the real macOS
  tarball checks and unpacks` serves it from the local server with the
  pinned key and pin: the size, SHA-256, signature, unpack and layout
  checks must pass, and the install must stop at `zig version` (a macOS
  `zig` cannot run on Linux), so nothing is installed;
- `-Dbaseline-zip=<file>`: the Stage 7b release package, for the
  `test-package` comparison above.

```sh
zig build test -Dexport-templates=<templates> \
    -Dmacos-zig-tarball=<file> -Dbaseline-zip=<file>
```

macOS is never run: no test starts a macOS program, and the macOS checks
read the files only (Ziggurat's Mach-O reader, plus `llvm-lipo`,
`llvm-objdump` and `rcodesign` when they are on `PATH`).

No test reaches the internet. The Zig download tests serve mirror lists,
signatures and small signed archives from a local HTTP server
(`test/host/fixture_server.zig`); the archives are committed in
`test/fixtures/toolchain/`, and `make.sh` there recreates them (it needs
GNU `tar`, `xz` and `zip`, for example from `nixpkgs#gnutar nixpkgs#xz
nixpkgs#zip`; the tests do not).

CI (`.forgejo/workflows/ci.yml`) runs formatting, `test` and `cross` on every
push. `test-gui` is an optional job that runs only when the workflow is
started by hand; its failure does not fail the workflow.
