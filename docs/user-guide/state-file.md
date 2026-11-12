# The state file

Every Ziggy app has a state file, stored as nested JSON, holding what the app remembers on one computer. Ziggy works out where it lives, reads and writes it, and hands the app a typed key-path API, so no JSON type reaches the app's code.

The config file, holding what the user chose, is described in [the config file](config-file.md).

## Where it lives

| Platform | Path |
|---|---|
| Linux | `$XDG_STATE_HOME/<app name>/state.json`, else `~/.local/state/<app name>/state.json` |
| macOS | `~/Library/Application Support/<app title>/state.json` |
| Windows | `%LOCALAPPDATA%\<app title>\state.json` |
| Android, iOS | `<app data directory>/state.json` |

The app's name and title come from its `app.zon`. On macOS the home directory is `CFFIXED_USER_HOME` when it is set and not empty, else `HOME`.

`<NAME>_STATE_DIR` names the directory of the file instead, with the app's name in capitals and dashes as underscores, such as `MY_APP_STATE_DIR` for an app named `my-app`. It is how a test keeps a run away from the developer's own files, and it is set from outside the app, not by its own code.

A program with no native app, such as a CLI, works the path out with `ziggy.state_path.desktopAppStatePath(allocator)`.

## The typed API

An app reads a value of the type it names, from a dotted key path:

```zig
const width = try ziggy.config_state.state.get(u8, arena, io, state_path, "gallery.row_height");
try ziggy.config_state.state.set(arena, io, state_path, "sidebar.left.open", true);
```

A state key is one named value in the state file, such as `desktop.last_folder` or `searches.recent`. A key path is the state keys of the file's nesting joined with dots. A state key cannot contain a dot and a path cannot index into a list: a list is read or written whole.

The types `get` takes, the meaning of an absent key, and the wrong-type error are the same as for the config file, and so are the rules for `set`. They are described under [the typed API](config-file.md#the-typed-api). A JSON file has one extra rule: writing a float that is not finite fails naming the key, because JSON cannot hold one.

## Changing a value from its current value

A write takes a lock file `<file>.lock` beside the file, which is broken when it is older than 30 seconds; under the lock it reads the file, applies the change, writes a temporary file beside it, checks that the file did not change under it, renames the temporary file over the file and releases the lock. Two writers changing different state keys both keep their change and no reader sees a half-written file.

That makes a `get` followed by a `set` lose another writer's change to that state key, because the other writer may land between the two calls. `update` is the one way to read a state key and write it back, or to write several state keys, under one lock and in one rename:

```zig
const AddRecent = struct {
    item: []const u8,

    pub fn run(self: *const @This(), arena: std.mem.Allocator, values: ziggy.config_state.state.Values) !void {
        var items: std.ArrayList([]const u8) = .empty;
        if (try values.get(?[]const []const u8, "searches.recent")) |existing| {
            for (existing) |item| {
                try items.append(arena, item);
            }
        }
        try items.append(arena, self.item);
        try values.set("searches.recent", items.items);
    }
};

try ziggy.config_state.state.update(arena, io, state_path, AddRecent{ .item = "sunset" });
```

`values.get` and `values.set` work as `get` and `set` do, on the values read under the lock. When the change fails, nothing is written. The change is run again with the file's new values when something that did not take the lock changed the file under it, so it works only from the values it is handed.

## Reading and writing from the frontend

The frontend reaches the file through plain JavaScript values:

```javascript
const value = await window.ziggy.getState("sidebar.left.open");
await window.ziggy.setState("sidebar.left.open", true);
```

An absent state key is `undefined`, and writing `undefined` removes the state key. The calls can reach any state key, in any table of the file. An app that wants to allow only some state keys checks the key path in its own handler.

## Writing from a handler, a task and a program with no native app

The path comes from where the code runs:

- A message handler, a menu item's function, a timer, `on_create` and the other app functions use `services.statePath()`.
- A task handler uses `context.state_path`.
- A handler written against the task queue package uses `context.statePath`.
- A program with no native app uses `ziggy.state_path.desktopAppStatePath(allocator)`.

## What happens with a missing or unreadable file

A missing state file gives an empty state. An unreadable state file is reported as such and gives an empty state; the first write keeps its bytes beside it as `<file>.unreadable-<uuid>`, so nothing the file held is dropped.

The file is read up to 16 MiB. A larger file reads as an unreadable file and a write to it fails with `error.FileTooLarge` before the file is touched.

## What a write keeps

The state file is always written whole. Unlike the config file, it has no comments or layout to keep.

## What belongs here

The state file holds what nobody chose: the folders a dialog last opened at, the searches that were merely run, how a gallery was sorted, which items were already shown, the databases opened lately and the interface's own working state. What the user chose belongs in [the config file](config-file.md).
