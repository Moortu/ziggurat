#!/usr/bin/env bash
# Recreates the small toolchain archives used by src/platform/toolchain_install.zig tests.
# Run from anywhere:
#   nix shell nixpkgs#gnutar nixpkgs#xz nixpkgs#zip --command bash test/fixtures/toolchain/make.sh
#
# Files:
#   zig-x86_64-linux-0.17.0.tar.xz  good archive: zig-x86_64-linux-0.17.0/{zig,lib/}
#                                    (xz with small blocks, so the reader crosses block ends)
#   zig-x86_64-linux-0.17.0.zip     the same tree as a zip
#   bad-version.tar.xz              the same layout, but zig prints 0.16.0
#   two-top.tar.xz                  the good folder plus a second top folder
#   zig-x86_64-linux-0.17.0.tar.xz.minisig
#                                    the real signature from
#                                    https://ziglang.org/download/0.17.0/ (not made here)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

top=zig-x86_64-linux-0.17.0

make_tree() { # $1 = folder, $2 = version printed
    mkdir -p "$1/lib"
    printf '#!/bin/sh\necho %s\n' "$2" > "$1/zig"
    chmod 0755 "$1/zig"
    chmod 0755 "$1" "$1/lib"
}

tar_xz() { # $1 = output, rest = entries (in $PWD)
    local out="$1"
    shift
    tar --format=gnu --sort=name --owner=0 --group=0 --numeric-owner \
        --mtime=@0 -cf - "$@" | xz -T1 --block-size=2048 -6 -c > "$out"
}

mkdir -p "$work/good" "$work/bad" "$work/two"
make_tree "$work/good/$top" 0.17.0
make_tree "$work/bad/$top" 0.16.0
make_tree "$work/two/$top" 0.17.0
make_tree "$work/two/zig-extra" 0.17.0
find "$work" -exec touch -h -d @0 {} +

(cd "$work/good" && tar_xz "$here/$top.tar.xz" "$top")
(cd "$work/bad" && tar_xz "$here/bad-version.tar.xz" "$top")
(cd "$work/two" && tar_xz "$here/two-top.tar.xz" "$top" zig-extra)

rm -f "$here/$top.zip"
(cd "$work/good" && TZ=UTC zip -q -X -r "$here/$top.zip" "$top")

echo "made:"
ls -l "$here"
