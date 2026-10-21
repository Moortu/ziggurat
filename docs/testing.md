# Testing

Zig 0.17.0 and Godot 4.7.2. Steps that run Godot find `godot` on `PATH`, or
take `-Dgodot-path=<absolute path>`.

| Command | What it runs | Needs |
|---|---|---|
| `zig fmt --check src test sdk tools build.zig` | formatting | Zig |
| `zig build test` | unit tests, integration tests, `test-godot` and `test-host` | Zig, Godot |
| `zig build test-unit` | unit tests only (no compiler child, no Godot) | Zig |
| `zig build test-godot` | the SDK tests inside a headless Godot | Godot |
| `zig build test-host` | the host tests in a headless Godot (`-Dhost-test-filter=<text>` runs only matching tests) | Godot |
| `zig build test-gui` | the GUI editor test under Xvfb: a script saved in the script editor reaches the running game (`test/host/gui/README.md`, also the manual desktop run). Not part of `test`. | Godot, `xvfb-run` |
| `zig build test-stress` | the reload stress test with 300 edits in a headless editor (`test/host/stress/driver.gd`): saves with swaps, three threads calling scripts, nested `Main::iteration()` from a script call, broken builds, leak scans. `test` and `test-host` run it with 20 edits. Not part of `test`; never cached; prints its run time. | Godot |
| `zig build cross` | compiles the test binaries for Windows and macOS (not run) | Zig |

On NixOS:

```sh
nix shell 'github:silversquirl/zig-flake/compat#"0.17.0"' nixpkgs#godot nixpkgs#xvfb-run \
    --command zig build test
```

CI (`.forgejo/workflows/ci.yml`) runs formatting, `test` and `cross` on every
push. `test-gui` is an optional job that runs only when the workflow is
started by hand; its failure does not fail the workflow.
