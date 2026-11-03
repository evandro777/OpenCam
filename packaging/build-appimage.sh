#!/usr/bin/env bash
# Builds OpenCamera-x86_64.AppImage from build/linux/x64/release/bundle.
# Needs libmpv-dev installed (its libmpv.so.2 and deps get bundled). GTK3 and libsecret stay on the host.
set -euo pipefail
cd "$(dirname "$0")/.."

rm -rf AppDir && mkdir -p AppDir/usr/bin AppDir/usr/lib
# Flutter finds data/ and lib/ next to the executable, so keep the bundle intact.
cp -r build/linux/x64/release/bundle/. AppDir/usr/bin/

cat > AppRun <<'EOF'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
export LD_LIBRARY_PATH="$HERE/usr/lib:$HERE/usr/bin/lib:${LD_LIBRARY_PATH:-}"
exec "$HERE/usr/bin/opencamera" "$@"
EOF
chmod +x AppRun

LD=linuxdeploy-x86_64.AppImage
if [ ! -x "$LD" ]; then
  curl -fsSL -o "$LD" https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage
  chmod +x "$LD"
fi

MPV="$(ldconfig -p | awk '/libmpv\.so\.2 /{print $NF; exit}')"
# --appimage-extract-and-run: CI runners have no FUSE.
[ -n "$MPV" ] || { echo "libmpv.so.2 not found (install libmpv-dev)"; exit 1; }
# GTK/GLib stay on the host (bundling them without linuxdeploy's gtk plugin breaks themes); plugin libs in usr/bin/lib are scanned for deps (jsoncpp).
VERSION="$(sed -nE 's/^version: *([^+]*).*/\1/p' pubspec.yaml)"
# No --output: linuxdeploy only fills AppDir; appimagetool packs it (and writes the .zsync).
./"$LD" --appimage-extract-and-run \
  --appdir AppDir \
  --executable AppDir/usr/bin/opencamera \
  --deploy-deps-only AppDir/usr/bin/lib \
  --exclude-library 'libgtk-3*' --exclude-library 'libgdk-3*' --exclude-library 'libglib-2*' \
  --exclude-library 'libgio-2*' --exclude-library 'libgobject-2*' --exclude-library 'libgmodule-2*' \
  --library "$MPV" \
  --custom-apprun AppRun \
  --desktop-file packaging/dev.opencamera.opencamera.desktop \
  --icon-file packaging/dev.opencamera.opencamera.png

# Update info: AppImageUpdate-style tools fetch the .zsync from the latest release and download only the changed blocks.
ARCH=x86_64 appimagetool --no-appstream \
  -u "gh-releases-zsync|evandro777|OpenCam|latest|OpenCamera-*x86_64.AppImage.zsync" \
  AppDir "OpenCamera-$VERSION-x86_64.AppImage"
