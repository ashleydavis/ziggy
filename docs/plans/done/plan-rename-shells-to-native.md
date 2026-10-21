# Rename the shells directory to native

## Overview

Every Ziggy app keeps its native project for each platform under `shells/<platform>/`. The directory becomes `native/<platform>/`, matching the term "the native app" that the glossary and the docs use. The change covers the two apps in this repository (`apps/ziggy-template` and `apps/ziggy-test-app`), the functions in Ziggy's `build.zig` that build an app's Linux and Windows native apps from a fixed path inside the app, and the two example apps (`ziggy-example-vite` and `ziggy-example-rsbuild`, checked out beside this repository as `../ziggy-example-vite` and `../ziggy-example-rsbuild`). The docs of this repository already say `native/`. Because Ziggy's `build.zig` names the path, an example pinned to a tag that still says `shells/` cannot move until a Ziggy release carries the new path.

## Issues

## Steps

1. Write documentation. The docs of this repository were already changed from `shells/` to `native/` (run `git grep -n "shells/" -- '*.md'` in this repository and confirm it prints nothing). In each example repository, replace `shells/` with `native/` in every markdown file: `git -C ../ziggy-example-vite grep -l "shells/" -- '*.md'` and the same for `../ziggy-example-rsbuild` list them (`README.md`, `CLAUDE.md` and every `scripts/*.md`). Leave the word "shells" where it names the native apps in general rather than the directory. STOP here. Do not continue to step 2 until the human has reviewed and approved the documentation. If the human revises it, revise the remaining steps to match before going on. Done, without the stop: the human decided not to review the docs first. Every markdown file in all four repositories (Ziggy, both examples and Photosphere, including `CLAUDE.md`, READMEs, `docs/` and `scripts/*.md`) now says `native/`.

2. Clean the build output of both apps in this repository before moving them, so no build output holding the old absolute path is carried across: `bun run clean:linux`, `bun run clean:windows` and, when an Android SDK is installed, `bun run clean:android`, each run with `--filter=ziggy-template` and with `--filter=ziggy-test-app` (through `mise exec --`). Then move each directory with a plain `mv` (not `git mv`, which stages): `mv apps/ziggy-template/shells apps/ziggy-template/native` and `mv apps/ziggy-test-app/shells apps/ziggy-test-app/native`. Leave all staging to the human. Done. No clean was run: every worktree was fresh, with no `node_modules`, `zig-out`, `.zig-cache` or Gradle output under any `shells/` directory, so there was nothing to clean.

3. Change Ziggy's `build.zig`: in `addLinuxShell` and the two Windows functions that use `appPath(b, app.directory, "shells/windows/src/main.zig")`, change each path literal from `shells/linux/src/main.zig` and `shells/windows/src/main.zig` to `native/linux/src/main.zig` and `native/windows/src/main.zig`. Change the comment on `IShellApp.directory` that names those two paths. Run `mise exec -- bun run compile:zig` and `mise exec -- bun run test:zig`; both must pass. Done.

4. Change every path in the two apps' code and config from `shells` to `native`. For each of `apps/ziggy-template` and `apps/ziggy-test-app`: Done.
   - `build.zig.zon`: the `"shells"` entry of `.paths` becomes `"native"`.
   - `.gitignore`: `shells/windows/package/` becomes `native/windows/package/`.
   - `scripts/*.sh`: every `shells/` path (`android-common.sh`, `build-ios.sh`, `build-linux.sh`, `build-macos.sh`, `clean-ios.sh`, `clean-linux.sh`, `clean-macos.sh`, `install-android-sdk.sh` comment, `open-ios.sh`, `open-linux.sh`, `open-macos.sh`, `package-ios.sh`, `package-linux.sh`, `package-macos.sh`, `run-ios.sh`, `run-linux.sh`, `run-macos.sh`, `sync-ios.sh`, `sync-linux.sh`, `sync-macos.sh`, `windows-common.sh`).
   - `smoke-tests/lib/linux.sh`: `LINUX_SHELL_DIR`'s path.
   Use the Edit tool on each line. Do not touch "shells" where it is ordinary English (`gradlew`'s "reduced shells", "subshells", "shells out to") or names the native apps in general in comments (`menu.zig`, `menu-actions.ts`, `menu.test.zig`).

5. Change the paths in the rest of this repository: the root `.gitignore` entries `apps/ziggy-template/shells/windows/package/` and `apps/ziggy-test-app/shells/windows/package/`, and `smoke-tests/lib/linux.sh` (`LINUX_SHELL_DIR`). Then run `git grep -n "shells/\|\"shells\"" -- ':!*.md'` and change any remaining path it finds. Search inside the moved directories too for a path that climbs out and back in through `shells` (`git grep -n shells -- 'apps/*/native'`); there were none at the time of writing, and the relative paths to Ziggy (`../../../ziggy` in the Xcode projects and the Gradle settings) keep the same depth. Done.

6. Run the checks of this repository (through `mise exec --`): `bun run compile`, `bun run test`, `bun run compile:zig`, `bun run test:zig`, `bun run test:smoke`, `bun run test:smoke:dev`, and, after running `adb devices` and finding a serial in state `device`, `bun run test:android-shell`, `bun run test:zig:android` and `bun run test:smoke:and`. Every one passes. If no Android device is attached, say so and say the Android suites are unrun; do not report the change as tested on Android. Done (see the Done note).

7. Move each example to the local checkout of Ziggy for testing, following the local path lines of `docs/user-guide/integrating-ziggy.md`: `build.zig.zon` (`.path = "../ziggy"`), `package.json` (`file:../ziggy/packages/ziggy/ui`) and `shells/android/settings.gradle` (`includeBuild`). Leave the Xcode projects on their tag, because they cannot be built on Linux. Then do steps 2 and 4 in the example: clean, `mv shells native`, and change every path listed by `git grep -n "shells/\|\"shells\"" -- ':!*.md'` (`build.zig.zon` `.paths` and its comment naming `shells/android/app/build.gradle`, `.gitignore`, `jest.config.js` and its comment, `scripts/*.sh`, `smoke-tests/lib/linux.sh`). Run in each example: `bun install`, `bun run compile`, `bun run test`, `bun run test:zig`, `bun run compile:zig`, `bun run test:smoke`, and the Android suites when `adb devices` shows a device. Every one passes. Done. Both examples were already on the local path (`../ziggy`) in all three places.

8. Stop and tell the human that the examples cannot move off the local path until a Ziggy release carries the new path. Releasing (tagging and pushing) is the human's to do, following `docs/development/releasing-ziggy.md`. Wait for the human to say which tag was released. Not done: the human decided there is no release in this change.

9. Move both examples from the local path to the new tag, following "Moving to a newer version" in `docs/user-guide/integrating-ziggy.md`: `build.zig.zon` (with `zig fetch --save=ziggy`), `package.json`, both Xcode projects and `native/android/app/build.gradle`. Run `bun install` and the same checks as step 7 against the tag. Every one passes. The human pushes, and each example's release workflow covers macOS, iOS and Windows. Not done: no release, so both examples stay on the local path and their Xcode projects keep their tag.

10. Update documentation. Run `git grep -n "shells"` in this repository and in both examples, and confirm every remaining hit is ordinary English or names the native apps in general, not the directory. Correct any doc that step 2 to step 9 made wrong. Done.

## Unit Tests

- No function is added or changed in behaviour. The existing suites cover the moved paths: `bun run test` (Jest in both apps, whose config ignores Gradle's copy of Ziggy under the Android project), `bun run test:zig` (which builds the apps' Linux native apps from `native/linux/src/main.zig` through `addLinuxShell`) and `bun run test:android-shell`.

## Smoke Tests

- `bun run test:smoke` in this repository: builds and runs the template and the test app on Linux from `native/linux`, through `sync-linux.sh` and `smoke-tests/lib/linux.sh`.
- `bun run test:smoke:dev`: dev mode, which builds the same native apps.
- `bun run compile:zig`: cross builds the Windows native apps from `native/windows/src/main.zig`.
- `bun run test:smoke:and` and `bun run test:zig:android` when a device is attached: Gradle builds from `native/android`.
- The same set in each example, against the local path and then against the new tag.
- macOS, iOS and Windows run in each repository's release workflow on GitHub, which the human starts by pushing.

## Verify

- `git grep -n "shells/\|\"shells\"" -- ':!*.md'` and `git grep -n "shells/" -- '*.md'` print nothing in this repository or either example.
- `apps/ziggy-template/native`, `apps/ziggy-test-app/native`, `../ziggy-example-vite/native` and `../ziggy-example-rsbuild/native` exist, and no `shells` directory is left in any of them.
- `bun run compile` and `bun run compile:zig` succeed in this repository and in both examples.
- `bun run test` and `bun run test:zig` pass in this repository and in both examples.
- `bun run test:smoke` and `bun run test:smoke:dev` pass in this repository; `bun run test:smoke` passes in both examples.
- The Android suites pass when `adb devices` shows a device; otherwise the report says they are unrun.

## Notes

- The identifiers that call the native apps "shells" (`IShellApp`, `addLinuxShell`, `SHELL_DIR`, `LINUX_SHELL_DIR`, `WINDOWS_SHELL_DIR`, `packages/ziggy/native/*/src/lib/shell.zig`) and the comments that say "the shells" are left as they are. Renaming them is a separate change of terms; ask the human whether they want it.
- There is an ignored `shells/android/.gradle/` at the root of this repository, left by some earlier run. It is not tracked and nothing refers to it. Removing it needs a recursive delete, which only the human may ask for; tell them it is there.
- The examples cannot be moved to `native/` while pinned to `v0.0.1`, because that tag's `build.zig` builds the Linux and Windows native apps from `shells/<platform>/src/main.zig`. Hence the local path for testing and the release in between.
- `git mv` would stage the rename, which is the human's to do; a plain `mv` leaves git to see the old paths deleted and the new ones untracked until the human stages them.
- Decision (human): Photosphere is in scope. Its `build.zig` calls `addLinuxShell` and `addWindowsShell`, which build from `native/<platform>/src/main.zig`, so `apps/photosphere/shells` moved to `apps/photosphere/native` with every path, script, config, comment and doc that named it (including `what-changed.yaml`, the `windows_resource` path in `build.zig` and the comment in `build.zig.zon`).
- Decision (human): no release. Steps 8 and 9 are not done; both examples stay on `../ziggy` and their Xcode projects keep their tag.
- Decision: the paths were changed with one literal substitution (`shells/` to `native/`, `"shells",` to `"native",` in `.paths`, and the one `apps/photosphere/shells` at the end of a line in Photosphere's `build.zig.zon`) over the files `git grep` listed, in place of one Edit per line. Each remaining hit of the word "shells" was then read and is ordinary English or names the native apps in general.
- Decision: done plans that named the old directory (in Ziggy and in Photosphere) were changed too, because the human asked for every doc in all four repositories to say `native/`. This plan alone keeps the old paths, since it describes the move.
- Decision: `mise` refused the fresh worktrees' `mise.toml` as untrusted. `mise trust` writes outside the project, so every command ran with `MISE_TRUSTED_CONFIG_PATHS` set to the worktrees' parent directory for that command only.
- Photosphere still tracks `apps/ziggy-example/shells/ios/.../xcschememanagement.plist` and `apps/ziggy-example/out/ios/...`: build output left from the Ziggy example before it moved to its own repository. Nothing refers to it and nothing builds it, so it was not moved. Deleting it is the human's call.

Done: every suite passed, run in parallel lanes against the worktrees, with Android emulators attached (`adb devices` showed several in state `device`). Ziggy: `compile`, `test`, `test:zig`, `compile:zig`, `test:smoke`, `test:smoke:dev`, `test:android-shell`, `test:zig:android`, `test:smoke:and`, and the template's `test:smoke` and `test:smoke:and`. Each example: `compile`, `test`, `test:zig`, `compile:zig`, `test:smoke`, `test:smoke:and`. Photosphere: `compile`, `test`, `test:zig`, `test:ziggy`, `test:ziggy:and`. `git grep -n "shells/\|\"shells\""` prints nothing outside this plan in any of the four repositories. macOS, iOS and Windows were not run.
