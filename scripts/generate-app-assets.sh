#!/usr/bin/env bash
set -euo pipefail

#
# Generates an app's icons and splash screens for Linux, Windows, macOS, iOS and Android from the SVG art its assets
# directory names in assets.json, and writes the macOS, iOS and Android resource files the native apps need.
#

usage() {
    printf 'Usage: %s --app <app directory> --assets <assets directory relative to the app>\n' "$0"
}

if [ $# -eq 0 ]; then
    usage
    exit 0
fi

app_directory=""
assets_directory=""
while [ $# -gt 0 ]; do
    case "$1" in
        --app)
            if [ $# -lt 2 ]; then
                printf 'generate-app-assets: --app needs a directory.\n' >&2
                usage >&2
                exit 2
            fi
            app_directory="$2"
            shift 2
            ;;
        --assets)
            if [ $# -lt 2 ]; then
                printf 'generate-app-assets: --assets needs a directory.\n' >&2
                usage >&2
                exit 2
            fi
            assets_directory="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'generate-app-assets: unknown argument %s.\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [ -z "$app_directory" ] || [ -z "$assets_directory" ]; then
    usage >&2
    exit 2
fi

for executable in jq convert identify; do
    if ! command -v "$executable" >/dev/null 2>&1; then
        printf 'generate-app-assets: %s is not on PATH, and this script needs it.\n' "$executable" >&2
        exit 1
    fi
done

# ImageMagick's internal SVG renderer reads no gradient fills and draws them black, so the SVGs are rendered by a
# browser, which draws the gradients and the text as the SVG describes them.
chrome=""
for browser in google-chrome chromium chromium-browser; do
    if command -v "$browser" >/dev/null 2>&1; then
        chrome="$browser"
        break
    fi
done
if [ -z "$chrome" ]; then
    printf 'generate-app-assets: google-chrome or chromium is not on PATH, and this script needs one to render the SVG art.\n' >&2
    exit 1
fi

assets_root="$app_directory/$assets_directory"
assets_json="$assets_root/assets.json"
if [ ! -f "$assets_json" ]; then
    printf 'generate-app-assets: %s does not exist.\n' "$assets_json" >&2
    exit 1
fi

read_field() {
    local field="$1"
    local value
    if ! value="$(jq -er --arg field "$field" '.[$field]' "$assets_json" 2>/dev/null)"; then
        printf 'generate-app-assets: %s has no "%s" field.\n' "$assets_json" "$field" >&2
        exit 1
    fi
    printf '%s' "$value"
}

app_name="$(read_field name)"
prefix="$(read_field prefix)"
icon="$(read_field icon)"
foreground="$(read_field foreground)"
portrait="$(read_field portrait)"
landscape="$(read_field landscape)"
background="$(read_field background)"
macos_target="$(read_field macosTarget)"
ios_target="$(read_field iosTarget)"

for input in "$icon" "$foreground" "$portrait" "$landscape"; do
    if [ ! -f "$assets_root/$input" ]; then
        printf 'generate-app-assets: %s, which %s names, does not exist.\n' "$assets_root/$input" "$assets_json" >&2
        exit 1
    fi
done

if ! [[ "$background" =~ ^#[0-9A-Fa-f]{6}$ ]]; then
    printf 'generate-app-assets: the background %s in %s is not a #RRGGBB colour.\n' "$background" "$assets_json" >&2
    exit 1
fi
background_red="${background:1:2}"
background_green="${background:3:2}"
background_blue="${background:5:2}"

# Renders an SVG at its own size to a PNG, through the browser, which draws its gradients and text.
render_svg() {
    local source="$1"
    local width="$2"
    local height="$3"
    local output="$4"
    local source_absolute
    source_absolute="$(cd "$(dirname "$source")" && pwd)/$(basename "$source")"
    local output_absolute
    output_absolute="$(cd "$(dirname "$output")" && pwd)/$(basename "$output")"
    "$chrome" --headless=new --disable-gpu --no-sandbox --hide-scrollbars --default-background-color=00000000 \
        --window-size="${width},${height}" --screenshot="$output_absolute" "file://$source_absolute" >/dev/null 2>&1
    if [ ! -f "$output_absolute" ]; then
        printf 'generate-app-assets: could not render %s with %s.\n' "$source" "$chrome" >&2
        exit 1
    fi
    convert "$output_absolute" -strip "$output_absolute"
}

# The PNG icons every platform's window and executable use.
render_svg "$assets_root/$icon" 1024 1024 "$assets_root/$prefix-1024.png"
convert "$assets_root/$prefix-1024.png" -resize 512x512! -strip "$assets_root/$prefix-512.png"
convert "$assets_root/$prefix-1024.png" -define icon:auto-resize=256,128,64,48,32,24,16 -strip "$assets_root/$prefix.ico"

# The splash images every platform shares. The BMPs are for the Windows window, which paints them with StretchDIBits.
render_svg "$assets_root/$portrait" 1290 2796 "$assets_root/splash-portrait.png"
render_svg "$assets_root/$landscape" 2796 1290 "$assets_root/splash-landscape.png"
convert "$assets_root/splash-portrait.png" -alpha off -type truecolor -strip BMP3:"$assets_root/splash-portrait.bmp"
convert "$assets_root/splash-landscape.png" -alpha off -type truecolor -strip BMP3:"$assets_root/splash-landscape.bmp"

write_catalog_contents() {
    printf '{\n    "info": {\n        "author": "xcode",\n        "version": 1\n    }\n}\n' > "$1"
}

# The file name of one pixel size in an existing macOS app icon set, or nothing when it has none.
existing_macos_icon_file() {
    local catalog="$1"
    local size="$2"
    jq -r --arg size "$size" '
        .images
        | map(select(.filename != null and ((.size | split("x")[0]) == $size)))
        | .[0].filename // empty
    ' "$catalog/Contents.json"
}

# A macOS app icon: the image square with transparent corners rounded at 22.37 percent of its size.
make_macos_icon() {
    local source="$1"
    local size="$2"
    local output="$3"
    local corner_diameter=$(( size * 4474 / 10000 ))
    convert "$source" -resize "${size}x${size}!" -strip \
        \( -size "${size}x${size}" xc:none -fill white -draw "roundrectangle 0,0,$(( size - 1 )),$(( size - 1 )),${corner_diameter},${corner_diameter}" \) \
        -alpha off -compose CopyOpacity -composite "$output"
}

# A round Android launcher icon: the image square with everything outside its inscribed circle made transparent.
make_round_icon() {
    local source="$1"
    local size="$2"
    local output="$3"
    convert "$source" -resize "${size}x${size}!" -strip \
        \( -size "${size}x${size}" xc:none -fill white -draw "circle $(( size / 2 )),$(( size / 2 )) $(( size / 2 )),1" \) \
        -alpha off -compose CopyOpacity -composite "$output"
}

macos_catalog="$app_directory/native/macos/$macos_target/Assets.xcassets"
mkdir -p "$macos_catalog/AppIcon.appiconset"
macos_sizes=(16 32 64 128 256 512 1024)
macos_files=()
for size in "${macos_sizes[@]}"; do
    file_name="icon_$size.png"
    if [ -f "$macos_catalog/AppIcon.appiconset/Contents.json" ]; then
        reused="$(existing_macos_icon_file "$macos_catalog/AppIcon.appiconset" "$size")"
        if [ -n "$reused" ]; then
            file_name="$reused"
        fi
    fi
    macos_files+=("$file_name")
    make_macos_icon "$assets_root/$prefix-1024.png" "$size" "$macos_catalog/AppIcon.appiconset/$file_name"
done

# The file name the app icon set uses for one pixel size.
macos_icon_file() {
    local pixel="$1"
    local index=0
    while [ $index -lt ${#macos_sizes[@]} ]; do
        if [ "${macos_sizes[$index]}" = "$pixel" ]; then
            printf '%s' "${macos_files[$index]}"
            return
        fi
        index=$(( index + 1 ))
    done
}

write_catalog_contents "$macos_catalog/Contents.json"
{
    printf '{\n    "images": [\n'
    first=1
    for entry in "16 1x 16x16" "32 2x 16x16" "32 1x 32x32" "64 2x 32x32" "128 1x 128x128" "256 2x 128x128" "256 1x 256x256" "512 2x 256x256" "512 1x 512x512" "1024 2x 512x512"; do
        read -r pixel scale logical_size <<< "$entry"
        if [ $first -eq 0 ]; then
            printf ',\n'
        fi
        printf '        {\n            "filename": "%s",\n            "idiom": "mac",\n            "scale": "%s",\n            "size": "%s"\n        }' "$(macos_icon_file "$pixel")" "$scale" "$logical_size"
        first=0
    done
    printf '\n    ],\n    "info": {\n        "author": "xcode",\n        "version": 1\n    }\n}\n'
} > "$macos_catalog/AppIcon.appiconset/Contents.json"

mkdir -p "$macos_catalog/SplashPortrait.imageset" "$macos_catalog/SplashLandscape.imageset" "$macos_catalog/SplashBackground.colorset"
convert "$assets_root/splash-portrait.png" -strip "$macos_catalog/SplashPortrait.imageset/splash-portrait.png"
convert "$assets_root/splash-landscape.png" -strip "$macos_catalog/SplashLandscape.imageset/splash-landscape.png"
printf '{\n    "images": [\n        {\n            "filename": "splash-portrait.png",\n            "idiom": "universal",\n            "scale": "1x"\n        }\n    ],\n    "info": {\n        "author": "xcode",\n        "version": 1\n    }\n}\n' > "$macos_catalog/SplashPortrait.imageset/Contents.json"
printf '{\n    "images": [\n        {\n            "filename": "splash-landscape.png",\n            "idiom": "universal",\n            "scale": "1x"\n        }\n    ],\n    "info": {\n        "author": "xcode",\n        "version": 1\n    }\n}\n' > "$macos_catalog/SplashLandscape.imageset/Contents.json"

ios_catalog="$app_directory/native/ios/$ios_target/Assets.xcassets"
mkdir -p "$ios_catalog/AppIcon.appiconset" "$ios_catalog/Splash.imageset" "$ios_catalog/SplashBackground.colorset"
convert "$assets_root/$prefix-1024.png" -resize 1024x1024! -strip "$ios_catalog/AppIcon.appiconset/AppIcon-512@2x.png"
write_catalog_contents "$ios_catalog/Contents.json"
printf '{\n    "images": [\n        {\n            "filename": "AppIcon-512@2x.png",\n            "idiom": "universal",\n            "platform": "ios",\n            "size": "1024x1024"\n        }\n    ],\n    "info": {\n        "author": "xcode",\n        "version": 1\n    }\n}\n' > "$ios_catalog/AppIcon.appiconset/Contents.json"
convert "$assets_root/splash-portrait.png" -strip "$ios_catalog/Splash.imageset/splash-portrait.png"
convert "$assets_root/splash-landscape.png" -strip "$ios_catalog/Splash.imageset/splash-landscape.png"
printf '{\n    "images": [\n        {\n            "filename": "splash-portrait.png",\n            "idiom": "universal",\n            "scale": "1x",\n            "width-class": "compact",\n            "height-class": "regular"\n        },\n        {\n            "filename": "splash-landscape.png",\n            "idiom": "universal",\n            "scale": "1x",\n            "width-class": "regular",\n            "height-class": "compact"\n        }\n    ],\n    "info": {\n        "author": "xcode",\n        "version": 1\n    }\n}\n' > "$ios_catalog/Splash.imageset/Contents.json"

write_colorset() {
    local catalog="$1"
    printf '{\n    "colors": [\n        {\n            "color": {\n                "color-space": "srgb",\n                "components": {\n                    "alpha": "1.000",\n                    "blue": "0x%s",\n                    "green": "0x%s",\n                    "red": "0x%s"\n                }\n            },\n            "idiom": "universal"\n        }\n    ],\n    "info": {\n        "author": "xcode",\n        "version": 1\n    }\n}\n' "$background_blue" "$background_green" "$background_red" > "$catalog/SplashBackground.colorset/Contents.json"
}
write_colorset "$macos_catalog"
write_colorset "$ios_catalog"

android_res="$app_directory/native/android/app/src/main/res"
mkdir -p "$android_res/mipmap-anydpi-v26" "$android_res/values" "$android_res/values-v31" "$android_res/drawable" "$android_res/drawable-port" "$android_res/drawable-land"
mkdir -p "$app_directory/tmp"
foreground_rendered="$app_directory/tmp/generate-app-assets-foreground.png"
render_svg "$assets_root/$foreground" 1024 1024 "$foreground_rendered"
for entry in "mdpi 48" "hdpi 72" "xhdpi 96" "xxhdpi 144" "xxxhdpi 192"; do
    read -r density launcher_size <<< "$entry"
    foreground_size=$(( launcher_size * 108 / 48 ))
    mkdir -p "$android_res/mipmap-$density"
    convert "$assets_root/$prefix-1024.png" -resize "${launcher_size}x${launcher_size}!" -strip "$android_res/mipmap-$density/ic_launcher.png"
    make_round_icon "$assets_root/$prefix-1024.png" "$launcher_size" "$android_res/mipmap-$density/ic_launcher_round.png"
    convert "$foreground_rendered" -resize "${foreground_size}x${foreground_size}!" -strip "$android_res/mipmap-$density/ic_launcher_foreground.png"
done

printf '<?xml version="1.0" encoding="utf-8"?>\n<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n    <background android:drawable="@color/ic_launcher_background"/>\n    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>\n</adaptive-icon>\n' > "$android_res/mipmap-anydpi-v26/ic_launcher.xml"
printf '<?xml version="1.0" encoding="utf-8"?>\n<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n    <background android:drawable="@color/ic_launcher_background"/>\n    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>\n</adaptive-icon>\n' > "$android_res/mipmap-anydpi-v26/ic_launcher_round.xml"
printf '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n    <color name="ic_launcher_background">%s</color>\n</resources>\n' "$background" > "$android_res/values/ic_launcher_background.xml"
printf '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n    <color name="splash_background">%s</color>\n</resources>\n' "$background" > "$android_res/values/splash.xml"
printf '<?xml version="1.0" encoding="utf-8"?>\n<layer-list xmlns:android="http://schemas.android.com/apk/res/android">\n    <item android:drawable="@color/splash_background"/>\n    <item>\n        <bitmap android:src="@drawable/splash" android:gravity="fill"/>\n    </item>\n</layer-list>\n' > "$android_res/drawable/splash_background.xml"
convert "$assets_root/splash-portrait.png" -strip "$android_res/drawable-port/splash.png"
convert "$assets_root/splash-landscape.png" -strip "$android_res/drawable-land/splash.png"
printf '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n    <style name="AppTheme" parent="@android:style/Theme.DeviceDefault.NoActionBar">\n        <item name="android:windowBackground">@drawable/splash_background</item>\n    </style>\n</resources>\n' > "$android_res/values/styles.xml"
printf '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n    <style name="AppTheme" parent="@android:style/Theme.DeviceDefault.NoActionBar">\n        <item name="android:windowSplashScreenBackground">@color/splash_background</item>\n        <item name="android:windowSplashScreenAnimatedIcon">@mipmap/ic_launcher_foreground</item>\n        <item name="android:postSplashScreenTheme">@android:style/Theme.DeviceDefault.NoActionBar</item>\n    </style>\n</resources>\n' > "$android_res/values-v31/styles.xml"

printf 'Generated the assets for %s.\n' "$app_name"
