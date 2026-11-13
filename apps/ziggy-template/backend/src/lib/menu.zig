//
// The template's desktop menu. The native app draws it with the platform's own menu API on every desktop platform and never on a mobile.
//
// Each item names what it runs. A `.standard` item is an action the native app does itself (quit, close-window, reload, the zoom and
// editing actions, full screen and the developer tools). A `.zig` item calls a Zig function of the app's on the thread that handles
// messages. A `.ui` item reaches the frontend as the app event {"type": "menu", "item": "<name>"}; each of those has a `.name`. An
// `.action` item runs one of the app's actions (see actions.zig). The Hello menu is the hello world example of a `.zig` item, a
// `.ui` item and an `.action` item. See Ziggy's guide "Menus".
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
                .shortcut = "CmdOrCtrl+W",
                .run = .{
                    .standard = .@"close-window",
                },
            },
            .{
                .label = "Quit",
                .shortcut = "CmdOrCtrl+Q",
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
                .shortcut = "CmdOrCtrl+Z",
                .run = .{
                    .standard = .undo,
                },
            },
            .{
                .label = "Redo",
                .shortcut = "CmdOrCtrl+Shift+Z",
                .run = .{
                    .standard = .redo,
                },
            },
            ziggy.menu.separator,
            .{
                .label = "Cut",
                .shortcut = "CmdOrCtrl+X",
                .run = .{
                    .standard = .cut,
                },
            },
            .{
                .label = "Copy",
                .shortcut = "CmdOrCtrl+C",
                .run = .{
                    .standard = .copy,
                },
            },
            .{
                .label = "Paste",
                .shortcut = "CmdOrCtrl+V",
                .run = .{
                    .standard = .paste,
                },
            },
            .{
                .label = "Select All",
                .shortcut = "CmdOrCtrl+A",
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
                .shortcut = "CmdOrCtrl+R",
                .run = .{
                    .standard = .reload,
                },
            },
            ziggy.menu.separator,
            .{
                .label = "Zoom In",
                .shortcut = "CmdOrCtrl+Plus",
                .run = .{
                    .standard = .@"zoom-in",
                },
            },
            .{
                .label = "Zoom Out",
                .shortcut = "CmdOrCtrl+Minus",
                .run = .{
                    .standard = .@"zoom-out",
                },
            },
            .{
                .label = "Actual Size",
                .shortcut = "CmdOrCtrl+0",
                .run = .{
                    .standard = .@"zoom-reset",
                },
            },
            ziggy.menu.separator,
            .{
                .label = "Toggle Full Screen",
                .shortcut = "F11",
                .run = .{
                    .standard = .@"toggle-fullscreen",
                },
            },
            ziggy.menu.separator,
            .{
                .label = "Toggle Developer Tools",
                .shortcut = "CmdOrCtrl+Shift+I",
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
            // Runs the template's action Say Hello From an Action, whose label and shortcut the item shows.
            .{
                .run = .{
                    .action = "hello-from-action",
                },
            },
        },
    },
};
