#!/usr/bin/env bash

# Replaces the copy of websocket.zig in this directory with the library at a commit of its repository. See update.md.

set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "Usage: update.sh <commit>" >&2
    exit 2
fi
commit="$1"

LIBRARY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

archive="$(mktemp "$LIBRARY_DIR/.websocket-download.XXXXXX")"
trap 'rm -f "$archive"' EXIT

curl -fsSL "https://github.com/karlseguin/websocket.zig/archive/$commit.tar.gz" -o "$archive" \
    || { echo "update.sh: could not download websocket.zig at $commit" >&2; exit 1; }

# GitHub puts every file under one top directory, websocket.zig-<commit>, whatever form of the commit was asked for.
top="$(tar -tzf "$archive" | sed -n '1p')"
top="${top%%/*}"

# The files the new version has, relative to this directory. Every file of the library's repository at the commit is kept, so a file
# the library adds is never left out.
wanted="$(tar -tzf "$archive" | sed "s|^$top/||" | grep -v '/$' | grep -v '^$')"

# A file the old version had and the new one does not is removed, one file at a time. This script, its documentation and what a
# build of the library writes stay.
while IFS= read -r path; do
    relative="${path#"$LIBRARY_DIR"/}"
    case "$relative" in
        update.sh|update.md|.websocket-download.*|.zig-cache/*|zig-out/*)
            continue
            ;;
    esac
    if ! printf '%s\n' "$wanted" | grep -qxF "$relative"; then
        rm "$path"
    fi
done < <(find "$LIBRARY_DIR" -type f)
find "$LIBRARY_DIR" -mindepth 1 -type d -empty -not -path "*/.zig-cache*" -not -path "*/zig-out*" -delete

tar -xzf "$archive" -C "$LIBRARY_DIR" --strip-components=1

echo "websocket.zig in $LIBRARY_DIR is now at $commit."
