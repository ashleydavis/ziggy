#!/usr/bin/env bash

# Packages the Windows app as a zip and an MSI installer, both unsigned. See package-windows.md.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/windows-common.sh"

arch="x64"
package_dir="$WINDOWS_EXAMPLE_DIR/out/windows"
prefix=""
if [ "$#" -gt 0 ] && [ "${1#--}" = "$1" ]; then
    arch="$1"
    shift
fi
while [ "$#" -gt 0 ]; do
    case "$1" in
        --output-dir)
            package_dir="$2"
            # The install prefix goes with the package, so two runs given different directories share nothing.
            prefix="$2/prefix/$arch"
            shift 2
            ;;
        *)
            echo "Unknown argument $1. See package-windows.md." >&2
            exit 2
            ;;
    esac
done
windows_zig_target "$arch" > /dev/null
windows_require_wix

version="$(windows_app_version)"
if [ -z "$prefix" ]; then
    prefix="$WINDOWS_SHELL_DIR/package/$arch"
fi
artifact_base="ziggy-test-app-$version-windows-$arch"
mkdir -p "$package_dir"

bash "$WINDOWS_SCRIPTS_DIR/sync-windows.sh" --arch "$arch" --prefix "$prefix" --optimize ReleaseSafe --strip

windows_zip "$package_dir/$artifact_base.zip" "$prefix" "$WINDOWS_APP_DIR_NAME"
echo "Created $package_dir/$artifact_base.zip"

# candle compiles the installer's description into an object file in the install prefix, and light links it into the MSI.
"$WINDOWS_WIX_DIR/candle.exe" -nologo -arch "$arch" \
    "-dVersion=$version" \
    "-dSourceDir=$prefix/$WINDOWS_APP_DIR_NAME" \
    -out "$prefix/package-windows.wixobj" \
    "$WINDOWS_SCRIPTS_DIR/package-windows.wxs"
"$WINDOWS_WIX_DIR/light.exe" -nologo -spdb \
    -out "$package_dir/$artifact_base.msi" \
    "$prefix/package-windows.wixobj"
echo "Created $package_dir/$artifact_base.msi"
