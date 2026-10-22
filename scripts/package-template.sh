#!/usr/bin/env bash

# Packages the Ziggy template of a version tag as ziggy-template-<tag>.zip: a new app, ready to unpack, with every reference to Ziggy pinned
# to that tag instead of the copy in Ziggy's repository. See package-template.md.

set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "Usage: package-template.sh <tag> <output-dir>" >&2
    exit 2
fi

TAG="$1"
OUTPUT_DIR="$2"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! [[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: '$TAG' is not a version tag (v<major>.<minor>.<patch>)" >&2
    exit 2
fi

# The Xcode projects take the version without the leading v, as a Swift package version.
VERSION="${TAG#v}"

for tool in git tar zig zip unzip; do
    if ! command -v "$tool" > /dev/null; then
        echo "error: $tool is not on PATH" >&2
        exit 1
    fi
done

if ! git -C "$REPO_DIR" rev-parse --verify --quiet "refs/tags/$TAG^{commit}" > /dev/null; then
    echo "error: there is no tag $TAG in $REPO_DIR (fetch the tags first)" >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
NAME="ziggy-template-$TAG"
APP_DIR="$OUTPUT_DIR/$NAME"
ARCHIVE="$OUTPUT_DIR/$NAME.zip"

if [ -e "$APP_DIR" ] || [ -e "$ARCHIVE" ]; then
    echo "error: $APP_DIR or $ARCHIVE already exists. Remove it or pick another output directory." >&2
    exit 1
fi

# Replaces the lines from the first line matching the glob FIRST through the next line matching the glob LAST (the same line when it matches
# both) with NEW_TEXT, which may be empty or several lines. Fails unless exactly one line matches FIRST and a line matching LAST follows it,
# so a template that has changed under this script stops it rather than being packaged half pinned.
#
# Arguments: <file> <first-line-glob> <last-line-glob> <new-text>
replace_lines() {
    local file="$1"
    local first="$2"
    local last="$3"
    local new_text="$4"
    local matches=0
    local in_block=0
    local closed=0
    local line

    while IFS= read -r line || [ -n "$line" ]; do
        if [ "$in_block" -eq 0 ] && [[ "$line" == $first ]]; then
            matches=$((matches + 1))
            in_block=1
        fi

        if [ "$in_block" -eq 1 ]; then
            if [[ "$line" == $last ]]; then
                in_block=0
                closed=$((closed + 1))
                if [ -n "$new_text" ]; then
                    printf '%s\n' "$new_text"
                fi
            fi
        else
            printf '%s\n' "$line"
        fi
    done < "$file" > "$file.new"

    if [ "$matches" -ne 1 ] || [ "$closed" -ne 1 ]; then
        echo "error: expected one block from '$first' to '$last' in $file, found $matches starting and $closed ending" >&2
        exit 1
    fi

    mv "$file.new" "$file"
}

# Fails when FILE does not contain the fixed string TEXT.
#
# Arguments: <file> <text>
require_text() {
    if ! grep -qF -- "$2" "$1"; then
        echo "error: $1 does not contain: $2" >&2
        exit 1
    fi
}

echo "Copying the template and mise.toml of $TAG into $APP_DIR"
mkdir "$APP_DIR"
git -C "$REPO_DIR" archive --format=tar "$TAG:apps/ziggy-template" | tar -x -C "$APP_DIR"
git -C "$REPO_DIR" show "$TAG:mise.toml" > "$APP_DIR/mise.toml"

# The files the archive holds: the template's tracked files and mise.toml, so nothing a build or a test writes gets in.
FILE_LIST="$OUTPUT_DIR/$NAME.files"
{
    git -C "$REPO_DIR" ls-tree -r --name-only "$TAG:apps/ziggy-template"
    echo "mise.toml"
} | sort > "$FILE_LIST"

echo "Pinning package.json"
replace_lines "$APP_DIR/package.json" '    "ziggy": "workspace:\*"' '    "ziggy": "workspace:\*"' \
    "    \"ziggy\": \"git+https://github.com/ashleydavis/ziggy.git#$TAG\""

echo "Pinning native/android/app/build.gradle"
replace_lines "$APP_DIR/native/android/app/build.gradle" "    implementation 'dev.ziggy:ziggy-native-android:*'" "    implementation 'dev.ziggy:ziggy-native-android:*'" \
    "    implementation 'dev.ziggy:ziggy-native-android:$TAG'"

echo "Pinning native/android/settings.gradle"
SETTINGS_GRADLE="$APP_DIR/native/android/settings.gradle"
replace_lines "$SETTINGS_GRADLE" "// The Ziggy template's Android project:*" "// instead." \
"// The Ziggy template's Android project: the app, which takes Ziggy's Android native app from Ziggy's repository on GitHub. Gradle checks
// the repository out at the version tag that the dependency \`dev.ziggy:ziggy-native-android\` in app/build.gradle names, and
// builds the native app from it."
replace_lines "$SETTINGS_GRADLE" "includeBuild(*" "}" \
"sourceControl {
    gitRepository(uri('https://github.com/ashleydavis/ziggy.git')) {
        producesModule('dev.ziggy:ziggy-native-android')
        rootDir = 'packages/ziggy/native/android'
    }
}"

echo "Pinning jest.config.js"
JEST_CONFIG="$APP_DIR/jest.config.js"
replace_lines "$JEST_CONFIG" "export default {" "export default {" \
"// Ziggy's package, which the Zig build fetches into zig-pkg and Gradle checks out under native/android/.gradle, holds tests of its
// own. They are Ziggy's to run, not this app's.
const ziggyCopies = [
    \"<rootDir>/zig-pkg/\",
    \"<rootDir>/native/android/.gradle/\",
];

export default {"
replace_lines "$JEST_CONFIG" '        "<rootDir>/build/",' '        "<rootDir>/build/",' \
'        "<rootDir>/build/",
        ...ziggyCopies,'
replace_lines "$JEST_CONFIG" "    ]," "    ]," \
'    ],
    testPathIgnorePatterns: [
        "/node_modules/",
        ...ziggyCopies,
    ],'

for platform in macos ios; do
    echo "Pinning native/$platform/ZiggyTemplate.xcodeproj"
    PBXPROJ="$APP_DIR/native/$platform/ZiggyTemplate.xcodeproj/project.pbxproj"
    replace_lines "$PBXPROJ" "		A20000000000000000000006 /\* $platform \*/ = {isa = PBXFileReference;*" "*" ""
    replace_lines "$PBXPROJ" "				A20000000000000000000006 /\* $platform \*/," "*" ""
    replace_lines "$PBXPROJ" "			mainGroup = A40000000000000000000001;" "*" \
"			mainGroup = A40000000000000000000001;
			packageReferences = (
				AB0000000000000000000001 /* XCRemoteSwiftPackageReference \"ziggy\" */,
			);"
    replace_lines "$PBXPROJ" "/\* Begin XCSwiftPackageProductDependency section \*/" "*" \
"/* Begin XCRemoteSwiftPackageReference section */
		AB0000000000000000000001 /* XCRemoteSwiftPackageReference \"ziggy\" */ = {
			isa = XCRemoteSwiftPackageReference;
			repositoryURL = \"https://github.com/ashleydavis/ziggy\";
			requirement = {
				kind = exactVersion;
				version = $VERSION;
			};
		};
/* End XCRemoteSwiftPackageReference section */

/* Begin XCSwiftPackageProductDependency section */"
    replace_lines "$PBXPROJ" "			isa = XCSwiftPackageProductDependency;" "*" \
"			isa = XCSwiftPackageProductDependency;
			package = AB0000000000000000000001 /* XCRemoteSwiftPackageReference \"ziggy\" */;"
done

# `zig fetch --save` writes a broken entry over an existing dependency that has a path, so the path dependency and its comment go first and
# zig fetch adds Ziggy afresh, with the hash of the tag's contents. It runs in the app's directory, which has a build.zig, so that is the
# build root it edits. It fetches into the app's zig-pkg, which is not in the archive.
echo "Pinning build.zig.zon"
BUILD_ZIG_ZON="$APP_DIR/build.zig.zon"
replace_lines "$BUILD_ZIG_ZON" "        // Ziggy, from the repository this template lives in.*" "        }," ""
(cd "$APP_DIR" && zig fetch --save=ziggy "git+https://github.com/ashleydavis/ziggy.git#$TAG")
replace_lines "$BUILD_ZIG_ZON" "        .ziggy = .{" "        .ziggy = .{" \
"        // Ziggy, at a version tag of its repository. Every other place that takes Ziggy (package.json, the Xcode projects and
        // native/android/app/build.gradle) names the same version.
        .ziggy = .{"
require_text "$BUILD_ZIG_ZON" ".url = \"git+https://github.com/ashleydavis/ziggy.git?ref=$TAG#"
require_text "$BUILD_ZIG_ZON" '.hash = "ziggy-'

# Nothing may still point at the copy of Ziggy in Ziggy's repository.
if grep -rn -F -e 'workspace:' -e 'packages/ziggy/native/macos"' -e 'packages/ziggy/native/ios"' -e 'includeBuild(' -e '.path = "../.."' \
    "$APP_DIR/package.json" "$APP_DIR/build.zig.zon" "$APP_DIR/native/android" "$APP_DIR/native/macos" "$APP_DIR/native/ios"; then
    echo "error: the lines above still point at the copy of Ziggy in Ziggy's repository" >&2
    exit 1
fi

echo "Writing $ARCHIVE"
(cd "$APP_DIR" && zip -q -X "$ARCHIVE" -@ < "$FILE_LIST")

if ! unzip -Z1 "$ARCHIVE" | sort | cmp -s - "$FILE_LIST"; then
    echo "error: $ARCHIVE does not hold exactly the files listed in $FILE_LIST" >&2
    exit 1
fi
rm "$FILE_LIST"

echo "Packaged the Ziggy template of $TAG as $ARCHIVE"
