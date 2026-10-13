#!/usr/bin/env bash

# Dev mode from start to finish, as a developer runs it: the supervisor starts the template's Vite dev server, builds the dev host and
# starts it in front of Vite, and a browser opens the dev host. A saved UI file reaches the page through Vite's own reload, which
# the dev host passes through, and a saved Zig file rebuilds and restarts the dev host and the page reconnects to the new core.
# The files are edited in a copy of the template, so nothing another run builds is touched. The copy is made inside the template's tmp
# directory, which the supervisor's watch skips, so that the copy finds Ziggy and the template's packages from where it is.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

# How long a build may take: the copy has a cache of its own, so the first build compiles the whole core.
BUILD_TIMEOUT_SECONDS=600

COPY_DIR="$(mktemp -d "$ZIGGY_SMOKE_APP_DIR/tmp/dev-hot-reload.XXXXXX")"

remove_copy() {
    find "$COPY_DIR" -type f -delete
    find "$COPY_DIR" -type l -delete
    find "$COPY_DIR" -depth -type d -empty -delete
}
trap 'stop_app_on_exit; remove_copy' EXIT

for part in build.zig build.zig.zon package.json vite.config.ts tsconfig.json core ui shells/linux shells/windows; do
    mkdir -p "$COPY_DIR/$(dirname "$part")"
    cp -R "$ZIGGY_SMOKE_APP_DIR/$part" "$COPY_DIR/$part"
done
# The copy is two directories below the template, so its path to Ziggy goes up two more.
sed -i.before-edit 's|^\( *\.path = "\)\([^"]*\)",$|\1../../\2",|' "$COPY_DIR/build.zig.zon"
grep -q '\.path = "\.\./\.\./' "$COPY_DIR/build.zig.zon" || fail "the copy's path to Ziggy was not rewritten: $(grep '\.path' "$COPY_DIR/build.zig.zon")"

#
# Waits for a file to hold something and prints it. Usage: wait_for_file <file> <seconds> <what it is, for the failure>
#
wait_for_file() {
    local waited=0
    while [ ! -s "$1" ]; do
        if [ "$waited" -ge "$(($2 * 10))" ]; then
            echo "The supervisor's output:" >&2
            cat "$ZIGGY_TEST_DIR/app.log" >&2
            fail "$3 never appeared"
        fi
        sleep 0.1
        waited=$((waited + 1))
    done
    tr -d '\n' < "$1"
}

#
# Connects to the control connection of the dev host that is running, after its port file appears.
#
connect_to_dev_host() {
    exec 3>&- 2>/dev/null || true
    ZIGGY_CONTROL_HOST=127.0.0.1
    ZIGGY_CONTROL_PORT="$(wait_for_file "$ZIGGY_TEST_DIR/control-port.txt" "$BUILD_TIMEOUT_SECONDS" "the dev host's control port")"
    export ZIGGY_CONTROL_HOST ZIGGY_CONTROL_PORT
    open_control_connection
    wait_for_ready
}

read -r supervisor_pid supervisor_pgid < <(launch_in_process_group "$ZIGGY_TEST_DIR/app.log" env \
    CHOKIDAR_USEPOLLING=1 \
    ZIGGY_TEST_MODE=1 \
    ZIGGY_TEST_PORT_FILE="$ZIGGY_TEST_DIR/control-port.txt" \
    bash -c 'cd "$1" && exec zig build ziggy-template-dev -- --no-open --test-hooks' bash "$COPY_DIR") || fail "the supervisor did not start"
# The supervisor, Vite and the dev host are all in this one process group.
echo "$supervisor_pgid" > "$ZIGGY_TEST_DIR/$DEV_HOST_PGID_FILE_NAME"

host_port="$(wait_for_file "$COPY_DIR/zig-out/dev/port.txt" "$BUILD_TIMEOUT_SECONDS" "the dev host's port")"
dev_open_browser "$ZIGGY_TEST_DIR" "$host_port" || fail "the browser did not open"
connect_to_dev_host
wait_for_text reply "says: hello from the UI" 60

# A saved UI file: Vite reloads the page with it, through the dev host, and the page talks to the same core.
sed -i.before-edit 's|says: \${reply.echo.greeting}|answers: ${reply.echo.greeting}|' "$COPY_DIR/ui/src/lib/format-reply.ts"
grep -q 'answers: ' "$COPY_DIR/ui/src/lib/format-reply.ts" || fail "the UI file was not edited"
wait_for_text reply "answers: hello from the UI" 120

# A saved Zig file: the dev host is rebuilt and restarted, and the page reloads and talks to the new core.
rm -f "$ZIGGY_TEST_DIR/control-port.txt"
sed -i.before-edit 's|        \.os = @tagName(builtin\.os\.tag),|        .os = "the rebuilt core",|' "$COPY_DIR/core/src/lib/channels.zig"
grep -q 'the rebuilt core' "$COPY_DIR/core/src/lib/channels.zig" || fail "the Zig file was not edited"
connect_to_dev_host
wait_for_text reply "on the rebuilt core" 120
wait_for_text reply "answers: hello from the UI" 60
if [ "$(cat "$COPY_DIR/zig-out/dev/port.txt")" != "$host_port" ]; then
    fail "the dev host came back on another port, so the page's address changed"
fi
grep -q "the dev host restarted" "$ZIGGY_TEST_DIR/app.log" || fail "the supervisor did not say it restarted the dev host"
