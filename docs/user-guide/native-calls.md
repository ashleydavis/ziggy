# Native calls

Terms are defined in the [glossary](../glossary.md).

A native call is how the backend has the native app do something only native code can do, such as showing a file dialog. The frontend never sees it: a task makes the call, and the native app does the work on its UI thread while the task waits.

Make native calls from a task, never from a message handler, because the call waits for the native app and a dialog waits for the user. For a message from the frontend whose response comes from a dialog, have a task give the response (see "A message whose response is a task's result" in [Tasks](tasks.md#a-message-whose-response-is-a-tasks-result)).

A native call the platform does not provide fails with `error.NativeCallMissing`, so an app that runs there handles that error.

## File and directory dialogs

A task shows a native dialog with `context.pickPaths(kind, title, initial_name)`:

- `kind`: open files, save a file or choose a directory.
- `title`: the dialog's title.
- `initial_name`: the suggested file name for a save, or the directory an open or directory dialog starts in.

It returns the JSON text of an array of the paths chosen, `[]` when the user cancelled. Ziggy's test app answers its `pick-files`, `pick-folder` and `pick-file` messages this way. A mobile device has no save dialog, so `pick-file` fails on iOS.

## The app's own native calls

Most things only the platform can do (a share sheet, a permission prompt, a keychain) are not worth a native call of their own. The `native_call` native call is one function for all of them: a task names a method and passes the JSON text of its argument, and the app's own code in its native app does what the method names and returns the JSON text of its result.

```zig
const reply = try context.nativeCall("share", request_json);
```

The reply holds the result and whether the native app succeeded. For a method the native app cannot do, or does not know, the result is the reason, in words the user can act on. Ziggy knows no method names: they belong to the app.

Where an app adds its own native calls, on each platform:

| Platform | Supported | Where the app adds them |
|---|---|---|
| Android | Yes | A `NativeCallHandler`, given to `ZiggyNativeApp.setNativeCallHandler` before `start`, in the app's `MainActivity` |
| iOS | Yes | A `ZiggyNativeCallHandler`, given to `ZiggyBridge.setNativeCallHandler` before `start`, in the app's iOS project |
| Linux | Yes | A function in the `native_call` field the app's `native/linux/src/main.zig` gives the native app (the template leaves it `null`) |
| macOS | No | Ziggy's macOS native app takes no handler yet |
| Windows | No | Ziggy's Windows native app takes no handler yet |
| Dev mode | No | The dev backend takes no handler |

## See also

- [Tasks](tasks.md): the task context, which makes every native call.
- [Ziggy architecture](../development/architecture.md#native-calls): where native calls fit in an app.
