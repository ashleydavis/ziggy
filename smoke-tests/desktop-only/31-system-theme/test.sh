#!/usr/bin/env bash

# With the setting system, the page's theme is the operating system's theme.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

#
# The operating system's theme: "light" or "dark".
#
system_theme() {
    case "$(uname -s)" in
        Linux)
            local scheme
            scheme="$(gsettings get org.gnome.desktop.interface color-scheme 2>/dev/null | tr -d "'")"
            case "$scheme" in
                prefer-dark)
                    printf 'dark\n'
                    return 0
                    ;;
                prefer-light|default)
                    printf 'light\n'
                    return 0
                    ;;
            esac
            local portal
            portal="$(gdbus call --session --dest org.freedesktop.portal.Desktop --object-path /org/freedesktop/portal/desktop --method org.freedesktop.portal.Settings.ReadOne org.freedesktop.appearance color-scheme 2>/dev/null)"
            case "$portal" in
                *"uint32 1"*)
                    printf 'dark\n'
                    return 0
                    ;;
                *"uint32 0"*)
                    printf 'light\n'
                    return 0
                    ;;
            esac
            return 1
            ;;
        Darwin)
            if [ "$(defaults read -g AppleInterfaceStyle 2>/dev/null)" = "Dark" ]; then
                printf 'dark\n'
            else
                printf 'light\n'
            fi
            ;;
        MINGW*|MSYS*|CYGWIN*)
            local value
            value="$(reg query 'HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' /v AppsUseLightTheme 2>/dev/null | grep -o '0x[0-9a-fA-F]*' | tail -1)"
            if [ "$value" = "0x0" ]; then
                printf 'dark\n'
            else
                printf 'light\n'
            fi
            ;;
        *)
            return 1
            ;;
    esac
}

expected="$(system_theme)" || fail "the operating system's theme could not be read"
start_test_app
wait_for_text theme-background "theme background: $expected" 10
wait_for_text theme "system $expected" 10
