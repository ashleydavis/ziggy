# User guide

This guide is for building an app on Ziggy. If you have not run Ziggy yet, start with the [quick start](quick-start.md). The words "the UI", "the backend" and "the native app" are defined in the [glossary](glossary.md).

To start an app of your own, use the `/ziggy:new` Claude Code command, which pins it to Ziggy's latest release. [Claude Code commands](claude-code-commands.md) says how to get it. Without the command, follow [Building your app](building-your-app.md).

## What an app looks like

An app is three parts in one folder:

- `ui/`: the UI, an ordinary web page in TypeScript and HTML, built by any bundler.
- `backend/`: the backend, the app's Zig code. Each thing the UI can ask for is a Zig function registered under a channel's name, and anything slow is a task, which runs on its own thread, reports progress and can be cancelled.
- `shells/`: the native app for each platform, which opens the window and shows the UI. Ziggy provides most of it, and the app's own part holds its name, window, icon, permissions and anything only the operating system can do.

The UI sends the backend a message with one call, `window.ziggy.invoke("<channel>", data)`, and gets the Zig function's message response back. The [quick start](quick-start.md#4-see-how-it-works) walks through one request from the UI to the Zig function and back, in an example app.

## Examples

Complete apps built on a released version of Ziggy:

- [Vite example](https://github.com/ashleydavis/ziggy-example-vite): the UI built with Vite.
- [Rsbuild example](https://github.com/ashleydavis/ziggy-example-rsbuild): the UI built with Rsbuild.

## The guides

Read the guides in this order:

1. [Building your app](building-your-app.md): starting a new app from the template, the parts of an app and dev mode.
2. [Integrating Ziggy](integrating-ziggy.md): the lines an app adds to use Ziggy, from a local path or from a version tag, and how to move to a newer tag.
3. [Channels](channels.md): how the UI sends the backend a message and gets its message response.
4. [Tasks](tasks.md): how the task queue works, with a diagram, and how to write, register, queue, follow and cancel a task.
5. [Distributing your app](distributing-your-app.md): packaging, signing and getting a build to testers and stores, on each platform.

Also:

- [Dependencies](dependencies.md): what an app needs on each platform, what each dependency is and why.
- [Commands](commands.md): every command an app has, and the ones in Ziggy's repository.
- [Claude Code commands](claude-code-commands.md): the slash commands that start a new app on Ziggy, check it, add channels and tasks to it and move it to a newer Ziggy, and how to install them.
- [Architecture](architecture.md): how the parts fit, the message protocol, tasks, channels, native calls, menus and test hooks.
- [The dev host's README](../packages/ziggy/dev/README.md): what dev mode can and cannot do.

Nothing of Ziggy's is published to npm or any other registry. An app takes Ziggy either from a checkout of the Ziggy repository, by a local path, or from a version tag of the repository, by its git URL.
