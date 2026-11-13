#!/usr/bin/env bash

# The URL handler a Linux smoke scenario installs in place of a browser: it records each address the system was asked to open.
# Usage: record-opened-url.sh <record file> <address>

set -eu

if [ "$#" -ne 2 ]; then
    echo "Usage: record-opened-url.sh <record file> <address>" >&2
    exit 2
fi

printf '%s\n' "$2" >> "$1"
