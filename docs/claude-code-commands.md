# Claude Code commands

`.claude/commands/ziggy` holds [Claude Code](https://claude.com/claude-code) slash commands for building an app on Ziggy. Claude Code finds commands in the `.claude/commands` folder of the project it runs in, so copy the `ziggy` folder into an app's `.claude/commands` to use them there. To start a new app, copy it into the empty folder the app will go in, with Ziggy checked out beside that folder as `ziggy`.

| Command | What it does |
|---|---|
| `/ziggy:new` | Starts a new app in the current folder: copies the template, asks for the app's names, renames it, points it at Ziggy and runs its checks, as [Building your app](building-your-app.md#starting-a-new-app-from-the-example) describes. |
| `/ziggy:check` | Runs every check the app has that the machine can run, fixes what fails and says what could not run. |
| `/ziggy:add-channel` | Adds a request the UI sends to the core: the handler, its registration, the UI's call and their tests. |
| `/ziggy:add-task` | Adds a background task type, as [Tasks](tasks.md) describes. |
| `/ziggy:upgrade` | Moves an app to a newer version of Ziggy, as [Integrating Ziggy](integrating-ziggy.md#moving-to-a-newer-version) describes. |
