//
// The template's desktop menu. Ziggy's shells draw it natively on every desktop platform and never on a phone.
//
// Each item says what it runs. A `.standard` item is an action the native app does itself (quit, close-window, reload, the zoom and
// editing actions, full screen and the developer tools). A `.zig` item calls a Zig function of the app's on the thread that handles
// messages. A `.ui` item reaches the UI as the app event {"type": "menu", "item": "<name>"}; each of those has a `.name`. The
// Hello menu is the hello world example of a `.zig` item and a `.ui` item. See "The menu and the window icon" in Ziggy's guide
// "Building your app".
//

const ziggy = @import("ziggy");
const hello_world = @import("hello-world.zig");

//
// The menu the template passes to ziggy.core.App as `.menu`.
//
pub const menu: []const ziggy.menu.Menu = &.{
    .{
        .label = "File",
        .items = &.{
            .{
                .label = "Close Window",
                .accelerator = "CmdOrCtrl+W",
                .run = .{
                    .standard = .@"close-window",
                },
            },
            .{
                .label = "Quit",
                .accelerator = "CmdOrCtrl+Q",
                .run = .{
                    .standard = .quit,
                },
            },
        },
    },
    .{
        .label = "Edit",
        .items = &.{
            .{
                .label = "Undo",
                .accelerator = "CmdOrCtrl+Z",
                .run = .{
                    .standard = .undo,
                },
            },
            .{
                .label = "Redo",
                .accelerator = "CmdOrCtrl+Shift+Z",
                .run = .{
                    .standard = .redo,
                },
            },
            ziggy.menu.separator,
            .{
                .label = "Cut",
                .accelerator = "CmdOrCtrl+X",
                .run = .{
                    .standard = .cut,
                },
            },
            .{
                .label = "Copy",
                .accelerator = "CmdOrCtrl+C",
                .run = .{
                    .standard = .copy,
                },
            },
            .{
                .label = "Paste",
                .accelerator = "CmdOrCtrl+V",
                .run = .{
                    .standard = .paste,
                },
            },
            .{
                .label = "Select All",
                .accelerator = "CmdOrCtrl+A",
                .run = .{
                    .standard = .@"select-all",
                },
            },
        },
    },
    .{
        .label = "View",
        .items = &.{
            .{
                .label = "Reload",
                .accelerator = "CmdOrCtrl+R",
                .run = .{
                    .standard = .reload,
                },
            },
            ziggy.menu.separator,
            .{
                .label = "Zoom In",
                .accelerator = "CmdOrCtrl+Plus",
                .run = .{
                    .standard = .@"zoom-in",
                },
            },
            .{
                .label = "Zoom Out",
                .accelerator = "CmdOrCtrl+Minus",
                .run = .{
                    .standard = .@"zoom-out",
                },
            },
            .{
                .label = "Actual Size",
                .accelerator = "CmdOrCtrl+0",
                .run = .{
                    .standard = .@"zoom-reset",
                },
            },
            ziggy.menu.separator,
            .{
                .label = "Toggle Full Screen",
                .accelerator = "F11",
                .run = .{
                    .standard = .@"toggle-fullscreen",
                },
            },
            ziggy.menu.separator,
            .{
                .label = "Toggle Developer Tools",
                .accelerator = "CmdOrCtrl+Shift+I",
                .run = .{
                    .standard = .@"toggle-devtools",
                },
            },
        },
    },
    .{
        // Hello world example: change it into your own menu, or delete it.
        .label = "Hello",
        .items = &.{
            .{
                .label = "Say Hello From Zig",
                .name = "hello-from-zig",
                .run = .{
                    .zig = hello_world.helloFromZigMenuItem,
                },
            },
            .{
                .label = "Say Hello From the UI",
                .name = "hello-from-ui",
                .run = .ui,
            },
        },
    },
};
