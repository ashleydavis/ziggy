# Upgrade notes

What an app has to change to move to each version of Ziggy, newest first. The `/ziggy:upgrade` Claude Code command reads this, along with the release notes. A version with nothing listed needs no change to the app beyond taking the new version.

## v0.0.24

- **`HandlerServices.VTable` has `configPath` and `statePath`.** Code of the app's that builds its own handler services vtable, such as a test, adds both.
- **`ITaskContext` has `configPath` and `statePath`,** and the task context constructor takes them. Code of the app's that builds a task context passes the two paths, or empty strings when the code it runs reads neither file.
- **`window.ziggy` has `getConfig`, `setConfig`, `getState`, `setState` and `getConfigProblem`.** A fake of `IZiggyBridge` in the app's tests adds the five.
- **The frontend reads and writes any config key or state key.** `window.ziggy.getConfig`, `setConfig`, `getState` and `setState` are not limited to a list; an app that wants to restrict them checks the key path in its own handlers.
- **The app's smoke tests set `<NAME>_CONFIG_DIR` and `<NAME>_STATE_DIR`.** The template's launchers show how: `env` on the desktop, `SIMCTL_CHILD_` variables on iOS and the `ZIGGY_TEST_APP_` extras on Android, which `ZiggyNativeApp.start` reads into the environment.
- **New, and optional:** the config and state files and `ziggy.config_state`, the typed key-path API that reads and writes them. See [the config file](user-guide/config-file.md) and [the state file](user-guide/state-file.md).
- **The theme setting.** `theme` is a top-level config key (`light`, `dark` or `system`), `--theme` overrides it for one run, and the Android extra `ziggy.theme` does the same. A page follows it with `prefers-color-scheme`. See [Theme](user-guide/theme.md).
- **`window.ziggy` has `onConfigChanged` and `removeConfigChangedListener`.** A fake of `IZiggyBridge` in the app's tests adds the two.
- **`MainActivity.onConfigurationChanged` forwards to `ZiggyNativeApp.onConfigurationChanged`,** so a phone's night mode change reaches the core. The template's activity shows it.
- **The template's `index.html` sets the page's background from `prefers-color-scheme`,** so the first paint has the right colour.
- **The Android web view must be created with the activity as its context,** which the template's `MainActivity` already does, so the activity's theme sets the page's colour scheme.
- **New, and optional:** `.backgrounds` on the app's `App`, the window colours each theme is painted in. The default is white and black.

## v0.0.23

- **Menu items' `accelerator` is now `shortcut`.** Rename every `.accelerator =` in the app's menu to `.shortcut =`. The syntax of the shortcut is unchanged.
- **`ziggy.accelerator` is now `ziggy.shortcut`,** and its type `Accelerator` is now `Shortcut`. Change any code of the app's that uses them.
- **The menu is no longer JSON.** `ziggy.menu.menuJson` and `RegisteredApp.menu_json` are gone: the menu is `ziggy.menu.menuEntries(menu, actions)` and `RegisteredApp.menu_entries`, a list of entries. Change any test of the app's that reads the menu JSON to read the entries. Native code of the app's own that called `ziggy_menu_json` calls `ziggy_menu` instead (see `ziggy.h`).
- **`HandlerServices.VTable` has `runAction`.** Code of the app's that builds its own handler services vtable, such as a test, adds a `runAction` entry.
- **`window.ziggy` has `registerAction`, `removeAction`, `runAction` and `listActions`.** A fake of `IZiggyBridge` in the app's tests adds the four.
- **New, and optional:** actions, passed to `ziggy.core.App` as `.actions` (see [Actions](user-guide/actions.md)).
