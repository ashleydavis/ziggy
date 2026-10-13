---
description: Start a new Ziggy app in the current folder, copied from the Ziggy template, renamed and pointed at Ziggy, with its tests run.
---

# Start a new Ziggy app

Make a new app from the Ziggy template in the current folder, following Ziggy's guide [Building your app](https://github.com/ashleydavis/ziggy/blob/main/docs/building-your-app.md), section "Starting a new app from the template". Read that section before doing anything: it is the authority, and this command only says how to carry it out.

## Find Ziggy

The app takes Ziggy from a checkout beside it (`../ziggy`). Check that `../ziggy` exists and is a Ziggy checkout (it has `packages/ziggy/core`). If it does not, stop and tell the human the command to clone it: `git clone https://github.com/ashleydavis/ziggy ../ziggy`. Do not clone it yourself.

## Ask for the names

Ask the human for these, in one message, and wait for the answers. Suggest values worked out from the first one, so they can accept them.

- The app's name, lowercase with dashes (`my-photo-app`). The core library's name is this with each `-` as `_`.
- The name a user sees (`My Photo App`).
- The app's identifier, reverse domain (`com.example.myphotoapp`).
- The Xcode projects' name, PascalCase (`MyPhotoApp`).
- Which bundler builds the UI: Vite, as the template does, or another.

## Make the app

1. Check the current folder is empty apart from hidden files. If it is not, stop and say what is in it.
2. Copy `../ziggy/apps/ziggy-template` into it, leaving out what builds write: `node_modules`, `dist`, `out`, `.zig-cache`, `zig-out`, `webview2-sdk`, `wix`, `tmp` and every `build` folder.
3. Write a `mise.toml` pinning the same Zig, Bun, Node and jq versions as `../ziggy/mise.toml`, and run `mise install`.
4. Point every part at Ziggy, as the guide lists: `build.zig.zon`, `shells/android/settings.gradle`, both Xcode projects and `package.json`. Delete the `.fingerprint` line from `build.zig.zon`.
5. Rename the app, every form the guide lists, using the answers above. Rename the folders and files that carry a name too: the `.xcodeproj` folders, the source folders beside them, the schemes and the Android Java package's folder. When done, search the whole app, case-insensitively, for `ziggy-template`, `ziggy_template`, `ZiggyTemplate`, `dev.ziggy.template` and "Ziggy template", and fix anything left. Anything that names Ziggy itself (`ziggy-core`, `ziggy-ui`, `ZiggyNativeMacOS`, `dev.ziggy.nativeapp` and the like) stays as it is.
6. Make new GUIDs for `scripts/package-windows.wxs` with `uuidgen`: the `UpgradeCode` and every `Component`'s `Guid`.
7. Run `zig build`. It fails and prints the new fingerprint. Put it in `build.zig.zon` as `.fingerprint` and run `zig build` again.
8. Run `bun install`.
9. When the human chose a bundler other than Vite, replace Vite with it: the `dev:ui` script, the `bundle:ui` script, the build config and the dev dependencies. The built UI must still load from a relative address with a classic deferred script, which is what the template's `vite.config.ts` does.
10. Run `git init` only when the human asks for it.

## Check it

Run the app's checks with `/ziggy:check`. Every one must pass before you report that the app is made. A failure is a mistake in the copy, the rename or the pointing at Ziggy: find it and fix it. Say which checks ran and which platforms they could not run on.

Then tell the human the next steps in a few lines: `bun run dev` to work on the UI in a browser, `/ziggy:add-channel` and `/ziggy:add-task` to give the core work to do.
