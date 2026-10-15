# Native calls

Terms are defined in the [glossary](../glossary.md).

A native call is how the backend has the native app do something only native code can do, such as showing a file dialog. The UI never sees it: a task makes the call, and the native app does the work on its UI thread while the task waits.

Make native calls from a task, never from a channel handler, because the call waits for the native app and a dialog waits for the user. To answer a message from the UI with a dialog, list the channel in `task_channels` (see "A message handled by a task" in [Tasks](tasks.md)).

A native call the platform does not provide fails with `error.HostCallbackMissing`, so an app that runs there handles that error.

## File and directory dialogs

A task shows a native dialog with `context.pickPaths(kind, title, initial_name)`:

- `kind`: open files, save a file or choose a directory.
- `title`: the dialog's title.
- `initial_name`: the suggested file name for a save, or the directory an open or directory dialog starts in.

It returns the JSON text of an array of the paths chosen, `[]` when the user cancelled. The template's `pick-files`, `pick-folder` and `pick-file` channels work this way. A mobile device has no save dialog, so `pick-file` fails on iOS.

## The app's own native calls

Most things only the platform can do (a share sheet, a permission prompt, a keychain) are not worth a native call of their own. The `host_request` native call is one function for all of them: a task names a method and passes the JSON text of its argument, and the app's own code in its native app does what the name says and returns the JSON text of its result.

```zig
const reply = try context.hostRequest("share", request_json);
```

The reply holds the result and whether the native app succeeded. For a method the native app cannot do, or does not know, the result is the reason, in words the user can act on. Ziggy knows no method names: they belong to the app.

Where an app adds its own native calls, on each platform:

| Platform | Supported | Where the app adds them |
|---|---|---|
| Android | Yes | A `HostRequestHandler`, given to `ZiggyShell.setHostRequestHandler` before `start`, in the app's `MainActivity` |
| iOS | Yes | A `ZiggyHostRequestHandler`, given to `ZiggyBridge.setHostRequestHandler` before `start`, in the app's iOS project |
| Linux | Yes | A function in the `host_request` field the app's `native/linux/src/main.zig` gives the native app (the template leaves it `null`) |
| macOS | No | Ziggy's macOS native app takes no handler yet |
| Windows | No | Ziggy's Windows native app takes no handler yet |
| Dev mode | No | The dev backend takes no handler |

## See also

- [Tasks](tasks.md): the task context, which makes every native call.
- [Ziggy architecture](../development/architecture.md#native-calls): where native calls fit in an app.
