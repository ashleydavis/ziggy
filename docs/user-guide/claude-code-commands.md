# Claude Code commands

Every app made from the Ziggy template comes with [Claude Code](https://claude.com/claude-code) slash commands for working on it, in its `.claude/commands/ziggy` directory. Claude Code finds them when it runs in the app's directory.

To start a new app with an AI coding agent, see [Starting a new app from the template](building-your-app.md#starting-a-new-app-from-the-template).

| Command | What it does |
|---|---|
| `/ziggy:check` | Runs every check the app has that the machine can run, fixes what fails and reports what could not run. |
| `/ziggy:add-message` | Adds a message the frontend sends to the backend: its handler and its registration, the frontend's call and their tests. |
| `/ziggy:add-task` | Adds a background task type. |
| `/ziggy:upgrade` | Moves an app to a newer version of Ziggy. |

## See also

- [Starting a new app from the template](building-your-app.md#starting-a-new-app-from-the-template): the steps the agent quick start follows.
- [Messages](messages.md): the guide `/ziggy:add-message` follows.
- [Tasks](tasks.md): the guide `/ziggy:add-task` follows.
- [Moving to a newer version](building-your-app.md#moving-to-a-newer-version): the steps `/ziggy:upgrade` follows.
