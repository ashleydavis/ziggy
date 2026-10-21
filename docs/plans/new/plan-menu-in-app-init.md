# Declare the menu in `ziggy.core.App`, with each item running Zig code or reaching the UI

## Overview

Today an app gives Ziggy its desktop menu as a JSON string (`menu_json`), and every item that is not one of the native app's standard actions is passed straight on to the UI as a `menu-action` system event, which the UI listens for with `window.ziggy.onMenuAction`. The core never runs anything for a menu item, so an item that does work goes core, UI and back to the core. This plan replaces the JSON string with a Zig value of Ziggy's own menu types, passed to `ziggy.core.App` as `.menu`. Each item says what it runs: a standard action the native app does itself, a Zig function the core calls, or the UI, which receives it as an ordinary app event `{ "type": "menu", "item": "<name>" }` through `onEvent`. `onMenuAction`, its remover and `IMenuActionEvent` are removed. The native apps do not change: the core still gives them the same menu JSON, built from the Zig value at compile time.

The app declares its menu as a constant of its own and passes it in:

```zig
// backend/src/lib/menu.zig
pub const menu: []const ziggy.menu.Menu = &.{
    .{
        .label = "File",
        .items = &.{
            .{
                .label = "Quit",
                .accelerator = "CmdOrCtrl+Q",
                .run = .{
                    .standard = .quit,
                },
            },
        },
    },
    .{
        .label = "Example",
        .items = &.{
            .{
                .label = "Start Short Task",
                .name = "start-short",
                .accelerator = "CmdOrCtrl+1",
                .run = .{
                    .zig = example_menu.startShortTask,
                },
            },
            ziggy.menu.separator,
            .{
                .label = "About",
                .name = "about",
                .run = .ui,
            },
        },
    },
};

// backend/src/handlers.zig
pub const app = ziggy.core.App(.{
    .messages = .{ ... },
    .tasks = .{ ... },
    .menu = menu.menu,
    .ui_files = &ui.files,
    .ui_query = ui_query.uiQuery,
});
```

## Issues

## Steps

This plan starts after step 21 of `docs/plans/new/plan-one-message-handler.md` (`ziggy.core.App`) is done and its tests pass. If it is not done, STOP and tell the human.

1. Add `packages/ziggy/core/src/lib/menu.zig` and export it from the core's root module as `ziggy.menu`.
   - `StandardAction`: an enum of the actions the native apps do themselves, its tags spelled exactly as the native apps match them today: `quit`, `@"close-window"`, `reload`, `@"toggle-devtools"`, `@"toggle-fullscreen"`, `@"zoom-in"`, `@"zoom-out"`, `@"zoom-reset"`, `undo`, `redo`, `cut`, `copy`, `paste`, `@"select-all"`. Read the lists in `packages/ziggy/native/linux/src/lib/shell.zig` (`performAction`), `packages/ziggy/native/windows/src/lib/actions.zig` and `packages/ziggy/native/macos/Sources/ZiggyNativeMacOS/ZiggyMenu.swift` and make the enum match them; if they disagree with each other, STOP and tell the human.
   - `MenuFn`: `*const fn (core: *core_module.Core, arena: std.mem.Allocator) anyerror!void`.
   - `Run`: `union(enum) { standard: StandardAction, zig: MenuFn, ui: void }`.
   - `Item`: a struct with `label`, `name: ?[]const u8`, `accelerator: ?[]const u8`, `run: ?Run`, `items: ?[]const Item` (a submenu) and `separator: bool`. Give every optional field a default of `null` (and `separator` a default of `false`) so an app writes only what it needs, as the Overview shows. `pub const separator: Item` is the separator.
   - `Menu`: a struct with `label` and `items: []const Item`.
   - `checkMenu(comptime menu: []const Menu) void`: fails the build with `@compileError`, naming the item's label, when: an item is neither a separator, a submenu nor has a `run`; a submenu also has a `run`; a `.zig` or `.ui` item has no `name`; a `.standard` item has a `name`; two items share a name; a name is spelled like a standard action; two items share an accelerator; an accelerator does not parse with `accelerator.parse` (call it at compile time; if Zig refuses, check accelerators in the unit test instead and record why in Notes).
   - `menuJson(comptime menu: []const Menu) []const u8`: the menu as the JSON text the native apps read today (an array of `{"label", "items"}`, an item `{"label", "action", "accelerator"}`, `{"separator": true}` or a submenu with its own `"items"`), built at compile time. An item's `"action"` is the standard action's tag for a `.standard` item and its `name` otherwise. An empty menu is `[]`.
   - `MenuTarget`: `union(enum) { zig: MenuFn, ui: void }`, and `menuTargets(comptime menu: []const Menu)`: a `std.StaticStringMap(MenuTarget)` from each `.zig` and `.ui` item's name to its target, built at compile time.
   - Every type, field and function gets its `//` comment block. Unit tests as listed below. `bun run test:zig` passes.
2. `packages/ziggy/core/src/lib/core.zig` `App`: replace `.menu_json` with `.menu: []const ziggy.menu.Menu`. `App` calls `checkMenu`, and the registered app carries `menu_json` (from `menuJson`) and `menu_targets` (from `menuTargets`). `Core` keeps its `menu_json` field, so `ziggy_menu_json` in `ziggy-api.zig` and every native app are unchanged, and gains `menu_targets`, copied from the app in `Core.create` beside `menu_json`. Update `packages/ziggy/core/src/test/helpers.zig` so `createCore` takes a menu, and the dispatcher test "the core holds the app's menu for shells to read".
3. `packages/ziggy/core/src/lib/system-messages.zig` `menuActionHandler`: look the action up in `core.menu_targets`. A `.zig` target is called with `core` and the message arena; its error is the handler's error, reported as today. A `.ui` target sends the UI `{"type": "menu", "item": "<name>"}` with `core.sendEvent`. A name that is not in the table (including a standard action, which the native apps run themselves and never post) fails with `UnknownMenuItem`. The handler no longer sends the `menu-action` system event. Update the comment above it and the `menu_action` comments in `packages/ziggy/core/src/lib/types.zig` and `jni.zig` (`menuActionCallback`) so they say the core runs the item.
4. Remove the UI's menu listener:
   - `packages/ziggy/core/src/lib/ziggy-inject.js`: remove `menuAction`, `onMenuAction` and `removeMenuActionListener`, and "menu actions" from the comment block that lists Ziggy's own events.
   - `packages/ziggy/ui/src/ziggy-bridge.ts`: remove `onMenuAction`, `removeMenuActionListener` and `IMenuActionEvent`. Add `IMenuEvent` (`type: "menu"` and `item: string`, each with its `//` comment) so an app can type the event its `onEvent` listener receives.
   - `packages/ziggy/ui/src/test/ziggy-inject.test.ts`: remove the `menu-action` rows and the two names from the list of `window.ziggy` calls.
   - `bun run compile` and `bun run test` pass.
5. The template: `apps/ziggy-template/backend/src/lib/menu.zig` becomes `pub const menu: []const ziggy.menu.Menu`, with the same menus, labels, accelerators and standard actions as its JSON today. `apps/ziggy-template/backend/src/handlers.zig` passes `.menu = menu.menu`. Update the comment block at the top of `menu.zig` to say what each kind of item does.
6. The test app:
   - `apps/ziggy-test-app/backend/src/lib/menu.zig` becomes a `ziggy.menu.Menu` constant with the same menus, labels, accelerators and standard actions. `start-short`, `start-long`, `start-many`, `cancel-long` and `about` are `.ui` items with those names, so the UI still presses the same buttons.
   - Add one `.zig` item to the Example menu, `Send Event From Zig` named `zig-event` with no accelerator, whose function in a new `apps/ziggy-test-app/backend/src/lib/menu-functions.zig` sends the UI `{"type": "menu-zig-event"}` with `core.sendEvent`.
   - `apps/ziggy-test-app/backend/src/handlers.zig` passes `.menu = menu.menu`.
   - `apps/ziggy-test-app/ui/src/main.ts`: remove `listenForMenuActions` and its `onMenuAction` listener. In the existing `onEvent` listener (`onAppEvent`), a `menu` event writes `menu-action <item>` to the event log (the same text as today, which the smoke tests read) and then does what `listenForMenuActions` does today with `buttonForMenuAction` and `aboutText`; a `menu-zig-event` event writes `menu-zig-event` to the event log. Remove the `IMenuActionEvent` import.
   - `apps/ziggy-test-app/backend/src/test/menu.test.zig`: rewrite against the new menu (see Unit Tests). Checks the compiler now makes (labels, names, accelerators parse, no duplicates) are dropped from it.
   - `bun run compile`, `bun run test`, `bun run test:zig` and `bun run compile:zig` pass.
7. Smoke tests: in `smoke-tests/desktop-only/11-menu-ui-actions/test.sh`, add `choose_menu_item zig-event` and `wait_for_text event-log "menu-zig-event"`. Run it with the test app's item removed from the table, or with `menuActionHandler` sending the wrong event, and watch it fail first. Then run every suite listed under Verify.
8. The examples: in `../ziggy-example-vite` and `../ziggy-example-rsbuild`, on the local Ziggy checkout as step 13 of `plan-one-message-handler.md` sets them up, move each app's `menu_json` to a `ziggy.menu.Menu` constant passed as `.menu`, and move any `onMenuAction` listener into the app's `onEvent` listener as a `menu` event. Run in each: `bun run compile`, `bun run test`, `bun run test:zig`, `bun run compile:zig`, `bun run test:smoke`, and the Android suites when `adb devices` shows a device in state `device`.
9. Photosphere (`../photosphere`, beside the Ziggy checkout): move `packages-zig/photosphere-core/src/lib/menu.zig` from JSON to a `ziggy.menu.Menu` constant passed to `ziggy.core.App` in `handlers.zig`. Each item the UI handles today becomes a `.ui` item with the same name; move the `onMenuAction` listener in `apps/photosphere-frontend/src/lib/platform-provider-ziggy.tsx` into its `onEvent` routing as a `menu` event, and update `src/test/fake-ziggy.ts` and `menu.test.zig`. Follow Photosphere's own `CLAUDE.md`. Run its compile, unit test and smoke test commands, and its Android suites when `adb devices` shows a device.
10. Documentation:
    - `docs/user-guide/building-your-app.md` "The menu and the window icon": the menu as a `ziggy.menu.Menu` constant passed to `ziggy.core.App`; the three kinds of item (`.standard`, `.zig`, `.ui`) and what each runs; `.name` on every `.zig` and `.ui` item; the `{ type: "menu", item }` event and that an app must not send an event of its own with `type: "menu"`; that a `.zig` item runs on the thread that handles messages, so slow work queues a task; the build errors `App` gives.
    - `docs/user-guide/messages.md`: the `menu` event in the section on `onEvent`, and remove `onMenuAction`.
    - `docs/development/architecture.md` "Menus" and "Protocol": the core runs `.zig` items and sends `.ui` items as app events; `menu-action` is no longer a system event the UI receives, only a system message the native apps post.
    - `docs/glossary.md` if it defines a menu action, `.claude/commands/ziggy/add-message.md` if it mentions menus, the comment blocks of both apps' `menu.zig`, `apps/ziggy-test-app/README.md`, `apps/ziggy-template/README.md` and `packages/ziggy/native/macos/README.md` where they describe the menu JSON or `menu-action`.
    - Check every link and anchor in the changed docs resolves.

## Unit Tests

- `packages/ziggy/core/src/test/menu.test.zig` (new, added to the core's test list in `build.zig`):
  - `menuJson` gives the JSON the native apps read for a menu with a standard item, a `.zig` item, a `.ui` item, a separator and a submenu, compared with the exact text expected.
  - `menuJson` of an empty menu is `[]`.
  - `menuTargets` maps each `.zig` item's name to its function and each `.ui` item's name to `.ui`, holds nothing for standard items and separators, and finds items inside a submenu.
  - `StandardAction` has a tag for every action each native app does itself: compare with the list in `packages/ziggy/native/windows/src/lib/actions.zig`, read from that file's own declarations if it exposes them, so the test fails when the lists drift apart.
- `packages/ziggy/core/src/test/dispatcher.test.zig`:
  - Replace "a menu-action message from a shell reaches the UI as a menu-action event" with: a `.ui` item's name posted as `menu-action` reaches the UI as the app event `{"type":"menu","item":"<name>"}`, and no `menu-action` system event is sent.
  - A `.zig` item's name posted as `menu-action` calls its function with the core, and the function's error comes back as the error reply.
  - An unknown name, and a standard action's name, fail with `UnknownMenuItem` and run nothing.
  - Keep "a menu-action message with no action is an error reply".
- `packages/ziggy/ui/src/test/ziggy-inject.test.ts`: `window.ziggy` has no `onMenuAction` or `removeMenuActionListener`, and an app event `{type: "menu", item}` reaches the `onEvent` listeners.
- `apps/ziggy-test-app/backend/src/test/menu.test.zig`: the menu has the `.ui` items the UI handles and the `zig-event` item, and `toggle-devtools` and `quit` are standard items; `menu-functions.zig`'s function sends `{"type":"menu-zig-event"}` (check the delivered event with the core test helpers).
- `apps/ziggy-test-app/ui/src/test/menu-actions.test.ts`: unchanged, it must still pass.
- The build errors from `checkMenu` cannot be unit tests. Check each one once with a deliberately wrong menu in the test app, and record each message in Notes.
- Watch each new test fail first with a test filter, not a full run.

## Smoke Tests

- `smoke-tests/desktop-only/11-menu-ui-actions`: the `.ui` items still press the same buttons and show About, and the new `zig-event` item runs its Zig function, whose event reaches the UI.
- `12-menu-view`, `13-menu-edit`, `14-menu-quit` and `15-menu-devtools` pass unchanged, which shows the standard actions still reach the native apps through the JSON built from the Zig menu.

## Verify

- `git grep -n -E 'onMenuAction|removeMenuActionListener|IMenuActionEvent|menu_json *=' -- ':!docs/plans'` prints nothing in Ziggy, both examples and Photosphere.
- `bun run compile` and `bun run compile:zig` succeed.
- `bun run test` and `bun run test:zig` pass.
- `bun run test:smoke`, `bun run test:smoke:dev`, the template's `test:smoke`, and, after `adb devices` shows a serial in state `device`, `bun run test:smoke:and` and `bun run test:zig:android` pass. Run them side by side.
- Each example's and Photosphere's checks from steps 8 and 9 pass.
- macOS, iOS and Windows are tested by the release workflow when the human pushes. Say so and do not report them as tested.

## Notes

- The native apps keep posting `menu-action` with the item's action text, and the standard actions keep their names in the JSON, so no native code changes. Only the comments that say the action goes to the UI change.
- The UI receives a `.ui` item as an ordinary app event, not a system event. The UI cannot tell it from an event the app's Zig code sends, and nothing needs it to. `type: "menu"` is the one event type Ziggy sends into the app's events.
- A `.zig` item runs on the thread that handles messages, like a message handler. Slow work queues a task from the function.
- `.name` is required on `.zig` and `.ui` items because the native apps and `choose_menu_item` pick an item by a text name.
- In the worktree, `Core.sendEvent` in `core.zig` writes `.kind = "apps"`, while `ziggy-inject.js` routes app events on `kind === "app"`. That is step 20's work in progress; if it is still there when this plan starts, it is a bug and is fixed in step 20 before step 3 here, because the `.ui` items depend on `sendEvent`.
