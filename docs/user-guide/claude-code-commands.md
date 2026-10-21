# Claude Code commands

`.claude/commands/ziggy` holds [Claude Code](https://claude.com/claude-code) slash commands for building an app on Ziggy. Claude Code finds commands in the `.claude/commands` directory of the project it runs in. To start a new app, run this in the empty directory the app will go in. It puts the commands of Ziggy's latest release in `.claude/commands/ziggy`:

```bash
tag=$(git ls-remote --tags --refs --sort=-version:refname https://github.com/ashleydavis/ziggy 'v*' | head -n 1 | sed 's#.*refs/tags/##')
curl -fsSL "https://github.com/ashleydavis/ziggy/archive/refs/tags/$tag.tar.gz" | tar -xz --strip-components=1 --wildcards '*/.claude/commands/ziggy/*'
```

Then start Claude Code there and run `/ziggy:new`.

| Command | What it does |
|---|---|
| `/ziggy:new` | Starts a new app in the current directory: copies the template of Ziggy's latest release, asks for the app's names, renames it, pins it to that release and runs its checks. |
| `/ziggy:check` | Runs every check the app has that the machine can run, fixes what fails and says what could not run. |
| `/ziggy:add-message` | Adds a message the UI sends to the backend: its handler and its registration, the UI's call and their tests. |
| `/ziggy:add-task` | Adds a background task type. |
| `/ziggy:upgrade` | Moves an app to a newer version of Ziggy. |

## See also

- [Starting a new app from the template](building-your-app.md#starting-a-new-app-from-the-template): the steps `/ziggy:new` follows.
- [Messages](messages.md): the guide `/ziggy:add-message` follows.
- [Tasks](tasks.md): the guide `/ziggy:add-task` follows.
- [Moving to a newer version](building-your-app.md#moving-to-a-newer-version): the steps `/ziggy:upgrade` follows.
