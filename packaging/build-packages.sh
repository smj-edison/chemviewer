#!/bin/sh
# Builds the portable package, and the installer if there is one, into dist/.
# Used by CI and packaging/test-in-podman.sh.
# usage: build-packages.sh linux|windows|macos VERSION
set -eu
cd "$(dirname "$0")/.."
system=$1
version=$2
kinds="portable installer"
case $system in
  # SDL linked in; needs only glibc 2.31+ (Debian 11, Ubuntu 20.04).
  linux)
    set -- -Dtarget=x86_64-linux-gnu.2.31 -Dcpu=baseline -Dsystem-sdl=false
    kinds=portable
    ;;
  # Cross-compiled, from any system.
  windows) set -- -Dtarget=x86_64-windows-gnu -Dcpu=baseline ;;
  # No -Dcpu: SDL's build would take it for a cross build and ask for an SDK.
  macos) set -- -Dsystem-sdl=false ;;
  *) echo "unknown system: $system" >&2; exit 1 ;;
esac
for kind in $kinds; do
  zig build "$@" -Doptimize=ReleaseSafe -Dpackage="$kind" -Dversion="$version" --prefix dist
done
ls -l dist/chemviewer-*
