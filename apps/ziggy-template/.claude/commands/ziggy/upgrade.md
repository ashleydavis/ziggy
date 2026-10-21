---
description: Move a Ziggy app to a newer version of Ziggy, change what the new version needs changed and run the app's checks.
---

# Move a Ziggy app to a newer Ziggy

Follow Ziggy's guide [Building your app](https://github.com/ashleydavis/ziggy/blob/main/docs/user-guide/building-your-app.md), section "Moving to a newer version". Read it first.

1. Find how the app takes Ziggy: a local path (`build.zig.zon` has `.path`) or a version tag (it has `.url`).
2. Ask the human which version to move to, unless they said, and wait for the answer.
3. Read the new version's release notes and the changes to Ziggy's guides since the app's version, and list what the app has to change. Show the human that list before changing anything.
4. For a version tag, change the version everywhere the guide lists: `build.zig.zon` (with `zig fetch --save=ziggy`), both Xcode projects, `native/android/app/build.gradle` and `package.json`. Run `bun install`. For a local path, the Ziggy checkout is the human's: tell them the `git` command that checks out the new version, and wait for them to run it.
5. Make the changes from step 3.
6. Run `/ziggy:check`, and fix what fails.

Report the version moved from and to, what was changed for it and how the checks went.
