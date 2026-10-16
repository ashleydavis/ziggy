# Docs review checklist

Every tracked markdown doc in the repo outside `docs/plans/`. Regenerate the list with `git ls-files '*.md' | grep -v '^docs/plans/'`.

## Top level

- [x] [README.md](../README.md)
- [x] [CLAUDE.md](../CLAUDE.md)

## Guides under docs/

- [x] [quick-start.md](quick-start.md)
- [x] [user-guide.md](user-guide.md)
- [x] [glossary.md](glossary.md)
- [x] [architecture.md](development/architecture.md)
- [x] [diagrams/communication.md](development/diagrams/communication.md)
- [x] [diagrams/dev-mode.md](development/diagrams/dev-mode.md)
- [x] [diagrams/message-bridge.md](development/diagrams/message-bridge.md)
- [x] [diagrams/task-queue.md](development/diagrams/task-queue.md)
- [ ] [dev-mode.md](development/dev-mode.md)
- [ ] [channels.md](user-guide/channels.md)
- [ ] [tasks.md](user-guide/tasks.md)
- [ ] [native-calls.md](user-guide/native-calls.md)
- [ ] [testing.md](user-guide/testing.md)
- [ ] [packages.md](development/packages.md)
- [ ] [user-guide/dependencies.md](user-guide/dependencies.md)
- [ ] [building-your-app.md](user-guide/building-your-app.md)
- [ ] [distributing-your-app.md](user-guide/distributing-your-app.md)
- [ ] [user-guide/scripts.md](user-guide/scripts.md)
- [ ] [development/commands.md](development/commands.md)
- [ ] [claude-code-commands.md](user-guide/claude-code-commands.md)
- [ ] [developing-ziggy.md](development/developing-ziggy.md)
- [ ] [releasing-ziggy.md](development/releasing-ziggy.md)

## Ziggy package

- [ ] [packages/ziggy/README.md](../packages/ziggy/README.md)
- [ ] [packages/ziggy/native/android/README.md](../packages/ziggy/native/android/README.md)
- [ ] [packages/ziggy/native/ios/README.md](../packages/ziggy/native/ios/README.md)
- [ ] [packages/ziggy/native/macos/README.md](../packages/ziggy/native/macos/README.md)

## Repo scripts and smoke tests

- [x] [scripts/render-diagrams.md](../scripts/render-diagrams.md)
- [x] [scripts/test-android-shell.md](../scripts/test-android-shell.md)
- [x] [scripts/test-zig-mobile.md](../scripts/test-zig-mobile.md)
- [x] [smoke-tests/run.md](../smoke-tests/run.md)
- [x] [smoke-tests/run-desktop.md](../smoke-tests/run-desktop.md)
- [x] [smoke-tests/lib/process-control.md](../smoke-tests/lib/process-control.md)
- [x] [smoke-tests/lib/test-lib.md](../smoke-tests/lib/test-lib.md)
- [x] [smoke-tests/lib/test-timeout.md](../smoke-tests/lib/test-timeout.md)

## Claude Code commands

- [ ] [ziggy/new.md](../.claude/commands/ziggy/new.md)
- [ ] [ziggy/upgrade.md](../.claude/commands/ziggy/upgrade.md)
- [ ] [ziggy/check.md](../.claude/commands/ziggy/check.md)
- [ ] [ziggy/add-channel.md](../.claude/commands/ziggy/add-channel.md)
- [ ] [ziggy/add-task.md](../.claude/commands/ziggy/add-task.md)

## Ziggy template: READMEs

- [ ] [apps/ziggy-template/README.md](../apps/ziggy-template/README.md)
- [ ] [native/android/README.md](../apps/ziggy-template/native/android/README.md)
- [ ] [native/ios/README.md](../apps/ziggy-template/native/ios/README.md)
- [ ] [native/macos/README.md](../apps/ziggy-template/native/macos/README.md)
- [ ] [native/windows/README.md](../apps/ziggy-template/native/windows/README.md)

## Ziggy template: smoke tests

- [x] [smoke-tests/run.md](../apps/ziggy-template/smoke-tests/run.md)
- [x] [smoke-tests/run-desktop.md](../apps/ziggy-template/smoke-tests/run-desktop.md)
- [x] [smoke-tests/lib/process-control.md](../apps/ziggy-template/smoke-tests/lib/process-control.md)
- [x] [smoke-tests/lib/test-lib.md](../apps/ziggy-template/smoke-tests/lib/test-lib.md)
- [x] [smoke-tests/lib/test-timeout.md](../apps/ziggy-template/smoke-tests/lib/test-timeout.md)

## Ziggy template: scripts

### Shared

- [x] [setup.md](../apps/ziggy-template/scripts/setup.md)
- [x] [clean.md](../apps/ziggy-template/scripts/clean.md)
- [x] [bundle-ui.md](../apps/ziggy-template/scripts/bundle-ui.md)
- [x] [zig-packages.md](../apps/ziggy-template/scripts/zig-packages.md)
- [x] [release-notes.md](../apps/ziggy-template/scripts/release-notes.md)

### Linux

- [x] [build-linux.md](../apps/ziggy-template/scripts/build-linux.md)
- [x] [run-linux.md](../apps/ziggy-template/scripts/run-linux.md)
- [x] [open-linux.md](../apps/ziggy-template/scripts/open-linux.md)
- [x] [sync-linux.md](../apps/ziggy-template/scripts/sync-linux.md)
- [x] [package-linux.md](../apps/ziggy-template/scripts/package-linux.md)
- [x] [clean-linux.md](../apps/ziggy-template/scripts/clean-linux.md)

### Windows

- [x] [windows-common.md](../apps/ziggy-template/scripts/windows-common.md)
- [x] [setup-windows.md](../apps/ziggy-template/scripts/setup-windows.md)
- [x] [fetch-webview2.md](../apps/ziggy-template/scripts/fetch-webview2.md)
- [x] [fetch-wix.md](../apps/ziggy-template/scripts/fetch-wix.md)
- [x] [build-windows.md](../apps/ziggy-template/scripts/build-windows.md)
- [x] [run-windows.md](../apps/ziggy-template/scripts/run-windows.md)
- [x] [open-windows.md](../apps/ziggy-template/scripts/open-windows.md)
- [x] [sync-windows.md](../apps/ziggy-template/scripts/sync-windows.md)
- [x] [package-windows.md](../apps/ziggy-template/scripts/package-windows.md)
- [x] [clean-windows.md](../apps/ziggy-template/scripts/clean-windows.md)

### macOS and iOS

- [x] [apple-common.md](../apps/ziggy-template/scripts/apple-common.md)
- [x] [build-macos.md](../apps/ziggy-template/scripts/build-macos.md)
- [x] [run-macos.md](../apps/ziggy-template/scripts/run-macos.md)
- [x] [open-macos.md](../apps/ziggy-template/scripts/open-macos.md)
- [x] [sync-macos.md](../apps/ziggy-template/scripts/sync-macos.md)
- [x] [package-macos.md](../apps/ziggy-template/scripts/package-macos.md)
- [x] [clean-macos.md](../apps/ziggy-template/scripts/clean-macos.md)
- [x] [setup-ios.md](../apps/ziggy-template/scripts/setup-ios.md)
- [x] [ios-device.md](../apps/ziggy-template/scripts/ios-device.md)
- [x] [build-ios.md](../apps/ziggy-template/scripts/build-ios.md)
- [x] [run-ios.md](../apps/ziggy-template/scripts/run-ios.md)
- [x] [open-ios.md](../apps/ziggy-template/scripts/open-ios.md)
- [x] [sync-ios.md](../apps/ziggy-template/scripts/sync-ios.md)
- [x] [package-ios.md](../apps/ziggy-template/scripts/package-ios.md)
- [x] [clean-ios.md](../apps/ziggy-template/scripts/clean-ios.md)

### Android

- [x] [android-common.md](../apps/ziggy-template/scripts/android-common.md)
- [x] [lib/android-env.md](../apps/ziggy-template/scripts/lib/android-env.md)
- [x] [install-android-sdk.md](../apps/ziggy-template/scripts/install-android-sdk.md)
- [x] [setup-android.md](../apps/ziggy-template/scripts/setup-android.md)
- [x] [build-android.md](../apps/ziggy-template/scripts/build-android.md)
- [x] [run-android.md](../apps/ziggy-template/scripts/run-android.md)
- [x] [open-android.md](../apps/ziggy-template/scripts/open-android.md)
- [x] [sync-android.md](../apps/ziggy-template/scripts/sync-android.md)
- [x] [package-android.md](../apps/ziggy-template/scripts/package-android.md)
- [x] [distribute-android.md](../apps/ziggy-template/scripts/distribute-android.md)
- [x] [clean-android.md](../apps/ziggy-template/scripts/clean-android.md)

## Ziggy test app

`apps/ziggy-test-app` keeps only the docs that differ from the template's copy by more than the app's name.

- [ ] [apps/ziggy-test-app/README.md](../apps/ziggy-test-app/README.md)
- [ ] [shells/android/README.md](../apps/ziggy-test-app/shells/android/README.md)
- [ ] [scripts/android-common.md](../apps/ziggy-test-app/scripts/android-common.md)
- [ ] [scripts/distribute-android.md](../apps/ziggy-test-app/scripts/distribute-android.md)
- [ ] [scripts/ios-device.md](../apps/ziggy-test-app/scripts/ios-device.md)
- [ ] [scripts/package-linux.md](../apps/ziggy-test-app/scripts/package-linux.md)
- [ ] [scripts/release-notes.md](../apps/ziggy-test-app/scripts/release-notes.md)
