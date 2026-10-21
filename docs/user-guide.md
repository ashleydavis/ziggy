# User guide

This guide is for building an app on Ziggy. If try Ziggy quickly, start with the [quick start](quick-start.md).

To create your own Ziggy app with an AI coding agent, such as Claude Code, start the agent in the empty directory the app will go in and tell it:

> Make a new Ziggy app here by following https://github.com/ashleydavis/ziggy/blob/main/docs/agent-quick-start.md

Otherwise follow [Building your app](user-guide/building-your-app.md).

Check the [glossary](glossary.md) to understand the jargon.

## The directory structure of an app

An app is one project with three directories:

- `ui/`: the UI, an ordinary web page in JavaScript/TypeScript, HTML and CSS, built by whatever bundler you like.
- `backend/`: the backend, the app's Zig code. Every message the UI sends is handled by the Zig function the app registered for its name, its message handler, and anything slow is a task, which runs on its own thread, reports progress and can be cancelled.
- `native/`: the native app for each platform, which opens the window and shows the UI. Ziggy provides most of it, and the app's own part holds its name, window, icon, permissions and anything only the operating system can do.

## Examples

Complete apps built on Ziggy:

- [Vite example](https://github.com/ashleydavis/ziggy-example-vite): the UI built with Vite.
- [Rsbuild example](https://github.com/ashleydavis/ziggy-example-rsbuild): the UI built with Rsbuild.

## The guides

Read the guides in this order:

1. [Building your app](user-guide/building-your-app.md): how to build your app on Ziggy.
2. [Messages](user-guide/messages.md): how to send JSON messages between frontend and backend.
3. [Tasks](user-guide/tasks.md): how to run background tasks that don't block the UI.
4. [Native calls](user-guide/native-calls.md): file dialogs and calls into your own native code.
5. [Testing your app](user-guide/testing.md): unit tests, smoke tests and the test hooks.
6. [Distributing your app](user-guide/distributing-your-app.md): packaging, signing and getting a build to testers and stores, on each platform.

Also:

- [Dependencies](user-guide/dependencies.md): what an app needs on each platform, what each dependency is and why.
- [Scripts](user-guide/scripts.md): the `bun run` scripts that set up, build, run, test and package your app.
- [Claude Code commands](user-guide/claude-code-commands.md): the Claude Code commands every app comes with, to check it, add messages and tasks to it and move it to a newer Ziggy.
- [Architecture](development/architecture.md): how it all fits together.
