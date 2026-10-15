# Quick start

The quickest way to see Ziggy working is to setup, build and run the desktop build of the example app. 

This quick start is for Linux, Windows and MacOS, but has only been tested on Linux. If you have feedback on the other platforms please log an issue or submit a PR.

Check the [glossary](glossary.md) to understand the jargon.

## 1. Install the tools

Install [mise](https://mise.jdx.dev), then what your platform needs.

### Linux

Install the libraries the app runs on and the tools its tests use:

```bash
sudo apt install libgtk-3-0 libwebkit2gtk-4.1-0 gstreamer1.0-plugins-good gstreamer1.0-libav xvfb
```

### Windows

Install [Git for Windows](https://gitforwindows.org), add `%LOCALAPPDATA%\mise\shims` to PATH and run every command in Git Bash.

### macOS

Install Xcode.

## 2. Get the example

```bash
git clone https://github.com/ashleydavis/ziggy-example-vite.git
cd ziggy-example-vite
mise trust
mise install
bun install
```

### Other examples:

- [Rsbuild example](https://github.com/ashleydavis/ziggy-example-rsbuild): the UI built with Rsbuild.

## 3. Set up

### Windows

Run `bun run setup`. It downloads the WebView2 SDK and installs Microsoft's C++ build tools. 

### Linux, MacOS

For desktop builds you need nothing else, If you want to run it on Android or iOS run `bun run setup`. It installs the Android SDK, NDK and JDK, and on a Mac checks Xcode for iOS.

## 4. Run it

Run the command for your platform:

```bash
bun run run:linux
bun run run:windows
bun run run:macos
```

This builds the app and opens its window:

![The example app's window: "The backend says: Hello world, from Zig on linux", and the output of the hello world task](images/quick-start-app.png)

To check everything works, `bun run test:smoke` runs the app's smoke test in a hidden window.

## 5. See how it works

### Sending and handling messages

The example app sends the backend a `hello-world` message and shows the response it gets back ([`ui/src/main.ts`](https://github.com/ashleydavis/ziggy-example-vite/blob/main/ui/src/main.ts)):

```ts
async function sayHello(): Promise<void> {
    const request = {
        name: "world",
    };
    const response = 
        await window.ziggy.send<IHelloWorldResponse>(
            "hello-world",
            request,
        );
    element("greeting").textContent = 
        greetingLine(response);
}
```

A Zig function in the backend handles the message and sends back a JSON response ([`backend/src/lib/hello-world-backend.zig`](https://github.com/ashleydavis/ziggy-example-vite/blob/main/backend/src/lib/hello-world-backend.zig)):

```zig
pub fn helloWorldHandler(
    core: *ziggy.core.Core,
    arena: std.mem.Allocator,
    data: std.json.Value,
) anyerror![]const u8 {
    _ = core;
    const name = ziggy.json.getString(data, "name") orelse {
        return error.MissingName;
    };
    return try ziggy.json.stringify(arena, .{
        .greeting = try std.fmt.allocPrint(arena, "Hello {s}, from Zig on {s}", .{
            name,
            @tagName(builtin.os.tag),
        }),
    });
}
```

The backend is compiled native code and runs on every platform, so it is fast and can do what a web page cannot, such as reading and writing files and calling the operating system directly.

The backend registers that function as the handler for `hello-world` messages ([`backend/src/handlers.zig`](https://github.com/ashleydavis/ziggy-example-vite/blob/main/backend/src/handlers.zig)):

```zig
pub const app = ziggy.core.AppHandlers{
    .channels = &[_]ziggy.core.ChannelEntry{
        .{
            .name = "hello-world",
            .handler = hello_world_backend.helloWorldHandler,
        },
    },
    ...
```

### Running background tasks

A message handler runs on the thread that handles every message from the UI, so while it works no other message is handled. That makes it good only for work that completes quickly. 

Anything slower, such as reading files, hashing or talking to the network, belongs in a task: it runs on its own worker thread and does not block the main thread, it can report progress while it runs and can be cancelled.

The example app queues a task when the "Start the hello world task" button is pressed, then shows each event the task sends and how it ends ([`ui/src/main.ts`](https://github.com/ashleydavis/ziggy-example-vite/blob/main/ui/src/main.ts)):

```ts
// Starts the task when the button is pressed.
element("start-task").addEventListener("click", () => {
    const taskId = window.ziggy.addTask({
        taskType: "hello-world-task",
        source: "hello-world",
        data: null,
        priority: "interactive",
    });
});

// Shows each event the task sends while it runs.
window.ziggy.onTaskEvent<ITaskMessageEvent<IOutputMessage>>(
    "task-message",
    event => {
        element("task-output").textContent +=
            `${event.message.text}\n`;
    },
);

// Shows how the task ended.
window.ziggy.onTaskEvent<ITaskCompletedEvent>(
    "task-completed",
    event => {
        element("task-output").textContent +=
            `The task ended: ${event.result.status}\n`;
    },
);
```

A Zig function runs the task on a worker thread, sends the UI an event and completes with a result ([`backend/src/lib/hello-world-backend.zig`](https://github.com/ashleydavis/ziggy-example-vite/blob/main/backend/src/lib/hello-world-backend.zig)):

```zig
pub fn helloWorldTaskHandler(
    context: *TaskContext,
    data: std.json.Value,
) anyerror!?[]const u8 {
    _ = data;
    try context.sendMessage(.{
        .type = "output",
        .text = "Hello world from a task",
    });
    return try context.arena.dupe(u8, "\"hello world task done\"");
}
```

The backend registers that function as the handler for `hello-world-task` tasks ([`backend/src/handlers.zig`](https://github.com/ashleydavis/ziggy-example-vite/blob/main/backend/src/handlers.zig)):

```zig
pub const app = ziggy.core.AppHandlers{
    ...
    .tasks = &[_]ziggy.task_runner.TaskHandlerEntry{
        .{
            .name = "hello-world-task",
            .handler = hello_world_backend.helloWorldTaskHandler,
        },
    },
    ...
```

`window.ziggy.addTask` queues the task and returns the id Ziggy gave it straight away, without waiting for the task to run. Every event the task sends carries that id, and `window.ziggy.onTaskEvent` listens for them.

### Try a change

Change the name in `ui/src/main.ts` or the greeting in `helloWorldHandler` and run the same `bun run run:<platform>` again to see it change.

## Next

- To change the UI and see it update as you save, run `bun run dev` and read [Dev mode](user-guide/building-your-app.md#dev-mode).
- To start an app of your own, use the `/ziggy:new` Claude Code command ([Claude Code commands](user-guide/claude-code-commands.md) says how to get it), or follow the steps in the [user guide](user-guide.md).
