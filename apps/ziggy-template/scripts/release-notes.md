# release-notes.sh

Prints the release notes for a build: one bullet per commit made since the last version tag of Ziggy, newest first. The release workflow (`.github/workflows/release.yml`) uses it for the notes on the GitHub release of the Ziggy template, and the template's Android tester distribution (`apps/ziggy-template/scripts/distribute-android.sh`) uses it for the note a tester reads beside the build. One script, so the two never describe the same commits differently.

Invoked as `bash scripts/release-notes.sh [options]` from the app's directory, or by its path from anywhere: it reads the git repository it is in. The notes go to stdout and nothing else does, so a caller can capture them. Which tag the notes were measured from goes to stderr.

## Arguments

- `--prefix <word>` keeps only commits whose subject starts with `<word>:` and strips that prefix from the bullet. Without it every commit is listed.
- `--exclude-tag <tag>` ignores that tag when looking for the last version tag.
- `--empty-message <text>` is printed when no commit matches, instead of empty output (default: `- No changes found`).
- `--limit <n>` keeps only the newest n bullets and adds a final one giving the number of older changes left out. The Android tester distribution passes one, because Firebase App Distribution rejects long release notes.

## What counts as the last version tag

The newest tag by version number, skipping `template`, which the release workflow moves to every build of the template it publishes and so would report almost nothing, and skipping whatever `--exclude-tag` names. Merge commits are left out. With no tag to measure from (a repository that has never been tagged, or a clone without its tags) the range is the whole history. The release workflow checks out with `fetch-depth: 0`, so it has the tags.
