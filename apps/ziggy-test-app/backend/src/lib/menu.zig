//
// The test app's desktop menu. Ziggy's shells draw it natively on every desktop platform and never on a phone.
//
// Each item says what it runs. A `.standard` item is an action the native app does itself (quit, close-window, reload, the zoom and
// editing actions, full screen and the developer tools). A `.zig` item calls a Zig function of the app's on the thread that handles
// messages. A `.ui` item reaches the UI as the app event {"type": "menu", "item": "<name>"}; each of those has a `.name`. The
// Example menu's task items and About are the UI's. Send Event From Zig runs a function in menu-functions.zig. See "Menus" in the
// architecture document.
//

const ziggy = @import("ziggy");
const menu_functions = @import("menu-functions.zig");

//
// The menu the test app passes to ziggy.core.App as `.menu`.
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
        .label = "Example",
        .items = &.{
            .{
                .label = "Start Short Task",
                .name = "start-short",
                .accelerator = "CmdOrCtrl+9",
                .run = .ui,
            },
            .{
                .label = "Start Long Task",
                .name = "start-long",
                .accelerator = "CmdOrCtrl+2",
                .run = .ui,
            },
            .{
                .label = "Start Three Long Tasks",
                .name = "start-many",
                .accelerator = "CmdOrCtrl+3",
                .run = .ui,
            },
            ziggy.menu.separator,
            .{
                .label = "Cancel Long Task",
                .name = "cancel-long",
                .accelerator = "CmdOrCtrl+4",
                .run = .ui,
            },
            ziggy.menu.separator,
            .{
                .label = "Send Event From Zig",
                .name = "zig-event",
                .run = .{
                    .zig = menu_functions.sendZigEvent,
                },
            },
        },
    },
    .{
        .label = "Help",
        .items = &.{
            .{
                .label = "About Ziggy Test App",
                .name = "about",
                .run = .ui,
            },
        },
    },
};
