# The config file

Every Ziggy app has a TOML config file, holding what the user chose. Ziggy works out where it lives, reads and writes it, and hands the app a typed key-path API, so no TOML type reaches the app's code.

The state file, holding what the app remembers, is described in [the state file](state-file.md).

## Where it lives

| Platform | Path |
|---|---|
| Linux | `$XDG_CONFIG_HOME/<app name>/config.toml`, else `~/.config/<app name>/config.toml` |
| macOS | `$XDG_CONFIG_HOME/<app name>/config.toml`, else `~/.config/<app name>/config.toml` |
| Windows | `%APPDATA%\<app title>\config.toml` |
| Android, iOS | `<app data directory>/config.toml` |

The app's name and title come from its `app.zon`. On macOS the home directory is `CFFIXED_USER_HOME` when it is set and not empty, else `HOME`.

`<NAME>_CONFIG_DIR` names the directory of the file instead, with the app's name in capitals and dashes as underscores, such as `MY_APP_CONFIG_DIR` for an app named `my-app`. It is how a test keeps a run away from the developer's own files, and it is set from outside the app, not by its own code.

A program with no native app, such as a CLI, works the path out with `ziggy.config_path.desktopAppConfigPath(allocator)`.

## The typed API

An app reads a value of the type it names, from a dotted key path:

```zig
const theme = try ziggy.config_state.config.get(?[]const u8, arena, io, config_path, "theme");
try ziggy.config_state.config.set(arena, io, config_path, "theme", "dark");
```

A config key is one named value in the config file, such as `theme` or `sync.enabled`. A key path is the config keys of the file's nesting joined with dots. A config key cannot contain a dot and a path cannot index into a list: a list is read or written whole.

`get` takes these types:

- `bool`.
- Every integer type, stored as a whole number; an integer in the file outside the type's range fails naming the key, the type and the integer.
- `f32` and `f64`. A whole number in the file reads as a float.
- `[]const u8` and `[]u8`. A TOML date, time or date-time reads as a string holding its text.
- An enum, from a string naming its tag. A string naming no tag fails naming the key, the enum and the string.
- An optional. An absent key reads as null.
- A slice or a fixed array, each element read by its own type.
- A struct, from a table. A field is read from the key of its name; a field absent from the file takes its default when it has one, null when it is optional, and fails naming the whole key path otherwise. A key the struct does not name is ignored.
- A slice of structs, from an array of tables.

A `T` the file cannot hold, such as a union or `std.json.Value`, is a compile error naming the type.

`set` takes any of those values. A null removes the key. A struct writes its fields as a table, leaving out a field whose value is null, since TOML has no null.

A value in the file of the wrong type fails `get` with `error.SettingWrongType`, whose message names the key path, the type asked for and the kind found. An absent key needed by a type that is not optional fails with an error naming the key.

## Changing a value from its current value

A write takes a lock file `<file>.lock` beside the file, which is broken when it is older than 30 seconds; under the lock it reads the file, applies the change, writes a temporary file beside it, checks that the file did not change under it, renames the temporary file over the file and releases the lock. Two writers changing different config keys both keep their change and no reader sees a half-written file.

That makes a `get` followed by a `set` lose another writer's change to that config key, because the other writer may land between the two calls. `update` is the one way to read a config key and write it back, or to write several config keys, under one lock and in one rename:

```zig
const AddSavedSearch = struct {
    search: []const u8,

    pub fn run(self: *const @This(), arena: std.mem.Allocator, values: ziggy.config_state.config.Values) !void {
        var searches: std.ArrayList([]const u8) = .empty;
        if (try values.get(?[]const []const u8, "saved_searches")) |existing| {
            for (existing) |search| {
                try searches.append(arena, search);
            }
        }
        try searches.append(arena, self.search);
        try values.set("saved_searches", searches.items);
    }
};

try ziggy.config_state.config.update(arena, io, config_path, AddSavedSearch{ .search = "sunset" });
```

`values.get` and `values.set` work as `get` and `set` do, on the values read under the lock. When the change fails, nothing is written. The change is run again with the file's new values when something that did not take the lock changed the file under it, so it works only from the values it is handed.

## Reading and writing from the frontend

The frontend reaches the file through plain JavaScript values:

```javascript
const theme = await window.ziggy.getConfig("theme");
await window.ziggy.setConfig("theme", "dark");
const problem = await window.ziggy.getConfigProblem();
```

An absent config key is `undefined`, and writing `undefined` removes the config key. The calls can reach any config key, in any table of the file. An app that wants to allow only some config keys checks the key path in its own handler.

`getConfigProblem` gives the line and reason of a bad line, or `undefined` when the file reads or is missing.

## Writing from a handler, a task and a program with no native app

The path comes from where the code runs:

- A message handler, a menu item's function, a timer, `on_create` and the other app functions use `services.configPath()`.
- A task handler uses `context.config_path`.
- A handler written against the task queue package uses `context.configPath`.
- A program with no native app uses `ziggy.config_path.desktopAppConfigPath(allocator)`.

## What happens with a missing or bad file

A missing config file gives every setting its default. A config file with a bad line is reported by line and reason: the app starts with the defaults and the file is left alone. A write to it fails with `ConfigFileInvalid` and leaves it alone.

The file is read up to 1 MiB. A larger file reads as a problem and a write to it fails with `error.FileTooLarge` before the file is touched.

## What a write keeps

A write keeps the file's comments and layout. A key of a table is written under the table's header, and a table the file does not have yet goes at the end under its own header. A write that changes or removes an array of tables (`[[...]]`) cannot be edited in place by the TOML library, so the whole file is written in sorted key order without comments; dates in it become strings. A date a write does not change stays a date in the file.

## Ziggy's own settings

Ziggy keeps its own settings as top-level config keys of the same config file an app uses. It keeps `theme`: `light`, `dark` or `system`, described in [Theme](theme.md). An app's own settings use other config keys.
