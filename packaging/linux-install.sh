#!/bin/sh
# Installs chemviewer with its desktop entry, icons and file types.
# usage: ./install.sh [PREFIX]   (default: ~/.local)
set -eu
prefix=${1:-$HOME/.local}
cd "$(dirname "$0")"
mkdir -p "$prefix"
cp -r bin share "$prefix/"
# Refresh the desktop's caches where the tools exist.
if command -v update-mime-database >/dev/null; then update-mime-database "$prefix/share/mime" || true; fi
if command -v update-desktop-database >/dev/null; then update-desktop-database "$prefix/share/applications" || true; fi
echo "Installed to $prefix. Make sure $prefix/bin is in your PATH."
