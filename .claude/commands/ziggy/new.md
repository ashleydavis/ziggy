---
description: Start a new Ziggy app in the current folder, copied from the Ziggy template of the latest release, renamed and pinned to that release, with its tests run.
---

# Start a new Ziggy app

Make a new app from the Ziggy template in the current folder, following Ziggy's guide [Building your app](https://github.com/ashleydavis/ziggy/blob/main/docs/building-your-app.md), section "Starting a new app from the template", which pins the app to Ziggy's latest release with the lines [Integrating Ziggy](https://github.com/ashleydavis/ziggy/blob/main/docs/integrating-ziggy.md) gives for a version tag. Read both before doing anything: they are the authority, and this command only says how to carry them out. The [Vite example](https://github.com/ashleydavis/ziggy-example-vite) is an app made this way: when a step is unclear, do what it did.

## Find the latest release

Find Ziggy's latest release, as step 1 of the guide says. If there is none, stop and say so. Tell the human which release the app will be pinned to.

## Ask for the names

Ask the human for these, in one message, and wait for the answers. Suggest values worked out from the first one, so they can accept them.

- The app's name, lowercase with dashes (`my-photo-app`). The backend library's name is this with each `-` as `_`.
- The name a user sees (`My Photo App`).
- The app's identifier, reverse domain (`com.example.myphotoapp`).
- The Xcode projects' name, PascalCase (`MyPhotoApp`).
- Which bundler builds the UI: Vite, as the template does, or another.

## Make the app

1. Check the current folder is empty apart from hidden files. If it is not, stop and say what is in it.
2. Download the template and Ziggy's `mise.toml` of that release and install the tools, as step 2 of the guide says.
3. Pin every part to the release, as step 3 of the guide says. Use the same form of each line the Vite example uses.
4. Rename the app, every form the guide lists, using the answers above. Rename the folders and files that carry a name too: the `.xcodeproj` folders, the source folders beside them, the schemes and the Android Java package's folder. When done, search the whole app, case-insensitively, for `ziggy-template`, `ziggy_template`, `ZiggyTemplate`, `dev.ziggy.template` and "Ziggy template", and fix anything left. Anything that names Ziggy itself (`ziggy-core`, `ziggy-ui`, `ZiggyNativeMacOS`, `dev.ziggy.nativeapp` and the like) stays as it is.
5. Make new GUIDs for `scripts/package-windows.wxs` with `uuidgen`: the `UpgradeCode` and every `Component`'s `Guid`.
6. Run `zig build`. It fails and prints the new fingerprint. Put it in `build.zig.zon` as `.fingerprint` and run `zig build` again.
7. Run `bun install`.
8. When the human chose a bundler other than Vite, replace Vite with it: the `dev:ui` script, the `vite build` call in `scripts/bundle-ui.sh`, the build config and the dev dependencies. The built UI must still load from a relative address with a classic deferred script, which is what the template's `vite.config.ts` does.
9. Run `git init` only when the human asks for it.

## Check it

Run the app's checks with `/ziggy:check`. Every one must pass before you report that the app is made. A failure is a mistake in the copy, the rename or the pointing at Ziggy: find it and fix it. Say which checks ran and which platforms they could not run on.

Then tell the human the next steps in a few lines: `bun run dev` to work on the UI in a browser, `/ziggy:add-channel` and `/ziggy:add-task` to give the backend work to do.
