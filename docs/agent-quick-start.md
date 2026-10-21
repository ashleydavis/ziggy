# New app quick start for agents

This page is for an AI coding agent, such as Claude Code, asked to start a new Ziggy app. To use it, start the agent in the empty directory the app will go in and tell it:

> Make a new Ziggy app here by following https://github.com/ashleydavis/ziggy/releases/latest/download/agent-quick-start.md

The rest of this page is the agent's instructions.

## Instructions

Make a new app from the Ziggy template in the current directory, pinned to Ziggy's latest release, following the guide "Building your app", section "Starting a new app from the template". The [Vite example](https://github.com/ashleydavis/ziggy-example-vite) is an app made this way: when a step is unclear, do what it did.

### Find the latest release

Find Ziggy's latest release, its highest version tag. The tag is the last part of the line this prints (`refs/tags/<tag>`):

```bash
git ls-remote --tags --refs --sort=-version:refname https://github.com/ashleydavis/ziggy 'v*' | head -n 1
```

If there is none, stop and say so. Tell the human which release the app will be pinned to.

Then read the guide of that release, `https://github.com/ashleydavis/ziggy/blob/<tag>/docs/user-guide/building-your-app.md`, before doing anything else. It is the authority, and this page only says how to carry it out. Read every other Ziggy doc at the same tag, never from `main`, so the steps match the template you copy.

### Ask for the names

Start by telling the human "I just need to know some details about your app...". Then ask for these one at a time, in this order: ask one question, wait for the answer, then ask the next. From the second question on, suggest a value worked out from the app's name, so they can accept it.

- The app's name, lowercase with dashes (`my-photo-app`). The backend library's name is this with each `-` as `_`.
- The name a user sees (`My Photo App`).
- The app's identifier, reverse domain (`com.example.myphotoapp`).
- The Xcode projects' name, PascalCase (`MyPhotoApp`).
- Which bundler builds the UI: Vite, as the template does, or another.

### Make the app

First tell the human that making the app takes a while, because it installs Zig, Bun, Node and jq with mise (the common way to install the exact versions of the tools a project uses) and installs the app's Bun and Zig dependencies (Ziggy among them).

Before each step below, and before committing the app, tell the human in one plain sentence what you are about to do and why, such as "Downloading the Ziggy template of v0.0.5 into this directory, which is the starting point of your app."

Do not build the app or run its tests, apart from the `zig build` in step 6 that prints the fingerprint. Building and testing it is the human's next step in the guide.

1. Check the current directory is empty apart from hidden files. If it is not, stop and say what is in it.
2. Download the template and Ziggy's `mise.toml` of that release and install the tools, as step 2 of the guide says. Before `mise install`, tell the human: "Installing Zig, Bun, Node and jq with mise, at the exact versions Ziggy's `mise.toml` pins, so this app builds with the same tools Ziggy is tested with."
3. Pin every part to the release, as step 3 of the guide says. Use the same form of each line the Vite example uses. Before `zig fetch`, tell the human: "Fetching Ziggy at <tag> as the app's Zig dependency, which records its address and hash in `build.zig.zon` so every build uses that exact version."
4. Rename the app, every form the guide lists, using the answers above. Rename the directories and files that carry a name too: the `.xcodeproj` directories, the source directories beside them, the schemes and the Android Java package's directory. When done, search the whole app, case-insensitively, for `ziggy-template`, `ziggy_template`, `ZiggyTemplate`, `dev.ziggy.template` and "Ziggy template", and fix anything left. Anything that names Ziggy itself (`ziggy-core`, `ziggy-ui`, `ZiggyNativeMacOS`, `dev.ziggy.nativeapp` and the like) stays as it is, and so do the Claude Code commands in `.claude/commands/ziggy`, which talk about the Ziggy template.
5. Make new GUIDs for `scripts/package-windows.wxs` with `uuidgen`: the `UpgradeCode` and every `Component`'s `Guid`.
6. Run `zig build`. It fails and prints the new fingerprint. Put it in `build.zig.zon` as `.fingerprint` and run `zig build` again.
7. Run `bun install`. Before it, tell the human: "Installing the app's Bun dependencies: TypeScript, Vite, Jest, Ziggy's UI types (`ziggy-ui`) and the rest of `package.json`."
8. When the human chose a bundler other than Vite, replace Vite with it: the `dev:ui` script, the `vite build` call in `scripts/bundle-ui.sh`, the build config and the dev dependencies. The built UI must still load from a relative address with a classic deferred script, which is what the template's `vite.config.ts` does.

### Commit it

Once the app is made, make the app a git repository and commit it, as step 6 of the guide says. Run `git status` before committing: the template's `.gitignore` keeps what builds and tests write out of the repository, so only the app's own files should be listed.

Then tell the human the next steps in a few lines: build and test the app with the commands in the guide's "Building and testing your new app" (`bun run compile`, `bun run test`, `bun run test:zig` and `bun run test:smoke`), run it with `bun run run:<platform>` for their platform, put it on GitHub, watch its CI and release workflows run and find each platform's release when they are done, as the guide's "Putting your app on GitHub" says, on GitHub's web pages (do not create the repository or push it yourself), `bun run dev` to work on the UI in a browser, and the Claude Code commands the app came with, `/ziggy:add-message` and `/ziggy:add-task`, to give the backend work to do.
