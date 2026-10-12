# Test the release build of a Ziggy app, with test hooks switched on by a signed token

## Overview

Today the smoke tests drive a separate test build, compiled with the `test-hooks` build option, and the app that ships is a different build that nothing runs. This plan makes the release build the one that is tested. The test hooks (test mode, the control connection, `pick-answer`, the network and single-instance skips) are compiled into every build and stay switched off unless the app is started with a short-lived token signed by the app's own private key. The app holds only the public key, passed in by the app's `build.zig`, so each app built on Ziggy has its own key pair and a token for one app does not work on another. The release workflow then builds each platform once, runs the unit tests and the smoke tests on that build and publishes nothing.

The work is in the `ziggy` repository (Ziggy and its example) and the `ziggy-example` repository (the test app, which is a copy of the example and gets the same changes). Photosphere picks the change up when it moves to the `ziggy` package (phases 3 and 4 of the extraction plan).

## Issues

## Steps

1. Write the documentation for the design as it is intended to work, in the `ziggy` repository, then STOP. Do not start step 2. Wait for the human to review and approve it. If they revise it, revise the remaining steps of this plan to match before continuing.
    - `docs/architecture.md`, section "Test hooks": the hooks are in every build and switched off by default; the token (what it holds: an expiry time and a per-run secret; how it is signed: Ed25519 over those fields; how it reaches the app on each platform: `ZIGGY_TEST_TOKEN` in the environment on desktop, the Intent extra `ziggy.testToken` on Android, `SIMCTL_CHILD_ZIGGY_TEST_TOKEN` on the iOS simulator); what the core checks (signature against the build's public key, expiry); that a build with no public key can never switch the hooks on; that the control connection refuses any connection whose first line is not the run's secret.
    - `docs/building-your-app.md`: making the app's key pair with the token tool (step 3), committing the public key file, passing it to Ziggy from the app's `build.zig`, keeping the private key out of the repository and storing it as a CI secret.
    - `apps/ziggy-example/smoke-tests/run.md`: the smoke tests run the release build; how the scripts make a token and pass it in; where the private key comes from (the CI secret, or a key pair the scripts make once per checkout under the app's gitignored `tmp/` when none is given).
    - `docs/releasing-ziggy.md` and the comment block at the top of `.github/workflows/release.yml`: one build job per platform, the unit test and smoke test jobs run on what it built and there is no package or publish job.

2. Core: switch the hooks on at run time instead of at build time. In `build.zig` replace the `test-hooks` option with a `test-public-key` option (a hex Ed25519 public key, empty by default) and pass it to the core's build options; change `dependency` to take the public key in place of `test_hooks: bool`. In `packages/ziggy/core/src/lib/core.zig`, register the test channels (the block at the `build_options.test_hooks` check) always, and only act on them once test mode is on. Add `packages/ziggy/core/src/lib/test-token.zig` with a function that parses a token, checks its Ed25519 signature (`std.crypto.sign.Ed25519`) against the build's public key, checks its expiry against the current time and returns the run's secret or an error naming the reason (no key built in, malformed, bad signature, expired). Replace `ziggy_test_hooks_enabled` in `ziggy-api.zig`, `ziggy.h` and `jni.zig` (`Java_dev_ziggy_shell_ZiggyNative_testHooksEnabled`) with a `ziggy_test_mode_from_token(token)` that returns whether the token is valid and keeps the secret for the control connection. Builds and `zig build test` pass.

3. Token tool: add a Zig program to the `ziggy` package (a `ziggy-test-token` build step, exported from `build.zig` for apps to use) with two commands: `keygen <private-key-file> <public-key-file>` and `sign <private-key-file> <expires-in-seconds>`, which prints a token holding a fresh random secret. Shell scripts call it rather than openssl, because the MacOS runner's LibreSSL cannot be relied on for Ed25519. Unit tests cover it.

4. Control connection: in `packages/ziggy/core/src/lib/test-control.zig`, require the first line of every connection to be `{"command": "hello", "secret": "<secret>"}` with the secret from the token, and close the connection on anything else.

5. Shells: read the token instead of `ZIGGY_TEST_MODE` and ask the core to check it. Linux `packages/ziggy/native/linux/src/lib/shell.zig` (the `ziggy_test_hooks_enabled` and `ZIGGY_TEST_MODE` lines), Windows `packages/ziggy/native/windows/src/lib/shell.zig`, MacOS and iOS `ZiggyBridge.swift`, Android `ZiggyShell.java` and `ZiggyNative.java` (extra `ziggy.testToken` replaces `ziggy.testMode`). `ZIGGY_TEST_PORT_FILE` stays. A refused token is logged with the core's reason and the app runs normally. The Android shell's JUnit tests and every shell's unit tests pass.

6. Example build: in `apps/ziggy-example/build.zig` replace the `test-hooks` option with reading the public key from a committed file `apps/ziggy-example/test-public-key.txt`, overridable with `-Dtest-public-key=<hex>`. Remove `--test-hooks` from every script that has it (`sync-*.sh`, `build-*.sh`, `lib/apple-common.sh`, `zig-packages.sh`); the cross-build loop in `zig-packages.sh` builds each target once instead of twice.

7. Example smoke tests: change `smoke-tests/lib/*.sh` so `ziggy_platform_prepare` uses a build it is given instead of building one: a new `ZIGGY_SMOKE_APP` variable (or `run.sh` argument) naming the packaged app (the Linux and Windows zip, the MacOS `.app` zip, the Android x86_64 APK, the iOS simulator `.app`); with none given it runs the platform's package script once. Each platform's start function makes a token with the token tool and passes it in place of `ZIGGY_TEST_MODE`. `send_command` in `lib/common.sh` sends the `hello` line first. The private key comes from `ZIGGY_TEST_PRIVATE_KEY_FILE`, or from a key pair the scripts make once under `apps/ziggy-example/tmp/` when it is unset; in that case the build uses the matching public key, so a local run works without the app's real private key.

8. Replace scenario `8-release-has-no-hooks` with `8-hooks-need-a-valid-token`: started with no token, with a token signed by another key and with an expired token, the app opens no control connection; with a valid token it does; a connection that does not send the secret first is closed. Watch it fail first by breaking the signature check.

9. iOS packaging: add a simulator build of the release app to `scripts/package-ios.sh` beside the device `.ipa`, so the smoke tests can run the release configuration on a simulator.

10. Workflow (`.github/workflows/release.yml` in `ziggy`):
    - `build`: one job per platform (linux, windows, macos, android, ios). It runs that platform's package script once and the cross-build check (Linux only), builds the unit test programs in ReleaseSafe and uploads the packages and the test programs as artifacts. The private key comes from a repository secret `ZIGGY_TEST_PRIVATE_KEY` written to a file under `tmp/`.
    - `unit-tests`: `needs: build`, downloads that platform's test programs and runs them (on the runner for desktop, on an emulator for Android, on a simulator for iOS) without compiling. Add whatever option `scripts/test-zig-mobile.sh` and `zig-packages.sh test` need to run programs they are given.
    - `smoke-tests`: `needs: build`, downloads that platform's package and runs the smoke tests on it with `ZIGGY_SMOKE_APP`.
    - Remove the `zig-build`, `package` and `publish` jobs and the Zig cache steps that only served them. `release-notes.sh` stays, because `distribute-android.sh` uses it.

11. Fix the Windows failure of scenario `5-cancel-one-of-several-sources` seen in `ziggy-example` run 38306113429 (cancelling the first of three sources did not cancel its task, which ran to the end). Find the cause in the Windows shell or the task queue and fix it there.

12. Run every test in `ziggy` here (Linux and Android): `zig build test`, the TypeScript tests, the Android shell's JUnit tests, the Zig tests on an emulator and the example's smoke tests on Linux and Android. Check the emulator pool first with `bun run emu:and:pool:status` in the Photosphere checkout.

13. Make a key pair for the example with the token tool. Commit `test-public-key.txt`. Give the human the private key file's path and the command to store it as the `ZIGGY_TEST_PRIVATE_KEY` secret (`gh secret set ZIGGY_TEST_PRIVATE_KEY -R ashleydavis/ziggy < <path>`), and wait for them to run it. Then, with the human's go-ahead to commit and push, push and follow the workflow until every job is green.

14. Apply steps 6 to 10 to the `ziggy-example` repository (the test app), with its own key pair and its own `ZIGGY_TEST_PRIVATE_KEY` secret. Its workflow clones `ziggy` beside it as it does now. Run its tests here, then, with the human's go-ahead, push and follow its workflow until every job is green.

15. Update the documentation from step 1 to match what was built, in `ziggy`, and the test app's README and `run.md`.

## Unit Tests

- `test-token.zig`: a valid token is accepted and returns its secret; a token signed by another key, a malformed token, an expired token and any token when the build has no public key are each refused with their own error.
- The token tool: `keygen` writes a pair that `sign` and the core's check agree on; `sign` makes a different secret each time.
- `test-control.zig`: a connection that sends the secret first is served; one that sends anything else first is closed without running a command.
- The shells' existing unit tests and the Android shell's JUnit tests, updated for the token in place of the test mode switch.

## Smoke Tests

- Every existing example scenario passes against the packaged release build on Linux, Windows, MacOS, Android and iOS.
- `8-hooks-need-a-valid-token`, as in step 8.

## Verify

- `zig build test`, the TypeScript tests and the Android shell's JUnit tests pass in `ziggy` and in the test app.
- The example's and the test app's smoke tests pass on Linux and Android here, run against the packaged release build.
- `git grep -n -E "test-hooks|test_hooks|ZIGGY_TEST_MODE|testHooksEnabled"` finds nothing in either repository outside the docs that describe the change.
- The `ziggy` and `ziggy-example` workflows are green on every platform, each platform's app is built once per run and no job builds what another job already built.

## Notes

- The smoke tests now run the shipped build, but two things shipped are still not run: the iOS device `.ipa` (a simulator cannot run it, so the simulator build of the same release configuration stands in) and the Android arm64 APK (the emulator runs x86_64).
- Every shipped app now contains the hook code. A leaked private key lets anyone switch the hooks on in that app until the key is changed, and a bug in the token check is a way in. The expiry and the per-run secret limit what a stolen token can do.
- Local runs use a key pair made under the app's `tmp/`, so developers never need the CI private key, and a build made locally only accepts tokens from that local key.
- Photosphere's smoke tests use `-Dtest-hooks` and `ZIGGY_TEST_MODE` today. They change to the token when Photosphere moves to the `ziggy` package, which is part of the extraction plan, not this one.
- Phone clocks: the expiry is checked against the device's clock. Emulators and simulators take the host's time, so this is not expected to matter in the tests.
