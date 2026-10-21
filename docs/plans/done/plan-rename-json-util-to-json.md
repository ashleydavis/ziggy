# Rename json_util to json

## Overview

Ziggy's core library exports its JSON helpers as `json_util` (`pub const json_util = @import("lib/json-util.zig");` in `packages/ziggy/core/src/index.zig`), so an app writes `ziggy.json_util.getString(...)` and `ziggy.json_util.stringify(...)`. The docs already show the shorter name the export should have, `ziggy.json` (`docs/quick-start.md` and `docs/user-guide/channels.md`), so they no longer match the code. This plan renames the export, its source file and its test file to `json` throughout Ziggy, the Ziggy template and Ziggy's test app, then moves the two example apps (`ziggy-example-vite` and `ziggy-example-rsbuild`, separate repositories that pin Ziggy to a version tag) onto a Ziggy release that has the new name. Backward compatibility is not required, so no `json_util` alias is kept.

## Issues

## Steps

- [x] 1. **Check the documentation.** The docs were changed ahead of the code, so this step drafts nothing new. Read `docs/quick-start.md` and `docs/user-guide/channels.md` and confirm every JSON helper call is written `ziggy.json.<function>` and that no doc outside `docs/plans/` still says `json_util` or `json-util` (`git grep -n 'json_util\|json-util' -- '*.md' ':!docs/plans'`). Fix any that do. STOP here and wait for the human to approve the documentation. If the human revises it, revise the remaining steps to match before continuing.
   - Done: both docs write `ziggy.json.getString` and `ziggy.json.stringify`, and the grep found no `json_util` or `json-util` in any doc. Nothing needed fixing. Decision in place of the human: the human told the implementing agent not to stop for review, so the docs were checked and work continued without an approval stop.

- [x] 2. **Rename the source file and the export in the core library.**
   - Rename `packages/ziggy/core/src/lib/json-util.zig` to `packages/ziggy/core/src/lib/json.zig` with `mv` (never `git mv`, which stages).
   - In `packages/ziggy/core/src/index.zig`, change `pub const json_util = @import("lib/json-util.zig");` to `pub const json = @import("lib/json.zig");`, and update the `//` comment above it if it names the old identifier.
   - In `packages/ziggy/core/src/lib/core.zig`, `task-runner.zig` and `test-control.zig`, change `const json_util = @import("json-util.zig");` to `const json = @import("json.zig");` and every `json_util.` in those files to `json.`.
   - Before renaming the local `const`, check each file for an existing declaration, parameter or local variable named `json` (`grep -n '\bjson\b'`). Zig refuses a name that shadows another in scope, so where one exists, rename that other identifier to say what it holds (for example `json_text`) rather than keeping `json_util`.
   - Run `mise exec -- zig build` from the repository root and fix every compile error.
   - Done: file renamed with `mv`, export and imports renamed. The index comment did not name the old identifier. The shadowing check found one clash, in `task-runner.zig`: a local `json` in `TaskContext.sendMessage` and a `json` parameter of `TaskContext.sendRawMessage`. Both were renamed to `message_json`. `zig build` succeeded.

- [x] 3. **Rename the core library's tests.**
   - Rename `packages/ziggy/core/src/test/json-util.test.zig` to `packages/ziggy/core/src/test/json.test.zig` with `mv`.
   - In it and in `packages/ziggy/core/src/test/dispatcher.test.zig`, `helpers.zig`, `queue-backend.test.zig`, `task-runner.test.zig` and `test-control.test.zig`, replace every `json_util` with `json` and every `json-util.zig` import path with `json.zig`, applying the same shadowing check as step 2.
   - Confirm how `build.zig` finds the test files (`addDirectoryTests`) and that the renamed file is still picked up, by checking that the JSON tests appear in the output of the run below.
   - Run `mise exec -- bun run test:zig` from the repository root. Every test must pass.
   - Done: test file renamed with `mv` and the listed tests updated. No shadowing clash in the test files. `addDirectoryTests` walks `src/test` for every `*.test.zig` file and imports each into a generated `all-tests.zig`; the generated file imports `src/test/json.test.zig`, so the renamed tests run. `bun run test:zig` passed (core: every test passed apart from the ones that were already skipped).

- [x] 4. **Rename the uses in the Ziggy template.** In `apps/ziggy-template/backend/src/lib/hello-world-backend.zig`, change `ziggy.json_util.` to `ziggy.json.`. Search the rest of `apps/ziggy-template` for `json_util` and change every hit. Run `mise exec -- bun run test:zig` and `mise exec -- bun run compile:zig` from `apps/ziggy-template`. Both must pass.
   - Done: `hello-world-backend.zig` was the only file in the template that used the old name. The template's `test:zig` and `compile:zig` both passed.

- [x] 5. **Rename the uses in Ziggy's test app.**
   - In `apps/ziggy-test-app/backend/src/lib/app-state.zig`, `hello-tasks.zig` and `pickers.zig`, change `const json_util = ziggy.json_util;` to `const json = ziggy.json;` and every `json_util.` to `json.`, applying the same shadowing check as step 2.
   - In `apps/ziggy-test-app/backend/src/lib/channels.zig` and the tests `apps/ziggy-test-app/backend/src/test/app-state.test.zig`, `handlers.test.zig` and `menu.test.zig`, replace every `json_util` with `json`.
   - Run `git grep -n 'json_util\|json-util' -- ':!docs/plans'` from the repository root. It must print nothing.
   - Run `mise exec -- bun run compile:zig` and `mise exec -- bun run test:zig` from the repository root. Both must pass.
   - Done: no shadowing clash in the test app. The grep printed nothing. `compile:zig` and `test:zig` passed, and so did `bun run compile` and `bun run test`.

- [x] 6. **Run the smoke tests and the phone suites.** The core library changed, so it is not tested until the phone suites have run. From the repository root run `mise exec -- bun run test:smoke`, `mise exec -- bun run test:smoke:dev`, `mise exec -- bun run test:zig:android` and `mise exec -- bun run test:smoke:and` (run `adb devices` first and read it: if no serial is in the `device` state, say so and stop, because the emulators belong to the human). Run the template's own smoke tests with `mise exec -- bun run --filter=ziggy-template test:smoke`. The iOS and macOS suites need a Mac: say they were not run.
   - Done: `adb devices` listed emulators in the `device` state. `test:smoke`, `test:smoke:dev`, `test:zig:android`, `test:smoke:and` and the template's `test:smoke` all passed. The iOS and macOS suites were not run (no Mac).

- [x] 7. **Stop for a Ziggy release.** The examples take Ziggy from a version tag, so they cannot move to the new name until a tag that has it exists. Cutting and pushing a tag is the human's to do (see `docs/development/releasing-ziggy.md`). STOP and tell the human the rename is ready for a release. Do not tag, commit or push.
   - Replaced: the examples (and Photosphere) no longer pin Ziggy to a tag. Their `build.zig.zon` takes Ziggy from the sibling checkout by relative path (`../ziggy`), so no release is needed. On the human's instruction nothing was tagged, committed or pushed, and the examples were changed and tested against the local Ziggy instead.

- [x] 8. **Move each example to the new release.** After the human says which tag has the rename, in each of `ziggy-example-vite` and `ziggy-example-rsbuild` (separate repositories, checked out beside this one):
   - Update the Ziggy pin to the new tag everywhere the example pins it: `build.zig.zon` (run `mise exec -- zig fetch --save=ziggy "git+https://github.com/ashleydavis/ziggy.git#<tag>"` so the hash is updated too), `package.json`, the Xcode projects and `shells/android/app/build.gradle`.
   - In `backend/src/lib/hello-world-backend.zig`, change `ziggy.json_util.` to `ziggy.json.`, and change any other `json_util` that `git grep -n json_util` finds.
   - Carry over any other change the template made between the old tag and the new one, as `/ziggy:upgrade` does.
   - Run each example's full test set: `bun run compile`, `bun run test`, `bun run compile:zig`, `bun run test:zig`, `bun run test:smoke`, and `bun run test:smoke:and` when an emulator is attached.
   - Done, against the local Ziggy rather than a tag (see step 7), so no pin was changed and there was no template change between tags to carry over. The examples have no `backend/src/lib/hello-world-backend.zig`; their Zig lives under `core/src`, and every `json_util` there (`core/src/lib/app-state.zig`, `channels.zig`, `hello-tasks.zig`, `pickers.zig` and the tests `app-state.test.zig`, `handlers.test.zig` and `menu.test.zig`) was renamed to `json`. `git grep -n json_util` prints nothing in either example. In each example `compile`, `test`, `compile:zig`, `test:zig`, `test:smoke` and `test:smoke:and` passed.
   - Photosphere also used the old name (its `packages-zig/photosphere-core` sources and tests), so it was renamed there too. Its docs never named the helpers. Photosphere's `compile`, `test`, `test:zig` and `test:ziggy` passed. The only remaining match there is inside a checked-in iOS debug-symbols binary under `apps/ziggy-example/out/`, a build output that was left alone.

- [x] 9. **Update the documentation.** Re-read `docs/quick-start.md`, `docs/user-guide/channels.md` and `docs/development/architecture.md` against the final code. Confirm each `ziggy.json` call in them matches the function names and signatures in `packages/ziggy/core/src/lib/json.zig`, and that any doc listing the core library's files names `json.zig` rather than `json-util.zig`.
   - Done: `json.zig` has `stringify(allocator, value)`, `getString(value, name)` and `getInteger(value, name)`, and every `ziggy.json` call in the docs matches them. `architecture.md` does not list the JSON helper file, and no doc names `json-util.zig`. No doc change was needed.

## Unit Tests

- No function is added or changed: only the name the helpers are reached by. The existing JSON helper tests, moved to `packages/ziggy/core/src/test/json.test.zig`, cover the helpers and must all pass under the new name.
- Every existing Zig test that calls the helpers (the core library's dispatcher, task runner, queue backend and test control tests, and the test app's app state, handlers and menu tests) must pass unchanged apart from the rename.

## Smoke Tests

- `bun run test:smoke` in Ziggy's repository: the test app's backend uses the helpers on most of its channels and tasks, so these scenarios exercise the renamed export end to end on the desktop.
- `bun run test:smoke:dev`: the same backend in the dev host.
- `bun run test:smoke:and` and `bun run test:zig:android`: the core library on Android.
- The template's `test:smoke`: its hello world message goes through `ziggy.json.getString` and `ziggy.json.stringify`.
- Each example's `test:smoke` after step 8.

## Verify

- `git grep -n 'json_util\|json-util' -- ':!docs/plans'` prints nothing in Ziggy's repository, and `git grep -n json_util` prints nothing in each example.
- `mise exec -- bun run compile:zig` and `mise exec -- bun run compile` succeed in Ziggy's repository and in each example.
- `mise exec -- bun run test:zig` and `mise exec -- bun run test` pass in Ziggy's repository and in each example.
- `mise exec -- bun run test:smoke`, `test:smoke:dev`, `test:zig:android` and `test:smoke:and` pass in Ziggy's repository, and the template's `test:smoke` passes.
- Each example's `test:smoke` passes against the new tag.

## Notes

- The source file and test file are renamed along with the export (`json-util.zig` to `json.zig`), so the file name and the name an app reaches it by agree.
- The local name `json` can clash with an existing `json` identifier in a file. The files use `std.json` with its prefix, which does not clash, but a parameter or local named `json` would. Steps 2, 3 and 5 check for this before renaming.
- The examples cannot change until a Ziggy release has the new name, and releasing is the human's job, so step 7 stops for it.
- The docs were changed to `ziggy.json` before this plan, so until step 5 is done they describe code that does not exist yet.
