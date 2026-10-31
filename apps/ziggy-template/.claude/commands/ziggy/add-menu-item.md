---
description: Add an item to a Ziggy app's desktop menu: its declaration in the app's menu, the Zig function or frontend code it runs, and its unit tests.
---

# Add a menu item to a Ziggy app

The human says what the item is labelled, which menu it goes in, what choosing it does and its keyboard shortcut, if it has one. If they have not said what it is labelled or what it does, ask, and wait for the answer.

Read Ziggy's guide [Menus](https://github.com/ashleydavis/ziggy/blob/main/docs/user-guide/menus.md), all of it, and the app's own menu (in the template, `backend/src/lib/menu.zig`, passed to `ziggy.core.App` as `.menu` in `backend/src/app.zig`), its menu functions (in the template, `helloFromZigMenuItem` in `backend/src/lib/hello-world.zig`), the frontend's handling of menu events (in the template, `logLineForEvent` in `frontend/src/lib/hello-world.ts` and `listenForTheMenu` in `frontend/src/main.ts`) and their tests (`backend/src/test/menu.test.zig` and `frontend/src/test/hello-world.test.ts`) before writing anything. Write the new item the way those are written.

## Decide what it runs

- A `.standard` item when one of the guide's standard actions already does it (quit, close the window, reload, zoom, the editing commands, full screen, the developer tools, focus the window). It has no `name` and needs no code of the app's.
- A `.zig` item when the backend does the work. The function runs on the thread that handles every frontend message, so it must be quick: slow work queues a task from it (use `/ziggy:add-task` for the task).
- A `.ui` item when the frontend does the work, such as showing a page or a dialog.
- A submenu when the human asks for items grouped under one label.

A phone shows no menu, so a user on Android or iOS can never choose the item. When a mobile user needs what it does, tell the human, and give the frontend its own way to do it too.

## Add it

1. Add the item to its menu in the app's menu file, in the place the human asked for, or at the end of the menu when they did not say. Make a new `ziggy.menu.Menu` when the menu does not exist yet. Give a `.zig` or `.ui` item a `name`: a lower-case, hyphenated string that no other item has and that is not the name of a standard action. Give a shortcut in `accelerator` only when the human asked for one, written as the guide's "Keyboard shortcuts" says, and choose another when it is already used by an item of the menu.
2. For a `.zig` item, write its function in a file in `backend/src/lib`, with the signature the guide gives under "A Zig function" and a `//` comment saying what it does, and point the item's `run` at it. When it tells the frontend something, it sends an app event with its own `type` (never `"menu"`): add that event's TypeScript interface to the frontend's `IAppEvent` union.
3. For a `.ui` item, or a `.zig` item whose function sends the frontend an event, handle the event in a plain function under `frontend/src/lib` (in the template, extend `logLineForEvent` or add a function beside it) and call it from the `window.ziggy.onEvent` listener in `frontend/src/main.ts`. Keep the logic out of `main.ts`.
4. Write the backend's unit tests in `backend/src/test` (in the template, beside the others in `menu.test.zig`): one that the item is in `app.app.menu_targets` under its name with the right kind, and one that posts the `menu-action` system message naming it, as the guide's "Testing menu items" does, and checks what the frontend is sent. A `.standard` item never reaches the backend and gets no backend test.
5. Write the frontend's unit tests for the function from step 3 under `frontend/src/test`.
6. Watch each new test fail with the item's code broken, then pass with it put back.
7. Run `/ziggy:check`.

The build checks the menu and fails naming the item when it is wrong (a missing or repeated name, a repeated or unreadable shortcut). Fix the item, never the check. A `.zig` function that fails returns a Zig error, which reaches the frontend as a `core-error` event: never swallow an error to make the item look like it worked.

## Report

Say which menu the item went in, what it runs, its name and shortcut, each file added or changed and what changed in it, and which checks ran and passed.
