# Docs review checklist

Every tracked markdown doc in the repo outside `docs/plans/`. Regenerate the list with `git ls-files '*.md' | grep -v '^docs/plans/'`.

## Top level

- [x] [README.md](../README.md)
- [ ] [CLAUDE.md](../CLAUDE.md)

## Guides under docs/

- [x] [quick-start.md](quick-start.md)
- [x] [user-guide.md](user-guide.md)
- [x] [glossary.md](glossary.md)
- [ ] [architecture.md](development/architecture.md)
- [x] [diagrams/communication.md](development/diagrams/communication.md)
- [x] [diagrams/dev-mode.md](development/diagrams/dev-mode.md)
- [x] [diagrams/message-bridge.md](development/diagrams/message-bridge.md)
- [x] [diagrams/task-queue.md](development/diagrams/task-queue.md)
- [ ] [dev-mode.md](development/dev-mode.md)
- [ ] [user-guide/dev-mode.md](user-guide/dev-mode.md)
- [ ] [app-declaration.md](user-guide/app-declaration.md)
- [ ] [messages.md](user-guide/messages.md)
- [ ] [menus.md](user-guide/menus.md)
- [ ] [tasks.md](user-guide/tasks.md)
- [ ] [threads.md](user-guide/threads.md)
- [ ] [native-calls.md](user-guide/native-calls.md)
- [ ] [testing.md](user-guide/testing.md)
- [ ] [packages.md](development/packages.md)
- [ ] [user-guide/dependencies.md](user-guide/dependencies.md)
- [x] [building-your-app.md](user-guide/building-your-app.md)
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

- [ ] [scripts/render-diagrams.md](../scripts/render-diagrams.md)
- [ ] [scripts/test-android-shell.md](../scripts/test-android-shell.md)
- [ ] [scripts/test-zig-mobile.md](../scripts/test-zig-mobile.md)
- [x] [smoke-tests/run.md](../smoke-tests/run.md)
- [x] [smoke-tests/run-desktop.md](../smoke-tests/run-desktop.md)
- [x] [smoke-tests/lib/process-control.md](../smoke-tests/lib/process-control.md)
- [x] [smoke-tests/lib/test-lib.md](../smoke-tests/lib/test-lib.md)
- [x] [smoke-tests/lib/test-timeout.md](../smoke-tests/lib/test-timeout.md)

## Claude Code commands

- [ ] [agent-quick-start.md](agent-quick-start.md)
- [x] [.claude/commands/release.md](../.claude/commands/release.md)
- [x] [ziggy/upgrade.md](../apps/ziggy-template/.claude/commands/ziggy/upgrade.md)
- [x] [ziggy/check.md](../apps/ziggy-template/.claude/commands/ziggy/check.md)
- [x] [ziggy/add-message.md](../apps/ziggy-template/.claude/commands/ziggy/add-message.md)
- [x] [ziggy/add-task.md](../apps/ziggy-template/.claude/commands/ziggy/add-task.md)

## Ziggy template: READMEs

- [x] [apps/ziggy-template/README.md](../apps/ziggy-template/README.md)
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

- [ ] [setup.md](../apps/ziggy-template/scripts/setup.md)
- [ ] [clean.md](../apps/ziggy-template/scripts/clean.md)
- [ ] [bundle-ui.md](../apps/ziggy-template/scripts/bundle-ui.md)
- [ ] [zig-packages.md](../apps/ziggy-template/scripts/zig-packages.md)
- [ ] [release-notes.md](../apps/ziggy-template/scripts/release-notes.md)

### Linux

- [ ] [build-linux.md](../apps/ziggy-template/scripts/build-linux.md)
- [ ] [run-linux.md](../apps/ziggy-template/scripts/run-linux.md)
- [ ] [open-linux.md](../apps/ziggy-template/scripts/open-linux.md)
- [ ] [sync-linux.md](../apps/ziggy-template/scripts/sync-linux.md)
- [ ] [package-linux.md](../apps/ziggy-template/scripts/package-linux.md)
- [ ] [clean-linux.md](../apps/ziggy-template/scripts/clean-linux.md)

### Windows

- [ ] [windows-common.md](../apps/ziggy-template/scripts/windows-common.md)
- [ ] [setup-windows.md](../apps/ziggy-template/scripts/setup-windows.md)
- [ ] [fetch-webview2.md](../apps/ziggy-template/scripts/fetch-webview2.md)
- [ ] [fetch-wix.md](../apps/ziggy-template/scripts/fetch-wix.md)
- [ ] [build-windows.md](../apps/ziggy-template/scripts/build-windows.md)
- [ ] [run-windows.md](../apps/ziggy-template/scripts/run-windows.md)
- [ ] [open-windows.md](../apps/ziggy-template/scripts/open-windows.md)
- [ ] [sync-windows.md](../apps/ziggy-template/scripts/sync-windows.md)
- [ ] [package-windows.md](../apps/ziggy-template/scripts/package-windows.md)
- [ ] [clean-windows.md](../apps/ziggy-template/scripts/clean-windows.md)

### macOS and iOS

- [ ] [apple-common.md](../apps/ziggy-template/scripts/apple-common.md)
- [ ] [build-macos.md](../apps/ziggy-template/scripts/build-macos.md)
- [ ] [run-macos.md](../apps/ziggy-template/scripts/run-macos.md)
- [ ] [open-macos.md](../apps/ziggy-template/scripts/open-macos.md)
- [ ] [sync-macos.md](../apps/ziggy-template/scripts/sync-macos.md)
- [ ] [package-macos.md](../apps/ziggy-template/scripts/package-macos.md)
- [ ] [clean-macos.md](../apps/ziggy-template/scripts/clean-macos.md)
- [ ] [setup-ios.md](../apps/ziggy-template/scripts/setup-ios.md)
- [ ] [ios-device.md](../apps/ziggy-template/scripts/ios-device.md)
- [ ] [build-ios.md](../apps/ziggy-template/scripts/build-ios.md)
- [ ] [run-ios.md](../apps/ziggy-template/scripts/run-ios.md)
- [ ] [open-ios.md](../apps/ziggy-template/scripts/open-ios.md)
- [ ] [sync-ios.md](../apps/ziggy-template/scripts/sync-ios.md)
- [ ] [package-ios.md](../apps/ziggy-template/scripts/package-ios.md)
- [ ] [clean-ios.md](../apps/ziggy-template/scripts/clean-ios.md)

### Android

- [ ] [android-common.md](../apps/ziggy-template/scripts/android-common.md)
- [ ] [lib/android-env.md](../apps/ziggy-template/scripts/lib/android-env.md)
- [ ] [install-android-sdk.md](../apps/ziggy-template/scripts/install-android-sdk.md)
- [ ] [setup-android.md](../apps/ziggy-template/scripts/setup-android.md)
- [ ] [build-android.md](../apps/ziggy-template/scripts/build-android.md)
- [ ] [run-android.md](../apps/ziggy-template/scripts/run-android.md)
- [ ] [open-android.md](../apps/ziggy-template/scripts/open-android.md)
- [ ] [sync-android.md](../apps/ziggy-template/scripts/sync-android.md)
- [ ] [package-android.md](../apps/ziggy-template/scripts/package-android.md)
- [ ] [distribute-android.md](../apps/ziggy-template/scripts/distribute-android.md)
- [ ] [clean-android.md](../apps/ziggy-template/scripts/clean-android.md)

## Ziggy test app

`apps/ziggy-test-app` keeps only the docs that differ from the template's copy by more than the app's name.

- [ ] [apps/ziggy-test-app/README.md](../apps/ziggy-test-app/README.md)
- [ ] [native/android/README.md](../apps/ziggy-test-app/native/android/README.md)
- [ ] [scripts/android-common.md](../apps/ziggy-test-app/scripts/android-common.md)
- [ ] [scripts/distribute-android.md](../apps/ziggy-test-app/scripts/distribute-android.md)
- [ ] [scripts/ios-device.md](../apps/ziggy-test-app/scripts/ios-device.md)
- [ ] [scripts/package-linux.md](../apps/ziggy-test-app/scripts/package-linux.md)
- [ ] [scripts/release-notes.md](../apps/ziggy-test-app/scripts/release-notes.md)
