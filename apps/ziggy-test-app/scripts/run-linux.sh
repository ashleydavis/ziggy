#!/usr/bin/env bash

# Builds the test app's Linux app and runs it. See run-linux.md.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bash "$SCRIPT_DIR/build-linux.sh"
exec "$SCRIPT_DIR/../shells/linux/zig-out/bin/ziggy-test-app" "$@"
