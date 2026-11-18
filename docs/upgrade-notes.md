# Upgrade notes

What an app has to change to move to each version of Ziggy, newest first. The `/ziggy:upgrade` Claude Code command reads this, along with the release notes. A version with nothing listed needs no change to the app beyond taking the new version.

## v0.0.28

- **Android: give the system splash the splash art at its full size.** Run `scripts/generate-app-assets.sh` for the app, which writes `splash_icon.png` in `drawable-nodpi`, `drawable-port-nodpi` and `drawable-land-nodpi` and points `android:windowSplashScreenAnimatedIcon` in `values-v31/styles.xml` at `@drawable/splash_icon`. Without it the system splash shows the small launcher icon, which jumps in size when the native splash picture replaces it. Keep the art inside the middle 192 dp circle, about 616 pixels across the middle of a 1290x2796 portrait image, as the template's art is: Android clips the system splash icon to that circle.
- **Take the template's `frontend/src/lib/splash.ts` and its test.** The overlay's image now covers the whole window: on Android the native app sets `--ziggy-window-inset-<side>`, and the image reaches past the page by those amounts, so the art stays where the native splash picture has it when the overlay takes over. Without it, on Android the art jumps as the overlay starts to fade.

## v0.0.26

- **iOS: show the splash art on the launch screen.** Copy the template's `native/ios/ZiggyTemplate/LaunchScreen.storyboard` into the app, add it to the app target's resources, and in `Info.plist` replace the `UILaunchScreen` entry with `UILaunchStoryboardName` set to `LaunchScreen`. Without it the launch screen is only the `SplashBackground` colour and the art appears after it.
- **An app with a splash calls `window.ziggy.splashFading(durationMilliseconds)` as its frontend overlay starts to fade.** Take the template's `frontend/src/lib/splash.ts` and its test, which add the `onFadeStart` option, and pass `onFadeStart: durationMilliseconds => window.ziggy.splashFading(durationMilliseconds)` to `installSplashScreen`, as the template's `frontend/src/main.ts` does. Until the app calls it, the Linux native splash picture stays over the app. A fake of `IZiggyBridge` in the app's tests adds `splashFading`.
- **Take `android:postSplashScreenTheme` out of `native/android/app/src/main/res/values-v31/styles.xml`.** The Android framework has no such attribute, so with it the Android build fails in `:app:processDebugResources`. `scripts/generate-app-assets.sh` no longer writes it.
- **Add `native/android/app/src/main/res/drawable/splash.png`, a copy of `drawable-port/splash.png`.** Without a default splash image, release lint fails the Android release build with `MissingDefaultResource`. `scripts/generate-app-assets.sh` now writes it.

## v0.0.24

- **`ziggy_config` has `has_key_press` and `is_mobile`.** Native code of the app's own that fills a `ziggy_config` field by field sets both.
- **New, and optional:** the remote control command `press-key` and the smoke test helper `press_key`. Copy `press_key` from the template's `smoke-tests/lib/common.sh` into the app's own to use it.
- **Every shortcut runs in the frontend.** A native app of the app's own registers no accelerator, key equivalent or key monitor: it shows each item's shortcut and runs the action the frontend posts.
- **`ziggy_standalone_action_shortcuts` returns no shortcut.** A native app that read it registers nothing.
- **A menu item with a shortcut a text box keeps fails the build,** so move the shortcut to an action with no menu item. Two shortcuts that are the same key press fail the build, which covers `Plus` and `Equal`, and on Linux and Windows `Ctrl+<key>` beside `CmdOrCtrl+<key>`. Two actions that are not on the menu and have the same shortcut also fail the build.
- **A held shortcut key runs its action once per press.**
- **A shortcut on a letter, a digit, `Plus`, `Minus`, `Equal` or `?` runs from the key that types its character.** One that holds Shift with a digit, `Plus`, `Minus` or `Equal` fails the build, so add Ctrl, Alt or Cmd.
- **WebView2's browser accelerator keys are off on Windows,** so an app that relied on F5 or Ctrl+F adds a menu item or an action.
- **New, and optional:** a shortcut can be `?` (see [Menus](user-guide/menus.md#keyboard-shortcuts)).
- **`ZiggyBridge.view` is the window or controller content for macOS and iOS apps.** Put `newBridge.view` on screen; `ZiggyBridge.webView` remains the app's own web view.
- **New, and optional:** `.splash` on `app.zon`. The frontend's matching overlay is app code; the template's `frontend/src/lib/splash.ts` is the copy to take. See [App icons and splash screens](user-guide/app-icons-and-splash.md).
- **`HandlerServices.VTable` has `configPath` and `statePath`.** Code of the app's that builds its own handler services vtable, such as a test, adds both.
- **`ITaskContext` has `configPath` and `statePath`,** and the task context constructor takes them. Code of the app's that builds a task context passes the two paths, or empty strings when the code it runs reads neither file.
- **`window.ziggy` has `getConfig`, `setConfig`, `getState`, `setState` and `getConfigProblem`.** A fake of `IZiggyBridge` in the app's tests adds the five.
- **The frontend reads and writes any config key or state key.** `window.ziggy.getConfig`, `setConfig`, `getState` and `setState` are not limited to a list; an app that wants to restrict them checks the key path in its own handlers.
- **The app's smoke tests set `<NAME>_CONFIG_DIR` and `<NAME>_STATE_DIR`.** The template's launchers show how: `env` on the desktop, `SIMCTL_CHILD_` variables on iOS and the `ZIGGY_TEST_APP_` extras on Android, which `ZiggyNativeApp.start` reads into the environment.
- **New, and optional:** the config and state files and `ziggy.config_state`, the typed key-path API that reads and writes them. See [the config file](user-guide/config-file.md) and [the state file](user-guide/state-file.md).
- **The theme setting.** `theme` is a top-level config key (`light`, `dark` or `system`), `--theme` overrides it for one run, and the Android extra `ziggy.theme` does the same. A page follows it with `prefers-color-scheme`. See [Theme](user-guide/theme.md).
- **`--light`, `--dark` and `--system` are Ziggy's,** short for `--theme`, and the environment variable `ZIGGY_THEME` sets the theme setting too. Ziggy takes the options out of the arguments, so an app that had an option of its own by one of those names renames it. An app's smoke tests can set `ZIGGY_THEME=light` so the Linux app never connects to the session bus (see [Theme](user-guide/theme.md)).
- **`window.ziggy` has `onConfigChanged` and `removeConfigChangedListener`.** A fake of `IZiggyBridge` in the app's tests adds the two.
- **`MainActivity.onConfigurationChanged` forwards to `ZiggyNativeApp.onConfigurationChanged`,** so a mobile's night mode change reaches the core. The template's activity shows it.
- **The template's `index.html` sets the page's background from `prefers-color-scheme`,** so the first paint has the right colour.
- **The Android web view must be created with the activity as its context,** which the template's `MainActivity` already does, so the activity's theme sets the page's colour scheme.
- **New, and optional:** `.backgrounds` on the app's `App`, the window colours each theme is painted in. The default is white and black.
- **The remote control server holds every app that connects, each as a numbered window.** A command names its window with a `window` field; a command for a window that has not connected waits for it. A smoke test that stops the app and starts it again starts a new remote control server for the new run, as the test app's `restart_test_app` does, so the new app is window 1.
- **`HandlerServices.VTable` has `new_window`.** Code of the app's that builds its own handler services vtable, such as a test, adds a `new_window` entry.
- **`window.ziggy` has `newWindow`.** A fake of `IZiggyBridge` in the app's tests adds it.
- **`ziggy_config` has `has_new_window`.** Native code of the app's own that fills a `ziggy_config` field by field sets it.
- **Log file names carry the process id: `<name>-<start time>-<pid>.log`.** A test or script of the app's that matches the file name exactly allows for it.
- **On Linux and macOS, Quit ends every window of the app, and SIGTERM ends a window as its Quit does.** Each window records itself under `windows` in the app's data directory.
- **New, and optional:** a new window, opened with `window.ziggy.newWindow(arguments)` or `HandlerServices.new_window` (see [New windows](user-guide/new-windows.md)).

## v0.0.23

- **Menu items' `accelerator` is now `shortcut`.** Rename every `.accelerator =` in the app's menu to `.shortcut =`. The syntax of the shortcut is unchanged.
- **`ziggy.accelerator` is now `ziggy.shortcut`,** and its type `Accelerator` is now `Shortcut`. Change any code of the app's that uses them.
- **The menu is no longer JSON.** `ziggy.menu.menuJson` and `RegisteredApp.menu_json` are gone: the menu is `ziggy.menu.menuEntries(menu, actions)` and `RegisteredApp.menu_entries`, a list of entries. Change any test of the app's that reads the menu JSON to read the entries. Native code of the app's own that called `ziggy_menu_json` calls `ziggy_menu` instead (see `ziggy.h`).
- **`HandlerServices.VTable` has `runAction`.** Code of the app's that builds its own handler services vtable, such as a test, adds a `runAction` entry.
- **`window.ziggy` has `registerAction`, `removeAction`, `runAction` and `listActions`.** A fake of `IZiggyBridge` in the app's tests adds the four.
- **New, and optional:** actions, passed to `ziggy.core.App` as `.actions` (see [Actions](user-guide/actions.md)).
