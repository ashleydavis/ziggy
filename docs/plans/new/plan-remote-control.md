# Remote control: test the release build, built once per platform

## Overview

The smoke tests must test the app that ships. The smoke tests drive a separate test build, compiled with the `test-hooks` build option, so the release build is never tested, and the app listens on a loopback port for the test script to connect to. This plan compiles the remote control code into every build, removes the `test-hooks` option and reverses the connection: a separate program, the remote control server, listens, and the app connects out to it only when started with `--remote-control <host:port>`. Because the release build is the test build, each platform is built and packaged once per workflow run, in a `app-build` job that runs first and caches its output, and the smoke tests install and drive that package. The work covers the `ziggy` repository (Ziggy, its template and its test app), the `ziggy-example-vite` and `ziggy-example-rsbuild` repositories and the `photosphere` repository. The same smoke tests run on Linux, Windows and macOS, and on Android and iOS they use a connected phone when there is one and an emulator or simulator otherwise.

## Issues

## Steps

### Ziggy repository

1. Remove the `test-hooks` build option, so the remote control code is in every build.
    - `build.zig`: delete the `test-hooks` option (line 13), the `test_hooks` parameter of `configureCore` and its `options.addOption(bool, "test_hooks", ...)`, and the `test_hooks` parameter of `dependency` (so it becomes `dependency(b, target, optimize)`) and the `.@"test-hooks"` it passes. Update the comment near line 768 about `--test-hooks`.
    - `packages/ziggy/core/src/lib/core.zig`: remove every `build_options.test_hooks` check (the start of the control connection near line 1005, the block near line 1105 and the test-result channel near line 1389), keeping the code inside them. The remote control connection starts when `config.test_mode` is true.
    - Delete `ziggy_test_hooks_enabled`: `packages/ziggy/core/src/lib/ziggy-api.zig` (the function, its `@export` and its mention in the comment near line 78), `packages/ziggy/core/src/lib/ziggy.h`, and `Java_dev_ziggy_nativeapp_ZiggyNative_testHooksEnabled` in `packages/ziggy/core/src/lib/jni.zig` with `testHooksEnabled` in `packages/ziggy/native/android/src/main/java/dev/ziggy/nativeapp/ZiggyNative.java`.
    - Remove the calls to it: Linux `packages/ziggy/native/linux/src/lib/native-app.zig` (line 219), Windows `packages/ziggy/native/windows/src/lib/native-app.zig` (line 477), macOS and iOS `ZiggyBridge.swift`, Android `ZiggyNativeApp.java` (line 157) and `packages/ziggy/dev/src/lib/dev-host.zig` (line 476). For this step test mode still comes from `ZIGGY_TEST_MODE` and the `ziggy.testMode` extra, so the smoke tests keep passing.
    - Dev tool: delete `--test-hooks` from `packages/ziggy/dev/src/lib/args.zig` (the `test_hooks` field and its parsing), `packages/ziggy/dev/src/lib/supervisor.zig` (the `-Dtest-hooks=true` argument) and `packages/ziggy/dev/src/test/args.test.zig`.
    - `apps/ziggy-template` and `apps/ziggy-test-app`: delete the `test-hooks` option from each `build.zig` and call `ziggy_build.dependency(b, target, optimize)`. Delete `--test-hooks` from every script under `scripts/` that takes it (`sync-*.sh`, `build-*.sh`, `lib/apple-common.sh`) and from their `.md` files. In each `scripts/zig-packages.sh`, build each target once instead of once per hooks value.
    - `apps/ziggy-template/native/android` and `apps/ziggy-test-app/native/android`: move the `INTERNET` permission, and anything else in `app/src/debug/AndroidManifest.xml`, into `app/src/main/AndroidManifest.xml` and delete the debug manifest. No app has a debug manifest.
    - Delete `smoke-tests/8-release-has-no-hooks`, and in `smoke-tests/lib/*.sh` and `apps/ziggy-template/smoke-tests/lib/*.sh` make `ziggy_platform_prepare` build once (the release build) and delete `ziggy_platform_artifact_files` and `ziggy_platform_has_control_port`, which only scenario 8 used.
    - `zig build`, `zig build test`, `bun run test` and `bun run test:android-shell` pass.

2. Add the remote control server, a TypeScript program using Express.js and the `ws` package, in a new tool directory `tools/remote-control-server` (`package.json` named `ziggy-remote-control-server` with a `bin` entry of the same name pointing at `src/index.ts`, `src/index.ts`, logic in `src/lib/`, tests in `src/test/`). Add `tools/*` to the root `package.json` `workspaces` and run `bun install` at the root. Lock `express`, `ws` and their type packages to their latest exact versions.
    - Invoked as `ziggy-remote-control-server --app-port <n> --script-port <n>`. It listens on the two loopback ports the test gives it: the app port, an Express server whose WebSocket endpoint (created with `ws` on the same HTTP server) the app connects to, and the script port, a plain TCP server (`node:net`) that the test script connects to with bash `/dev/tcp`. A port already in use ends it with an error naming the port.
    - It accepts one app connection at a time and one script connection at a time. Each line read from the script is sent to the app as one WebSocket text message, and each text message from the app is written back to the script as one line. When the app connection ends it accepts the next one, so a scenario that restarts the app keeps the same server. A script line that arrives when no app is connected waits for the app until a timeout, then gets `{"ok":false,"error":"AppNotConnected"}`.
    - Every failure is written to stderr with what failed and the port or path involved, and the process exits non-zero. It ends when its stdin closes or it receives SIGTERM.
    - Add `README.md` beside it covering its arguments.
    - Unit tests for every function in `src/lib/`. `bun run compile` and `bun run test` pass.

3. Reverse the control connection, rename it to remote control and read `--remote-control`.
    - `packages/ziggy/core/src/lib/types.zig` and `ziggy.h`: replace `test_port_file` with `remote_control: ?[*:0]const u8` (the server's `host:port`). Keep `test_mode`, which the native app sets to true exactly when `remote_control` is set.
    - Rename `packages/ziggy/core/src/lib/test-control.zig` to `remote-control.zig` and `core/src/test/test-control.test.zig` to `remote-control.test.zig`. Rename `TestControl` to `RemoteControl`, `from_test_control` to `from_remote_control`, the error `TestControlNotRunning` to `RemoteControlNotRunning` and the `test_control` export in `core/src/index.zig` to `remote_control`, and update every use (`test-commands.zig`, `core.zig` and the tests). Every comment and message that says "test control" says "remote control".
    - `remote-control.zig`: replace the listening socket, `acceptConnections` and the port file with one outgoing WebSocket connection to `ws://<config.remote_control>/`, read on one connection thread with the existing command handling: each WebSocket text message is one command and each reply is sent as one text message. The WebSocket client is `websocket.Client` from `karlseguin/websocket.zig`, added to Ziggy's `build.zig.zon` with `zig fetch --save` locked to an exact commit, and imported only by `remote-control.zig`. Before writing code against it, build it for every target Ziggy builds (Linux, Windows, macOS, Android and iOS) with Zig 0.16. If it does not build, report what failed and use `wssup`, which states Zig 0.16 support. `beginStop` closes the WebSocket to end the thread's read instead of connecting to wake `accept`. Update the file's top comment. A failed connect fails `RemoteControl.start` with an error that names the address, which makes the app's start fail.
    - Native apps: read `--remote-control <host:port>` from the command line and remove both arguments before the arguments reach the app's `on_create`, so an app's own argument handling never sees them. Linux `native-app.zig` (remove them from argv before `g_application_run`, because GApplication refuses options it does not know), Windows `native-app.zig`, macOS and iOS `ZiggyBridge.swift` (`CommandLine.arguments`), the dev host `dev-host.zig`. Android `ZiggyNativeApp.java` reads the string extra `ziggy.remoteControl` instead. Delete every read of `ZIGGY_TEST_MODE`, `ZIGGY_TEST_PORT_FILE`, `ziggy.testMode` and `ziggy.testPortFile`.
    - `packages/ziggy/dev`: add `--remote-control <host:port>` to `args.zig` and pass it through `supervisor.zig` to the dev host.
    - Tests: `core/src/test/remote-control.test.zig`, `main-thread.test.zig` and `dispatcher.test.zig` start a WebSocket server of their own with `websocket.zig`'s server, pass its address as `remote_control` and accept the core's connection. Add tests for the argument removal in each native app's tests and for `args.zig`.
    - `zig build`, `zig build test`, `bun run test` and `bun run test:android-shell` pass.

4. Smoke tests use the server and a packaged app. Make the same change in `smoke-tests/` and `apps/ziggy-template/smoke-tests/`.
    - `lib/common.sh`: `start_test_app` picks two random ports, starts `bun run ziggy-remote-control-server --app-port <n> --script-port <n>` in the background with `launch_in_process_group`, sets `ZIGGY_CONTROL_HOST=127.0.0.1`, `ZIGGY_CONTROL_PORT` to the script port and `ZIGGY_REMOTE_CONTROL` to `127.0.0.1:<app port>`, then calls `ziggy_platform_start`. `open_control_connection` connects once the server is listening. `stop_app_on_exit` also stops the server. `control` is unchanged. Update the interface comment at the top of the file.
    - `lib/linux.sh`, `lib/windows.sh`, `lib/macos.sh`: pass `--remote-control "$ZIGGY_REMOTE_CONTROL"` to the executable in place of the `ZIGGY_TEST_MODE` and `ZIGGY_TEST_PORT_FILE` variables, and delete the port-file wait.
    - `lib/ios.sh`: `xcrun simctl launch "$udid" "$IOS_BUNDLE_ID" --remote-control "$ZIGGY_REMOTE_CONTROL"` in place of the `SIMCTL_CHILD_` variables.
    - `lib/android.sh`: `adb reverse tcp:<app port> tcp:<app port>` in place of `adb forward`, the extra `--es ziggy.remoteControl "$ZIGGY_REMOTE_CONTROL"` in place of `ziggy.testMode` and `ziggy.testPortFile`, and `adb reverse --remove` on stop.
    - `lib/ios-device.sh` (used in place of the simulator when an iPhone or iPad is connected): launch the app with `--remote-control "$ZIGGY_REMOTE_CONTROL"` in place of the test environment, and delete the port forward of the old control port.
    - `ziggy_platform_prepare` takes the packaged app from `ZIGGY_SMOKE_PACKAGE` when it is set (the Linux zip, the Windows zip, the macOS app zip, the Android x86_64 APK, the iOS simulator `.app`) and installs or unpacks it into the run directory. When it is not set it runs the platform's package script once (the iOS simulator build script for iOS).
    - Run `bun run test:smoke` on Linux and every scenario passes. Run `bash -n` over every edited script.

5. Ziggy workflows: build once per platform, then reuse it. Edit `.github/workflows/ci.yml` and `.github/workflows/release.yml`.
    - Keep the workflow diff small: edit jobs in place, keep job names, step names, comments and order wherever they still apply, and change only the lines this step needs.
    - Every later job that uses a Zig build needs the job that built it (`app-build` for the app, `cli-build` for the CLI), restores that job's cache with `fail-on-cache-miss: true` and runs no Zig build of its own. The one exception is `zig build test` in the unit test jobs, which compiles the tests on top of the restored `.zig-cache`. Jobs that use no Zig build (the TypeScript compile and unit test jobs) need neither.
    - Rename the Linux-only `zig-build` job to `app-build` and replace its "Build and cross-build the Zig code" step, so `app-build` runs first, as a matrix over `linux`, `windows`, `macos`, `android` and `ios`, each on its own runner (the runners the `smoke-tests` matrix uses). Each entry builds the test app, runs the test app's package script for its platform (and for `ios` also the simulator build) and saves the install prefixes, the packages and `.zig-cache` with `actions/cache/save` under `ziggy-build-<platform>-${{ github.sha }}`.
    - `unit-tests` and `smoke-tests`: `needs: app-build`, restore that key with `actions/cache/restore` and `fail-on-cache-miss: true`, and stop building the app themselves. `smoke-tests` sets `ZIGGY_SMOKE_PACKAGE` to the restored package.
    - `release.yml` `publish` keeps `needs: [app-build, unit-tests, smoke-tests]`.
    - Update the comment blocks at the top of both files and above each job.

### Example repositories

Make every change in this section in `ziggy-example-vite` and again in `ziggy-example-rsbuild`.

6. Move to the Ziggy release that contains steps 1 to 5: run `zig fetch --save=ziggy "git+https://github.com/ashleydavis/ziggy.git?ref=<tag>"` so `build.zig.zon` names the new tag and hash, and update the tag in `package.json`, the Xcode projects and `native/android/app/build.gradle`, as Ziggy's `CLAUDE.md` requires.

7. Remove the test hooks build and add the server. Add `ziggy-remote-control-server` from the Ziggy repository at the same tag to `devDependencies` in `package.json` and run `bun install`.
    - `build.zig`: delete the `test-hooks` option and its comment, call `ziggy_build.dependency(b, target, optimize)`.
    - Delete `--test-hooks` from `scripts/sync-*.sh`, `scripts/build-*.sh`, `scripts/lib/apple-common.sh` and their `.md` files. `scripts/zig-packages.sh`: the `cross` mode builds each target once.
    - `native/android`: move the `INTERNET` permission, and anything else in `app/src/debug/AndroidManifest.xml`, into `app/src/main/AndroidManifest.xml` and delete the debug manifest.
    - `smoke-tests/lib/*.sh`: the same changes as step 4.
    - `zig build`, `zig build test`, `bun run test` and `bun run test:smoke` on Linux pass.

8. Example workflows.
    - Keep the workflow diff small: edit jobs in place, keep job names, step names, comments and order wherever they still apply, and change only the lines this step needs.
    - Every later job that uses a Zig build needs the job that built it (`app-build` for the app, `cli-build` for the CLI), restores that job's cache with `fail-on-cache-miss: true` and runs no Zig build of its own. The one exception is `zig build test` in the unit test jobs, which compiles the tests on top of the restored `.zig-cache`. Jobs that use no Zig build (the TypeScript compile and unit test jobs) need neither.
    - `.github/workflows/ci.yml`: rename the `zig-build` job to `app-build` and replace its "Build and cross-build the Zig code" step, so `app-build` runs first as a matrix over `linux`, `windows`, `macos-arm64`, `macos-x64`, `android` and `ios` on their own runners, each running `bun run package:<platform>` (and for `ios` the simulator build) and saving the output and `.zig-cache` under `example-build-<platform>-${{ github.sha }}`. `zig-unit-tests` needs `app-build` and restores the Linux entry with `fail-on-cache-miss: true`.
    - Each `.github/workflows/release-<platform>.yml`, edited in place: add a first `app-build` job on that platform's runner that runs `bun run package:<platform>` (and for iOS the simulator build) and saves the output under the same key. `app-smoke-tests` needs `app-build`, restores the key and runs the smoke tests with `ZIGGY_SMOKE_PACKAGE` set. Delete `package-release`. `create-release` needs `[app-build, app-smoke-tests]` and uploads the package restored from the cache.
    - Update the comment blocks at the top of each workflow (they mention the cross-build and the separate package job).

### Photosphere repository

9. Move to the Ziggy release: `zig fetch --save=ziggy "git+https://github.com/ashleydavis/ziggy.git?ref=<tag>"`, and update the `ziggy` tag in `apps/photosphere-frontend/package.json`.

10. Remove the test hooks build and add the server. Add `ziggy-remote-control-server` from the Ziggy repository at the same tag to `devDependencies` in the root `package.json` and run `bun install`.
    - `build.zig`: delete the `test-hooks` option (line 184), call `ziggy_build.dependency(b, target, optimize)` (line 216), replace `test_modules` (line 234) with `modules`, since the hooks are always in.
    - Delete `--test-hooks` from every script in `apps/photosphere/scripts/` that takes it and from its `.md` file.
    - `apps/photosphere-smoke-tests/lib/*.sh`: the same changes as step 4, with the `PHOTOSPHERE_CONTROL_HOST` and `PHOTOSPHERE_CONTROL_PORT` names this suite uses. Keep `PHOTOSPHERE_TEST_MODE=1`, which is Photosphere's own test mode, and delete `ZIGGY_TEST_MODE`.
    - `.claude/commands/test/manual-walkthrough.md` and `auto-walkthrough.md`: build with `zig build photosphere-linux -p tmp/desktop-hooks/test` and start the app with `--remote-control` through the server.
    - `zig build`, `zig build test -Dcpu=baseline`, `bun run test` and the Linux app smoke tests pass.

11. Photosphere workflows.
    - Keep the workflow diff small: edit jobs in place, keep job names, step names, comments and order wherever they still apply, and change only the lines this step needs.
    - Every later job that uses a Zig build needs the job that built it (`app-build` for the app, `cli-build` for the CLI), restores that job's cache with `fail-on-cache-miss: true` and runs no Zig build of its own. The one exception is `zig build test` in the unit test jobs, which compiles the tests on top of the restored `.zig-cache`. Jobs that use no Zig build (the TypeScript compile and unit test jobs) need neither.
    - `ci-zig.yml`: add a first `app-build` job, a matrix over the platforms the release workflows build (`linux`, `windows`, `macos-arm64`, `macos-x64`, `android`, `ios`), and a `cli-build` matrix job beside it over the desktop platforms. Each entry runs the `build-aws-sdk`, `build-zlib-ng`, `build-imagemagick` and `build-ffmpeg` actions from `.github/actions` as steps, then the build, and saves the output under `photosphere-app-<platform>-${{ github.sha }}` or `photosphere-cli-<platform>-${{ github.sha }}`. Delete the separate library jobs. `zig-unit-tests` needs both and restores the Linux entries with `fail-on-cache-miss: true`.
    - Each `release-zig-<platform>.yml`, edited in place: `app-build` is the first job, on that platform's runner. Its steps resolve the tag (the `prepare-tag` script, with its `tag` and `is-release` outputs), run the library actions, run `bun run --filter=ziggy package:<platform>` with the version (for iOS also the simulator build) and save the output. On desktop platforms `build-zig-<platform>` becomes `cli-build`, with the library steps and no `needs`. `cli-smoke-tests` needs `cli-build`, `app-smoke-tests` needs `app-build` and sets `PHOTOSPHERE_SMOKE_PACKAGE`, and both restore with `fail-on-cache-miss: true`. Delete `prepare-tag`, the library jobs and `package-release`. `create-release` needs every other job and uploads the restored package and CLI.
    - Update the comment blocks in each workflow.

### Documentation

12. Write the documentation in each repository to match the code.
    - Ziggy `docs/user-guide/testing.md` and `docs/development/architecture.md` ("Test hooks"): the remote control code is in every build; it does nothing unless the app is started with `--remote-control <host:port>` (the `ziggy.remoteControl` extra on Android); the app connects out to the remote control server; how the server relays lines between the script and the app.
    - Ziggy `docs/development/commands.md`: `--remote-control` replaces `--test-hooks` for `ziggy dev`. Add `tools/remote-control-server/README.md` covering the program and its arguments.
    - Ziggy `docs/glossary.md`: define "remote control server" and update any entry about test hooks.
    - Ziggy `CLAUDE.md` line 35 and `ziggy-example-vite/CLAUDE.md` line 33 (and the rsbuild copy): the rule that hooks exist only in builds with the `test-hooks` option is replaced by one saying the hooks act only when the app is started with `--remote-control`.
    - Each example's `README.md` "Test hooks" section and command table, `smoke-tests/run.md` and every script `.md` that says a build option is "never for a release".
    - Photosphere `apps/photosphere-smoke-tests/run.md`, `README.md`, `lib/common.md` and `docs/photosphere-on-ziggy.md`.
    - The top comment of each workflow file describes the `app-build` job and what depends on it.

## Unit Tests

- `remote-control-server/src/test/*.test.ts`: listening on the ports it is given; a port in use ends it with an error naming the port; relaying a script line to the app and the reply back; accepting a second app after the first disconnects; `AppNotConnected` after the timeout; a script disconnecting mid-command.
- `core/src/test/remote-control.test.zig`: the core connects to `remote_control` and answers commands; a refused connection fails `RemoteControl.start` with the address in the error; `beginStop` ends the connection thread.
- `core/src/test/main-thread.test.zig` and `dispatcher.test.zig`: updated to the outgoing connection; `RemoteControlNotRunning` when `remote_control` is null.
- Each native app's tests: `--remote-control <address>` sets `test_mode` and `remote_control` and is removed from the arguments passed on; arguments without it pass through unchanged; `--remote-control` with no address is reported as an error.
- `dev/src/test/args.test.zig`: `--remote-control` parsed; `--test-hooks` no longer accepted.
- Android `ZiggyNativeApp` JUnit test: the `ziggy.remoteControl` extra sets remote control; its absence leaves test mode off.

## Smoke Tests

- Every existing scenario in Ziggy's `smoke-tests`, the template's, each example's and Photosphere's `apps/photosphere-smoke-tests` runs against the packaged app through the remote control server, on each platform the workflows run.
- New Ziggy scenario `smoke-tests/8-starts-without-remote-control`: starts the packaged app without `--remote-control`, checks it runs and that the server's app port gets no connection within a set time.
- `restart_test_app` scenarios (those that pass `keep-data`) pass, which shows the server accepts a second app connection.

## Verify

- `zig build` and `zig build test` exit 0 in each repository; `bun run compile` and `bun run test` exit 0; `bun run test:android-shell` exits 0 in Ziggy.
- `bash -n` passes over every edited shell script.
- `grep -rni "test control\|test-control\|test_control\|TestControl\|test-hooks\|test_hooks\|ZIGGY_TEST_MODE\|ZIGGY_TEST_PORT_FILE\|ziggy.testMode" ` over each repository (excluding `node_modules`, `zig-pkg`, `.zig-cache`, `zig-out`, `docs/plans` and Photosphere's `apps/desktop` and `apps/smoke-tests`) prints no matches.
- The Linux smoke tests pass locally in each repository with `ZIGGY_SMOKE_PACKAGE` (or `PHOTOSPHERE_SMOKE_PACKAGE`) pointing at the output of the Linux package script.
- In each workflow file every job that uses a Zig build needs `app-build` or `cli-build` (Photosphere only), no other job runs a package script or a `zig build` other than `zig build test`, and no workflow step cross-compiles (`grep -n "cross" .github/workflows/*.yml` prints only comments that say the build is native).
- The workflows pass on GitHub for every platform once the branch is pushed.

## Notes

- `prepare-tag` and Photosphere's library jobs ran before the build. They become steps of `app-build` so it is the first job. `app-build` and `cli-build` both run the library actions; on a cache miss both compile the libraries.
- GitHub evicts cache entries once a repository passes its cache size limit. A run whose `app-build` entry was evicted before a later job restored it fails with `fail-on-cache-miss`; re-running the workflow rebuilds it.
- The iOS simulator cannot run the device IPA, so iOS builds twice in `app-build`: the simulator app for the smoke tests and the IPA for distribution.
- The Android package script builds `x86_64` and `arm64` by default, so the emulator smoke tests install the `x86_64` APK from the package.
- The release builds carry the remote control code, and any process that can launch the app can start it with `--remote-control`. No token or other check guards it.
- Steps 6 and 9 need a Ziggy release tag that contains steps 1 to 5. The executing agent cannot push or tag Ziggy: at step 6 it reports that the tag is needed and continues with the steps that do not depend on it. `docs/plans/new/plan-ziggy-signed-test-hooks.md` describes a different design (signed tokens and a listening port) for the same goal; this plan replaces that design.
- Photosphere's Electron app (`apps/desktop`) and `apps/smoke-tests` have their own control server (`TestControlServer`) and are not changed by this plan.
- `websocket.zig` becomes Ziggy's first dependency (`build.zig.zon` has none), so every app built on Ziggy links it.
- The iOS device package (`package-ios.sh`) is unsigned and does not install on a phone, so a smoke run on a connected iPhone still needs its own signed build.
- Settled, not to be reopened:
    - The app connects to the remote control server over WebSocket. The server is TypeScript with Express.js, in `tools/remote-control-server/` in the Ziggy repository.
    - The test picks the server's two ports at random and passes them in. There is no port file.
    - The examples and Photosphere install the server as a dev dependency from the Ziggy repository.
    - The existing workflows are edited in place with the smallest diff: no workflow is merged, added or split. The build jobs are `app-build` and, in Photosphere, `cli-build`.
    - No app has a debug Android manifest. `INTERNET` is in each main manifest.
    - How a connected iPhone reaches the server is outside this plan.
