# Quick start

The quickest way to see Ziggy working is to run one of the example apps, which take Ziggy from a released version. These steps are for Linux. Windows and macOS need different tools, listed in [Dependencies](dependencies.md).

## 1. Install the tools

Install [mise](https://mise.jdx.dev).

Install the libraries the app runs on and the tools its tests use:

```bash
sudo apt install libgtk-3-0 libwebkit2gtk-4.1-0 gstreamer1.0-plugins-good gstreamer1.0-libav xvfb
```

## 2. Get the example

```bash
git clone https://github.com/ashleydavis/ziggy-example-vite.git
cd ziggy-example-vite
mise trust
mise install
bun install
```

These steps use the Vite example. Each example has the same commands, so any of them can take its place:

- [Vite example](https://github.com/ashleydavis/ziggy-example-vite): the UI built with Vite.
- [Rsbuild example](https://github.com/ashleydavis/ziggy-example-rsbuild): the UI built with Rsbuild.

## 3. Run it

```bash
bun run run:linux
```

This builds the app and opens its window. The app is a hello world: one message the UI sends to the Zig code, and one task.

To check everything works, `bun run test:smoke` runs the app's smoke test in a hidden window.

## 4. See how it works

The line under the heading, which starts "The backend says:", is the UI sending the `hello-world` message to the Zig code and showing its answer. It takes three pieces of code.

The UI sends the message and waits for the answer (`ui/src/main.ts`):

```ts
async function sayHello(): Promise<void> {
    const response = await window.ziggy.invoke<IHelloWorldResponse>("hello-world", {
        name: "world",
    });
    element("greeting").textContent = greetingLine(response);
}
```

A Zig function answers it with JSON (`backend/src/lib/hello-world-backend.zig`):

```zig
pub fn helloWorldHandler(core: *ziggy.core.Core, arena: std.mem.Allocator, data: std.json.Value) anyerror![]const u8 {
    _ = core;
    const name = ziggy.json_util.getString(data, "name") orelse {
        return error.MissingName;
    };
    return try ziggy.json_util.stringify(arena, .{
        .greeting = try std.fmt.allocPrint(arena, "Hello {s}, from Zig on {s}", .{
            name,
            @tagName(builtin.os.tag),
        }),
    });
}
```

The app tells Ziggy which function handles which message (`backend/src/handlers.zig`):

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

The button below it starts the `hello-world-task` task, which is in the same Zig file: slow work runs as a task, which reports back while it runs. Change the name in `ui/src/main.ts` or the greeting in `helloWorldHandler` and run `bun run run:linux` again to see it change.

## Next

- To change the UI and see it update as you save, run `bun run dev` and read [Dev mode](building-your-app.md#dev-mode).
- To start an app of your own, use the `/ziggy:new` Claude Code command ([Claude Code commands](claude-code-commands.md) says how to get it), or follow the steps in the [user guide](user-guide.md).
