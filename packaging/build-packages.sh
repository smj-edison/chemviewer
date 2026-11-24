#!/bin/sh
# Builds the portable package and the installer into dist/.
# Used by CI and packaging/windows/test-in-podman.sh.
# usage: build-packages.sh windows|macos VERSION
set -eu
cd "$(dirname "$0")/.."
case $1 in
  # Cross-compiled, from any system.
  windows) set -- "$2" -Dtarget=x86_64-windows-gnu -Dcpu=baseline ;;
  # No -Dcpu: SDL's build would take it for a cross build and ask for an SDK.
  macos) set -- "$2" -Dsystem-sdl=false ;;
  *) echo "unknown system: $1" >&2; exit 1 ;;
esac
version=$1
shift
for kind in portable installer; do
  zig build "$@" -Doptimize=ReleaseSafe -Dpackage=$kind -Dversion="$version" --prefix dist
done
ls -l dist/chemviewer-*
