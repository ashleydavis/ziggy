#!/usr/bin/env bash

# Draws every Mermaid diagram under docs/diagrams (each .mmd file) into the SVG beside it, then adds the labels Mermaid cannot place
# itself. See render-diagrams.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DIAGRAMS_DIR="$REPO_DIR/docs/diagrams"

# The Mermaid command line tool draws in a headless Chrome or Chromium. It uses the one PUPPETEER_EXECUTABLE_PATH names, else the
# first on PATH.
browser="${PUPPETEER_EXECUTABLE_PATH:-}"
if [ -z "$browser" ]; then
    for candidate in google-chrome chromium chromium-browser; do
        if command -v "$candidate" > /dev/null 2>&1; then
            browser="$(command -v "$candidate")"
            break
        fi
    done
fi
if [ -z "$browser" ]; then
    echo "ERROR: no Chrome or Chromium found to draw the diagrams with. Install one, or set PUPPETEER_EXECUTABLE_PATH." >&2
    exit 1
fi

mkdir -p "$REPO_DIR/tmp"
WORK_DIR="$(mktemp -d "$REPO_DIR/tmp/render-diagrams.XXXXXX")"
trap 'find "$WORK_DIR" -type f -delete; find "$WORK_DIR" -depth -type d -empty -delete' EXIT
jq -n --arg browser "$browser" '{executablePath: $browser, args: ["--no-sandbox"]}' > "$WORK_DIR/puppeteer.json"

for source in "$DIAGRAMS_DIR"/*.mmd; do
    svg="${source%.mmd}.svg"
    echo "Drawing $(basename "$source")"
    PUPPETEER_SKIP_DOWNLOAD=1 bunx --bun @mermaid-js/mermaid-cli@11.4.2 -p "$WORK_DIR/puppeteer.json" -b white -i "$source" -o "$svg"
    bun "$SCRIPT_DIR/add-diagram-labels.ts" "$source" "$svg"
done
