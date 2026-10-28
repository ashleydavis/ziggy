#!/usr/bin/env bash

# Replaces the copy of websocket.zig in this directory with the library at a commit of its repository. See update.md.

set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "Usage: update.sh <commit>" >&2
    exit 2
fi
commit="$1"

LIBRARY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Ziggy's changes to the library, each a patch in patches/ named <number>-<name>.patch with a .md beside it describing it, in the
# order of their numbers. The names are checked before anything is replaced.
patch_names="$(cd "$LIBRARY_DIR/patches" && find . -maxdepth 1 -type f -name '*.patch' | sed 's|^\./||' | sort -n)"
numbers=""
while IFS= read -r name; do
    [ -n "$name" ] || continue
    number="${name%%-*}"
    if ! [[ "$number" =~ ^[0-9]+$ ]] || [ "$number" = "$name" ]; then
        echo "update.sh: patches/$name does not start with its number. Name it <number>-<name>.patch." >&2
        exit 1
    fi
    numbers+="$((10#$number))"$'\n'
done <<< "$patch_names"
duplicate="$(printf '%s' "$numbers" | sort -n | uniq -d | sed -n '1p')"
if [ -n "$duplicate" ]; then
    echo "update.sh: more than one patch in patches/ has the number $duplicate. Give each its own number." >&2
    exit 1
fi

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

# A file the old version had and the new one does not is removed, one file at a time. This script, its documentation, Ziggy's
# patches and what a build of the library writes stay.
while IFS= read -r path; do
    relative="${path#"$LIBRARY_DIR"/}"
    case "$relative" in
        update.sh|update.md|patches/*|.websocket-download.*|.zig-cache/*|zig-out/*)
            continue
            ;;
    esac
    if ! printf '%s\n' "$wanted" | grep -qxF "$relative"; then
        rm "$path"
    fi
done < <(find "$LIBRARY_DIR" -type f)
find "$LIBRARY_DIR" -mindepth 1 -type d -empty -not -path "*/.zig-cache*" -not -path "*/zig-out*" -delete

tar -xzf "$archive" -C "$LIBRARY_DIR" --strip-components=1

# Ziggy's patches, in the order of their numbers.
while IFS= read -r name; do
    [ -n "$name" ] || continue
    patch --forward --silent -p1 -d "$LIBRARY_DIR" < "$LIBRARY_DIR/patches/$name" \
        || { echo "update.sh: patches/$name does not apply to websocket.zig at $commit. Make it again for this version." >&2; exit 1; }
done <<< "$patch_names"
echo "websocket.zig in $LIBRARY_DIR is now at $commit, with Ziggy's patches applied."
