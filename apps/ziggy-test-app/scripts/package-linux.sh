#!/usr/bin/env bash

# Packages the test app's Linux app as a zip and a deb. See package-linux.md.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SHELL_DIR="$EXAMPLE_DIR/native/linux"
OUTPUT_DIR="$EXAMPLE_DIR/out/linux"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        *)
            echo "Unknown argument $1. See package-linux.md." >&2
            exit 2
            ;;
    esac
done

VERSION="$(jq -r '.version' "$EXAMPLE_DIR/package.json")"
ARCHITECTURE="$(uname -m)"
case "$ARCHITECTURE" in
    x86_64)
        DEB_ARCHITECTURE="amd64"
        ;;
    aarch64)
        DEB_ARCHITECTURE="arm64"
        ;;
    *)
        echo "package-linux.sh: no deb architecture is known for $ARCHITECTURE" >&2
        exit 1
        ;;
esac
BASE_NAME="ziggy-test-app-$VERSION-linux-$ARCHITECTURE"

(cd "$EXAMPLE_DIR" && bun run bundle:ui)
STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ziggy-test-app-package-XXXXXX")"
(cd "$EXAMPLE_DIR" && zig build ziggy-test-app-linux -Doptimize=ReleaseSafe -Dstrip=true -p "$STAGE_DIR/prefix")
mkdir -p "$OUTPUT_DIR"

# The zip holds the executable, which has the frontend embedded, in one folder.
mkdir -p "$STAGE_DIR/zip/ziggy-test-app"
cp "$STAGE_DIR/prefix/bin/ziggy-test-app" "$STAGE_DIR/zip/ziggy-test-app/"
rm -f "$OUTPUT_DIR/$BASE_NAME.zip"
(cd "$STAGE_DIR/zip" && zip -q -r "$OUTPUT_DIR/$BASE_NAME.zip" ziggy-test-app)

# The deb installs under /opt, puts a link in /usr/bin and adds a menu entry so the app shows in the applications menu.
mkdir -p "$STAGE_DIR/deb/DEBIAN" "$STAGE_DIR/deb/opt/ziggy-test-app" "$STAGE_DIR/deb/usr/bin" "$STAGE_DIR/deb/usr/share/applications"
cp "$STAGE_DIR/prefix/bin/ziggy-test-app" "$STAGE_DIR/deb/opt/ziggy-test-app/"
ln -s /opt/ziggy-test-app/ziggy-test-app "$STAGE_DIR/deb/usr/bin/ziggy-test-app"
cat > "$STAGE_DIR/deb/usr/share/applications/dev.ziggy.testapp.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Ziggy test app
Comment=A small complete app built on Ziggy
Exec=/usr/bin/ziggy-test-app
Terminal=false
Categories=Utility;
StartupWMClass=dev.ziggy.testapp
DESKTOP
cat > "$STAGE_DIR/deb/DEBIAN/control" <<CONTROL
Package: ziggy-test-app
Version: $VERSION
Architecture: $DEB_ARCHITECTURE
Maintainer: Ziggy
Depends: libgtk-3-0, libwebkit2gtk-4.1-0, gstreamer1.0-plugins-good, gstreamer1.0-libav
Description: The Ziggy test app app
 A small complete app built on Ziggy.
CONTROL
rm -f "$OUTPUT_DIR/$BASE_NAME.deb"
dpkg-deb --build --root-owner-group "$STAGE_DIR/deb" "$OUTPUT_DIR/$BASE_NAME.deb"

echo "Packaged $OUTPUT_DIR/$BASE_NAME.zip and $OUTPUT_DIR/$BASE_NAME.deb"
