# UI changes without a Zig rebuild

## Decisions not approved by a human

- A new command-line option, `--ui-dir <directory>`, makes the native app serve the frontend's files from that directory on disk instead of the files embedded in the executable.
- The option works in every build, like `--remote-control`, and does nothing unless it is given.
- The splash files Ziggy generates (`ziggy-splash.html`, `ziggy-splash-portrait.png`, `ziggy-splash-landscape.png`) are still served from the embedded files, because they are not in the app's built frontend.
- A request for a file missing from the directory gets the same not-found answer as a missing embedded file. It never falls back to the embedded copy, so a stale embedded file can never hide a missing one.
- The template gets a `dev:ziggy-template:<platform>` script per desktop platform: it builds the native app once when it has not been built, runs Vite's build in watch mode into the frontend's output directory and starts the app with `--ui-dir` pointing there. A UI change then needs only a reload (View, Reload) and no Zig build.

## Acceptance criteria

- Started with `--ui-dir <dir>`, the app serves `index.html` and every other frontend file from `<dir>`, read at request time.
- Changing a file in `<dir>` and reloading the page shows the change with no Zig build and no restart.
- Without `--ui-dir`, the app serves its embedded files exactly as today.
- `--ui-dir` naming a directory that does not exist stops the start with an error naming the directory.
- The template's dev script starts the app on the watched build, and a frontend edit shows after a reload with no Zig compile in between.

## Overview

The frontend is embedded in the executable at build time, so every UI change, however small, costs a Zig build and a relink before it can be seen in the real app. Ziggy's existing dev mode runs the frontend in a browser, which does not show the app in its own window and system web view. This plan lets a native app serve its frontend from a directory on disk when started with `--ui-dir`, so during development the frontend is rebuilt by Vite alone and the app picks up the change on reload.

## Issues

## Steps

1. [ ] **Core: an on-disk UI directory.**
    - In the core's C interface (`packages/ziggy/core/src/lib/ziggy.h`) add `const char* ui_dir;` to `ziggy_config`, with a comment: the directory the frontend's files are served from, or null for the embedded files. Mirror the field in the Zig side of the config wherever the other `ziggy_config` fields are declared.
    - In the core, at create time, when `ui_dir` is set: check the directory exists and fail `ziggy_create` with an error naming it when it does not; keep a copy of the path for the core's lifetime.
    - In the function behind `ziggy_ui_file` (the lookup every native app calls to serve a request), when `ui_dir` is set: for one of the three generated splash paths, answer from the embedded files as today; for any other path, reject a path that is absolute or contains a `..` segment, read the file from `ui_dir` joined with the path and answer with its bytes, or answer not found when it does not exist. The content type is chosen from the file name exactly as for an embedded file.
    - Memory: the bytes read are owned and freed the same way the lookup's caller already frees or holds an answer; if the current interface returns borrowed embedded bytes, add the matching free call to the interface and call it from each native app after the response is written.
    - Add the unit tests listed under Unit Tests to the core's test directory. Run `bun run test:zig` and save output to `tmp/evidence/tests/step-1.txt` and the build output to `tmp/evidence/compile/step-1.txt`.

2. [ ] **Native apps: the `--ui-dir` option.** In `packages/ziggy/native/linux/src/lib/native-app.zig`, `packages/ziggy/native/windows/src/lib/native-app.zig` and the macOS and iOS `ZiggyBridge.swift` and Android `ZiggyNativeApp.java`, wherever `--remote-control <host:port>` is taken out of the arguments:
    - Take `--ui-dir <directory>` out the same way, turn a relative directory into an absolute one against the current directory, and set `config.ui_dir`.
    - Android takes it as the extra `ziggy.uiDir`, as it takes `ziggy.remoteControl`.
    - Run `bun run test:zig` and the Linux smoke tests. Save output to `tmp/evidence/tests/step-2.txt`.

3. [ ] **Template: the dev scripts.** In the root `package.json` and the template's scripts:
    - Add `apps/ziggy-template/scripts/dev-linux.sh` (and the Windows and macOS equivalents beside the existing `run-*.sh` scripts), each with a `.md` beside it describing what it does, how it is invoked and its arguments. Each builds the native app with the existing build script when the executable is missing, starts `vite build --watch` with `launch_in_process_group`-style process handling used by the other scripts so it ends with the app, and starts the app with `--ui-dir` set to the Vite output directory.
    - Add `dev:ziggy-template:linux`, `dev:ziggy-template:windows` and `dev:ziggy-template:macos` to `package.json`.

4. [ ] **Smoke test.** Add `smoke-tests/desktop-only/<next number>-ui-dir/test.sh` and `test.md`:
    - Copy the test app's built frontend into the test's own directory (from `ziggy_test_temp_dir`), start the app with `--ui-dir` pointing at the copy (pass it through the platform library the same way `--remote-control` is passed), and check the page shows its usual text.
    - Edit one text in the copied `index.html` or bundle, choose the menu's reload (`choose_menu_item reload`), and check the changed text shows.
    - Start the app once more with `--ui-dir` naming a missing directory and check it exits non-zero with the directory's name in its output.
    - Run it alone and with the whole Linux suite. Save output to `tmp/evidence/tests/step-4.txt`.

5. [ ] **Documentation.**
    - `docs/user-guide/dev-mode.md`: a section on `--ui-dir` and the template's dev scripts: what it serves from disk, that the splash files stay embedded, that a reload picks up a change and that it needs no Zig build.
    - `docs/user-guide/testing.md` or wherever `--remote-control` is listed as a command-line option: add `--ui-dir`.
    - `docs/upgrade-notes.md`: under the next version, "New, and optional: `--ui-dir`", that `ziggy_config` has `ui_dir` for native code of the app's own that fills it field by field, and the template's new dev scripts to copy.
    - `apps/ziggy-template/README.md`: the dev scripts.

6. [ ] **Verify.** Run every check in the Verify section and save the output under `tmp/evidence/`.

7. [ ] **Self Review.** Check the evidence in `tmp/evidence/` against each Review item and the acceptance criteria. Uncheck any step whose evidence is missing or failing and add a step before Verify for anything missed.

## Unit Tests

- With no `ui_dir`, the UI file lookup answers the embedded file as today.
- With `ui_dir`, the lookup answers a file's bytes from disk, and answers the new bytes after the file is rewritten.
- With `ui_dir`, a missing file is not found, and is not answered from the embedded copy.
- With `ui_dir`, the three generated splash paths are answered from the embedded files.
- With `ui_dir`, a path that is absolute or contains `..` is not found.
- `ziggy_create` with a `ui_dir` that does not exist fails naming the directory.
- Each native app's argument parsing takes `--ui-dir <dir>` out of the arguments and makes it absolute (in the existing argument parsing tests for each platform that has them).

## Smoke Tests

- `<next number>-ui-dir`: the app serves its frontend from a directory on disk, shows an edit after a reload, and refuses a missing directory.
- Every existing suite still passes on Linux, showing the embedded path is unchanged.

## Verify

- `bun run test:zig` passes, and the Zig build and the Windows compile check pass.
- The TypeScript compile and unit tests pass.
- The Linux smoke tests pass, including the new `ui-dir` test.
- `bun run dev:ziggy-template:linux` starts the template, an edit to its frontend is shown after View, Reload, and the terminal shows no Zig build after the first.
- CI-only (no Windows, Mac or Android device here): the Windows, macOS, iOS and Android builds and smoke tests.

## Review

- [ ] The code compiles (evidence in `tmp/evidence/compile`).
- [ ] All tests have passed (evidence in `tmp/evidence/tests`).
- [ ] Acceptance criteria has been met (evidence in `tmp/evidence/acceptance`, including screenshots for GUI apps).
- [ ] The documentation is updated and accurate to the code. When the plan had a documentation review stop and the human approved the documentation, the code conforms to the approved documentation. Otherwise the documentation conforms to the code. Check the documentation against the rules too.
- [ ] Local project rules have been followed.
- [ ] Global rules have been followed.

## Reviewed

- [ ] The code compiles (evidence in `tmp/evidence/compile`).
- [ ] All tests have passed (evidence in `tmp/evidence/tests`).
- [ ] Acceptance criteria has been met (evidence in `tmp/evidence/acceptance`, including screenshots for GUI apps).
- [ ] The documentation is updated and accurate to the code. When the plan had a documentation review stop and the human approved the documentation, the code conforms to the approved documentation. Otherwise the documentation conforms to the code. Check the documentation against the rules too.
- [ ] Local project rules have been followed.
- [ ] Global rules have been followed.

## Review issues

## Notes

- The human chose no documentation review stop and asked for no research before the plan was written. Steps 1 and 2 therefore name the code by its role (the function behind `ziggy_ui_file`, the place each native app takes out `--remote-control`) rather than by line, and the executing agent finds each in the code.
- `--ui-dir` is not a test hook: it is for development, needs no `--remote-control`, and only changes where the app reads its own frontend from.
- A file watcher inside the app that reloads the page by itself was rejected: a reload from the menu is enough, and a watcher would mean a thread and platform file-watch code in every native app.
- Ziggy's existing dev mode (the frontend in a browser) is unchanged.
