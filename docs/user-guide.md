# User guide

This guide is for building an app on Ziggy. To try Ziggy quickly, start with the [quick start](quick-start.md).

To create your own Ziggy app with an AI coding agent, such as Claude Code, start the agent in the empty directory the app will go in and tell it:

> Make a new Ziggy app here by following https://github.com/ashleydavis/ziggy/releases/latest/download/agent-quick-start.md

Otherwise follow [Building your app](user-guide/building-your-app.md).

Check the [glossary](glossary.md) to understand the jargon.

## The directory structure of an app

An app is one project with three directories:

- `frontend/`: the frontend, an ordinary web page in JavaScript/TypeScript, HTML and CSS, built on whatever bundler you like.
- `backend/`: the backend, the app's Zig code. Messages, menus and background tasks are handled here.
- `native/`: the native app for each platform, which opens the window, creates the web view and shows the frontend. Ziggy creates this for you, but you set various details like the icon and permissions.

## Examples

Complete apps built on Ziggy:

- [Vite example](https://github.com/ashleydavis/ziggy-example-vite): the frontend built with Vite.
- [Rsbuild example](https://github.com/ashleydavis/ziggy-example-rsbuild): the frontend built with Rsbuild.

## The guides

Read the guides in this order:

1. [Building your app](user-guide/building-your-app.md): how to build your app on Ziggy.
2. [Dev mode](user-guide/dev-mode.md): how to run your app's frontend in a browser that reloads as you save.
3. [Messages](user-guide/messages.md): how to send JSON messages between frontend and backend.
4. [Menus](user-guide/menus.md): the desktop menu, its keyboard shortcuts and how a chosen item reaches the backend or the frontend.
5. [Tasks](user-guide/tasks.md): how to run background tasks that don't block the frontend.
6. [Native calls](user-guide/native-calls.md): file dialogs and calls into your own native code.
7. [Testing your app](user-guide/testing.md): unit tests, smoke tests and the test hooks.
8. [Distributing your app](user-guide/distributing-your-app.md): packaging, signing and getting builds to testers and app stores.

Also:

- [Dependencies](user-guide/dependencies.md): dependencies your app needs on each platfrorm.
- [Scripts](user-guide/scripts.md): the `bun run` scripts that set up, build, run, test and package your app.
- [Claude Code commands](user-guide/claude-code-commands.md): the Claude Code commands every app comes with to help you extend and upgrade your app.
- [Architecture](development/architecture.md): how it all fits together.
