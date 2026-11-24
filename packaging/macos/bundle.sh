#!/bin/sh
# Run by packaging/package.zig on macOS; uses only tools that come with the
# Xcode command line tools. Assembles and signs chemviewer.app.
# usage: bundle.sh VERSION EXE INSPECT INFO_PLIST ICON_DIR MOLTENVK LICENSE NOTICES OUT.(zip|dmg)
set -eu
version=$1 exe=$2 inspect=$3 plist=$4 icon_dir=$5 moltenvk=$6 license=$7 notices=$8 out=$9
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
app=$tmp/stage/chemviewer.app
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks" "$app/Contents/Resources"

cp "$exe" "$app/Contents/MacOS/chemviewer"
cp "$inspect" "$app/Contents/MacOS/chemviewer-inspect"
# SDL looks for MoltenVK here first (see SDL_cocoavulkan.m).
cp "$moltenvk" "$app/Contents/Frameworks/libMoltenVK.dylib"
chmod 755 "$app/Contents/MacOS/"* "$app/Contents/Frameworks/libMoltenVK.dylib"
cp "$license" "$app/Contents/Resources/LICENSE.txt"
cp "$notices" "$app/Contents/Resources/THIRD-PARTY-NOTICES.txt"
sed "s/@VERSION@/$version/g" "$plist" > "$app/Contents/Info.plist"

# Fail if anything outside the system (e.g. from Homebrew) is linked.
if otool -L "$app/Contents/MacOS/chemviewer" | tail -n +2 | grep -vE '^[[:space:]]+(/usr/lib|/System)/'; then
  echo "chemviewer links libraries that are not bundled" >&2
  exit 1
fi

icons=$tmp/chemviewer.iconset
mkdir "$icons"
for n in 16 32 128 256; do
  cp "$icon_dir/$n.png" "$icons/icon_${n}x$n.png"
  cp "$icon_dir/$((n * 2)).png" "$icons/icon_${n}x$n@2x.png"
done
cp "$icon_dir/512.png" "$icons/icon_512x512.png"
iconutil -c icns "$icons" -o "$app/Contents/Resources/chemviewer.icns"

# Ad-hoc signature: required to run on Apple silicon, but not notarized.
codesign --force --sign - "$app/Contents/Frameworks/libMoltenVK.dylib"
codesign --force --sign - "$app/Contents/MacOS/chemviewer-inspect"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"

case $out in
  *.zip) ditto -c -k --keepParent "$app" "$out" ;;
  *.dmg)
    ln -s /Applications "$tmp/stage/Applications"
    hdiutil create -quiet -ov -volname chemviewer -srcfolder "$tmp/stage" -format UDZO "$out"
    ;;
esac
