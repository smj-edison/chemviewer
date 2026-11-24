#!/bin/sh
# Runs the Linux or Windows CI job in a container, from a clean clone of HEAD with
# nothing fetched yet (uncommitted changes are not included). Packages are
# copied to dist/. usage: test-in-podman.sh linux|windows [VERSION]
set -eu
cd "$(dirname "$0")/.."
mkdir -p dist
podman build -t chemviewer-package packaging
podman run --rm --security-opt label=disable \
  -v "$PWD:/repo:ro" -v "$PWD/dist:/out" chemviewer-package sh -ec '
    git config --global --add safe.directory "*"
    git clone -q /repo /build
    cd /build
    packaging/build-packages.sh "$1" "$2"
    cp dist/chemviewer-* /out/
  ' sh "$1" "${2:-0.0.0}"
