# Upgrade notes

What an app has to change to move to each version of Ziggy, newest first. The `/ziggy:upgrade` Claude Code command reads this, along with the release notes. A version with nothing listed needs no change to the app beyond taking the new version.

## v0.0.23

- **Menu items' `accelerator` is now `shortcut`.** Rename every `.accelerator =` in the app's menu to `.shortcut =`. The syntax of the shortcut is unchanged.
- **`ziggy.accelerator` is now `ziggy.shortcut`,** and its type `Accelerator` is now `Shortcut`. Change any code of the app's that uses them.
- **The menu is no longer JSON.** `ziggy.menu.menuJson` and `RegisteredApp.menu_json` are gone: the menu is `ziggy.menu.menuEntries(menu, actions)` and `RegisteredApp.menu_entries`, a list of entries. Change any test of the app's that reads the menu JSON to read the entries. Native code of the app's own that called `ziggy_menu_json` calls `ziggy_menu` instead (see `ziggy.h`).
- **`HandlerServices.VTable` has `runAction`.** Code of the app's that builds its own handler services vtable, such as a test, adds a `runAction` entry.
- **`window.ziggy` has `registerAction`, `removeAction`, `runAction` and `listActions`.** A fake of `IZiggyBridge` in the app's tests adds the four.
- **New, and optional:** actions, passed to `ziggy.core.App` as `.actions` (see [Actions](user-guide/actions.md)).
